# ===----------------------------------------------------------------------=== #
# Mojo Mac Playground — P1: editor + run.
#
# A native macOS editor for Mojo, written in Mojo. Type code in the top pane,
# hit ⌘R, and the bottom pane streams the program's output. Syntax highlighting
# is a Mojo tokenizer painting NSTextStorage attributes; running is an NSTask
# whose pipes are drained by an NSTimer on the main thread, so a program that
# hangs or crashes cannot take the editor with it.
#
# Every AppKit call goes through std.objc: selector, dispatch stub, argument
# count and register file all checked at compile time against the SDK.
# ===----------------------------------------------------------------------=== #

from std.objc import (
    ObjCClass,
    ObjCObject,
    msg_send,
    send,
    nsstring,
    extern_object,
    autoreleasepool,
    ObjCClassBuilder,
    new_instance,
    named_global,
    sel,
)
from std.ffi import external_call, c_char
from std.memory import OpaquePointer, Pointer
from std.os import getenv
from std.collections.string.string_span import StringSlice, _get_kgen_string
from highlight import (
    tokenize,
    TOK_KEYWORD,
    TOK_STRING,
    TOK_COMMENT,
    TOK_NUMBER,
    TOK_DECORATOR,
    TOK_TYPE,
)

comptime P = OpaquePointer[MutUntrackedOrigin]

comptime WIN_W = 1000.0
comptime WIN_H = 720.0
comptime EDITOR_FRAC = 0.62


@fieldwise_init
struct CGPoint(Copyable, Movable):
    var x: Float64
    var y: Float64


@fieldwise_init
struct CGSize(Copyable, Movable):
    var width: Float64
    var height: Float64


@fieldwise_init
struct CGRect(Copyable, Movable):
    var origin: CGPoint
    var size: CGSize


@fieldwise_init
struct NSRange(Copyable, Movable):
    var location: Int
    var length: Int


# ── App state (callbacks get no closure, so it lives in named globals) ────────
comptime g_editor = named_global["pg.editor", Int]
comptime g_output = named_global["pg.output", Int]
comptime g_window = named_global["pg.window", Int]
comptime g_actions = named_global["pg.actions", Int]
comptime g_task = named_global["pg.task", Int]
comptime g_read_fd = named_global["pg.readfd", Int]
comptime g_running = named_global["pg.running", Int]
comptime g_path = named_global["pg.path", Int]  # heap C string, or 0
comptime g_errslot = named_global["pg.errslot", Int]  # NSError** out-param sink


@always_inline
def err_out() -> P:
    """A writable slot for an `NSError **` argument we do not inspect. Mojo's
    Pointer is non-nullable, so this stands in for NULL."""
    return P(unsafe_from_address=Int(g_errslot()))



# A libc call whose name the stdlib already declares with a different
# signature (`read`) cannot go through external_call -- one LLVM declaration
# per symbol name, so the second signature collides. Same fix as objc_msgSend:
# reference the symbol and call it through a per-signature pointer cast.
@always_inline
def _sym[name: StaticString]() -> P:
    return P(
        _mlir_value=__mlir_op.`pop.extern_ptr_symbol`[
            name=_get_kgen_string[name](),
            alignment=Int(1).__mlir_index__(),
            _type=P._mlir_type,
        ]()
    )


@always_inline
def posix_read(fd: Int, buf: P, count: Int) -> Int:
    var sym = _sym["read"]()
    var call = Pointer(to=sym).unsafe_bitcast[
        def(Int, P, Int, /) thin abi("C") -> Int
    ]()[]
    return call(fd, buf, count)


@always_inline
def set_nonblocking(fd: Int):
    # fcntl(fd, F_SETFL(4), O_NONBLOCK(4))
    var sym = _sym["fcntl"]()
    var call = Pointer(to=sym).unsafe_bitcast[
        def(Int, Int, Int, /) thin abi("C") -> Int
    ]()[]
    _ = call(fd, Int(4), Int(4))


# ── Cocoa helpers ────────────────────────────────────────────────────────────


def ns_to_string(s: ObjCObject) -> String:
    if s.is_nil():
        return String("")
    var p = msg_send[P, "NSString", "UTF8String"](s)
    if Int(p) == 0:
        return String("")
    return String(unsafe_from_utf8_ptr=p.unsafe_bitcast[c_char]())


def color(r: Float64, g: Float64, b: Float64) -> ObjCObject:
    return msg_send[
        ObjCObject, "NSColor", "colorWithRed:green:blue:alpha:", is_class=True
    ](ObjCClass.lookup["NSColor"]().as_object(), r, g, b, Float64(1.0))


