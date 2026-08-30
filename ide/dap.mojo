# The debug adapter client.
#
# Roast does not debug Mojo any more than it parses it. `lldb-dap` does --
# the adapter Xcode ships, speaking the Debug Adapter Protocol -- and this
# talks to it over a pipe. DAP is LSP's twin: JSON-RPC-shaped messages with
# Content-Length framing, read without blocking from the same timer. So this
# module is deliberately the shape of lsp.mojo, and borrows its `readable`
# and `posix_read` rather than owning a second copy of the syscall dance.
#
# WHAT WORKS AND WHAT DOES NOT
#
# Breakpoints, stepping, the stop line and the call stack all work today,
# because they rest on DWARF line tables, which are language-neutral. What
# does not work is looking at variables: lldb says so itself, out loud, the
# first time a program stops --
#
#   warning: This version of LLDB has no plugin for the language "mojo".
#   Inspection of frame variables will be limited.
#
# -- and the plugin it means is KGEN/lib/MojoLLDB, which this fork carries
# but does not build into the lldb on this machine. That is the v2 job.
# Pretending otherwise would be worse than the warning.
#
# THREE THINGS THE PROTOCOL DOES THAT SURPRISE
#
# Breakpoints SLIDE. Ask for line 2 and the adapter answers line 10, because
# line 2 was inlined away and 10 is the nearest line that has code. The reply
# carries the line it actually bound, and an editor that draws the marker
# where the click was rather than where the breakpoint IS lies to you every
# time. So `verified_line` is what the gutter draws.
#
# The adapter is CHATTY. Launching a program that links this toolchain emits
# several hundred `module` events before anything interesting happens. They
# are dropped by falling off the end of the handler, which costs one string
# compare each -- worth writing down, because a client that logged them would
# spend its startup writing.
#
# Nothing may be sent before `initialized` ARRIVES. Not the response to
# initialize -- the event, which comes later. Breakpoints asked for before
# then are held and sent when it does, which is why `set_breakpoints` works
# before `start` and is the natural way for an editor to use it.
from json import JSON
from json import parse
from pipeutf8 import take_chunk, sanitized
from lsp import readable, posix_read
from std.objc import (
    ObjCClass,
    ObjCObject,
    msg_send,
    nsstring,
    ns_to_string,
    autoreleasepool,
    named_global,
)
from std.memory import OpaquePointer, Pointer
from std.ffi import external_call, c_char
from std.os import getenv

comptime P = OpaquePointer[MutUntrackedOrigin]

# ── State ───────────────────────────────────────────────────────────────────
comptime g_task = named_global["dap.task", Int]
comptime g_in = named_global["dap.in", Int]
comptime g_read_fd = named_global["dap.readfd", Int]
comptime g_seq = named_global["dap.seq", Int]
# 0 not started, 1 spawned, 2 initialized-event seen, 3 configured and running
comptime g_phase = named_global["dap.phase", Int]
# Nothing the adapter legitimately sends is this large: a stack, a scope,
# a few hundred variables. A number past these is invalid data, and the
# honest response is to stop believing the stream rather than to allocate
# for it.
comptime MAX_MESSAGE = 64 * 1024 * 1024
comptime MAX_INBOX = 96 * 1024 * 1024

comptime g_pending = named_global["dap.inbox.pending", List[UInt8]]
comptime g_inbox = named_global["dap.inbox", List[String]]

# Where the program is stopped, and why. Line 0 means running.
comptime g_stop_line = named_global["dap.stop.line", Int]
comptime g_stop_thread = named_global["dap.stop.thread", Int]
comptime g_stop_file = named_global["dap.stop.file", List[String]]
comptime g_stop_reason = named_global["dap.stop.reason", List[String]]
# Bumped whenever the program stops or resumes, so the app can notice without
# keeping a flag of its own -- the same trick the build driver's serial uses.
comptime g_serial = named_global["dap.serial", Int]
comptime g_exited = named_global["dap.exited", Int]

# Breakpoints, as asked for and as bound. Flat parallel lists, read from a
# draw callback, which wants no allocation.
comptime g_bp_file = named_global["dap.bp.file", List[String]]
comptime g_bp_line = named_global["dap.bp.line", List[Int]]
comptime g_bp_bound = named_global["dap.bp.bound", List[Int]]
comptime g_bp_verified = named_global["dap.bp.verified", List[Int]]
# Set when the breakpoint list changes while the adapter is up, so the tick
# resends it rather than every caller remembering to.
comptime g_bp_dirty = named_global["dap.bp.dirty", Int]

