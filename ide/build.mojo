# Running the compiler from inside the editor.
#
# What a project is
# -----------------
# A folder. There is no project file, and the reason is that Mojo has no link
# step: the compiler is handed one file and follows its imports from there. So
# a project does not need a list of sources -- it needs an entry point, and
# every other file in it is reached by being imported.
#
# That makes the whole build model one question: which file is the entry point?
# Roast answers it in three steps, cheapest first:
#
#   1. `main.mojo` in the project root -- the convention.
#   2. any file in the root whose text contains `def main(` -- so a project
#      that named its entry something else still builds without configuring
#      anything.
#   3. the file being edited -- which is what makes a single loose file with no
#      project around it still buildable. There is no separate single-file
#      mode; it is the same path with a smaller answer to the same question.
#
# Output goes to `build/` beside the entry point, which is also the directory
# the sidebar already hides.
#
# The process itself is an NSTask with one pipe carrying both stdout and
# stderr, drained without blocking from the same timer that drains the language
# server -- for the same reason. A compiler thinking hard must not be an editor
# that has stopped responding.
from std.objc import (
    ObjCClass,
    ObjCObject,
    msg_send,
    nsstring,
    ns_to_string,
    autoreleasepool,
    named_global,
)
from std.memory import OpaquePointer
from std.ffi import external_call, c_char

from lsp import readable, posix_read
from json import JSON
from process_env import apply as apply_environment
from pipeutf8 import take_chunk

comptime P = OpaquePointer[MutUntrackedOrigin]

# Scanning paths and diagnostics is done on bytes: every character that matters
# here is ASCII, and a byte compare needs no lifetime to be right about.
comptime SLASH: UInt8 = 47
comptime COLON: UInt8 = 58
comptime ZERO: UInt8 = 48
comptime NINE: UInt8 = 57


# ── State ───────────────────────────────────────────────────────────────────
comptime g_task = named_global["build.task", Int]
comptime g_pending = named_global["build.out.pending", List[UInt8]]
comptime g_fd = named_global["build.fd", Int]
comptime g_exit = named_global["build.exit", Int]
comptime g_serial = named_global["build.serial", Int]

# Zero-initialised globals again: a List starts life as a valid empty list, a
# String does not. Everything textual therefore lives in a one-element list.
comptime g_out = named_global["build.out", List[String]]
comptime g_label = named_global["build.label", List[String]]

# What to launch if the current task succeeds -- Run is Build followed by the
# binary, and this is where the second half waits.
comptime g_then_exe = named_global["build.then.exe", List[String]]
comptime g_then_cwd = named_global["build.then.cwd", List[String]]


def _get(slot: List[String]) -> String:
    if len(slot) == 0:
        return String()
    return slot[0]


def _put(list_ptr: Pointer[List[String], MutUntrackedOrigin], var s: String):
    if len(list_ptr[]) == 0:
        list_ptr[].append(s^)
    else:
        list_ptr[][0] = s^


def output() -> String:
    return _get(g_out()[])


def clear_output():
    _put(g_out(), String())


# The console keeps what a person scrolls back through, not a session's
# entire history. Without a ceiling it grows for as long as Roast runs --
# and a program that prints in a loop, or an adapter trace left on, reaches
# a size where doubling the buffer is a request the allocator refuses.
comptime MAX_CONSOLE = 8 * 1024 * 1024
comptime CONSOLE_KEEP = 6 * 1024 * 1024


def append_output(var s: String):
    var acc = output()
    acc += s
    if acc.byte_length() > MAX_CONSOLE:
        # Drop the oldest, on a line boundary so nothing is cut mid-line.
        let from_byte = acc.byte_length() - CONSOLE_KEEP
        let nl = acc.find("\n", from_byte)
        let cut = nl + 1 if nl >= 0 else from_byte
        acc = String("… earlier output trimmed …\n") + String(
            acc[byte = cut : acc.byte_length()]
        )
    _put(g_out(), acc^)


def label() -> String:
    return _get(g_label()[])


def is_running() -> Bool:
    return g_task()[] != 0


def exit_status() -> Int:
    return g_exit()[]


def serial() -> Int:
    """Bumped every time a task finishes, so a caller can notice without
    keeping its own flag."""
    return g_serial()[]