def mono_font(size: Float64) -> ObjCObject:
    var f = msg_send[
        ObjCObject, "NSFont", "fontWithName:size:", is_class=True
    ](
        ObjCClass.lookup["NSFont"]().as_object(),
        nsstring(String("Menlo")).ptr(),
        size,
    )
    return f


def kind_color(kind: Int) -> ObjCObject:
    # A calm dark-background palette; plain text is the default colour.
    if kind == TOK_KEYWORD:
        return color(0.83, 0.48, 0.72)  # magenta
    if kind == TOK_STRING:
        return color(0.60, 0.78, 0.44)  # green
    if kind == TOK_COMMENT:
        return color(0.45, 0.50, 0.56)  # grey
    if kind == TOK_NUMBER:
        return color(0.88, 0.68, 0.35)  # amber
    if kind == TOK_DECORATOR:
        return color(0.45, 0.72, 0.88)  # blue
    if kind == TOK_TYPE:
        return color(0.40, 0.78, 0.76)  # teal
    return color(0.85, 0.87, 0.90)



def utf16_offsets(source: StringSlice) -> List[Int]:
    """Map every UTF-8 byte offset to its UTF-16 code-unit offset.

    The tokenizer works in bytes; NSTextStorage ranges are UTF-16 units. They
    agree only for ASCII, so one `⌘` in a comment is enough to push every later
    range past the end and raise NSRangeException. Returns n+1 entries so a
    span's end offset maps too.
    """
    var b = source.as_bytes()
    var n = len(b)
    var map = List[Int](length=n + 1, fill=0)
    var u16 = 0
    var i = 0
    while i < n:
        var c = b[i]
        var size = 1
        var units = 1
        if c >= UInt8(0xF0):
            size = 4
            units = 2  # astral: a surrogate pair
        elif c >= UInt8(0xE0):
            size = 3
        elif c >= UInt8(0xC0):
            size = 2
        for k in range(size):
            if i + k <= n:
                map[i + k] = u16
        u16 += units
        i += size
    map[n] = u16
    return map^


def highlight_editor():
    """Re-colour the whole buffer. Fast enough at playground sizes; P3 swaps in
    LSP semantic tokens and per-paragraph updates."""
    with autoreleasepool():
        var editor = ObjCObject(g_editor()[])
        var storage = msg_send[ObjCObject, "NSTextView", "textStorage"](editor)
        var source = ns_to_string(
            msg_send[ObjCObject, "NSTextView", "string"](editor)
        )
        # NSString length is in UTF-16 units, as are all text ranges.
        var total = msg_send[Int, "NSString", "length"](
            msg_send[ObjCObject, "NSTextView", "string"](editor)
        )
        var u16 = utf16_offsets(source)

        var fg = extern_object["NSForegroundColorAttributeName"]()
        _ = msg_send[ObjCObject, "NSTextStorage", "beginEditing"](storage)
        # Default colour first, then the spans on top.
        _ = msg_send[
            ObjCObject, "NSTextStorage", "addAttribute:value:range:"
        ](storage, fg.ptr(), kind_color(-1).ptr(), NSRange(0, total))

        var spans = tokenize(source)
        for i in range(len(spans)):
            var s = spans[i].copy()
            _ = msg_send[
                ObjCObject, "NSTextStorage", "addAttribute:value:range:"
            ](
                storage,
                fg.ptr(),
                kind_color(s.kind).ptr(),
                NSRange(u16[s.start], u16[s.end] - u16[s.start]),
            )
        _ = msg_send[ObjCObject, "NSTextStorage", "endEditing"](storage)


comptime OUT_NORMAL = 0
comptime OUT_COMMAND = 1
comptime OUT_STATUS = 2
comptime OUT_ERROR = 3


def out_color(kind: Int) -> ObjCObject:
    if kind == OUT_COMMAND:
        return color(0.45, 0.72, 0.88)  # blue: the command we ran
    if kind == OUT_STATUS:
        return color(0.55, 0.60, 0.66)  # grey: exit status, notices
    if kind == OUT_ERROR:
        return color(0.90, 0.45, 0.42)  # red
    return color(0.85, 0.87, 0.90)  # program output