# The program's own output, which arrives as `output` events rather than on a
# pipe: the adapter owns the inferior's stdout.
comptime g_output = named_global["dap.output", List[String]]

# ROAST_DAP_TRACE prints every message that is not a `module` event. Read
# once at start rather than per message: the adapter sends several hundred
# events before a program runs, and a getenv on each is a real cost for a
# switch that cannot change while a session is up.
comptime g_trace = named_global["dap.trace", Int]
# Set when the adapter answers `disconnect`, so shutdown waits for the thing
# it asked for rather than for a fixed number of milliseconds.
comptime g_disconnected = named_global["dap.disconnected", Int]

# The stopped frame's locals. Filled by a three-request chain the `stopped`
# event starts (stackTrace -> scopes -> variables), cleared the moment the
# program moves again -- a variables view showing values from the previous
# stop is worse than one showing nothing, because it looks current.
comptime g_frame_id = named_global["dap.frame.id", Int]
comptime g_var_names = named_global["dap.var.names", List[String]]
comptime g_var_values = named_global["dap.var.values", List[String]]
comptime g_var_types = named_global["dap.var.types", List[String]]
comptime g_var_fresh = named_global["dap.var.fresh", Int]

# The call stack at the stop, top first: where the program IS, and how it got
# there. Eight levels -- a person reads three, the runtime's startup frames
# fill the rest, and past eight is scenery.
# One evaluation in flight at a time: the expression as asked, the answer or
# the error, and a take-once flag for the renderer. A queue would imply a
# watch list re-evaluated on every stop; that is a later thing, and its cost
# (running target code per stop, unasked) deserves its own decision.
comptime g_eval_expr = named_global["dap.eval.expr", List[String]]
comptime g_eval_result = named_global["dap.eval.result", List[String]]
comptime g_eval_ok = named_global["dap.eval.ok", Int]
comptime g_eval_fresh = named_global["dap.eval.fresh", Int]

comptime g_frame_names = named_global["dap.frame.names", List[String]]
comptime g_frame_files = named_global["dap.frame.files", List[String]]
comptime g_frame_lines = named_global["dap.frame.lines", List[Int]]


def _slot(list_ptr: Pointer[List[String], MutUntrackedOrigin]) -> String:
    return list_ptr[][0] if len(list_ptr[]) > 0 else String()


def _put(list_ptr: Pointer[List[String], MutUntrackedOrigin], var s: String):
    if len(list_ptr[]) == 0:
        list_ptr[].append(s^)
    else:
        list_ptr[][0] = s^


def is_running() -> Bool:
    return g_task()[] != 0


def is_configured() -> Bool:
    return g_phase()[] >= 3


def is_stopped() -> Bool:
    return g_stop_line()[] > 0


def stop_line() -> Int:
    return g_stop_line()[]


def stop_file() -> String:
    return _slot(g_stop_file())


def stop_reason() -> String:
    return _slot(g_stop_reason())


def serial() -> Int:
    return g_serial()[]


def exited() -> Bool:
    return g_exited()[] != 0


def output() -> String:
    return _slot(g_output())


def clear_output():
    _put(g_output(), String())


# ── Breakpoints ─────────────────────────────────────────────────────────────
def take_variables_fresh() -> Bool:
    """True exactly once per variables arrival: the render-me handshake.

    The stop chain bumps the serial twice -- once when the stack lands (the
    editor moves) and once when the variables do (the pane fills). A consumer
    keying off the serial alone would render the block on every later bump
    too, and a breakpoint reply is enough to cause one."""
    if g_var_fresh()[] == 0:
        return False
    g_var_fresh()[] = 0
    return True


def evaluate(var expr: String) -> Bool:
    """Run `expr` in the stopped frame -- real Mojo, compiled by the plugin's
    JIT and executed IN the debuggee. That is what makes it a debugger
    feature and not a calculator: `total + 1` reads the live `total`.

    Only while stopped, because the frame is what gives names meaning."""
    if not is_stopped():
        return False
    _put(g_eval_expr(), expr)
    var args = JSON.object()
    args.set(String("expression"), JSON(expr^))
    args.set(String("frameId"), JSON(g_frame_id()[]))
    # "watch" forces expression evaluation; "repl" would let the adapter
    # mistake an expression for an lldb command when it looks like one.
    args.set(String("context"), JSON(String("watch")))
    _ = request(String("evaluate"), args^)
    return True


def take_eval_fresh() -> Bool:
    if g_eval_fresh()[] == 0:
        return False
    g_eval_fresh()[] = 0
    return True