# ── Finding the entry point ─────────────────────────────────────────────────
def _read_file(path: String) -> String:
    try:
        with open(path, "r") as f:
            return f.read()
    except:
        return String()


def _exists(path: String) -> Bool:
    with autoreleasepool():
        let NSFileManager = ObjCClass.lookup["NSFileManager"]()
        let fm = msg_send[
            ObjCObject, "NSFileManager", "defaultManager", is_class=True
        ](NSFileManager.as_object())
        var p = path
        return msg_send[Bool, "NSFileManager", "fileExistsAtPath:"](
            fm, nsstring(p).ptr()
        )


def _root_mojo_files(root: String) -> List[String]:
    var out = List[String]()
    with autoreleasepool():
        let NSFileManager = ObjCClass.lookup["NSFileManager"]()
        let fm = msg_send[
            ObjCObject, "NSFileManager", "defaultManager", is_class=True
        ](NSFileManager.as_object())
        var r = root
        let names = msg_send[
            ObjCObject, "NSFileManager", "contentsOfDirectoryAtPath:error:"
        ](fm, nsstring(r).ptr(), ObjCObject(0).ptr())
        if names.addr() == 0:
            return out^
        let n = msg_send[Int, "NSArray", "count"](names)
        for i in range(n):
            let nm = msg_send[ObjCObject, "NSArray", "objectAtIndex:"](names, i)
            let name = ns_to_string(nm)
            if name.endswith(".mojo") and not name.startswith("."):
                out.append(root + String("/") + name)
    return out^


def dirname(path: String) -> String:
    let b = path.as_bytes()
    var cut = -1
    for i in range(len(b)):
        if b[i] == SLASH:
            cut = i
    if cut <= 0:
        return String()
    return String(path[byte=0:cut])


def _declares_main(path: String) -> Bool:
    """Does this file declare a top-level `main`?

    At the start of a line, not just anywhere in the text -- an entry point is
    unindented by definition, and a comment that merely mentions one is not
    one. This file is the proof: the note at the top explains the rule using
    the exact string it is looking for, and a substring search over it
    nominates build.mojo as the entry point of the whole editor.
    """
    let text = _read_file(path)
    if text.startswith("def main(") or text.startswith("fn main("):
        return True
    return text.find("\ndef main(") >= 0 or text.find("\nfn main(") >= 0


def entry_point(root: String, current: String) -> String:
    """Which file to hand the compiler. See the note at the top of the file."""
    if root != "":
        let conventional = root + String("/main.mojo")
        if _exists(conventional):
            return conventional

        # No main.mojo. The file on screen, if it is one of this project's own
        # entry points -- with several to choose from, the one being looked at
        # is the one meant.
        if (
            current != ""
            and dirname(current) == root
            and _declares_main(current)
        ):
            return current

        # Otherwise the one file in the root that declares a main. Tests are
        # skipped: every test suite here has a `def main`, and none of them is
        # what the project is. Without this rule, `ide/` has six candidates and
        # picks a test.
        var found = String()
        for path in _root_mojo_files(root):
            if path.endswith("_test.mojo"):
                continue
            if _declares_main(path):
                if found == "":
                    found = path
                elif path < found:
                    # Deterministic when there is still more than one, so the
                    # same project builds the same way twice.
                    found = path
        if found != "":
            return found^
    # A loose file, or a project with no entry point of its own.
    return current


def binary_for(entry: String) -> String:
    """`<dir>/build/<stem>` -- next to the entry point, in the folder the
    sidebar already leaves out."""
    let b = entry.as_bytes()
    let n = len(b)
    var cut = -1
    for i in range(n):
        if b[i] == SLASH:
            cut = i
    var dir = String(".")
    var name = entry
    if cut >= 0:
        var d = dirname(entry)
        if d != "":
            dir = d^
        var stem = String(entry[byte = cut + 1 : n])
        name = stem^
    if name.endswith(".mojo"):
        var stem = String(name[byte = 0 : name.byte_length() - 5])
        name = stem^
    return dir + String("/build/") + name