def append_output(text: String, kind: Int = OUT_NORMAL):
    """Append to the output pane in a visible colour.

    Text appended through the storage's mutableString carries no attributes and
    renders in the default black -- invisible on this background -- so the
    appended range is coloured explicitly.
    """
    with autoreleasepool():
        var out = ObjCObject(g_output()[])
        var storage = msg_send[ObjCObject, "NSTextView", "textStorage"](out)
        var start = msg_send[Int, "NSTextStorage", "length"](storage)

        _ = msg_send[ObjCObject, "NSTextStorage", "beginEditing"](storage)
        var mutable_str = msg_send[
            ObjCObject, "NSTextStorage", "mutableString"
        ](storage)
        _ = send[ObjCObject, "appendString:"](
            mutable_str, nsstring(text).ptr()
        )
        var end = msg_send[Int, "NSTextStorage", "length"](storage)
        if end > start:
            _ = msg_send[
                ObjCObject, "NSTextStorage", "addAttribute:value:range:"
            ](
                storage,
                extern_object["NSForegroundColorAttributeName"]().ptr(),
                out_color(kind).ptr(),
                NSRange(start, end - start),
            )
            _ = msg_send[
                ObjCObject, "NSTextStorage", "addAttribute:value:range:"
            ](
                storage,
                extern_object["NSFontAttributeName"]().ptr(),
                mono_font(12.0).ptr(),
                NSRange(start, end - start),
            )
        _ = msg_send[ObjCObject, "NSTextStorage", "endEditing"](storage)
        _ = msg_send[ObjCObject, "NSTextView", "scrollRangeToVisible:"](
            out, NSRange(end, 0)
        )


def set_output(text: String):
    with autoreleasepool():
        var out = ObjCObject(g_output()[])
        _ = msg_send[ObjCObject, "NSTextView", "setString:"](
            out, nsstring(text).ptr()
        )


# ── Running ──────────────────────────────────────────────────────────────────


def source_path() -> String:
    """Where the buffer is written for a run: the open document, else a temp
    file that persists for the session."""
    var p = g_path()[]
    if p != 0:
        return String(
            unsafe_from_utf8_ptr=P(unsafe_from_address=p).unsafe_bitcast[
                c_char
            ]()
        )
    return String("/tmp/mojo-playground-scratch.mojo")


def save_buffer_to(path: String) raises:
    with autoreleasepool():
        var editor = ObjCObject(g_editor()[])
        var text = msg_send[ObjCObject, "NSTextView", "string"](editor)
        # -[NSString writeToFile:atomically:encoding:error:] (NSUTF8 = 4)
        var ok = msg_send[
            Bool, "NSString", "writeToFile:atomically:encoding:error:"
        ](text, nsstring(path).ptr(), True, Int(4), err_out())
        if not ok:
            raise Error("could not write " + path)


def start_run(gpu: Bool) raises:
    if g_running()[] != 0:
        append_output(
            String("[already running — Stop first]\n"), OUT_STATUS
        )
        return

    var path = source_path()
    save_buffer_to(path)
    set_output(String(""))
    append_output(
        String("$ mojo run ")
        + (String("--target-accelerator=metal-vega2 ") if gpu else String(""))
        + path
        + "\n",
        OUT_COMMAND,
    )

    with autoreleasepool():
        # Arguments: mojo run [--target-accelerator=...] <path>
        var args = msg_send[
            ObjCObject, "NSMutableArray", "array", is_class=True
        ](ObjCClass.lookup["NSMutableArray"]().as_object())
        _ = msg_send[ObjCObject, "NSMutableArray", "addObject:"](
            args, nsstring(String("run")).ptr()
        )
        if gpu:
            _ = msg_send[ObjCObject, "NSMutableArray", "addObject:"](
                args,
                nsstring(String("--target-accelerator=metal-vega2")).ptr(),
            )
        _ = msg_send[ObjCObject, "NSMutableArray", "addObject:"](
            args, nsstring(path).ptr()
        )

        var task = msg_send[ObjCObject, "NSTask", "alloc", is_class=True](
            ObjCClass.lookup["NSTask"]().as_object()
        )
        task = msg_send[ObjCObject, "NSObject", "init"](task)
        _ = msg_send[ObjCObject, "NSTask", "setLaunchPath:"](
            task, nsstring(String(MOJO_BIN)).ptr()
        )
        _ = msg_send[ObjCObject, "NSTask", "setArguments:"](task, args.ptr())

        var pipe = msg_send[ObjCObject, "NSPipe", "pipe", is_class=True](
            ObjCClass.lookup["NSPipe"]().as_object()
        )
        _ = msg_send[ObjCObject, "NSTask", "setStandardOutput:"](
            task, pipe.ptr()
        )
        _ = msg_send[ObjCObject, "NSTask", "setStandardError:"](
            task, pipe.ptr()
        )

        var handle = msg_send[
            ObjCObject, "NSPipe", "fileHandleForReading"
        ](pipe)
        var fd = msg_send[Int, "NSFileHandle", "fileDescriptor"](handle)
        # Non-blocking, so the timer can poll without ever stalling the UI.
        set_nonblocking(fd)

        # Retain the task and pipe for the run's lifetime.
        _ = external_call["objc_retain", P](task.ptr())
        _ = external_call["objc_retain", P](pipe.ptr())
        g_task()[] = task.addr()
        g_read_fd()[] = fd
        g_running()[] = 1

        _ = msg_send[ObjCObject, "NSTask", "launch"](task)