def eval_expr() -> String:
    return _slot(g_eval_expr())


def eval_result() -> String:
    return _slot(g_eval_result())


def eval_ok() -> Bool:
    return g_eval_ok()[] != 0


def frame_count() -> Int:
    return len(g_frame_names()[])


def frame_name(i: Int) -> String:
    return g_frame_names()[][i]


def frame_file(i: Int) -> String:
    return g_frame_files()[][i]


def frame_line(i: Int) -> Int:
    return g_frame_lines()[][i]


def variable_count() -> Int:
    return len(g_var_names()[])


def variable_name(i: Int) -> String:
    return g_var_names()[][i]


def variable_value(i: Int) -> String:
    """The value as the adapter sent it, except for one mercy: lldb-dap
    renders scalars as `0000000000000000  5` -- sixteen hex digits, two
    spaces, then the number a person wanted. When the value has exactly that
    shape, the hex is dropped. Anything else passes through untouched."""
    let raw = g_var_values()[][i]
    let sep = raw.find("  ")
    # Sixteen digits for a pointer-width scalar, eight for a 32-bit one --
    # `peak` came back as `02000000  2`, which the old fixed 16 missed and
    # so leaked the raw bytes into a view meant to show a number.
    if sep == 8 or sep == 16:
        var all_hex = True
        let b = raw.as_bytes()
        for j in range(sep):
            let c = Int(b[j])
            if not (
                (c >= 0x30 and c <= 0x39)
                or (c >= 0x61 and c <= 0x66)
                or (c >= 0x41 and c <= 0x46)
            ):
                all_hex = False
                break
        if all_hex and raw.byte_length() > sep + 2:
            return String(raw[byte = sep + 2 : raw.byte_length()])
    return raw


def variable_type(i: Int) -> String:
    return g_var_types()[][i]


# What a locals view can actually show. `hits` in the fern example is a
# List of 691,200 UInt32, and lldb renders it in full: a value nobody can
# read, that we then copy out of the list, into the block being built, and
# through the sanitiser, on every fetch -- because these accessors hand
# back Strings BY VALUE. Inspecting a variable should not mean copying it.
#
# Bounding it here means every copy downstream is cheap by construction.
# The tail is the part a person loses, and losing it is the point: nothing
# past this is being read off a screen.
comptime DISPLAY_LIMIT = 4096


def _display(var text: String) -> String:
    """`text`, valid UTF-8 and short enough to show."""
    var clean = sanitized(text^)
    if clean.byte_length() <= DISPLAY_LIMIT:
        return clean^
    # Cut on a character boundary, not a byte one.
    var cut = DISPLAY_LIMIT
    let raw = clean.as_bytes()
    while cut > 0 and Int(raw[cut]) & 0xC0 == 0x80:
        cut -= 1
    return String(clean[byte=0:cut]) + String(" … (")
        + String(clean.byte_length()) + String(" bytes)")


def _clear_variables():
    """Variables only. The frames are NOT cleared here, deliberately: the
    variables reply arrives two round trips after the stack it belongs to,
    and _take_variables resets before filling -- clearing frames there
    would wipe the stack the same stop just stored. Frames clear on
    MOTION, in _clear_stop."""
    g_var_names()[] = List[String]()
    g_var_values()[] = List[String]()
    g_var_types()[] = List[String]()


def _clear_stop():
    """Everything a stop learned: locals and the stack. For resume, step,
    and exit -- stale frames pointing at the previous stop are worse than
    none, because they look current."""
    _clear_variables()
    g_frame_names()[] = List[String]()
    g_frame_files()[] = List[String]()
    g_frame_lines()[] = List[Int]()


def breakpoint_count() -> Int:
    return len(g_bp_line()[])


def breakpoint_file(i: Int) -> String:
    return g_bp_file()[][i] if i >= 0 and i < breakpoint_count() else String()


def breakpoint_line(i: Int) -> Int:
    """Where it was asked for -- what the person clicked."""
    return g_bp_line()[][i] if i >= 0 and i < breakpoint_count() else 0


def verified_line(i: Int) -> Int:
    """Where it actually bound, or the asked-for line while the adapter is
    down. This is what a gutter should draw: a marker on a line that has no
    code is a promise the debugger will not keep."""
    if i < 0 or i >= breakpoint_count():
        return 0
    let bound = g_bp_bound()[][i]
    return bound if bound > 0 else g_bp_line()[][i]