def ensure_dir(path: String) -> Bool:
    with autoreleasepool():
        let NSFileManager = ObjCClass.lookup["NSFileManager"]()
        let fm = msg_send[
            ObjCObject, "NSFileManager", "defaultManager", is_class=True
        ](NSFileManager.as_object())
        var p = path
        return msg_send[
            Bool,
            "NSFileManager",
            "createDirectoryAtPath:withIntermediateDirectories:attributes:error:",
        ](fm, nsstring(p).ptr(), True, ObjCObject(0).ptr(), ObjCObject(0).ptr())


# ── Running it ──────────────────────────────────────────────────────────────
def start(
    exe: String, args: List[String], cwd: String, var what: String
) -> Bool:
    """Launch with the editor's inherited environment unchanged."""
    return start_with_environment(exe, args, cwd, what^, JSON.object())


def start_with_environment(
    exe: String,
    args: List[String],
    cwd: String,
    var what: String,
    environment: JSON,
) -> Bool:
    """Launch a process with stdout and stderr on one pipe. Not waited for."""
    if is_running():
        return False
    if not _exists(exe):
        append_output(String("cannot run ") + exe + String("\n"))
        g_exit()[] = 127
        g_serial()[] += 1
        return False

    _put(g_label(), what^)
    with autoreleasepool():
        let NSTask = ObjCClass.lookup["NSTask"]()
        var task = msg_send[ObjCObject, "NSTask", "alloc", is_class=True](
            NSTask.as_object()
        )
        task = msg_send[ObjCObject, "NSObject", "init"](task)
        var e = exe
        _ = msg_send[ObjCObject, "NSTask", "setLaunchPath:"](
            task, nsstring(e).ptr()
        )

        let NSMutableArray = ObjCClass.lookup["NSMutableArray"]()
        var argv = msg_send[
            ObjCObject, "NSMutableArray", "array", is_class=True
        ](NSMutableArray.as_object())
        for a in args:
            var s = a
            _ = msg_send[ObjCObject, "NSMutableArray", "addObject:"](
                argv, nsstring(s).ptr()
            )
        _ = msg_send[ObjCObject, "NSTask", "setArguments:"](task, argv.ptr())

        # The working directory is the project, so a program that writes a file
        # writes it where its source lives rather than wherever Roast started.
        if cwd != "":
            var c = cwd
            _ = msg_send[ObjCObject, "NSTask", "setCurrentDirectoryPath:"](
                task, nsstring(c).ptr()
            )

        # Merge only the settings the caller owns.  Python uses this to select
        # a project venv without losing the driver, loader, proxy, or temporary
        # directory settings inherited by Roast.
        apply_environment(task, environment)

        let NSPipe = ObjCClass.lookup["NSPipe"]()
        let pipe = msg_send[ObjCObject, "NSPipe", "pipe", is_class=True](
            NSPipe.as_object()
        )
        # One pipe for both: diagnostics come out of stderr and program output
        # out of stdout, and interleaving them is what a console is.
        _ = msg_send[ObjCObject, "NSTask", "setStandardOutput:"](
            task, pipe.ptr()
        )
        _ = msg_send[ObjCObject, "NSTask", "setStandardError:"](
            task, pipe.ptr()
        )
        let reader = msg_send[ObjCObject, "NSPipe", "fileHandleForReading"](
            pipe
        )
        let fd = msg_send[Int, "NSFileHandle", "fileDescriptor"](reader)

        _ = external_call["objc_retain", P](task.ptr())
        _ = external_call["objc_retain", P](reader.ptr())
        g_task()[] = task.addr()
        g_fd()[] = fd
        g_exit()[] = 0

        _ = msg_send[ObjCObject, "NSTask", "launch"](task)
    return True


def _drain() -> Int:
    """Whatever is in the pipe right now, without waiting for more."""
    if g_fd()[] == 0:
        return 0
    var total = 0
    comptime CAP = 65536
    while readable(g_fd()[]):
        # calloc, and a spare byte: the buffer is already NUL-terminated, so
        # what comes back can be taken as a string without a length beside it.
        let buf = external_call["calloc", P](Int(CAP + 1), Int(1))
        let n = posix_read(g_fd()[], buf, CAP)
        if n <= 0:
            _ = external_call["free", NoneType](buf)
            break
        # Whole characters only. The compiler's diagnostics are full of
        # arrows and box drawing, so a split boundary here is not exotic.
        append_output(take_chunk(g_pending()[], buf, n))
        _ = external_call["free", NoneType](buf)
        total += n
        if n < CAP:
            break
    return total