def drain_output():
    """Read whatever the child has produced, without blocking."""
    var fd = g_read_fd()[]
    if fd == 0:
        return
    var buf = List[UInt8](length=4096, fill=0)
    while True:
        var n = posix_read(
            fd,
            P(unsafe_from_address=Int(buf.unsafe_ptr())),
            Int(4095),
        )
        if n <= 0:
            break
        buf[n] = 0
        var chunk = String(
            unsafe_from_utf8_ptr=buf.unsafe_ptr().bitcast[c_char]()
        )
        append_output(filter_noise(chunk))


def filter_noise(chunk: String) -> String:
    """Drop the toolchain's benign Crashpad notice.

    `Failed to initialize Crashpad...` is printed by the SDK's mojo driver
    whenever it cannot find its crash handler. The program runs correctly
    regardless -- but shown in an output pane it reads exactly like a crash,
    so it is filtered here rather than alarming the user.
    """
    if "Crashpad" not in chunk:
        return chunk
    var kept = String("")
    for line in chunk.split("\n"):
        if "Crashpad" in line:
            continue
        kept += line + "\n"
    return kept


def check_finished():
    if g_running()[] == 0:
        return
    var task = ObjCObject(g_task()[])
    var still = msg_send[Bool, "NSTask", "isRunning"](task)
    if still:
        return
    drain_output()  # last bytes after exit
    var status = msg_send[Int32, "NSTask", "terminationStatus"](task)
    append_output(
        String("[exit ") + String(Int(status)) + "]\n",
        OUT_STATUS if status == 0 else OUT_ERROR,
    )
    g_running()[] = 0
    g_read_fd()[] = 0


# ── Callbacks ────────────────────────────────────────────────────────────────


def on_run(self_: P, cmd: P, sender: P) abi("C"):
    try:
        start_run(False)
    except e:
        append_output(
            String("[playground error: ") + String(e) + "]\n", OUT_ERROR
        )


def on_run_gpu(self_: P, cmd: P, sender: P) abi("C"):
    try:
        start_run(True)
    except e:
        append_output(
            String("[playground error: ") + String(e) + "]\n", OUT_ERROR
        )


def on_stop(self_: P, cmd: P, sender: P) abi("C"):
    if g_running()[] != 0:
        var task = ObjCObject(g_task()[])
        _ = msg_send[ObjCObject, "NSTask", "terminate"](task)
        append_output(String("[stopped]\n"), OUT_STATUS)


def on_tick(self_: P, cmd: P, timer: P) abi("C"):
    drain_output()
    check_finished()


def on_text_changed(self_: P, cmd: P, note: P) abi("C"):
    highlight_editor()


def on_open(self_: P, cmd: P, sender: P) abi("C"):
    with autoreleasepool():
        var panel = msg_send[
            ObjCObject, "NSOpenPanel", "openPanel", is_class=True
        ](ObjCClass.lookup["NSOpenPanel"]().as_object())
        var rc = msg_send[Int, "NSSavePanel", "runModal"](panel)
        if rc != 1:
            return
        var url = msg_send[ObjCObject, "NSSavePanel", "URL"](panel)
        var path = ns_to_string(msg_send[ObjCObject, "NSURL", "path"](url))
        var loaded = msg_send[
            ObjCObject,
            "NSString",
            "stringWithContentsOfFile:encoding:error:",
            is_class=True,
        ](
            ObjCClass.lookup["NSString"]().as_object(),
            nsstring(path).ptr(),
            Int(4),
            err_out(),
        )
        if not loaded.is_nil():
            var editor = ObjCObject(g_editor()[])
            _ = msg_send[ObjCObject, "NSTextView", "setString:"](
                editor, loaded.ptr()
            )
            g_path()[] = Int(
                external_call["strdup", P](path.as_c_string_slice())
            )
            _ = msg_send[ObjCObject, "NSWindow", "setTitle:"](
                ObjCObject(g_window()[]),
                nsstring(String("Mojo Playground — ") + path).ptr(),
            )
            highlight_editor()
        else:
            append_output(String("[open failed: ") + path + "]\n", OUT_ERROR)