def is_verified(i: Int) -> Bool:
    return i >= 0 and i < breakpoint_count() and g_bp_verified()[][i] != 0


def breakpoint_at(path: String, line: Int) -> Int:
    """The index of a breakpoint on this line -- asked-for OR bound, so
    clicking the marker where it is drawn removes it."""
    var i = 0
    while i < breakpoint_count():
        if g_bp_file()[][i] == path and (
            g_bp_line()[][i] == line or g_bp_bound()[][i] == line
        ):
            return i
        i += 1
    return -1


def toggle_breakpoint(path: String, line: Int) -> Bool:
    """Add or remove one. True if it is now set."""
    let at = breakpoint_at(path, line)
    if at >= 0:
        let f = g_bp_file()
        let l = g_bp_line()
        let b = g_bp_bound()
        let v = g_bp_verified()
        let last = breakpoint_count() - 1
        f[].swap_elements(at, last)
        l[].swap_elements(at, last)
        b[].swap_elements(at, last)
        v[].swap_elements(at, last)
        _ = f[].pop()
        _ = l[].pop()
        _ = b[].pop()
        _ = v[].pop()
        g_bp_dirty()[] = 1
        return False
    g_bp_file()[].append(path)
    g_bp_line()[].append(line)
    g_bp_bound()[].append(0)
    g_bp_verified()[].append(0)
    g_bp_dirty()[] = 1
    return True


def clear_breakpoints():
    let f = g_bp_file()
    let l = g_bp_line()
    let b = g_bp_bound()
    let v = g_bp_verified()
    while len(l[]) > 0:
        _ = f[].pop()
        _ = l[].pop()
        _ = b[].pop()
        _ = v[].pop()
    g_bp_dirty()[] = 1


def _files_with_breakpoints() -> List[String]:
    var out = List[String]()
    var i = 0
    while i < breakpoint_count():
        let f = g_bp_file()[][i]
        var seen = False
        for s in out:
            if s == f:
                seen = True
                break
        if not seen:
            out.append(f)
        i += 1
    return out^


# ── The wire ────────────────────────────────────────────────────────────────
def _send(var body: JSON) -> Bool:
    if g_in()[] == 0:
        return False
    with autoreleasepool():
        let text = body.serialize()
        var framed = String("Content-Length: ")
        framed += String(text.byte_length())
        framed += "\r\n\r\n"
        framed += text
        var local = framed
        let data = msg_send[ObjCObject, "NSString", "dataUsingEncoding:"](
            nsstring(local), Int(4)
        )
        _ = msg_send[ObjCObject, "NSFileHandle", "writeData:"](
            ObjCObject(g_in()[]), data.ptr()
        )
    return True


def request(var command: String, var args: JSON) -> Int:
    g_seq()[] += 1
    let id = g_seq()[]
    var msg = JSON.object()
    msg.set(String("seq"), JSON(id))
    msg.set(String("type"), JSON(String("request")))
    msg.set(String("command"), JSON(command^))
    msg.set(String("arguments"), args^)
    _ = _send(msg^)
    return id


def send_breakpoints():
    """One setBreakpoints per file, which is what the protocol takes: the
    request REPLACES every breakpoint in the file it names, so a file that
    has lost its last breakpoint still has to be told, with an empty list."""
    if g_phase()[] < 2:
        return
    for path in _files_with_breakpoints():
        var lines = JSON.array()
        var i = 0
        while i < breakpoint_count():
            if g_bp_file()[][i] == path:
                var one = JSON.object()
                one.set(String("line"), JSON(g_bp_line()[][i]))
                lines.push(one^)
            i += 1
        var src = JSON.object()
        src.set(String("path"), JSON(path))
        var args = JSON.object()
        args.set(String("source"), src^)
        args.set(String("breakpoints"), lines^)
        _ = request(String("setBreakpoints"), args^)
    g_bp_dirty()[] = 0


def start(
    adapter: String,
    program: String,
    cwd: String,
    init_command: String = String(""),
    pre_run_command: String = String(""),
) -> Bool:
    return start_with_environment(
        adapter,
        program,
        cwd,
        init_command,
        pre_run_command,
        JSON.object(),
    )