def pump() -> Int:
    """Called from the timer. Returns bytes read; reaps the process on exit."""
    if g_task()[] == 0:
        return 0
    var total = _drain()
    with autoreleasepool():
        let task = ObjCObject(g_task()[])
        if not msg_send[Bool, "NSTask", "isRunning"](task):
            # It has gone, but the pipe may still hold its last words.
            total += _drain()
            g_exit()[] = msg_send[Int, "NSTask", "terminationStatus"](task)
            g_task()[] = 0
            g_fd()[] = 0
            g_serial()[] += 1
    return total


def stop():
    if g_task()[] == 0:
        return
    with autoreleasepool():
        _ = msg_send[ObjCObject, "NSTask", "terminate"](ObjCObject(g_task()[]))
    _ = _drain()
    g_task()[] = 0
    g_fd()[] = 0
    g_exit()[] = -1
    g_serial()[] += 1
    clear_then()


# ── Run = build, then the binary ────────────────────────────────────────────
def set_then(var exe: String, var cwd: String):
    _put(g_then_exe(), exe^)
    _put(g_then_cwd(), cwd^)


def clear_then():
    _put(g_then_exe(), String())
    _put(g_then_cwd(), String())


def then_exe() -> String:
    return _get(g_then_exe()[])


def then_cwd() -> String:
    return _get(g_then_cwd()[])


# ── Reading the compiler's mind ─────────────────────────────────────────────
@fieldwise_init
struct Issue(ImplicitlyCopyable, Movable):
    """One line of `path:line:col: error: message`, taken apart."""

    var path: String
    var line: Int  # one-based, the way the compiler prints it
    var col: Int  # one-based
    var severity: Int  # 1 error, 2 warning
    var message: String


def _tail_int(s: String, upto: Int) -> Int:
    """The integer ending at `upto`, or -1. Used walking a prefix backwards."""
    let b = s.as_bytes()
    let end = upto
    var start = end
    while start > 0 and b[start - 1] >= ZERO and b[start - 1] <= NINE:
        start -= 1
    if start == end:
        return -1
    var v = 0
    for i in range(start, end):
        v = v * 10 + Int(b[i]) - Int(ZERO)
    return v


def parse_issues(text: String) -> List[Issue]:
    """Every diagnostic in a build log, in the order the compiler said them.

    Anything that is not shaped like a diagnostic is left alone -- a console
    that swallows lines it does not recognise is worse than one that doesn't
    try.
    """
    var issues = List[Issue]()
    let n = text.byte_length()
    var start = 0
    while start < n:
        var end = text.find("\n", start)
        if end < 0:
            end = n
        var line = String(text[byte=start:end])
        start = end + 1

        var sev = 0
        var at = line.find(": error: ")
        var skip = 9
        if at < 0:
            at = line.find(": warning: ")
            skip = 11
            if at >= 0:
                sev = 2
        else:
            sev = 1
        if sev == 0:
            continue

        var message = String(line[byte = at + skip : line.byte_length()])

        # `path:line:col` reading right to left, because a path may itself
        # contain colons and the numbers may not.
        var head_end = at
        let col = _tail_int(line, head_end)
        if col < 0:
            continue
        let lb = line.as_bytes()
        var p = head_end
        while p > 0 and lb[p - 1] != COLON:
            p -= 1
        if p == 0:
            continue
        head_end = p - 1
        let lno = _tail_int(line, head_end)
        if lno < 0:
            continue
        p = head_end
        while p > 0 and lb[p - 1] != COLON:
            p -= 1
        if p == 0:
            continue
        var path = String(line[byte = 0 : p - 1])
        if path == "":
            continue
        issues.append(Issue(path^, lno, col, sev, message^))
    return issues^


def first_error(text: String) -> Issue:
    """The first real error, or a blank Issue if the log has none."""
    for issue in parse_issues(text):
        if issue.severity == 1:
            return issue
    return Issue(String(), 0, 0, 0, String())