def on_save(self_: P, cmd: P, sender: P) abi("C"):
    try:
        var path = source_path()
        if g_path()[] == 0:
            with autoreleasepool():
                var panel = msg_send[
                    ObjCObject, "NSSavePanel", "savePanel", is_class=True
                ](ObjCClass.lookup["NSSavePanel"]().as_object())
                var rc = msg_send[Int, "NSSavePanel", "runModal"](panel)
                if rc != 1:
                    return
                var url = msg_send[ObjCObject, "NSSavePanel", "URL"](panel)
                path = ns_to_string(
                    msg_send[ObjCObject, "NSURL", "path"](url)
                )
                g_path()[] = Int(
                    external_call["strdup", P](path.as_c_string_slice())
                )
        save_buffer_to(path)
        append_output(String("[saved ") + path + "]\n", OUT_STATUS)
    except e:
        append_output(String("[save failed: ") + String(e) + "]\n", OUT_ERROR)


def should_terminate(self_: P, cmd: P, app: P) abi("C") -> Bool:
    return True


# ── Building the UI ──────────────────────────────────────────────────────────


comptime MOJO_BIN = "/Volumes/S/mojo/vega-sdk/bin/mojo"

comptime STARTER = """# Welcome to the Mojo Mac Playground.
#
#   ⌘R   run on the CPU
#   ⇧⌘R  run on the Radeon Pro Vega II
#   ⌘O / ⌘S   open / save
from std.time import perf_counter_ns


def main():
    var total = 0
    for i in range(1_000_000):
        total += i
    print("sum of the first million integers:", total)
"""


def make_text_view(frame: CGRect, editable: Bool) -> ObjCObject:
    var tv = msg_send[ObjCObject, "NSTextView", "alloc", is_class=True](
        ObjCClass.lookup["NSTextView"]().as_object()
    )
    tv = msg_send[ObjCObject, "NSTextView", "initWithFrame:"](tv, frame)
    _ = msg_send[ObjCObject, "NSTextView", "setFont:"](
        tv, mono_font(13.0).ptr()
    )
    _ = msg_send[ObjCObject, "NSTextView", "setBackgroundColor:"](
        tv, color(0.09, 0.10, 0.12).ptr()
    )
    _ = msg_send[ObjCObject, "NSTextView", "setTextColor:"](
        tv, color(0.85, 0.87, 0.90).ptr()
    )
    _ = msg_send[ObjCObject, "NSTextView", "setInsertionPointColor:"](
        tv, color(0.95, 0.95, 0.95).ptr()
    )
    _ = msg_send[ObjCObject, "NSTextView", "setEditable:"](tv, editable)
    _ = msg_send[ObjCObject, "NSTextView", "setRichText:"](tv, False)
    # Code, not prose: no smart quotes, dashes or autocorrect.
    _ = msg_send[
        ObjCObject, "NSTextView", "setAutomaticQuoteSubstitutionEnabled:"
    ](tv, False)
    _ = msg_send[
        ObjCObject, "NSTextView", "setAutomaticDashSubstitutionEnabled:"
    ](tv, False)
    _ = msg_send[
        ObjCObject, "NSTextView", "setAutomaticTextReplacementEnabled:"
    ](tv, False)
    _ = msg_send[ObjCObject, "NSView", "setAutoresizingMask:"](tv, Int(18))
    return tv


def scroll_wrapping(view: ObjCObject, frame: CGRect) -> ObjCObject:
    var sv = msg_send[ObjCObject, "NSScrollView", "alloc", is_class=True](
        ObjCClass.lookup["NSScrollView"]().as_object()
    )
    sv = msg_send[ObjCObject, "NSScrollView", "initWithFrame:"](sv, frame)
    _ = msg_send[ObjCObject, "NSScrollView", "setHasVerticalScroller:"](
        sv, True
    )
    _ = msg_send[ObjCObject, "NSScrollView", "setDocumentView:"](
        sv, view.ptr()
    )
    _ = msg_send[ObjCObject, "NSView", "setAutoresizingMask:"](sv, Int(18))
    return sv