def start_with_environment(
    adapter: String,
    program: String,
    cwd: String,
    init_command: String,
    pre_run_command: String,
    environment: JSON,
) -> Bool:
    """Spawn the adapter and ask it to launch the program.

    `stopOnEntry` is false: someone who pressed Debug with no breakpoints
    wants their program to run, not to stare at a stop in the runtime's
    startup. A breakpoint is how you say otherwise.
    """
    if is_running():
        return True
    with autoreleasepool():
        let NSTask = ObjCClass.lookup["NSTask"]()
        var task = msg_send[ObjCObject, "NSTask", "alloc", is_class=True](
            NSTask.as_object()
        )
        task = msg_send[ObjCObject, "NSObject", "init"](task)
        var path = adapter
        _ = msg_send[ObjCObject, "NSTask", "setLaunchPath:"](
            task, nsstring(path).ptr()
        )
        let NSPipe = ObjCClass.lookup["NSPipe"]()
        let inp = msg_send[ObjCObject, "NSPipe", "pipe", is_class=True](
            NSPipe.as_object()
        )
        let outp = msg_send[ObjCObject, "NSPipe", "pipe", is_class=True](
            NSPipe.as_object()
        )
        _ = msg_send[ObjCObject, "NSTask", "setStandardInput:"](task, inp.ptr())
        _ = msg_send[ObjCObject, "NSTask", "setStandardOutput:"](
            task, outp.ptr()
        )
        let writer = msg_send[ObjCObject, "NSPipe", "fileHandleForWriting"](inp)
        let reader = msg_send[ObjCObject, "NSPipe", "fileHandleForReading"](outp)
        let fd = msg_send[Int, "NSFileHandle", "fileDescriptor"](reader)
        _ = external_call["objc_retain", P](task.ptr())
        _ = external_call["objc_retain", P](writer.ptr())
        _ = external_call["objc_retain", P](reader.ptr())
        g_task()[] = task.addr()
        g_in()[] = writer.addr()
        g_read_fd()[] = fd
        _ = msg_send[ObjCObject, "NSTask", "launch"](task)

    g_trace()[] = 1 if getenv("ROAST_DAP_TRACE") != "" else 0
    g_disconnected()[] = 0
    g_phase()[] = 1
    g_exited()[] = 0
    g_stop_line()[] = 0
    _put(g_stop_file(), String())
    _put(g_stop_reason(), String())
    _put(g_output(), String())

    var init_args = JSON.object()
    init_args.set(String("adapterID"), JSON(String("lldb")))
    init_args.set(String("linesStartAt1"), JSON(True))
    init_args.set(String("columnsStartAt1"), JSON(True))
    init_args.set(String("pathFormat"), JSON(String("path")))
    _ = request(String("initialize"), init_args^)

    var launch_args = JSON.object()
    launch_args.set(String("program"), JSON(program))
    launch_args.set(String("cwd"), JSON(cwd))
    launch_args.set(String("stopOnEntry"), JSON(False))
    if environment.count() > 0:
        # lldb-dap applies this dictionary to the inferior, not the adapter.
        # That is the process which embeds CPython through std.python.
        launch_args.set(String("env"), parse(environment.serialize()))
    # `initCommands` run before the target exists (where `plugin load`
    # belongs -- the type system must be registered before the first module
    # is parsed); `preRunCommands` run with a target, before launch (where a
    # command that sets breakpoints, like `mojo break-on-raise`, belongs).
    var cmds = JSON.array()
    # Tell lldb what a locals view is for before it renders anything. A
    # `List[UInt32]` of 691,200 elements is a legitimate variable and an
    # illegitimate string: rendered in full it is tens of megabytes, sent
    # over the wire, parsed, stored, and copied -- to show a person the
    # first line of it. Roast never displays more than a few bytes of a
    # value, so it should never ask for more.
    #
    # These are lldb's own limits, applied at the source rather than
    # trimmed after the fact, which is the difference between not doing
    # work and doing it twice.
    cmds.push(JSON(String("settings set target.max-children-count 64")))
    cmds.push(JSON(String("settings set target.max-string-summary-length 512")))
    if init_command != "":
        cmds.push(JSON(init_command))
    launch_args.set(String("initCommands"), cmds^)
    if pre_run_command != "":
        var pre = JSON.array()
        pre.push(JSON(pre_run_command))
        launch_args.set(String("preRunCommands"), pre^)
    _ = request(String("launch"), launch_args^)
    return True