def menu_item(
    title: String, selector: StaticString, key: String, mask: Int
) -> ObjCObject:
    var item = msg_send[ObjCObject, "NSMenuItem", "alloc", is_class=True](
        ObjCClass.lookup["NSMenuItem"]().as_object()
    )
    item = msg_send[
        ObjCObject, "NSMenuItem", "initWithTitle:action:keyEquivalent:"
    ](item, nsstring(title).ptr(), sel_for(selector), nsstring(key).ptr())
    if mask != 0:
        _ = msg_send[ObjCObject, "NSMenuItem", "setKeyEquivalentModifierMask:"](
            item, mask
        )
    return item


def sel_for(name: StaticString) -> P:
    return external_call["sel_registerName", P](name.unsafe_ptr())


def build_menu(app: ObjCObject, actions: ObjCObject):
    """A minimal menu bar: an app menu (so ⌘Q works) and a Run menu."""
    var NSMenu = ObjCClass.lookup["NSMenu"]()
    var NSMenuItem = ObjCClass.lookup["NSMenuItem"]()

    var main_menu = msg_send[ObjCObject, "NSMenu", "alloc", is_class=True](
        NSMenu.as_object()
    )
    main_menu = msg_send[ObjCObject, "NSMenu", "initWithTitle:"](
        main_menu, nsstring(String("MainMenu")).ptr()
    )

    # App menu.
    var app_item = msg_send[ObjCObject, "NSMenuItem", "alloc", is_class=True](
        NSMenuItem.as_object()
    )
    app_item = msg_send[ObjCObject, "NSObject", "init"](app_item)
    _ = msg_send[ObjCObject, "NSMenu", "addItem:"](main_menu, app_item.ptr())
    var app_menu = msg_send[ObjCObject, "NSMenu", "alloc", is_class=True](
        NSMenu.as_object()
    )
    app_menu = msg_send[ObjCObject, "NSMenu", "initWithTitle:"](
        app_menu, nsstring(String("Playground")).ptr()
    )
    var quit = menu_item(String("Quit"), "terminate:", String("q"), 0)
    _ = msg_send[ObjCObject, "NSMenu", "addItem:"](app_menu, quit.ptr())
    _ = msg_send[ObjCObject, "NSMenuItem", "setSubmenu:"](
        app_item, app_menu.ptr()
    )

    # File menu.
    var file_item = msg_send[ObjCObject, "NSMenuItem", "alloc", is_class=True](
        NSMenuItem.as_object()
    )
    file_item = msg_send[ObjCObject, "NSObject", "init"](file_item)
    _ = msg_send[ObjCObject, "NSMenu", "addItem:"](main_menu, file_item.ptr())
    var file_menu = msg_send[ObjCObject, "NSMenu", "alloc", is_class=True](
        NSMenu.as_object()
    )
    file_menu = msg_send[ObjCObject, "NSMenu", "initWithTitle:"](
        file_menu, nsstring(String("File")).ptr()
    )
    for spec in [
        (String("Open…"), StaticString("pgOpen:"), String("o")),
        (String("Save"), StaticString("pgSave:"), String("s")),
    ]:
        var it = menu_item(spec[0], spec[1], spec[2], 0)
        _ = msg_send[ObjCObject, "NSMenuItem", "setTarget:"](
            it, actions.ptr()
        )
        _ = msg_send[ObjCObject, "NSMenu", "addItem:"](file_menu, it.ptr())
    _ = msg_send[ObjCObject, "NSMenuItem", "setSubmenu:"](
        file_item, file_menu.ptr()
    )

    # Run menu.
    var run_item = msg_send[ObjCObject, "NSMenuItem", "alloc", is_class=True](
        NSMenuItem.as_object()
    )
    run_item = msg_send[ObjCObject, "NSObject", "init"](run_item)
    _ = msg_send[ObjCObject, "NSMenu", "addItem:"](main_menu, run_item.ptr())
    var run_menu = msg_send[ObjCObject, "NSMenu", "alloc", is_class=True](
        NSMenu.as_object()
    )
    run_menu = msg_send[ObjCObject, "NSMenu", "initWithTitle:"](
        run_menu, nsstring(String("Run")).ptr()
    )
    var r1 = menu_item(String("Run"), "pgRun:", String("r"), 0)
    _ = msg_send[ObjCObject, "NSMenuItem", "setTarget:"](r1, actions.ptr())
    _ = msg_send[ObjCObject, "NSMenu", "addItem:"](run_menu, r1.ptr())
    # ⇧⌘R : NSEventModifierFlagShift(1<<17) | Command(1<<20)
    var r2 = menu_item(
        String("Run on Vega II"), "pgRunGPU:", String("R"), 131072 + 1048576
    )
    _ = msg_send[ObjCObject, "NSMenuItem", "setTarget:"](r2, actions.ptr())
    _ = msg_send[ObjCObject, "NSMenu", "addItem:"](run_menu, r2.ptr())
    var r3 = menu_item(String("Stop"), "pgStop:", String("."), 0)
    _ = msg_send[ObjCObject, "NSMenuItem", "setTarget:"](r3, actions.ptr())
    _ = msg_send[ObjCObject, "NSMenu", "addItem:"](run_menu, r3.ptr())
    _ = msg_send[ObjCObject, "NSMenuItem", "setSubmenu:"](
        run_item, run_menu.ptr()
    )

    _ = msg_send[ObjCObject, "NSApplication", "setMainMenu:"](
        app, main_menu.ptr()
    )