def stop():
    """End the session: kill the PROGRAM, then the adapter.

    Terminating the adapter alone leaves the debuggee behind, stopped at
    whatever breakpoint it was sitting on, forever -- there is nobody left to
    resume it. That is a leak with teeth: every Stop strands a frozen process,
    they accumulate, and eventually new launches fail for reasons that look
    like anything but this. It showed up as two debugger checks that passed
    alone and failed in the suite, with an orphan from an earlier run still
    on the process list.

    `disconnect` with terminateDebuggee is the protocol's own answer. The
    adapter is given a moment to act on it before being terminated, because
    a disconnect that is never read is the same as not sending one.

    The bound lines go with it: they were facts about a process that no
    longer exists, and a marker still sitting on the line the LAST run bound
    is a marker about nothing.
    """
    if not is_running():
        return
    var args = JSON.object()
    args.set(String("terminateDebuggee"), JSON(True))
    _ = request(String("disconnect"), args^)
    # Drained rather than slept through: the adapter answers, and reading the
    # answer is how we know it got as far as killing the inferior.
    var spins = 0
    while spins < 200:
        _ = poll()
        if g_disconnected()[] != 0:
            break
        spins += 1
    with autoreleasepool():
        _ = msg_send[ObjCObject, "NSTask", "terminate"](ObjCObject(g_task()[]))
    g_task()[] = 0
    g_in()[] = 0
    g_read_fd()[] = 0
    g_phase()[] = 0
    g_stop_line()[] = 0
    g_stop_thread()[] = 0
    _put(g_stop_file(), String())
    _put(g_stop_reason(), String())
    _put(g_inbox(), String())
    var i = 0
    while i < breakpoint_count():
        g_bp_bound()[][i] = 0
        g_bp_verified()[][i] = 0
        i += 1
    g_serial()[] += 1


# ── Driving it ──────────────────────────────────────────────────────────────
def _resume(var command: String):
    _clear_stop()
    if not is_stopped():
        return
    var args = JSON.object()
    args.set(String("threadId"), JSON(g_stop_thread()[]))
    _ = request(command^, args^)
    # Optimistic, and deliberately so: the adapter answers `continued` for
    # some of these and stays silent for others, and an editor that left the
    # stop marker up until it heard back would look frozen.
    g_stop_line()[] = 0
    _put(g_stop_reason(), String())
    g_serial()[] += 1


def resume():
    _resume(String("continue"))


def step_over():
    _resume(String("next"))


def step_in():
    _resume(String("stepIn"))


def step_out():
    _resume(String("stepOut"))


def pause():
    if not is_running() or is_stopped():
        return
    var args = JSON.object()
    # Thread 0 means "whatever is running" to this adapter; a real id is only
    # known once something has stopped, which is the case this is for.
    args.set(String("threadId"), JSON(g_stop_thread()[]))
    _ = request(String("pause"), args^)


# ── Reading ─────────────────────────────────────────────────────────────────
def poll() -> Int:
    """Drain the adapter and handle whole messages. Returns how many."""
    if g_read_fd()[] == 0:
        return 0
    var handled = 0
    with autoreleasepool():
        comptime CAP = 65536
        while readable(g_read_fd()[]):
            let buf = external_call["calloc", P](Int(CAP + 1), Int(1))
            let n = posix_read(g_read_fd()[], buf, CAP)
            if n <= 0:
                _ = external_call["free", NoneType](buf)
                break
            var acc = _slot(g_inbox())
            # Only what forms whole characters. A 64 KB read boundary lands
            # wherever it lands, and half a codepoint appended here is a
            # String that crashes whoever iterates it later.
            acc += take_chunk(g_pending()[], buf, n)
            _put(g_inbox(), acc^)
            _ = external_call["free", NoneType](buf)
            if n < CAP:
                break

        while True:
            var acc = _slot(g_inbox())
            let header_end = acc.find("\r\n\r\n")
            if header_end < 0:
                break
            let header = String(acc[byte=0:header_end])
            let marker = header.find("Content-Length:")
            if marker < 0:
                _put(g_inbox(), String(acc[byte = header_end + 4 : acc.byte_length()]))
                continue
            var length = 0
            var i = marker + 15
            let hb = header.as_bytes()
            while i < header.byte_length():
                let c = Int(hb[i])
                if c >= 0x30 and c <= 0x39:
                    length = length * 10 + (c - 0x30)
                elif length > 0:
                    break
                i += 1
            let body_at = header_end + 4
            # A length that is not a length means the stream is not where we
            # think it is. Nothing this adapter sends is anywhere near this
            # big, so rather than wait for bytes that will never come --
            # appending every later read to an inbox that can no longer
            # drain, until a String asks the allocator for gigabytes -- drop
            # what we have and resynchronise on the next header.
            if length < 0 or length > MAX_MESSAGE:
                _put(g_inbox(), String())
                print("  dap: implausible Content-Length", length, "— resynchronising")
                break
            if acc.byte_length() < body_at + length:
                # Still waiting for the body. That is normal, but only up to
                # a point: an inbox that grows without ever yielding a
                # message is a desynchronised stream, not a slow one.
                if acc.byte_length() > MAX_INBOX:
                    _put(g_inbox(), String())
                    print("  dap: inbox past", MAX_INBOX, "bytes with no whole message — resynchronising")
                break
            let body = String(acc[byte = body_at : body_at + length])
            _put(g_inbox(), String(acc[byte = body_at + length : acc.byte_length()]))
            _handle(parse(body))
            handled += 1
    return handled