def main() raises:
    with autoreleasepool():
        var NSApplication = ObjCClass.lookup["NSApplication"]()
        var app = msg_send[
            ObjCObject, "NSApplication", "sharedApplication", is_class=True
        ](NSApplication.as_object())
        _ = msg_send[Bool, "NSApplication", "setActivationPolicy:"](app, Int(0))

        # Delegate: quit when the window closes.
        var db = ObjCClassBuilder("PlaygroundDelegate")
        db.add_method["applicationShouldTerminateAfterLastWindowClosed:"](
            should_terminate
        )
        var delegate = new_instance(db^.register())
        _ = msg_send[ObjCObject, "NSApplication", "setDelegate:"](
            app, delegate.ptr()
        )

        # Actions target: menus, timer and the text-view delegate.
        var ab = ObjCClassBuilder("PlaygroundActions")
        ab.add_method["pgRun:", encoding="v@:@"](on_run)
        ab.add_method["pgRunGPU:", encoding="v@:@"](on_run_gpu)
        ab.add_method["pgStop:", encoding="v@:@"](on_stop)
        ab.add_method["pgOpen:", encoding="v@:@"](on_open)
        ab.add_method["pgSave:", encoding="v@:@"](on_save)
        ab.add_method["pgTick:", encoding="v@:@"](on_tick)
        ab.add_method["textDidChange:"](on_text_changed)
        var actions = new_instance(ab^.register())
        _ = external_call["objc_retain", P](actions.ptr())
        g_actions()[] = actions.addr()

        # Window.
        var win = msg_send[ObjCObject, "NSWindow", "alloc", is_class=True](
            ObjCClass.lookup["NSWindow"]().as_object()
        )
        win = msg_send[
            ObjCObject,
            "NSWindow",
            "initWithContentRect:styleMask:backing:defer:",
        ](
            win,
            CGRect(CGPoint(80.0, 80.0), CGSize(WIN_W, WIN_H)),
            Int(15),
            Int(2),
            Bool(False),
        )
        _ = msg_send[ObjCObject, "NSWindow", "setTitle:"](
            win, nsstring(String("Mojo Playground")).ptr()
        )
        g_window()[] = win.addr()
        var content = msg_send[ObjCObject, "NSWindow", "contentView"](win)

        # Editor above, output below, with a draggable divider between them.
        # NSSplitView owns the geometry from here: it lays the panes out, drags
        # the divider, and resizes them with the window.
        comptime out_h = WIN_H * (1.0 - EDITOR_FRAC)
        var split = msg_send[
            ObjCObject, "NSSplitView", "alloc", is_class=True
        ](ObjCClass.lookup["NSSplitView"]().as_object())
        split = msg_send[ObjCObject, "NSSplitView", "initWithFrame:"](
            split, CGRect(CGPoint(0.0, 0.0), CGSize(WIN_W, WIN_H))
        )
        # Horizontal divider (panes stacked vertically) with the thin style.
        _ = msg_send[ObjCObject, "NSSplitView", "setVertical:"](split, False)
        _ = msg_send[ObjCObject, "NSSplitView", "setDividerStyle:"](
            split, Int(2)  # NSSplitViewDividerStyleThin
        )
        # Remember where the user left the divider, across launches.
        _ = msg_send[ObjCObject, "NSSplitView", "setAutosaveName:"](
            split, nsstring(String("PlaygroundSplit")).ptr()
        )
        _ = msg_send[ObjCObject, "NSView", "setAutoresizingMask:"](
            split, Int(18)
        )

        var editor = make_text_view(
            CGRect(CGPoint(0.0, 0.0), CGSize(WIN_W, WIN_H * EDITOR_FRAC)),
            True,
        )
        _ = msg_send[ObjCObject, "NSTextView", "setDelegate:"](
            editor, actions.ptr()
        )
        g_editor()[] = editor.addr()
        var editor_scroll = scroll_wrapping(
            editor,
            CGRect(CGPoint(0.0, 0.0), CGSize(WIN_W, WIN_H * EDITOR_FRAC)),
        )

        var output = make_text_view(
            CGRect(CGPoint(0.0, 0.0), CGSize(WIN_W, out_h)), False
        )
        g_output()[] = output.addr()
        var output_scroll = scroll_wrapping(
            output, CGRect(CGPoint(0.0, 0.0), CGSize(WIN_W, out_h))
        )

        # Order matters: first subview is the top pane.
        _ = msg_send[ObjCObject, "NSSplitView", "addSubview:"](
            split, editor_scroll.ptr()
        )
        _ = msg_send[ObjCObject, "NSSplitView", "addSubview:"](
            split, output_scroll.ptr()
        )
        _ = msg_send[ObjCObject, "NSView", "addSubview:"](
            content, split.ptr()
        )
        # Place the divider (autosave overrides this on later launches).
        _ = msg_send[
            ObjCObject, "NSSplitView", "setPosition:ofDividerAtIndex:"
        ](split, WIN_H * EDITOR_FRAC, Int(0))

        _ = msg_send[ObjCObject, "NSTextView", "setString:"](
            editor, nsstring(String(STARTER)).ptr()
        )
        highlight_editor()
        append_output(
            String("Mojo Mac Playground — ⌘R to run, ⇧⌘R on the Vega II.\n"),
            OUT_STATUS,
        )

        build_menu(app, actions)

        if getenv("PG_SELFTEST") != "":
            selftest(editor, actions)
            return

        # Poll child output on the main thread; no blocks, no threads.
        _ = msg_send[
            ObjCObject,
            "NSTimer",
            "scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:",
            is_class=True,
        ](
            ObjCClass.lookup["NSTimer"]().as_object(),
            Float64(0.05),
            actions.ptr(),
            sel["pgTick:"]().ptr(),
            actions.ptr(),
            Bool(True),
        )

        _ = msg_send[ObjCObject, "NSWindow", "makeKeyAndOrderFront:"](
            win, app.ptr()
        )
        _ = msg_send[
            ObjCObject, "NSApplication", "activateIgnoringOtherApps:"
        ](app, Bool(True))

    var app2 = msg_send[
        ObjCObject, "NSApplication", "sharedApplication", is_class=True
    ](ObjCClass.lookup["NSApplication"]().as_object())
    _ = msg_send[ObjCObject, "NSApplication", "run"](app2)