def _handle(var msg: JSON):
    let kind = msg.get("type")[].as_string()
    if kind == "event":
        _event(msg.get("event")[].as_string(), msg.get("body")[])
        return
    if kind == "request" and g_trace()[] != 0:
        # A reverse request -- the adapter asking US for something, which
        # this client does not answer. Traced rather than ignored silently,
        # because an adapter waiting on a reply looks exactly like a hung
        # debugger and there is nothing else that would say so.
        print("  dap REVERSE request:", msg.get("command")[].as_string())
    if kind == "response":
        let command = msg.get("command")[].as_string()
        if g_trace()[] != 0:
            print(
                "  dap response:", command,
                "success", msg.get("success")[].as_bool(),
                repr(msg.get("message")[].as_string()),
            )
        if command == "disconnect":
            g_disconnected()[] = 1
        elif command == "setBreakpoints":
            _take_breakpoints(msg.get("body")[])
        elif command == "stackTrace":
            _take_stack(msg.get("body")[])
        elif command == "scopes":
            _take_scopes(msg.get("body")[])
        elif command == "variables":
            _take_variables(msg.get("body")[])
        elif command == "evaluate":
            # Failure carries its explanation in `message`, success its
            # answer in `body.result`; either way the asker hears back.
            if msg.get("success")[].as_bool():
                g_eval_ok()[] = 1
                # Same reasoning as the locals: an expression's result is
                # the debuggee's bytes.
                _put(
                    g_eval_result(),
                    _display(msg.get("body")[].get("result")[].as_string()),
                )
            else:
                g_eval_ok()[] = 0
                # lldb-dap does not use the DAP `message` field: the text
                # lives in body.error.format. Read both, prefer whichever
                # actually says something.
                var text = msg.get("message")[].as_string()
                if text == "":
                    text = (
                        msg.get("body")[].get("error")[].get("format")[]
                        .as_string()
                    )
                _put(g_eval_result(), text^)
            g_eval_fresh()[] = 1
            g_serial()[] += 1


def _event(name: String, body: JSON):
    # `module` is excluded by hand: it is most of the traffic and none of the
    # information, and a trace that scrolls it away is not a trace.
    if g_trace()[] != 0 and name != "module":
        if name == "output":
            print(
                "  dap event: output",
                repr(body.get("output")[].as_string()),
            )
        elif name == "breakpoint" or name == "process":
            print("  dap event:", name, body.serialize())
        else:
            print("  dap event:", name)
    if name == "initialized":
        # Not the initialize RESPONSE: this event is the adapter saying it is
        # ready to be configured, and nothing may be configured before it.
        g_phase()[] = 2
        send_breakpoints()
        var empty = JSON.object()
        _ = request(String("configurationDone"), empty^)
        g_phase()[] = 3
        return
    if name == "breakpoint":
        # lldb-dap can answer setBreakpoints while the location is still
        # pending, then announce the resolved location in one or more
        # standard DAP breakpoint events. Ignoring those leaves the gutter
        # permanently "unverified" even when the program stops on it.
        _take_breakpoint_event(body)
        return
    if name == "stopped":
        g_stop_thread()[] = body.get("threadId")[].as_int()
        _put(g_stop_reason(), body.get("reason")[].as_string())
        # The event says a thread stopped, not where. The line comes from the
        # stack, which is a second round trip -- so the line is set when that
        # reply lands, not here.
        var args = JSON.object()
        args.set(String("threadId"), JSON(g_stop_thread()[]))
        args.set(String("startFrame"), JSON(0))
        args.set(String("levels"), JSON(8))
        _ = request(String("stackTrace"), args^)
        return
    if name == "exited" or name == "terminated":
        g_exited()[] = 1
        g_stop_line()[] = 0
        _clear_stop()
        _put(g_stop_reason(), String())
        g_serial()[] += 1
        return
    if name == "output":
        let category = body.get("category")[].as_string()
        if category == "" or category == "stdout" or category == "stderr":
            var acc = _slot(g_output())
            acc += body.get("output")[].as_string()
            _put(g_output(), acc^)
        return
    # Everything else -- and `module` arrives in the hundreds -- falls off the
    # end here, which is the cheapest thing that can happen to it.


def _take_breakpoints(body: JSON):
    """Record where each breakpoint actually bound.

    The reply is positional against the request, and the request was one
    file's breakpoints in the order they sit in our lists. So this walks our
    breakpoints for that file in the same order -- which is why the file is
    read back out of the reply's `source` rather than assumed.
    """
    let list = body.get("breakpoints")[]
    if list.count() == 0:
        return
    # Which file this reply is about: the adapter echoes the source on each
    # breakpoint, and every breakpoint in one reply came from one request.
    let first = list.at(0)[]
    let path = first.get("source")[].get("path")[].as_string()
    var nth = 0
    var i = 0
    while i < breakpoint_count() and nth < list.count():
        if g_bp_file()[][i] == path or path == "":
            let b = list.at(nth)[]
            let line = b.get("line")[].as_int()
            if line > 0:
                g_bp_bound()[][i] = line
            g_bp_verified()[][i] = 1 if b.get("verified")[].as_bool() else 0
            nth += 1
        i += 1
    g_serial()[] += 1


def _take_breakpoint_event(body: JSON):
    """Apply a DAP breakpoint changed/new event to the matching local row."""
    let b = body.get("breakpoint")[]
    let path = b.get("source")[].get("path")[].as_string()
    let line = b.get("line")[].as_int()
    var i = 0
    while i < breakpoint_count():
        let ours = g_bp_file()[][i]
        let same_file = (
            (path == "" and breakpoint_count() == 1)
            or path == ours
            or path.endswith(String("/") + ours)
            or ours.endswith(String("/") + path)
        )
        let same_line = (
            (line == 0 and breakpoint_count() == 1)
            or line == g_bp_line()[][i]
            or line == g_bp_bound()[][i]
        )
        if same_file and same_line:
            if line > 0:
                g_bp_bound()[][i] = line
            g_bp_verified()[][i] = (
                1 if b.get("verified")[].as_bool() else 0
            )
            g_serial()[] += 1
            return
        i += 1


def _take_stack(body: JSON):
    let frames = body.get("stackFrames")[]
    if frames.count() == 0:
        return
    g_frame_names()[] = List[String]()
    g_frame_files()[] = List[String]()
    g_frame_lines()[] = List[Int]()
    var i = 0
    while i < frames.count():
        let f = frames.at(i)[]
        g_frame_names()[].append(_display(f.get("name")[].as_string()))
        g_frame_files()[].append(
            _display(f.get("source")[].get("path")[].as_string())
        )
        g_frame_lines()[].append(f.get("line")[].as_int())
        i += 1
    let top = frames.at(0)[]
    g_stop_line()[] = top.get("line")[].as_int()
    _put(g_stop_file(), top.get("source")[].get("path")[].as_string())
    g_serial()[] += 1
    # Third leg of the stop chain: the frame's scopes, then its variables.
    g_frame_id()[] = top.get("id")[].as_int()
    var args = JSON.object()
    args.set(String("frameId"), JSON(g_frame_id()[]))
    _ = request(String("scopes"), args^)


def _take_scopes(body: JSON):
    """Ask for the first scope's variables -- lldb-dap puts Locals first, and
    locals-plus-arguments is what a person stopped at a breakpoint wants.
    Globals and registers can wait for a pane that can expand things."""
    let scopes = body.get("scopes")[]
    if scopes.count() == 0:
        return
    var args = JSON.object()
    args.set(
        String("variablesReference"),
        JSON(scopes.at(0)[].get("variablesReference")[].as_int()),
    )
    _ = request(String("variables"), args^)


def _take_variables(body: JSON):
    _clear_variables()
    let vars = body.get("variables")[]
    var i = 0
    while i < vars.count():
        let v = vars.at(i)[]
        # Sanitised at the boundary. These are the debuggee's bytes, not
        # ours: a String local that is not yet initialised renders as
        # whatever was at that address, and arbitrary bytes are not text.
        # Everything downstream -- the locals view, the console, the agent's
        # reply -- can then treat them as the strings they claim to be.
        g_var_names()[].append(_display(v.get("name")[].as_string()))
        g_var_values()[].append(_display(v.get("value")[].as_string()))
        g_var_types()[].append(_display(v.get("type")[].as_string()))
        i += 1
    g_var_fresh()[] = 1
    g_serial()[] += 1