def selftest(editor: ObjCObject, actions: ObjCObject) raises:
    """Exercise the paths a user's keystrokes hit -- highlighting over
    multi-byte text, incremental edits, and a real run -- with no window
    interaction, so it can be checked in CI."""
    var cases = [
        String("x = 1\n"),
        String("# ⌘R runs — an em dash and a command glyph\nvar s = \"héllo\"\n"),
        String("@always_inline\ndef f(a: Int) -> Int:\n    return a * 2  # 🎉\n"),
        String(STARTER),
    ]
    for i in range(len(cases)):
        _ = msg_send[ObjCObject, "NSTextView", "setString:"](
            editor, nsstring(cases[i]).ptr()
        )
        highlight_editor()
        print("selftest: highlighted case", i, "ok")

    # Incremental edits, the way typing arrives.
    var acc = String("")
    for i in range(40):
        acc += "a"
        if i % 7 == 0:
            acc += " ⌘ def "
        _ = msg_send[ObjCObject, "NSTextView", "setString:"](
            editor, nsstring(acc).ptr()
        )
        highlight_editor()
    print("selftest: 40 incremental edits ok")

    # A real run through the same code path as ⌘R.
    _ = msg_send[ObjCObject, "NSTextView", "setString:"](
        editor,
        nsstring(String('def main():\n    print("hello from the playground")\n')).ptr(),
    )
    start_run(False)
    var waited = 0
    while g_running()[] != 0 and waited < 600:
        drain_output()
        check_finished()
        _ = external_call["usleep", Int32](Int32(50000))
        waited += 1
    var out = ns_to_string(
        msg_send[ObjCObject, "NSTextView", "string"](ObjCObject(g_output()[]))
    )
    var ran = "hello from the playground" in out
    print("selftest: program output captured:", ran)
    print("PLAYGROUND-SELFTEST: PASS" if ran else "PLAYGROUND-SELFTEST: FAIL")
