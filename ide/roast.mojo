# Roast — a Mojo IDE, written in cocoa-mojo. Milestone 0: the shell.
#
# A real Mac application window: menu bar, toolbar, source-list sidebar, split
# view, and a status bar. No editor yet — milestone 1 brings the rope and the
# grid view. What this proves is that the whole AppKit shell of a document app
# can be assembled from Mojo, with every delegate and action being a Mojo `fn`
# reached through classes registered at run time.
#
# Set ROAST_AUTOCLOSE_TICKS=N to close the window after N timer ticks, so the
# full lifecycle runs unattended in CI. Same trick as window_smoke.
from std.objc import (
    Obj,
    Cls,
    load_framework,
    ObjCClass,
    ObjCObject,
    msg_send,
    nsstring,
    autoreleasepool,
    IMP1,
    IMP1Bool,
    named_global,
    extern_object,
    sel,
    ObjCClassBuilder,
    new_instance,
)
from std.memory import OpaquePointer
from std.os import getenv
from std.time import sleep, perf_counter_ns
from std.ffi import external_call
from std.objc import ns_to_string, SEL
from gridview import (
    set_lncol_field,
    take_dropped,
    g_caret,
    selected_text,
    g_grid,
    make_grid_view,
    set_rope,
    document_size,
    GUTTER_W,
    set_query,
    find_next,
    find_previous,
    match_count,
    query,
    caret_position,
    line_height,
)
from rope import Rope
from gridview import (
    set_caret,
    document_size,
    g_revision,
    g_buffer,
    g_caret,
    show_popup,
    hide_popup,
    popup_open,
    byte_to_utf16,
    font_size,
    set_font_size,
)
import lsp
import document
import build
import session
import dap
import python_env
from json import JSON, parse
from gridview import set_shown_path, push_undo, replace_selection
from gridview import theme_names, current_theme, theme_is_dark, rebuild_theme
from gridview import theme_color, ROLE_SIDEBAR_BG, ROLE_SIDEBAR_TEXT

comptime P = OpaquePointer[MutUntrackedOrigin]


# Delegate methods that answer with an object return the `id` as an address,
# because they must be able to answer nil and Mojo's Pointer cannot be null.
# See the IMP*Obj note in std/objc/classes.mojo.
comptime NIL = 0


# Geometry comes from gridview, which needs the same structs to do its
# arithmetic. One declaration, not two that can drift.
from gridview import CGPoint, CGSize, CGRect, NSRange, rect


# ── State the callbacks can reach ────────────────────────────────────────────
# Callbacks are C-ABI `fn`s and get no closure, so anything they touch is a
# named process global. Each is zero until main() sets it.
comptime g_window = named_global["roast.window", Int]
comptime g_status = named_global["roast.status", Int]
# The build spinner beside the status text, and when the compile began --
# a static "Building..." reads as a hang once a compile takes real seconds.
comptime g_spinner = named_global["roast.spinner", Int]
comptime g_build_began = named_global["roast.build.began", Int]
# What was last written to the status line. The field itself is
# write-only in this code, and an agent asking "what is happening" has
# to be answered from somewhere.
comptime g_status_text = named_global["roast.status.text", List[String]]
comptime g_ticks = named_global["roast.ticks", Int]
comptime g_autoclose = named_global["roast.autoclose", Int]
comptime g_actions = named_global["roast.actions", Int]
comptime g_findfield = named_global["roast.findfield", Int]

# Edits bump gridview's revision; the timer notices and sends one didChange
# for a burst of typing rather than one per keystroke. (The uri and the
# sent revision live per-document in document.mojo.)
comptime g_idle_ticks = named_global["roast.idle", Int]

# The project: a folder, and the outline view showing what is in it. Children
# are listed on demand and cached per directory, so opening a folder never
# walks it -- a tree with a quarter of a million files under it costs whatever
# has been expanded and nothing more.
comptime g_root = named_global["roast.root", List[String]]
# Where the language server is currently rooted, so re-rooting it to the same
# place is recognised as the no-op it is rather than costing a process.
comptime g_lsp_root = named_global["roast.lsp.root", List[String]]
comptime g_outline = named_global["roast.outline", Int]
comptime g_tree_cache = named_global["roast.tree.cache", Int]

# The revision the file on disk matches. The buffer is dirty whenever the rope
# has moved past it, which is one comparison rather than a flag someone has to
# remember to set.
comptime g_tabbar = named_global["roast.tabbar", Int]

# The console, and the horizontal split it lives in the bottom of.
comptime g_console = named_global["roast.console", Int]
comptime g_vsplit = named_global["roast.vsplit", Int]
# The outer sidebar|editor split, kept for the same reason as g_vsplit: a
# divider nobody can address is a divider nobody can move.
comptime g_hsplit = named_global["roast.hsplit", Int]
comptime g_console_open = named_global["roast.console.open", Int]
# How many bytes of build.output() the console pane is already showing, so a
# pump appends the delta instead of re-setting the whole transcript.
comptime g_console_shown = named_global["roast.console.shown", Int]
comptime g_build_seen = named_global["roast.build.seen", Int]
# A venv creation may be the first half of Run, Debug, or pip. Its mode lives
# in build.label (the task state which is already proven to cross timer ticks);
# only pip's arbitrary requirement needs a separate owned string.
comptime g_python_spec = named_global["roast.python.spec", List[String]]
# The editor's share of the height when the console is showing.
comptime EDITOR_SHARE = 0.68
comptime TAB_H = 28.0
comptime TAB_MIN = 90.0
comptime TAB_MAX = 200.0
# The close box, and the gutter the strip reserves at each end for the overflow
# arrows. Both are in points; the scroll offset is whole points in an Int
# because an app-lifetime global has to survive zero-initialisation.
comptime TAB_CLOSE = 16.0
comptime TAB_GUTTER = 14.0
comptime g_tab_scroll = named_global["roast.tab.scroll", Int]
comptime g_pending_completion = named_global["roast.completing", Int]
# The last handshake this app has announced its open documents to.
comptime g_lsp_announced = named_global["roast.lsp.announced", Int]
comptime g_comp_seen = named_global["roast.comp.seen", Int]


def g_buffer_text() -> String:
    if len(g_buffer()[]) == 0:
        return String()
    return g_buffer()[][0].to_string()


def g_buffer_lines() -> Int:
    """Lines in the open buffer, for the startup report."""
    if len(g_buffer()[]) == 0:
        return 0
    return g_buffer()[][0].line_count()


def set_status(text: String):
    """Write the status bar. Safe before the field exists."""
    _remember_status(text)
    if g_status()[] == 0:
        return
    with autoreleasepool():
        let field = ObjCObject(g_status()[])
        Obj["NSTextField"](field.addr()).setStringValue(nsstring(text).ptr())


def _remember_status(text: String):
    """Keep the last status line where a reader can get at it."""
    let slot = g_status_text()
    if len(slot[]) == 0:
        slot[].append(text)
    else:
        slot[][0] = text


# ── Toolbar item identifiers ─────────────────────────────────────────────────
# NSToolbar addresses its items by string identifier; the delegate is asked for
# each one by name. Keeping them in one place keeps the three delegate methods
# honest with each other.
comptime TB_BUILD = "roast.build"
comptime TB_RUN = "roast.run"
comptime TB_STOP = "roast.stop"
# The debugger's transport controls. They sit in the bar at all times rather
# than appearing when a session starts: a toolbar that changes shape while you
# are reaching for it is worse than one whose items grey out, and NSToolbar
# already knows how to grey an item out.
comptime TB_DEBUG = "roast.debug"
comptime TB_CONTINUE = "roast.continue"
comptime TB_STEP_OVER = "roast.stepover"
comptime TB_STEP_IN = "roast.stepin"
comptime TB_STEP_OUT = "roast.stepout"
comptime TB_FIND = "roast.find"


def toolbar_ids() -> ObjCObject:
    """The toolbar's item identifiers, in bar order."""
    let NSMutableArray = ObjCClass.lookup["NSMutableArray"]()
    let ids = Cls["NSMutableArray"]().array()
    for name in [
        String(TB_BUILD),
        String(TB_RUN),
        String(TB_STOP),
        # A space, then the debugger's controls in the order you reach for
        # them: continue first, the three steps after it.
        String("NSToolbarSpaceItem"),
        # Debug starts the session; the four after it drive one. Without this
        # the step buttons imply a session the bar gives you no way to begin,
        # and the answer was a menu shortcut you had to know about.
        String(TB_DEBUG),
        String(TB_CONTINUE),
        String(TB_STEP_OVER),
        String(TB_STEP_IN),
        String(TB_STEP_OUT),
        # Flexible space then search: the find field sits at the trailing edge,
        # where every Mac app puts it.
        String("NSToolbarFlexibleSpaceItem"),
        String(TB_FIND),
    ]:
        Obj["NSMutableArray"](ids.addr()).addObject(nsstring(name).ptr())
    return ids


# ── Callbacks ────────────────────────────────────────────────────────────────
class RoastAppDelegate:
    """The application delegate.

    A `class` declaration is a real Objective-C class: the compiler derives
    each selector from the method name, takes its type encoding from the SDK,
    and registers the lot when the class is first instantiated. Nothing here
    names a selector, an encoding or an IMP.
    """

    def applicationDidFinishLaunching_(self, note: ObjCObject):
        print("roast: applicationDidFinishLaunching")

    def applicationShouldTerminateAfterLastWindowClosed_(
        self, app: ObjCObject
    ) -> Bool:
        # A single-window IDE quits with its window. Tabs live in one window,
        # so this stays true once tabbing is on.
        return True

    def application_openFile_(self, app: ObjCObject, path: ObjCObject) -> Bool:
        """Open a document: double-clicked in the Finder, dropped on the icon,
        or `open -a Roast foo.mojo`.

        AppKit sends this during launch as well as later, which is safe here
        because the window and its views are built before [NSApp run] -- so
        there is no moment when a path can arrive and find nothing to put it
        in. Returning False makes the Finder report that the app could not
        open the document, so the answer is the one open_path actually got.
        """
        try:
            let opened = open_path(ns_to_string(path))
            if opened:
                bring_to_front()
            return opened
        except:
            return False

    def application_openFiles_(self, app: ObjCObject, paths: ObjCObject):
        """Several at once -- a multiple selection, or a drop of more than one
        file. AppKit calls THIS and not openFile: when it exists, so both are
        implemented rather than trusting it to fall back.

        replyToOpenOrPrint: is not optional: without it the Finder waits, and
        during launch the app never finishes launching. 0 is success, 2 is
        failure, and a batch counts as opened if any of it did.
        """
        try:
            var any = False
            with autoreleasepool():
                let n = msg_send[Int, "NSArray", "count"](paths)
                var i = 0
                while i < n:
                    let one = ns_to_string(
                        msg_send[ObjCObject, "NSArray", "objectAtIndex:"](
                            paths, i
                        )
                    )
                    if open_path(one):
                        any = True
                    i += 1
            if any:
                bring_to_front()
            _ = msg_send[ObjCObject, "NSApplication", "replyToOpenOrPrint:"](
                app, Int(0) if any else Int(2)
            )
        except:
            try:
                _ = msg_send[
                    ObjCObject, "NSApplication", "replyToOpenOrPrint:"
                ](app, Int(2))
            except:
                pass

    def applicationWillTerminate_(self, note: ObjCObject):
        # The body may raise; the boundary catches. Hence no `try` around a
        # call that can only fail by the server having already gone.
        save_session()
        dap.stop()
        lsp.stop()
        print("roast: applicationWillTerminate")


# ── Console ─────────────────────────────────────────────────────────────────
# One pane for the compiler's output and the program's, because a build that
# succeeds and then runs is one continuous thing to read.
def _dir_of(path: String) -> String:
    let b = path.as_bytes()
    var cut = -1
    for i in range(len(b)):
        if b[i] == 47:
            cut = i
    if cut <= 0:
        return String(".")
    return String(path[byte=0:cut])


def console_sync():
    """Show the log and keep its tail in view.

    Appends what is new rather than re-setting the whole transcript: the pane
    is refreshed on every pump, so setString: made showing a program's output
    quadratic in its length -- a chatty Run got slower the longer it printed.
    The byte count tracks build.output(); a shorter output means it was
    cleared, and the pane starts over.
    """
    if g_console()[] == 0:
        return
    with autoreleasepool():
        let tv = ObjCObject(g_console()[])
        let text = build.output()
        let have = g_console_shown()[]
        if text.byte_length() < have:
            Obj["NSTextView"](tv.addr()).setString(nsstring(text).ptr())
        elif text.byte_length() > have:
            let delta = String(text[byte=have : text.byte_length()])
            let storage = Obj["NSTextView"](tv.addr()).textStorage()
            let at = Obj["NSTextStorage"](storage.addr()).length()
            # Plain-string replacement at the end takes its attributes from
            # the character before it, so the console keeps its font without
            # an attributed string being built per append.
            Obj["NSTextStorage"](storage.addr()).replaceCharactersInRange_withString(
                NSRange(at, 0),
                nsstring(delta).ptr(),
            )
        else:
            return
        g_console_shown()[] = text.byte_length()
        Obj["NSTextView"](tv.addr()).scrollToEndOfDocument(ObjCObject(0).ptr())


def console_text() -> String:
    """What the pane is actually showing, read back from AppKit rather than
    from the buffer it was built from -- so a check of this is a check of the
    whole path, not of a string we already had."""
    if g_console()[] == 0:
        return String()
    with autoreleasepool():
        return ns_to_string(
            Obj["NSTextView"](ObjCObject(g_console()[]).addr()).string()
        )


def show_console(want: Bool):
    """Slide the divider. The console is a pane, not a window, so hiding it is
    giving its height back to the editor rather than removing anything."""
    if g_vsplit()[] == 0:
        return
    with autoreleasepool():
        let vs = ObjCObject(g_vsplit()[])
        let b = Obj["NSView"](vs.addr()).bounds()
        var pos = b.size.height
        if want:
            pos = b.size.height * EDITOR_SHARE
        Obj["NSSplitView"](vs.addr()).setPosition_ofDividerAtIndex(pos, Int(0))
        let subs = Obj["NSView"](vs.addr()).subviews()
        print(
            "roast: console",
            "open" if want else "closed",
            Obj["NSView"](Obj["NSArray"](subs.addr()).objectAtIndex(1).addr()).frame().size.height,
        )
    g_console_open()[] = 1 if want else 0


# ── Where the toolchain is ──────────────────────────────────────────────────
comptime INSTALL_ROOT = "/Applications/Roast/CocoaMojo/current"


def is_toolchain(root: String) -> Bool:
    """A directory is a toolchain only if it can actually compile.

    Nothing here may assume a path exists because it was computed. The
    unchecked version of this handed NSTask a path that was not there, and
    NSTask raises rather than returning -- which ends the process.
    """
    if root == "":
        return False
    return file_exists(root + String("/bin/cocoamojo"))


def _bundle_toolchain() -> String:
    """Where the running binary would keep a toolchain of its own.

    NSBundle answers `Contents/Resources` inside an app and the
    executable's own directory outside one, so this covers a shipped
    bundle and a bare `roast` sitting beside a distribution alike.
    """
    try:
        with autoreleasepool():
            let NSBundle = ObjCClass.lookup["NSBundle"]()
            let main = msg_send[
                ObjCObject, "NSBundle", "mainBundle", is_class=True
            ](NSBundle.as_object())
            if main.addr() == 0:
                return String()
            let res = msg_send[ObjCObject, "NSBundle", "resourcePath"](main)
            if res.addr() == 0:
                return String()
            return ns_to_string(res) + String("/CocoaMojo")
    except:
        return String()


def toolchain_root() -> String:
    """The CocoaMojo this editor compiles, completes and runs with.

    One ordered list, every entry CHECKED rather than trusted:

      1. COCOAMOJO_ROOT      a harness, or the `cocoamojo` driver that
                             launched us, pointing somewhere deliberate
      2. beside the binary   an app carrying its own toolchain, or a bare
                             `roast` inside a distribution
      3. the installation    /Applications/Roast/CocoaMojo/current
      4. ~/Applications/...  the same, installed for one user

    The order serves both eras without a flag: while Roast still carries a
    toolchain, 2 answers; once it is thin, 2 does not exist and 3 does.
    And a child Roast -- built by this editor from the IDE source, running
    from a build directory with no environment and nothing beside it --
    reaches 3 and finds a real toolchain instead of a path that merely
    looked like one.
    """
    let env = getenv("COCOAMOJO_ROOT")
    if is_toolchain(env):
        return env^
    let beside = _bundle_toolchain()
    if is_toolchain(beside):
        return beside^
    if is_toolchain(String(INSTALL_ROOT)):
        return String(INSTALL_ROOT)
    let home = getenv("HOME")
    if home != "":
        let mine = home + String(INSTALL_ROOT)
        if is_toolchain(mine):
            return mine^
    return String()


def _driver() -> String:
    """The cocoamojo beside us. An editor built by this toolchain should
    compile with this toolchain, not with whatever is on PATH."""
    var here = getenv("ROAST_COCOAMOJO")
    if here != "":
        return here^
    let root = toolchain_root()
    if root == "":
        return String()
    return root + String("/bin/cocoamojo")


# ── Project Python ─────────────────────────────────────────────────────────
# A venv task records its continuation in build.label: Run, Debug, one pip
# requirement, or the project's requirements.txt/pyproject.toml.
def _python_project() -> String:
    return python_env.project_location(
        project_root(), document.path_at(document.current_index())
    )


def _put_python_spec(var spec: String):
    let slot = g_python_spec()
    if len(slot[]) == 0:
        slot[].append(spec^)
    else:
        slot[][0] = spec^


def _python_spec() -> String:
    let slot = g_python_spec()
    return slot[][0] if len(slot[]) > 0 else String()


def _python_variables() -> JSON:
    var env = python_env.variables(_python_project(), toolchain_root())
    # Builds, runs and debug sessions compile against the SAME stdlib the
    # server indexes and the person edits: the wrapper honours this.
    var std = stdlib_root()
    if std != "":
        env.set(String("COCOAMOJO_STDLIB"), JSON(std^))
    return env^


def _start_python_environment(after: Int = 0, spec: String = String()) -> Bool:
    """Create or repair this project's venv without blocking AppKit."""
    if build.is_running():
        set_status(String("Already running — press Stop first"))
        return False
    let project = _python_project()
    if project == "":
        set_status(String("Open a project or save the current file first"))
        return False
    let root = toolchain_root()
    let python = python_env.runtime_python(root)
    if python == "" or python_env.runtime_library(root) == "":
        set_status(
            String("Python was not installed — run the installer")
            + String(" again and tick Include Python")
        )
        return False
    let destination = python_env.environment_dir(project, root)
    if destination == "":
        set_status(String("Could not create the Python Application Support folder"))
        return False

    var args = List[String]()
    args.append(String("-m"))
    args.append(String("venv"))
    if python_env.environment_ready(project, root):
        # Refresh links and configuration after an application/runtime update;
        # installed project packages remain in place.
        args.append(String("--upgrade"))
    args.append(destination)

    _put_python_spec(spec)
    var label = String("Creating Python")
    if after == 1:
        label = String("Creating Python for Run")
    elif after == 2:
        label = String("Creating Python for Debug")
    elif after == 3:
        label = String("Creating Python for Package")
    elif after == 4:
        label = String("Creating Python for Project")
    build.clear_then()
    build.clear_output()
    build.append_output(
        String("Python environment: ") + destination + String("\n")
    )
    show_console(True)
    console_sync()
    if build.start_with_environment(
        python,
        args,
        project,
        label^,
        python_env.bootstrap_variables(root),
    ):
        set_status(String("Creating Python environment…"))
        return True
    _put_python_spec(String())
    set_status(String("Could not start the bundled Python runtime"))
    return False


def _ensure_python(after: Int, spec: String = String()) -> Bool:
    """True when this action can proceed now; otherwise queue it after venv."""
    let project = _python_project()
    let root = toolchain_root()
    if project == "" or not python_env.runtime_available(root):
        # Ordinary Mojo projects remain buildable if a development checkout
        # has not been packaged with Python yet. Explicit Python commands use
        # _start_python_environment and report that absence instead.
        return True
    if python_env.environment_ready(project, root):
        return True
    _ = _start_python_environment(after, spec)
    return False


def _start_pip(var args: List[String]) -> Bool:
    let project = _python_project()
    let root = toolchain_root()
    if not python_env.environment_ready(project, root):
        set_status(String("Create the project Python environment first"))
        return False
    let python = python_env.environment_python(project, root)
    build.clear_then()
    build.clear_output()
    var command = String("pip")
    for arg in args:
        command += String(" ") + arg
    build.append_output(
        String("Python environment: ")
        + python_env.environment_dir(project, root)
        + String("\n")
        + command
        + String("\n")
    )
    show_console(True)
    console_sync()
    if build.start_with_environment(
        python,
        args,
        project,
        String("Installing Python"),
        python_env.pip_variables(project, root),
    ):
        set_status(String("Installing Python packages…"))
        return True
    set_status(String("Could not start pip"))
    return False


def _install_python_requirement(var spec: String):
    if spec.strip() == "":
        return
    if not _ensure_python(3, spec):
        return
    var args = python_env.package_arguments(spec^, _python_project())
    if len(args) > 3:
        _ = _start_pip(args^)


def _install_project_dependencies():
    if not _ensure_python(4):
        return
    var args = python_env.project_dependency_arguments(_python_project())
    if len(args) == 0:
        set_status(String("No requirements.txt or pyproject.toml in this project"))
        return
    _ = _start_pip(args^)


def _save_dirty() -> Int:
    """The compiler reads the disk, so what is on the disk had better be what
    is on the screen. Building without this compiles the last save, which
    looks exactly like the compiler ignoring your fix."""
    let n = document.dirty_count()
    if n == 0:
        return 0
    let started_at = document.current_index()
    var saved = 0
    var i = 0
    while i < document.count():
        if document.dirty_at(i) and document.path_at(i) != "":
            _ = switch_document(i)
            _ = save_current()
            saved += 1
        i += 1
    _ = switch_document(started_at)
    refresh_tabs()
    refresh_grid()
    return saved


def _start_build(then_run: Bool):
    if build.is_running():
        set_status(String("Already running — press Stop first"))
        return
    if then_run and not _ensure_python(1):
        return
    let driver = _driver()
    if driver == "":
        set_status(String("No compiler: set COCOAMOJO_ROOT"))
        return

    let saved = _save_dirty()
    let entry = build.entry_point(
        project_root(), document.path_at(document.current_index())
    )
    if entry == "":
        set_status(String("Nothing to build — open a file or a folder"))
        return

    let binary = build.binary_for(entry)
    _ = build.ensure_dir(_dir_of(binary))
    build.clear_output()
    var head = String("cocoamojo --build ") + entry
    head += String(" -o ") + binary + String("\n")
    if saved > 0:
        head = String("saved ") + String(saved) + String(" file(s)\n") + head
    build.append_output(head^)

    var args = List[String]()
    args.append(String("--build"))
    args.append(entry)
    args.append(String("-o"))
    args.append(binary)

    # Run is Build followed by the binary. Queue the second half now; the
    # timer starts it if and only if the first half exits zero.
    if then_run:
        build.set_then(binary, _dir_of(entry))
    else:
        build.clear_then()

    show_console(True)
    console_sync()
    if build.start_with_environment(
        driver,
        args,
        _dir_of(entry),
        String("Building"),
        _python_variables(),
    ):
        set_status(String("Building ") + _basename(entry) + String("…"))
    else:
        console_sync()
        set_status(String("Could not start the compiler"))


# ── Debugging ───────────────────────────────────────────────────────────────
# Roast does not debug Mojo; lldb-dap does, and dap.mojo talks to it. What is
# here is the part an editor owns: where the adapter lives, building with
# debug info before launching it, and moving the caret to wherever the
# program stopped.
comptime g_dap_seen = named_global["roast.dap.seen", Int]
comptime g_def_seen = named_global["roast.def.seen", Int]
# The ROAST_DEFINE door's target, and whether it has fired.
comptime g_define_line = named_global["roast.define.line", Int]
comptime g_define_col = named_global["roast.define.col", Int]
comptime g_define_done = named_global["roast.define.done", Int]
# The references and signature doors share the definition door's machinery:
# one place, one kind, fired once the server has the document.
comptime g_probe_line = named_global["roast.probe.line", Int]
comptime g_probe_col = named_global["roast.probe.col", Int]
comptime g_probe_kind = named_global["roast.probe.kind", Int]
comptime g_probe_done = named_global["roast.probe.done", Int]
comptime g_probe_name = named_global["roast.probe.name", List[String]]


def _put_rename_name(var name: String):
    let slot = g_probe_name()
    if len(slot[]) == 0:
        slot[].append(name^)
    else:
        slot[][0] = name^
comptime g_hover_seen = named_global["roast.hover.seen", Int]
comptime g_ref_seen = named_global["roast.ref.seen", Int]
comptime g_sig_seen = named_global["roast.sig.seen", Int]
# Where the cycle through references has got to.
comptime g_ref_at = named_global["roast.ref.at", Int]
# ROAST_DEBUG_STEPS: which button gets pressed at the next stop.
comptime g_dbg_step_i = named_global["roast.dbg.step.i", Int]
comptime g_shot_i = named_global["roast.dbg.shot.i", Int]
# Bumped each time a fresh locals block is rendered; the agent walk keys on it
# so it acts when the locals are ON SCREEN, not merely when the stop event
# arrived -- variables come from the adapter a tick or two later.
comptime g_vars_serial = named_global["roast.dbg.vars.serial", Int]
comptime g_vars_acted = named_global["roast.dbg.vars.acted", Int]
comptime g_ren_seen = named_global["roast.ren.seen", Int]


def dap_adapter() -> String:
    """The debug adapter. A setting first, so someone with their own lldb can
    say so and have it remembered; then the toolchain's OWN lldb-dap, which
    ships with the MojoLLDB plugin beside it and is the difference between
    "the editor follows the stop" and "frame variable answers"
    (spikes/MOJOLLDB-SPIKE.md); then Xcode's, which debugs but cannot
    inspect a Mojo variable."""
    let chosen = session.setting(String("debug.adapter"))
    if chosen != "" and file_exists(chosen):
        return chosen^
    let env = getenv("ROAST_DAP")
    if env != "":
        return env^
    let root = toolchain_root()
    if root != "":
        let ours = root + String("/bin/lldb-dap")
        if file_exists(ours):
            return ours^
    let xcode = String(
        "/Applications/Xcode.app/Contents/Developer/usr/bin/lldb-dap"
    )
    return xcode if file_exists(xcode) else String()


def dap_plugin(adapter: String) -> String:
    """The MojoLLDB plugin that belongs to `adapter`, or nothing.

    Looked for BESIDE the adapter (bin/lldb-dap -> lib/libMojoLLDB.dylib)
    rather than in our own toolchain, because the plugin must match the
    liblldb the adapter links -- handing our plugin to Xcode's lldb-dap is
    an ABI mismatch, and the reason the whole spike exists."""
    let slash = adapter.rfind("/")
    if slash < 0:
        return String()
    let plugin = (
        String(adapter[byte=0:slash]) + String("/../lib/libMojoLLDB.dylib")
    )
    return plugin if file_exists(plugin) else String()


def _start_debug():
    """Build with debug info, then hand the binary to the adapter.

    A separate path from Build rather than a flag on it, because the two want
    different compilers: an optimised build is what you ship and a
    debug-level-full build is what you can step through. Sharing one output
    would mean the last thing you pressed decides what the other one does.
    """
    if dap.is_running():
        set_status(String("Already debugging — Stop first (⌘.)"))
        return
    if not _ensure_python(2):
        return
    let adapter = dap_adapter()
    if adapter == "":
        set_status(String("No debug adapter: install Xcode, or set debug.adapter"))
        return
    let driver = _driver()
    if driver == "":
        set_status(String("No compiler: set COCOAMOJO_ROOT"))
        return
    let saved = _save_dirty()
    let entry = build.entry_point(
        project_root(), document.path_at(document.current_index())
    )
    if entry == "":
        set_status(String("Nothing to debug — open a file or a folder"))
        return
    let binary = build.binary_for(entry) + String("-debug")
    _ = build.ensure_dir(_dir_of(binary))
    build.clear_output()
    dap.clear_output()
    var head = String("cocoamojo --build ") + entry
    head += String(" --debug-level full --no-optimization -o ") + binary
    head += String("\n")
    if saved > 0:
        head = String("saved ") + String(saved) + String(" file(s)\n") + head
    build.append_output(head^)

    var args = List[String]()
    args.append(String("--build"))
    args.append(entry)
    args.append(String("--debug-level"))
    args.append(String("full"))
    # Unoptimised as well as annotated, and the second is not optional. With
    # optimisation on, `total` and `sum` in a five-line program are not in the
    # DWARF at all -- eliminated before any debug info could describe them --
    # and breakpoints slide to whatever line survived. Measured on exactly
    # that program: -O0 puts both locals back and the breakpoint binds on the
    # line that was clicked instead of the next one down.
    args.append(String("--no-optimization"))
    args.append(String("-o"))
    args.append(binary)
    # The adapter is started by _build_finished when this exits zero, the
    # same way Run is queued behind Build -- one place decides whether a
    # compile succeeded, and it is not here.
    build.set_then(String(""), _dir_of(entry))
    g_debug_pending()[] = 1
    _put_debug_binary(binary)
    show_console(True)
    console_sync()
    if build.start_with_environment(
        driver,
        args,
        _dir_of(entry),
        String("Building"),
        _python_variables(),
    ):
        set_status(String("Building ") + _basename(entry) + String(" to debug…"))
    else:
        g_debug_pending()[] = 0
        console_sync()
        set_status(String("Could not start the compiler"))


comptime g_debug_pending = named_global["roast.debug.pending", Int]
comptime g_debug_binary = named_global["roast.debug.binary", List[String]]


def _put_debug_binary(var path: String):
    let slot = g_debug_binary()
    if len(slot[]) == 0:
        slot[].append(path^)
    else:
        slot[][0] = path^


def _debug_binary() -> String:
    let slot = g_debug_binary()
    return slot[][0] if len(slot[]) > 0 else String()


def _launch_debugger():
    """The compile succeeded; start the adapter on what it produced."""
    g_debug_pending()[] = 0
    let binary = _debug_binary()
    if binary == "":
        return
    let cwd = _dir_of(binary)
    let plugin = dap_plugin(dap_adapter())
    var init_cmd = String()
    if plugin != "":
        init_cmd = String("plugin load ") + plugin
    var pre_run = String()
    if plugin != "" and session.setting(String("debug.break_on_raise")) == "1":
        # The plugin's own command: stop where an error is RAISED rather
        # than where it lands. preRun rather than init, because it needs a
        # target to set its resolver on.
        pre_run = String("mojo break-on-raise")
    let started = dap.start_with_environment(
        dap_adapter(),
        binary,
        cwd,
        init_cmd,
        pre_run,
        _python_variables(),
    )
    print(
        "roast: debugging", _basename(binary),
        "with", dap.breakpoint_count(), "breakpoint(s)",
    )
    if started:
        g_dap_seen()[] = dap.serial()
        build.append_output(
            String("\n─── debugging ") + _basename(binary) + String(" ───\n")
        )
        console_sync()
        set_status(
            String("Debugging — ")
            + String(dap.breakpoint_count())
            + String(" breakpoint(s)")
        )
    else:
        set_status(String("Could not start the debug adapter"))


def _nth_csv(s: String, want: Int) -> String:
    """The want-th comma-separated field of s, or empty past the end."""
    var rest = s
    var i = 0
    while True:
        let cut = rest.find(",")
        if cut < 0:
            if i == want:
                return rest
            return String()
        if i == want:
            return String(rest[byte=:cut])
        let tail = String(rest[byte = cut + 1 : rest.byte_length()])
        rest = tail
        i += 1


def _trace_debug_action(name: String):
    """A rule in the console for each transport action, so the trace reads
    action -> where it landed -> locals, the way a person replays a session.
    Only while stopped: a marker for a press that did nothing is noise."""
    try:
        if not dap.is_stopped():
            return
        build.append_output(
            String("==== debug: ") + name + String(" ====\n")
        )
        console_sync()
    except:
        pass


def _press_debug_button(name: String) -> Bool:
    """Press one of the debugger's toolbar buttons the way a click does.

    The item is looked up in the LIVE toolbar by identifier and its action is
    sent to its own target through NSApp -- not a direct call to the handler.
    A button missing from the bar, wired to the wrong selector, or aimed at a
    dead target all fail here exactly as they would under the pointer, which
    is the point: ROAST_DEBUG_LINE proves the debug session, this proves the
    buttons.
    """
    var ident = String()
    if name == "continue":
        ident = String(TB_CONTINUE)
    elif name == "over":
        ident = String(TB_STEP_OVER)
    elif name == "in":
        ident = String(TB_STEP_IN)
    elif name == "out":
        ident = String(TB_STEP_OUT)
    else:
        return False
    with autoreleasepool():
        if g_window()[] == 0:
            return False
        let win = ObjCObject(g_window()[])
        let tb = Obj["NSWindow"](win.addr()).toolbar()
        if tb.addr() == 0:
            return False
        let items = Obj["NSToolbar"](tb.addr()).items()
        let n = Obj["NSArray"](items.addr()).count()
        let app = Cls["NSApplication"]().sharedApplication()
        var i = 0
        while i < n:
            let item = Obj["NSArray"](items.addr()).objectAtIndex(i)
            let iid = Obj["NSToolbarItem"](item.addr()).itemIdentifier()
            if Obj["NSString"](iid.addr()).isEqualToString(
                nsstring(ident).ptr()
            ):
                let target = Obj["NSToolbarItem"](item.addr()).target()
                if name == "continue":
                    _ = Obj["NSApplication"](app.addr()).sendAction_to_from(
                        sel["roastContinue:"]().ptr(), target.ptr(), item.ptr()
                    )
                elif name == "over":
                    _ = Obj["NSApplication"](app.addr()).sendAction_to_from(
                        sel["roastStepOver:"]().ptr(), target.ptr(), item.ptr()
                    )
                elif name == "in":
                    _ = Obj["NSApplication"](app.addr()).sendAction_to_from(
                        sel["roastStepIn:"]().ptr(), target.ptr(), item.ptr()
                    )
                else:
                    _ = Obj["NSApplication"](app.addr()).sendAction_to_from(
                        sel["roastStepOut:"]().ptr(), target.ptr(), item.ptr()
                    )
                return True
            i += 1
        return False


def _debug_changed():
    """The program stopped, resumed or exited. Follow it."""
    if dap.exited():
        set_status(String("Program exited"))
        refresh_grid()
        let shots_on_exit = getenv("ROAST_AGENT_SHOTS")
        if shots_on_exit != "":
            # The proof the trace SURVIVES the session: photographed after
            # exit, not during a stop. Nothing clears the console here; only
            # the next build or debug does.
            print("roast: agent shot ->", agent_send_self(
                String("screenshot ") + shots_on_exit
                + String("/after-exit.png")))
        return
    if not dap.is_stopped():
        refresh_grid()
        return
    # Show the file it stopped in, which may not be the one on screen -- a
    # breakpoint in an imported file is the common case, exactly as with a
    # build error.
    let where = dap.stop_file()
    if where != "":
        let uri = String("file://") + where
        let tab = document.index_of(uri)
        if tab >= 0:
            _ = switch_document(tab)
            after_switch()
        elif file_exists(where):
            if load_file(where):
                after_switch()
    # The pane holding the session's trace opens if anything closed it --
    # the window builds with it shut, and an early layout pass can stomp the
    # divider after _start_debug opened it. A stopped debugger whose locals
    # sit in a zero-height pane reads as a debugger doing nothing, which is
    # exactly how it read.
    if g_console_open()[] == 0:
        show_console(True)

    let line = dap.stop_line()
    if line > 0 and len(g_buffer()[]) > 0:
        let rope = g_buffer()[][0]
        var target = line - 1
        if target < 0:
            target = 0
        if target >= rope.line_count():
            target = rope.line_count() - 1
        set_caret(rope.line_start(target))
        scroll_to_caret()
    set_status(
        String("Stopped: ")
        + dap.stop_reason()
        + String("  ·  ")
        + _basename(where)
        + String(":")
        + String(line)
    )
    print(
        "roast: debug stopped at",
        _basename(where) + String(":") + String(line),
        "reason",
        dap.stop_reason(),
    )
    _show_variables()
    _show_eval()
    refresh_grid()

    # Unattended stepping: one toolbar press per stop, from the list in
    # ROAST_DEBUG_STEPS ("in,over,out,continue"). The press is logged before
    # the next stop is, so the output reads press -> stop -> press -> stop
    # and a check can follow the whole walk.
    # The same walk, driven over Apple Events instead of by a direct call:
    # each verb is posted to this process and dispatched by the handler, so
    # the whole agent path -- event, unpack, dispatch, toolbar item, target --
    # is exercised against a live debug session.
    # Gate the probe on the locals having RENDERED for this stop: act once
    # per landing, photograph what a person would actually see, and only then
    # press the next button.
    let probing = getenv("ROAST_AGENT_SHOTS") != "" \
        or getenv("ROAST_AGENT_STEPS") != ""
    if probing and g_vars_serial()[] == g_vars_acted()[]:
        return
    g_vars_acted()[] = g_vars_serial()[]

    let shots_at_stop = getenv("ROAST_AGENT_SHOTS")
    if shots_at_stop != "":
        # Its own counter: the step index is consumed by the walk, and two
        # stops writing one filename loses every picture but the last.
        g_shot_i()[] = g_shot_i()[] + 1
        print("roast: agent shot ->", agent_send_self(
            String("screenshot ") + shots_at_stop + String("/stop-")
            + String(g_shot_i()[]) + String("-line") + String(line)
            + String(".png")))

    let agent_steps = getenv("ROAST_AGENT_STEPS")
    if agent_steps != "":
        let aidx = g_dbg_step_i()[]
        let averb = _nth_csv(agent_steps, aidx)
        if averb != "":
            g_dbg_step_i()[] = aidx + 1
            # A person's cadence, not a machine's: the earlier walk finished
            # in well under a second and nobody could SEE the highlight move.
            sleep(0.25)
            # Ask the debugger where it is and what it holds -- over an
            # event, before stepping. Line numbers alone would not show the
            # transport carrying anything: these values come out of the live
            # debuggee, through the adapter, through the handler, and back in
            # a reply descriptor.
            print("roast: agent ask stopped ->", agent_send_self(String("stopped")))
            print("roast: agent ask vars ->", agent_send_self(String("variables")))
            print(
                "roast: agent step", averb, "at line", line,
                "->", agent_send_self(averb),
            )

    let steps = getenv("ROAST_DEBUG_STEPS")
    if steps != "":
        let idx = g_dbg_step_i()[]
        let name = _nth_csv(steps, idx)
        if name != "":
            g_dbg_step_i()[] = idx + 1
            if _press_debug_button(name):
                print("roast: debug pressed", name, "(toolbar) at line", line)
            else:
                print("roast: debug press FAILED for", name)


def _show_eval():
    """One evaluation's answer, into the console. Failure prints too --
    the JIT's complaint is the answer when the expression was wrong."""
    if not dap.take_eval_fresh():
        return
    var block = String("  eval ") + dap.eval_expr()
    if dap.eval_ok():
        block += String(" = ") + dap.eval_result() + String("\n")
    else:
        block += String("  — ") + dap.eval_result() + String("\n")
    build.append_output(block^)
    console_sync()


def _pretty_type(raw: String) -> String:
    """The type as a person would write it. The DWARF names scalars by their
    MLIR spelling -- `!kgen.scalar<index>` is what every `Int` in the
    program prints as -- and a locals view full of MLIR is a locals view
    nobody reads. Unrecognised types pass through untouched."""
    # Every scalar the compiler spells in MLIR, not the four that happened
    # to come up first: `peak: __mlir_type.`!kgen.scalar<ui32>`` is what a
    # UInt32 looked like in the locals view until now.
    for pair in [
        (String("scalar<index>"), String("Int")),
        (String("scalar<bool>"), String("Bool")),
        (String("scalar<f64>"), String("Float64")),
        (String("scalar<f32>"), String("Float32")),
        (String("scalar<f16>"), String("Float16")),
        (String("scalar<bf16>"), String("BFloat16")),
        (String("scalar<si8>"), String("Int8")),
        (String("scalar<si16>"), String("Int16")),
        (String("scalar<si32>"), String("Int32")),
        (String("scalar<si64>"), String("Int64")),
        (String("scalar<ui8>"), String("UInt8")),
        (String("scalar<ui16>"), String("UInt16")),
        (String("scalar<ui32>"), String("UInt32")),
        (String("scalar<ui64>"), String("UInt64")),
    ]:
        if raw.find(pair[0]) >= 0:
            return pair[1]
    return raw


def _show_variables():
    """The stopped frame's locals, into the console.

    The console rather than a new pane, deliberately: it is where a debug
    session's output already goes, it scrolls, and it needed zero new Cocoa
    surface -- so variables shipped the same day the plugin did. A dedicated
    pane with expandable children is the upgrade, not the prerequisite."""
    if not dap.take_variables_fresh():
        return
    let n = dap.variable_count()
    if n == 0:
        return
    g_vars_serial()[] = g_vars_serial()[] + 1
    var block = String("── locals · ") + _basename(dap.stop_file())
    block += String(":") + String(dap.stop_line()) + String(" ──\n")
    # `name: Type` built first so the values can share a column. A locals
    # view is read by running an eye down it, and ragged `=` signs make
    # that a search instead.
    var labels = List[String]()
    var width = 0
    for i in range(n):
        var label = dap.variable_name(i)
        let t = _pretty_type(dap.variable_type(i))
        if t != "":
            label += String(": ") + t
        let w = len(label.codepoints())
        if w > width:
            width = w
        labels.append(label^)
    for i in range(n):
        block += String("  ") + labels[i]
        let value = dap.variable_value(i)
        # Pad only when something follows. A line that ends in the column
        # padding is a line with trailing spaces, which shows up in a diff
        # and in anything a person copies out of the console.
        if value != "" and value != _pretty_type(dap.variable_type(i)):
            var pad = width - len(labels[i].codepoints())
            while pad > 0:
                block += String(" ")
                pad -= 1
        # A value that only repeats the type says nothing: `rng: Rng = Rng`
        # is one fact printed twice. The type already carried it.
        if value == _pretty_type(dap.variable_type(i)) or value == "":
            block += String("\n")
            continue
        # lldb says `<error: variable not available>` for a local that is
        # declared but not yet live. That is an ordinary state at a
        # breakpoint on the first line, and reading it as an error sends
        # people looking for a fault that is not there.
        if value.find("variable not available") >= 0:
            block += String("   — not yet in scope\n")
            continue
        block += String(" = ") + value + String("\n")
    # The stack under the locals: how the program got here, top first. The
    # runtime's startup frames are real but nobody is debugging THEM, so the
    # walk stops at the first frame whose source is not the user's -- which
    # in practice is `__wrap_and_execute_main` in _startup.mojo.
    if dap.frame_count() > 1:
        block += String("  stack:\n")
        for i in range(dap.frame_count()):
            let file = dap.frame_file(i)
            if i > 0 and file.find("_startup.mojo") >= 0:
                break
            block += String("    ") + dap.frame_name(i)
            if file != "":
                block += (
                    String("  ·  ") + _basename(file) + String(":")
                    + String(dap.frame_line(i))
                )
            block += String("\n")
    build.append_output(block^)
    console_sync()


# ── Navigation ──────────────────────────────────────────────────────────────
# The language server has advertised definitionProvider and hoverProvider
# since the first handshake, and nothing had ever asked. Eleven capabilities
# came back; two were used. These are the two worth the least code and the
# most in a day's editing.
def ask_definition() -> Bool:
    """Where is the thing under the caret defined?"""
    if not lsp.is_ready() or document.current_uri() == "":
        set_status(String("No language server"))
        return False
    if len(g_buffer()[]) == 0:
        return False
    let buf = g_buffer()[][0]
    let line = buf.line_of_offset(g_caret()[])
    # UTF-16, because that is what the protocol counts in -- the same
    # conversion completion already makes.
    let col = byte_to_utf16(g_caret()[]) - byte_to_utf16(buf.line_start(line))
    flush_pending_edit()
    _ = lsp.request_definition(document.current_uri(), line, col)
    set_status(String("Looking…"))
    return True


def ask_hover() -> Bool:
    if not lsp.is_ready() or document.current_uri() == "":
        return False
    if len(g_buffer()[]) == 0:
        return False
    let buf = g_buffer()[][0]
    let line = buf.line_of_offset(g_caret()[])
    let col = byte_to_utf16(g_caret()[]) - byte_to_utf16(buf.line_start(line))
    flush_pending_edit()
    _ = lsp.request_hover(document.current_uri(), line, col)
    return True


def _go_to_definition():
    """The answer arrived. Open it and put the caret on it.

    Through the same door a build error uses, because they are the same
    action: a place in a file that may not be open. The one difference is
    the message, since "no definition" is a normal answer to a question
    about a local and a build error is never normal.
    """
    let uri = lsp.definition_uri()
    let line = lsp.definition_line()
    if uri == "" or line < 0:
        set_status(String("No definition found"))
        return
    # Sliced out of a separate binding, the way Document.name does it:
    # `path = String(path[...])` reads and writes the same value in one
    # expression, which the compiler rightly refuses.
    let full = uri
    var path = full
    if full.startswith("file://"):
        path = uri_to_path(full)
    if not file_exists(path):
        set_status(String("Definition is in a file that is not there: ") + path)
        return
    # The server counts from zero and _jump_to takes the compiler's
    # one-based convention.
    _jump_to(path, line + 1, lsp.definition_character() + 1)
    print(
        "roast: definition ->",
        _basename(path) + String(":") + String(line + 1),
    )
    set_status(
        String("→ ") + _basename(path) + String(":") + String(line + 1)
    )


def ask_references() -> Bool:
    if not lsp.is_ready() or document.current_uri() == "":
        set_status(String("No language server"))
        return False
    if len(g_buffer()[]) == 0:
        return False
    let buf = g_buffer()[][0]
    let line = buf.line_of_offset(g_caret()[])
    let col = byte_to_utf16(g_caret()[]) - byte_to_utf16(buf.line_start(line))
    flush_pending_edit()
    _ = lsp.request_references(document.current_uri(), line, col)
    set_status(String("Searching…"))
    return True


def ask_signature() -> Bool:
    if not lsp.is_ready() or document.current_uri() == "":
        return False
    if len(g_buffer()[]) == 0:
        return False
    let buf = g_buffer()[][0]
    let line = buf.line_of_offset(g_caret()[])
    let col = byte_to_utf16(g_caret()[]) - byte_to_utf16(buf.line_start(line))
    flush_pending_edit()
    _ = lsp.request_signature(document.current_uri(), line, col)
    return True


def _ref_path(i: Int) -> String:
    let full = lsp.reference_uri(i)
    if full.startswith("file://"):
        return uri_to_path(full)
    return full


def _show_references():
    """The list goes to the console, and the caret goes to the first.

    The console because it is already a scrolling pane of text that someone
    is looking at during a build, and because `path:line:col:` is the shape
    the compiler's own diagnostics take -- so a list of references reads like
    the rest of what appears there rather than like a new kind of thing.
    """
    let n = lsp.reference_count()
    g_ref_at()[] = 0
    if n == 0:
        set_status(String("No references found"))
        return
    var out = String("\n─── ") + String(n)
    out += String(" reference" if n == 1 else " references")
    out += String(" ───\n")
    var i = 0
    while i < n:
        let path = _ref_path(i)
        out += path
        out += String(":")
        out += String(lsp.reference_line(i) + 1)
        out += String(":")
        out += String(lsp.reference_character(i) + 1)
        out += String("\n")
        i += 1
    build.append_output(out^)
    show_console(True)
    console_sync()
    print("roast: references", n)
    _go_to_reference(0)


def _go_to_reference(index: Int):
    let n = lsp.reference_count()
    if n == 0:
        return
    var at = index % n
    if at < 0:
        at += n
    g_ref_at()[] = at
    let path = _ref_path(at)
    if path == "" or not file_exists(path):
        return
    _jump_to(path, lsp.reference_line(at) + 1, lsp.reference_character(at) + 1)
    set_status(
        String("Reference ")
        + String(at + 1)
        + String(" of ")
        + String(n)
        + String("  ·  ")
        + _basename(path)
        + String(":")
        + String(lsp.reference_line(at) + 1)
    )


def _offset_of(rope: Rope, line: Int, character: Int) -> Int:
    """A protocol position as a byte offset in this rope.

    `character` counts UTF-16 units, which for an identifier is the same as
    bytes and for a line with an emoji in it is not. Walked rather than
    assumed, because the one time it differs is the one time a rename would
    silently cut a character in half.
    """
    if line < 0 or line >= rope.line_count():
        return -1
    let start = rope.line_start(line)
    if character <= 0:
        return start
    let text = rope.line(line)
    var seen = 0
    var at = start
    for c in text.codepoints():
        if seen >= character:
            break
        seen += 2 if Int(c) > 0xFFFF else 1
        at += len(String(c).as_bytes())
    return at


def ask_rename(new_name: String) -> Bool:
    if not lsp.is_ready() or document.current_uri() == "":
        set_status(String("No language server"))
        return False
    if len(g_buffer()[]) == 0 or new_name == "":
        return False
    let buf = g_buffer()[][0]
    let line = buf.line_of_offset(g_caret()[])
    let col = byte_to_utf16(g_caret()[]) - byte_to_utf16(buf.line_start(line))
    flush_pending_edit()
    _ = lsp.request_rename(document.current_uri(), line, col, new_name)
    set_status(String("Renaming…"))
    return True


def _rename_path(i: Int) -> String:
    let full = lsp.rename_uri(i)
    if full.startswith("file://"):
        return uri_to_path(full)
    return full


def _apply_rename():
    """Apply the WorkspaceEdit the server sent back.

    Two rules decide whether this is correct or a corrupter of files.

    Edits within a file are applied BACK TO FRONT. Every edit is a range in
    the text as it was when the server read it, so applying the first one
    shifts every range after it; going backwards means no edit ever moves a
    range that has not been applied yet. The server does not promise an
    order, so they are sorted here rather than trusted.

    And each file gets ONE undo entry, taken before its first edit. A rename
    is one action to the person who asked for it, and undoing it one
    occurrence at a time would be its own kind of damage.

    Files are left dirty rather than saved. A rename touching a file nobody
    has looked at is exactly when someone wants to look before committing to
    it, and Build saves dirty files anyway.
    """
    let n = lsp.rename_count()
    if n == 0:
        print("roast: renamed 0 — the server returned no edits")
        set_status(String("Nothing renamed — no occurrences, or not renameable"))
        return
    let started_at = document.current_index()
    var files = 0
    var edits_done = 0

    # One pass per distinct file, found by scanning rather than by building a
    # set: a rename touches a handful of files, and a set would cost more to
    # write than it saves.
    var seen = List[String]()
    var i = 0
    while i < n:
        let path = _rename_path(i)
        var already = False
        for s in seen:
            if s == path:
                already = True
                break
        if already or path == "" or not file_exists(path):
            i += 1
            continue
        seen.append(path)

        let uri = String("file://") + path
        var tab = document.index_of(uri)
        if tab < 0:
            if not load_file(path):
                i += 1
                continue
            tab = document.index_of(uri)
        if tab < 0 or not switch_document(tab):
            if document.current_index() != tab:
                i += 1
                continue

        # This file's edits, sorted by position, applied backwards.
        var idx = List[Int]()
        var j = 0
        while j < n:
            if _rename_path(j) == path:
                idx.append(j)
            j += 1
        # Insertion sort by (line, character): a handful of edits, and the
        # order has to be exact rather than fast.
        var a = 1
        while a < len(idx):
            let key = idx[a]
            var b = a - 1
            while b >= 0 and (
                lsp.rename_start_line(idx[b]) > lsp.rename_start_line(key)
                or (
                    lsp.rename_start_line(idx[b]) == lsp.rename_start_line(key)
                    and lsp.rename_start_char(idx[b])
                    > lsp.rename_start_char(key)
                )
            ):
                idx[b + 1] = idx[b]
                b -= 1
            idx[b + 1] = key
            a += 1

        if len(g_buffer()[]) == 0:
            i += 1
            continue
        push_undo()
        var k = len(idx) - 1
        var applied = 0
        while k >= 0:
            let e = idx[k]
            let rope = g_buffer()[][0]
            let from_ = _offset_of(
                rope, lsp.rename_start_line(e), lsp.rename_start_char(e)
            )
            let to_ = _offset_of(
                rope, lsp.rename_end_line(e), lsp.rename_end_char(e)
            )
            if from_ >= 0 and to_ >= from_:
                set_rope(rope.replace(from_, to_, lsp.rename_text(e)))
                applied += 1
            k -= 1
        if applied > 0:
            files += 1
            edits_done += applied
            set_caret(min(g_caret()[], g_buffer()[][0].byte_length()))
        i += 1

    _ = switch_document(started_at)
    after_switch()
    refresh_tabs()
    refresh_grid()
    print("roast: renamed", edits_done, "in", files, "file(s)")
    if getenv("ROAST_RENAME") != "" and len(g_buffer()[]) > 0:
        # The count is not the claim; the text is. A door that reports two
        # edits over a buffer saying something else is the exact failure a
        # rename has, and the only way to see it is to print the lines.
        let rope = g_buffer()[][0]
        var ln = 0
        while ln < rope.line_count():
            let text = rope.line(ln)
            if text != "":
                print("roast: line", ln + 1, repr(text))
            ln += 1
    set_status(
        String("Renamed ")
        + String(edits_done)
        + String(" occurrence" if edits_done == 1 else " occurrences")
        + String(" in ")
        + String(files)
        + String(" file" if files == 1 else " files")
        + String(" — unsaved")
    )


def ask_new_name(old: String) -> String:
    """The rename prompt. An alert with a text field in it, which is what a
    Mac app uses when it needs one short string and nothing else."""
    with autoreleasepool():
        let NSAlert = ObjCClass.lookup["NSAlert"]()
        var alert = msg_send[ObjCObject, "NSAlert", "alloc", is_class=True](
            NSAlert.as_object()
        )
        alert = msg_send[ObjCObject, "NSObject", "init"](alert)
        _ = msg_send[ObjCObject, "NSAlert", "setMessageText:"](
            alert, nsstring(String("Rename")).ptr()
        )
        _ = msg_send[ObjCObject, "NSAlert", "setInformativeText:"](
            alert,
            nsstring(
                String("Every use in the project is renamed with it.")
            ).ptr(),
        )
        _ = msg_send[ObjCObject, "NSAlert", "addButtonWithTitle:"](
            alert, nsstring(String("Rename")).ptr()
        )
        _ = msg_send[ObjCObject, "NSAlert", "addButtonWithTitle:"](
            alert, nsstring(String("Cancel")).ptr()
        )
        let NSTextField = ObjCClass.lookup["NSTextField"]()
        var field = msg_send[
            ObjCObject, "NSTextField", "alloc", is_class=True
        ](NSTextField.as_object())
        field = msg_send[ObjCObject, "NSView", "initWithFrame:"](
            field, rect(0.0, 0.0, 260.0, 24.0)
        )
        _ = msg_send[ObjCObject, "NSControl", "setStringValue:"](
            field, nsstring(old).ptr()
        )
        _ = msg_send[ObjCObject, "NSAlert", "setAccessoryView:"](
            alert, field.ptr()
        )
        let win = msg_send[ObjCObject, "NSAlert", "window"](alert)
        _ = msg_send[Bool, "NSWindow", "makeFirstResponder:"](win, field.ptr())
        if msg_send[Int, "NSAlert", "runModal"](alert) != 1000:
            return String()
        return ns_to_string(
            msg_send[ObjCObject, "NSControl", "stringValue"](field)
        )


def ask_python_requirement() -> String:
    """Ask for one pip requirement without involving a shell.

    The text becomes one argv element, so version constraints and PEP 508
    markers are not reinterpreted. `-r path` is the one supported two-part
    form; the Python manager resolves a relative path against the project.
    """
    with autoreleasepool():
        let NSAlert = ObjCClass.lookup["NSAlert"]()
        var alert = msg_send[ObjCObject, "NSAlert", "alloc", is_class=True](
            NSAlert.as_object()
        )
        alert = msg_send[ObjCObject, "NSObject", "init"](alert)
        _ = msg_send[ObjCObject, "NSAlert", "setMessageText:"](
            alert, nsstring(String("Install Python package")).ptr()
        )
        _ = msg_send[ObjCObject, "NSAlert", "setInformativeText:"](
            alert,
            nsstring(
                String(
                    "Enter one package requirement, for example numpy==2.3, "
                    "or -r requirements-dev.txt. pip installs it into this "
                    "project's managed environment."
                )
            ).ptr(),
        )
        _ = msg_send[ObjCObject, "NSAlert", "addButtonWithTitle:"](
            alert, nsstring(String("Install")).ptr()
        )
        _ = msg_send[ObjCObject, "NSAlert", "addButtonWithTitle:"](
            alert, nsstring(String("Cancel")).ptr()
        )
        let NSTextField = ObjCClass.lookup["NSTextField"]()
        var field = msg_send[
            ObjCObject, "NSTextField", "alloc", is_class=True
        ](NSTextField.as_object())
        field = msg_send[ObjCObject, "NSView", "initWithFrame:"](
            field, rect(0.0, 0.0, 360.0, 24.0)
        )
        _ = msg_send[ObjCObject, "NSAlert", "setAccessoryView:"](
            alert, field.ptr()
        )
        let win = msg_send[ObjCObject, "NSAlert", "window"](alert)
        _ = msg_send[Bool, "NSWindow", "makeFirstResponder:"](win, field.ptr())
        if msg_send[Int, "NSAlert", "runModal"](alert) != 1000:
            return String()
        return ns_to_string(
            msg_send[ObjCObject, "NSControl", "stringValue"](field)
        )


def word_under_caret() -> String:
    """The identifier the caret is in, for the prompt's initial value."""
    if len(g_buffer()[]) == 0:
        return String()
    let buf = g_buffer()[][0]
    let line = buf.line_of_offset(g_caret()[])
    let start = buf.line_start(line)
    let text = buf.line(line)
    let at = g_caret()[] - start
    let bytes = text.as_bytes()
    var a = at
    while a > 0 and _is_ident_byte(Int(bytes[a - 1])):
        a -= 1
    var b = at
    while b < len(bytes) and _is_ident_byte(Int(bytes[b])):
        b += 1
    if b <= a:
        return String()
    return String(text[byte=a:b])


def _is_ident_byte(b: Int) -> Bool:
    return (
        (b >= 0x30 and b <= 0x39)
        or (b >= 0x41 and b <= 0x5A)
        or (b >= 0x61 and b <= 0x7A)
        or b == 0x5F
    )


def _show_signature():
    """The signature, with the argument the caret is in called out.

    One line of status bar, so the label and the active parameter are joined
    rather than styled -- but the parameter is named, because a signature
    with nothing highlighted is a docstring and the editor already shows you
    one of those on hover.
    """
    let label = lsp.signature_label()
    if label == "":
        return
    print("roast: signature", repr(label), "param", repr(lsp.signature_parameter()))
    # Truncated, because a signature is not always a signature: this server
    # can answer with a mangled MLIR type four hundred characters long, and a
    # status bar full of `!lit.ref.pack<:param_list<...` tells nobody
    # anything. What fits is what helps.
    var shown = label
    if shown.byte_length() > 140:
        shown = String(shown[byte=:137]) + String("…")
    let param = lsp.signature_parameter()
    if param != "" and param.byte_length() < 60:
        set_status(shown + String("      ← ") + param)
    else:
        set_status(shown^)


def _show_hover():
    let text = lsp.hover_text()
    if text != "":
        set_status(text)


def _jump_to(path: String, line: Int, col: Int):
    """Put the caret on a diagnostic, opening the file if it is not open."""
    if path == "":
        return
    let uri = String("file://") + path
    let tab = document.index_of(uri)
    if tab >= 0:
        _ = switch_document(tab)
    elif not load_file(path):
        return
    # Either way, the error's file is now the current tab, and everything that
    # follows a tab change has to happen: reveal it in the strip, point the
    # server at it, redraw. Doing this only when `switch_document` returned
    # true skipped it for a file that had just been opened -- which is the
    # common case for a build error in a file you were not looking at.
    after_switch()
    print("roast: jump to", _basename(path), "line", line, "col", col)
    # The compiler counts from one; the buffer counts from zero.
    var target = line - 1
    if target < 0:
        target = 0
    if len(g_buffer()[]) == 0:
        return
    let rope = g_buffer()[][0]
    if target >= rope.line_count():
        target = rope.line_count() - 1
    var at = rope.line_start(target)
    if col > 1:
        at += col - 1
    if at > rope.byte_length():
        at = rope.byte_length()
    set_caret(at)
    scroll_to_caret()
    refresh_grid()


def _build_finished():
    let status = build.exit_status()
    let what = build.label()
    console_sync()
    let shown = console_text()
    print(
        "roast:",
        what.lower(),
        "finished, status",
        status,
        "-- console holds",
        shown.byte_length(),
        "bytes",
    )
    if getenv("ROAST_AUTOBUILD") != "":
        # CI reads the pane rather than the pipe, so what is asserted is what
        # someone would actually be looking at.
        print("--- console ---")
        print(shown)
        print("--- end ---")

    if what.startswith("Creating Python"):
        var after = 0
        if what == "Creating Python for Run":
            after = 1
        elif what == "Creating Python for Debug":
            after = 2
        elif what == "Creating Python for Package":
            after = 3
        elif what == "Creating Python for Project":
            after = 4
        # Own this before clearing the global slot. A borrowed String would
        # otherwise observe the empty value and silently drop a queued pip
        # install after successful venv creation.
        var spec = String(_python_spec())
        _put_python_spec(String())
        if status != 0:
            set_status(String("Python environment creation failed"))
            return
        set_status(
            String("Python environment ready: ")
            + python_env.environment_dir(_python_project(), toolchain_root())
        )
        restart_lsp_for_python()
        if after == 1:
            _start_build(True)
        elif after == 2:
            _start_debug()
        elif after == 3:
            _install_python_requirement(spec^)
        elif after == 4:
            _install_project_dependencies()
        return

    if what == "Installing Python":
        if status == 0:
            set_status(String("Python packages installed"))
            restart_lsp_for_python()
        else:
            set_status(String("pip failed (") + String(status) + String(")"))
        return

    if status == 0:
        if g_debug_pending()[] != 0:
            build.clear_then()
            _launch_debugger()
            return
        let next_exe = build.then_exe()
        if next_exe != "":
            var cwd = build.then_cwd()
            build.clear_then()
            build.append_output(
                String("\n─── ") + _basename(next_exe) + String(" ───\n")
            )
            console_sync()
            var none = List[String]()
            if build.start_with_environment(
                next_exe,
                none,
                cwd,
                String("Running"),
                _python_variables(),
            ):
                set_status(String("Running ") + _basename(next_exe) + String("…"))
                return
            console_sync()
            set_status(String("Built, but could not run it"))
            return
        if what == "Running":
            set_status(String("Finished"))
        else:
            set_status(String("Build succeeded"))
        return

    # Failed. Whatever queued behind this does not happen.
    build.clear_then()
    g_debug_pending()[] = 0
    let log = build.output()
    let issue = build.first_error(log)
    if issue.line > 0:
        _jump_to(issue.path, issue.line, issue.col)
        set_status(
            _basename(issue.path)
            + String(":")
            + String(issue.line)
            + String("  ")
            + issue.message
        )
    elif what == "Running":
        set_status(String("Exited with status ") + String(status))
    else:
        set_status(String("Build failed (") + String(status) + String(")"))


class RoastActions:
    """Every menu and toolbar action, the sidebar's data source, and the
    timer -- one object, because one target is what AppKit wants.

    This replaces twenty-three `add_method` calls and the twenty-one
    encoding strings that went with them. The `roast*` selectors are ours,
    so their `v@:@` shape is derived; the AppKit ones are looked up.
    """

    def roastConsole_(self, sender: ObjCObject):
        try:
            show_console(g_console_open()[] == 0)
        except:
            pass

    def roastBuild_(self, sender: ObjCObject):
        try:
            _start_build(False)
        except:
            set_status(String("Build failed to start"))

    def roastRun_(self, sender: ObjCObject):
        try:
            _start_build(True)
        except:
            set_status(String("Run failed to start"))

    def roastPythonEnvironment_(self, sender: ObjCObject):
        try:
            _ = _start_python_environment()
        except:
            set_status(String("Python environment creation failed to start"))

    def roastPythonInstall_(self, sender: ObjCObject):
        try:
            let requirement = ask_python_requirement()
            if requirement != "":
                _install_python_requirement(requirement^)
        except:
            set_status(String("Python package installation failed to start"))

    def roastPythonInstallProject_(self, sender: ObjCObject):
        try:
            _install_project_dependencies()
        except:
            set_status(String("Project dependency installation failed to start"))

    def roastPythonShowEnvironment_(self, sender: ObjCObject):
        try:
            let project = _python_project()
            if project == "":
                set_status(String("Open a project or save the current file first"))
                return
            let root = toolchain_root()
            let path = python_env.environment_dir(project, root)
            # Which interpreter answered, not just where the environment
            # sits. The bundled Python is optional at install time, so
            # "Python" alone no longer says which one this is.
            let origin = python_env.runtime_origin(root)
            let home = python_env.runtime_home(root)
            if home == "":
                set_status(
                    String("Python was not installed — run the installer")
                    + String(" again and tick Include Python")
                )
                return
            let which = String(" [") + origin + String(": ") + home + String("]")
            if python_env.environment_ready(project, root):
                set_status(String("Python: ") + path + which)
            else:
                set_status(
                    String("Python environment not created: ") + path + which
                )
        except:
            pass

    def roastStop_(self, sender: ObjCObject):
        try:
            if not build.is_running():
                set_status(String("Nothing running"))
                return
            let what = build.label()
            build.stop()
            g_build_seen()[] = build.serial()
            build.append_output(String("\n─── stopped ───\n"))
            console_sync()
            set_status(what + String(" stopped"))
        except:
            pass

    def roastNewTab_(self, sender: ObjCObject):
        """A new, empty document in a new tab."""
        try:
            # An empty document, which becomes real the first time it is saved.
            _ = document.open_document(String(""), Rope(String("")))
            after_switch()
        except:
            pass

    def roastNextTab_(self, sender: ObjCObject):
        try:
            if document.count() < 2:
                return
            let next = (document.current_index() + 1) % document.count()
            if switch_document(next):
                after_switch()
        except:
            pass

    def roastPrevTab_(self, sender: ObjCObject):
        try:
            if document.count() < 2:
                return
            let prev = (
                document.current_index() + document.count() - 1
            ) % document.count()
            if switch_document(prev):
                after_switch()
        except:
            pass

    def roastOpenExample_(self, sender: ObjCObject):
        """Open a shipped example: the folder as the project, its files as tabs.

        An example is a project, and `fern` is three files. Opening only the
        entry point makes the other two invisible until someone thinks to go
        looking in the sidebar, which rather defeats shipping them as a worked
        example.
        """
        try:
            with autoreleasepool():
                let path = Obj["NSMenuItem"](sender.addr()).representedObject()
                if path.addr() == 0:
                    set_status(String("That example has no path"))
                    return
                let file = ns_to_string(path)
                let cut = file.rfind("/")
                if cut <= 0:
                    set_status(String("Malformed example path"))
                    return
                let folder = String(file[byte=:cut])

                let opened = open_example_project(folder, file)
                if opened == 0:
                    set_status(String("Could not open ") + file)
                    return
                after_switch()
                set_status(
                    String("Example: ")
                    + folder[byte=cut_name(folder):]
                    + String("  ·  ")
                    + String(opened)
                    + String(" file" if opened == 1 else " files")
                )
        except:
            pass

    def roastCloseTab_(self, sender: ObjCObject):
        """Close the current tab. Shares its rule with the tab's × so the two
        cannot disagree about what happens to unsaved work."""
        close_tab_at(document.current_index())

    def outlineViewSelectionDidChange_(self, note: ObjCObject):
        """Clicking a file opens it. Clicking a folder does nothing but expand."""
        try:
            with autoreleasepool():
                if g_outline()[] == 0:
                    return
                let view = ObjCObject(g_outline()[])
                let row = Obj["NSTableView"](view.addr()).selectedRow()
                if row < 0:
                    return
                let item = Obj["NSOutlineView"](view.addr()).itemAtRow(row)
                if item.addr() == 0:
                    return
                let path = ns_to_string(item)
                if is_directory(path):
                    return
                _ = load_file(path)
        except:
            pass

    def roastRunScript_(self, sender: ObjCObject):
        """Pick a script and run it against this session. The panel is
        Cocoa's; the execution is run_agent_script's, the same function the
        agent's `run-script` verb uses -- one path, two ways in."""
        try:
            with autoreleasepool():
                let NSOpenPanel = ObjCClass.lookup["NSOpenPanel"]()
                let panel = Cls["NSOpenPanel"]().openPanel()
                Obj["NSOpenPanel"](panel.addr()).setCanChooseFiles(True)
                Obj["NSOpenPanel"](panel.addr()).setCanChooseDirectories(
                    False
                )
                Obj["NSOpenPanel"](panel.addr()).setAllowsMultipleSelection(
                    False
                )
                if Obj["NSSavePanel"](panel.addr()).runModal() != 1:
                    return
                let url = Obj["NSSavePanel"](panel.addr()).URL()
                let p = ns_to_string(Obj["NSURL"](url.addr()).path())
                show_console(True)
                set_status(run_agent_script(p))
        except:
            pass

    def roastOpenStdlib_(self, sender: ObjCObject):
        """The standard library as a project: the user-space copy."""
        try:
            let std = stdlib_root()
            if std == "":
                set_status(String("No standard library found"))
                return
            open_folder(std)
        except:
            pass

    def roastOpenIDESource_(self, sender: ObjCObject):
        """Roast's own source, as a project. It is written in the language
        it edits, so this is both the largest worked example the toolchain
        ships and the thing to change if you want a different editor."""
        try:
            let src = user_ide_source_dir()
            if src != "" and file_exists(src + String("/roast.mojo")):
                open_folder(src)
                return
            let tc = toolchain_root()
            if tc != "" and file_exists(
                tc + String("/share/ide-source/roast.mojo")
            ):
                open_folder(tc + String("/share/ide-source"))
                return
            set_status(String("No IDE source in this distribution"))
        except:
            pass

    def roastResetUserSpace_(self, sender: ObjCObject):
        """Fresh copies of stdlib and examples from the bundle, after a
        confirm -- edits there are the point of the copies, so throwing
        them away deserves a question."""
        try:
            with autoreleasepool():
                let NSAlert = ObjCClass.lookup["NSAlert"]()
                var alert = Cls["NSAlert"]().alloc()
                alert = Obj["NSAlert"](alert.addr()).init()
                Obj["NSAlert"](alert.addr()).setMessageText(
                    nsstring(String(
                        "Reset the standard library, examples and IDE source?"
                    )).ptr()
                )
                Obj["NSAlert"](alert.addr()).setInformativeText(
                    nsstring(String(
                        "Your edited copies in Application Support are"
                        " replaced with the app's pristine ones. Projects"
                        " and Python environments are untouched."
                    )).ptr()
                )
                _ = Obj["NSAlert"](alert.addr()).addButtonWithTitle(
                    nsstring(String("Reset")).ptr()
                )
                _ = Obj["NSAlert"](alert.addr()).addButtonWithTitle(
                    nsstring(String("Cancel")).ptr()
                )
                if Obj["NSAlert"](alert.addr()).runModal() != 1000:
                    return
            if migrate_user_space(force=True):
                restart_lsp_for_python()
                set_status(String("Standard library and examples reset"))
            else:
                set_status(String("Nothing to reset — not running from an app"))
        except:
            pass

    def roastOpenFolder_(self, sender: ObjCObject):
        try:
            with autoreleasepool():
                let NSOpenPanel = ObjCClass.lookup["NSOpenPanel"]()
                let panel = Cls["NSOpenPanel"]().openPanel()
                Obj["NSOpenPanel"](panel.addr()).setCanChooseFiles(False)
                Obj["NSOpenPanel"](panel.addr()).setCanChooseDirectories(True)
                if Obj["NSSavePanel"](panel.addr()).runModal() != 1:
                    return
                let url = Obj["NSSavePanel"](panel.addr()).URL()
                open_folder(
                    ns_to_string(Obj["NSURL"](url.addr()).path())
                )
        except:
            pass

    def roastOpen_(self, sender: ObjCObject):
        """Open a file. The panel is Cocoa's, so it looks and behaves like every
        other open panel on the machine."""
        try:
            with autoreleasepool():
                let NSOpenPanel = ObjCClass.lookup["NSOpenPanel"]()
                let panel = Cls["NSOpenPanel"]().openPanel()
                Obj["NSOpenPanel"](panel.addr()).setCanChooseFiles(True)
                Obj["NSOpenPanel"](panel.addr()).setCanChooseDirectories(False)
                Obj["NSOpenPanel"](panel.addr()).setAllowsMultipleSelection(
                    False
                )
                # Modal, because there is one buffer: opening a second file while
                # the first is still being chosen has nowhere to go until
                # milestone 3 gives documents somewhere to live.
                let answer = Obj["NSSavePanel"](panel.addr()).runModal()
                if answer != 1:  # NSModalResponseOK
                    return
                let url = Obj["NSSavePanel"](panel.addr()).URL()
                let path = Obj["NSURL"](url.addr()).path()
                _ = load_file(ns_to_string(path))
        except:
            pass

    def roastSave_(self, sender: ObjCObject):
        try:
            _ = save_current()
        except:
            pass

    def roastSaveAll_(self, sender: ObjCObject):
        """Write every dirty buffer.

        There is one buffer, so today this is Save with a different name. It exists
        now because the command belongs in the File menu from the start and because
        the loop it will grow -- over documents, saving the dirty ones -- is easier
        to add than to retrofit around callers who learned to call Save instead.
        """
        try:
            let n = document.dirty_count()
            if n == 0:
                set_status(String("Nothing to save"))
                return
            let started_at = document.current_index()
            var saved = 0
            var i = 0
            while i < document.count():
                if document.dirty_at(i):
                    # Switching makes it the working set; saving writes the working
                    # set. One path for one document and for all of them.
                    _ = switch_document(i)
                    _ = save_current()
                    saved += 1
                i += 1
            _ = switch_document(started_at)
            refresh_tabs()
            refresh_grid()
            set_status(String("Saved ") + String(saved) + String(" files"))
        except:
            pass

    def roastComplete_(self, sender: ObjCObject):
        """Ask the server what could go here, at the caret."""
        try:
            if not lsp.is_ready() or document.current_uri() == "" or len(g_buffer()[]) == 0:
                set_status(String("No language server"))
                return
            let buf = g_buffer()[][0]
            let line = buf.line_of_offset(g_caret()[])
            let col = byte_to_utf16(g_caret()[]) - byte_to_utf16(
                buf.line_start(line)
            )
            # The server answers the document it was last told about, so an edit
            # still sitting in the debounce would be answered against stale text.
            if g_revision()[] != document.sent_revision():
                lsp.did_change(
                    document.current_uri(), g_revision()[], buf.to_string()
                )
                document.set_sent_revision(g_revision()[])
            _ = lsp.request_completion(document.current_uri(), line, col)
            g_pending_completion()[] = 1
            set_status(String("Completing…"))
        except:
            pass

    def roastGoToDefinition_(self, sender: ObjCObject):
        try:
            _ = ask_definition()
        except:
            pass

    def roastHover_(self, sender: ObjCObject):
        try:
            if not ask_hover():
                set_status(String("No language server"))
        except:
            pass

    def roastFindReferences_(self, sender: ObjCObject):
        try:
            _ = ask_references()
        except:
            pass

    def roastNextReference_(self, sender: ObjCObject):
        try:
            if lsp.reference_count() == 0:
                set_status(String("No references — find them first (⇧⌘F)"))
                return
            _go_to_reference(g_ref_at()[] + 1)
        except:
            pass

    def roastRename_(self, sender: ObjCObject):
        try:
            if not lsp.is_ready():
                set_status(String("No language server"))
                return
            let old = word_under_caret()
            if old == "":
                set_status(String("Put the caret on a name first"))
                return
            let fresh = ask_new_name(old)
            if fresh == "" or fresh == old:
                return
            _ = ask_rename(fresh)
        except:
            pass

    def roastSignature_(self, sender: ObjCObject):
        try:
            if not ask_signature():
                set_status(String("No language server"))
        except:
            pass

    def roastDebug_(self, sender: ObjCObject):
        try:
            _start_debug()
        except:
            set_status(String("Debug failed to start"))

    def roastEvaluate_(self, sender: ObjCObject):
        """Run the selected text as Mojo, in the stopped frame, in the
        debuggee. The answer lands in the console beside the locals."""
        try:
            if not dap.is_stopped():
                set_status(String("Evaluate needs a stopped program"))
                return
            let expr = selected_text()
            if expr.byte_length() == 0:
                set_status(String("Select an expression to evaluate"))
                return
            if dap.evaluate(expr):
                set_status(String("Evaluating…"))
        except:
            pass

    def roastBreakOnRaise_(self, sender: ObjCObject):
        """Stop where an error is RAISED, not where it lands. Takes effect on
        the next debug session: the resolver is installed at launch, and
        rewiring a live target is more machinery than the toggle is worth."""
        try:
            let on = session.setting(String("debug.break_on_raise")) != "1"
            session.set_setting(
                String("debug.break_on_raise"),
                String("1") if on else String("0"),
            )
            Obj["NSMenuItem"](sender.addr()).setState(Int(1) if on else Int(0))
            if on:
                set_status(
                    String("Break on raise: on (next debug session)")
                )
            else:
                set_status(String("Break on raise: off"))
        except:
            pass

    def roastDebugStop_(self, sender: ObjCObject):
        try:
            if not dap.is_running():
                set_status(String("Not debugging"))
                return
            dap.stop()
            g_debug_pending()[] = 0
            set_status(String("Debugging stopped"))
            refresh_grid()
        except:
            pass

    def roastContinue_(self, sender: ObjCObject):
        _trace_debug_action(String("continue"))
        try:
            if dap.is_stopped():
                dap.resume()
                set_status(String("Running…"))
                refresh_grid()
        except:
            pass

    def roastStepOver_(self, sender: ObjCObject):
        _trace_debug_action(String("step over"))
        try:
            dap.step_over()
        except:
            pass

    def roastStepIn_(self, sender: ObjCObject):
        _trace_debug_action(String("step into"))
        try:
            dap.step_in()
        except:
            pass

    def roastStepOut_(self, sender: ObjCObject):
        _trace_debug_action(String("step out"))
        try:
            dap.step_out()
        except:
            pass

    def roastToggleBreakpoint_(self, sender: ObjCObject):
        """The keyboard's way to the gutter's click."""
        try:
            let path = document.path_at(document.current_index())
            if path == "":
                set_status(String("Save the file first"))
                return
            if len(g_buffer()[]) == 0:
                return
            let line = g_buffer()[][0].line_of_offset(g_caret()[]) + 1
            let on = dap.toggle_breakpoint(path, line)
            set_status(
                (String("Breakpoint at line ") if on else
                 String("Cleared breakpoint at line ")) + String(line)
            )
            refresh_grid()
        except:
            pass

    def roastClearBreakpoints_(self, sender: ObjCObject):
        try:
            dap.clear_breakpoints()
            set_status(String("Breakpoints cleared"))
            refresh_grid()
        except:
            pass

    def roastTheme_(self, sender: ObjCObject):
        """Switch theme. The name rides on the menu item."""
        try:
            let name = ns_to_string(
                Obj["NSMenuItem"](sender.addr()).representedObject()
            )
            if name == "":
                return
            session.set_setting(String("view.theme"), name)
            apply_theme()
            set_status(String("Theme: ") + name)
        except:
            pass

    def roastZoomIn_(self, sender: ObjCObject):
        try:
            zoom_font(1.0)
        except:
            pass

    def roastZoomOut_(self, sender: ObjCObject):
        try:
            zoom_font(-1.0)
        except:
            pass

    def roastFind_(self, sender: ObjCObject):
        """Put the cursor in the toolbar's search field."""
        try:
            with autoreleasepool():
                if g_findfield()[] == 0:
                    return
                _ = Obj["NSWindow"](ObjCObject(g_window()[]).addr()).makeFirstResponder(
                    ObjCObject(g_findfield()[]).ptr(),
                )
        except:
            pass

    def roastFindChanged_(self, sender: ObjCObject):
        """The field's text changed, or Enter was pressed in it."""
        try:
            with autoreleasepool():
                let field = ObjCObject(g_findfield()[])
                let text = Obj["NSTextField"](field.addr()).stringValue()
                set_query(ns_to_string(text))
                print("roast: find", repr(query()), "matches", match_count())
                _ = find_next()
                report_matches()
                scroll_to_caret()
        except:
            pass

    def roastFindNext_(self, sender: ObjCObject):
        try:
            _ = find_next()
            report_matches()
            scroll_to_caret()
        except:
            pass

    def roastFindPrevious_(self, sender: ObjCObject):
        try:
            _ = find_previous()
            report_matches()
            scroll_to_caret()
        except:
            pass

    def roastHideFind_(self, sender: ObjCObject):
        """Escape: clear the search and give the editor its focus back."""
        try:
            with autoreleasepool():
                if g_findfield()[] != 0:
                    Obj["NSControl"](ObjCObject(g_findfield()[]).addr()).setStringValue(
                        nsstring(String("")).ptr(),
                    )
                set_query(String())
                if g_grid()[] != 0:
                    _ = Obj["NSWindow"](ObjCObject(g_window()[]).addr()).makeFirstResponder(
                        ObjCObject(g_grid()[]).ptr(),
                    )
                set_status(String("Ready"))
                refresh_grid()
        except:
            pass

    def timerTick_(self, timer: ObjCObject):
        g_ticks()[] += 1

        # Read whatever the server has said. This is the whole reason the client
        # reads without blocking: a language server thinking hard must not be an
        # editor that has stopped responding.
        try:
            # Anything dropped on the editor since the last tick. Opened
            # here rather than in the view's drop handler: a folder open
            # tears down the language server and rebuilds the tab strip,
            # which is not work to do from inside AppKit's drag machinery.
            # The theme the session remembers, put on screen once. The
            # attributes are built at startup, before the session document
            # is loaded, so a saved theme is not in them -- and nothing else
            # would apply it until someone opened the menu and chose again.
            if g_theme_menu_done()[] == 0:
                install_theme_menu()
                if current_theme() != "System":
                    apply_theme()
            

            let dropped = take_dropped()
            if len(dropped) > 0:
                var opened = 0
                for path in dropped:
                    if open_path(path):
                        opened += 1
                if opened > 0:
                    let what = String(opened) + String(
                        " item" if opened == 1 else " items"
                    )
                    set_status(String("Opened ") + what + String(" from a drop"))
                    refresh_grid()
                else:
                    set_status(String("Nothing there Roast can open"))

            if lsp.is_running():
                # A handshake that just completed means a server that knows
                # nothing yet -- startup, or the fresh process a project
                # change launched. Tell it what is open before asking it
                # anything.
                if (
                    lsp.is_ready()
                    and g_lsp_announced()[] != lsp.ready_serial()
                ):
                    g_lsp_announced()[] = lsp.ready_serial()
                    announce_open_documents()
                if lsp.poll() > 0:
                    # A completion reply arrives as a bump in the serial; showing
                    # the popup is the app's job, not the client's.
                    if (
                        g_pending_completion()[] != 0
                        and lsp.g_comp_serial()[] != g_comp_seen()[]
                    ):
                        g_comp_seen()[] = lsp.g_comp_serial()[]
                        g_pending_completion()[] = 0
                        if g_grid()[] != 0:
                            show_popup(ObjCObject(g_grid()[]))
                        if lsp.completion_count() == 0:
                            set_status(String("No completions"))
                        else:
                            set_status(
                                String(lsp.completion_count())
                                + String(" completions")
                            )
                    elif lsp.definition_serial() != g_def_seen()[]:
                        g_def_seen()[] = lsp.definition_serial()
                        _go_to_definition()
                    elif lsp.hover_serial() != g_hover_seen()[]:
                        g_hover_seen()[] = lsp.hover_serial()
                        _show_hover()
                    elif lsp.references_serial() != g_ref_seen()[]:
                        g_ref_seen()[] = lsp.references_serial()
                        _show_references()
                    elif lsp.signature_serial() != g_sig_seen()[]:
                        g_sig_seen()[] = lsp.signature_serial()
                        _show_signature()
                    elif lsp.rename_serial() != g_ren_seen()[]:
                        g_ren_seen()[] = lsp.rename_serial()
                        _apply_rename()
                    else:
                        _report_diagnostics()
                    refresh_grid()

                # Tell the server about edits once the typing pauses. Sending on
                # every keystroke would have it re-parsing text nobody has finished
                # writing.
                if g_revision()[] != document.sent_revision():
                    _show_dirty()
                    refresh_tabs()
                    g_idle_ticks()[] += 1
                    if g_idle_ticks()[] >= 3 and document.current_uri() != "":
                        if len(g_buffer()[]) > 0:
                            lsp.did_change(
                                document.current_uri(),
                                g_revision()[],
                                g_buffer()[][0].to_string(),
                            )
                        document.set_sent_revision(g_revision()[])
                        g_idle_ticks()[] = 0
                else:
                    g_idle_ticks()[] = 0
        except:
            pass

        # The compiler, on the same terms as the server: drained without blocking,
        # because a build that takes a minute must not be an editor that takes a
        # minute. pump() also reaps the process, which is what moves the serial.
        # The definition door, once the server is ready and has the document.
        # Twenty ticks in rather than immediately: a request about a file the
        # server has not finished reading gets an empty answer, which would
        # make this check pass or fail on timing rather than on behaviour.
        if (
            g_define_line()[] > 0
            and g_define_done()[] == 0
            and g_ticks()[] > 20
            and lsp.is_ready()
        ):
            g_define_done()[] = 1
            let want_line = g_define_line()[] - 1
            if len(g_buffer()[]) > 0:
                let buf = g_buffer()[][0]
                if want_line < buf.line_count():
                    set_caret(
                        buf.line_start(want_line) + g_define_col()[] - 1
                    )
            _ = ask_definition()

        if (
            g_probe_kind()[] != 0
            and g_probe_done()[] == 0
            and g_ticks()[] > 20
            and lsp.is_ready()
        ):
            g_probe_done()[] = 1
            let want = g_probe_line()[] - 1
            if len(g_buffer()[]) > 0:
                let buf = g_buffer()[][0]
                if want < buf.line_count():
                    set_caret(buf.line_start(want) + g_probe_col()[] - 1)
            if g_probe_kind()[] == 1:
                _ = ask_references()
            elif g_probe_kind()[] == 3:
                let slot = g_probe_name()
                if len(slot[]) > 0:
                    _ = ask_rename(slot[][0])
            else:
                _ = ask_signature()

        # CI, and a quick way to see the path work: fire Build or Run a few ticks
        # in, once the window is really up, with nobody at the keyboard.
        # ROAST_AGENT runs one command from inside a real window, so CI can
        # grep a reply that came through the same dispatcher an event does.
        # Deferred agent commands come due.
        try:
            var di = 0
            while di < len(g_agent_at()[]):
                if g_agent_at()[][di] <= g_ticks()[]:
                    var due = g_agent_later()[][di]
                    _ = g_agent_at()[].pop(di)
                    _ = g_agent_later()[].pop(di)
                    print("roast: agent (deferred) <", due)
                    print("roast: agent (deferred) >", agent_command(due))
                else:
                    di += 1
        except:
            pass

        if g_ticks()[] == 4:
            if getenv("ROAST_AGENT_SELFTEST") != "":
                _ = agent_self_test()
            let script = getenv("ROAST_AGENT")
            if script != "":
                # Several commands, ';'-separated, so a check can walk a
                # sequence the way a person does: set a breakpoint, then
                # press Debug.
                var rest = script
                while True:
                    let cut = rest.find(";")
                    var one = rest
                    if cut >= 0:
                        one = String(rest[byte=:cut])
                    print("roast: agent <", one)
                    print("roast: agent >", agent_command(String(one)))
                    if cut < 0:
                        break
                    let tail2 = String(rest[byte = cut + 1 : rest.byte_length()])
                    rest = tail2

        if g_ticks()[] == 3:
            let auto = getenv("ROAST_AUTOBUILD")
            if auto != "":
                try:
                    _start_build(auto == "run")
                except:
                    pass

        # The debug adapter, on the same terms as the compiler and the
        # language server: drained without blocking, and noticed by a serial
        # rather than a flag anyone has to remember to clear.
        try:
            if dap.is_running():
                if dap.poll() > 0:
                    if dap.output() != "":
                        build.append_output(dap.output())
                        dap.clear_output()
                        console_sync()
                    if dap.serial() != g_dap_seen()[]:
                        g_dap_seen()[] = dap.serial()
                        _debug_changed()
                # A breakpoint toggled while the program is up has to reach
                # the adapter; the tick is where that happens, so no caller
                # has to remember.
                if dap.g_bp_dirty()[] != 0 and dap.is_configured():
                    dap.send_breakpoints()
        except:
            pass

        try:
            if build.is_running():
                # Lazily: the tick is the one place every build passes
                # through, however it was started, so nobody has to remember
                # to switch the spinner on.
                if g_build_began()[] == 0:
                    g_build_began()[] = Int(perf_counter_ns())
                    if g_spinner()[] != 0:
                        with autoreleasepool():
                            Obj["NSProgressIndicator"](
                                g_spinner()[]
                            ).startAnimation(ObjCObject(0).ptr())
                # The spinner turns and the status counts, so a long compile
                # reads as a long compile and not as a hang. Start of build
                # is remembered by _start_build; second granularity is
                # enough for the question actually being asked.
                if g_spinner()[] != 0 and g_build_began()[] != 0:
                    if g_ticks()[] % 30 == 0:
                        let secs = (
                            Int(perf_counter_ns() - g_build_began()[])
                            // 1_000_000_000
                        )
                        if secs >= 2:
                            let slot2 = g_status_text()
                            var base = String("Working")
                            if len(slot2[]) > 0:
                                base = slot2[][0]
                            # Strip a previous "… Ns" suffix by cutting at
                            # the marker this code itself appends.
                            let cut2 = base.find("  ·  ⏱")
                            if cut2 >= 0:
                                let trimmed = String(base[byte=:cut2])
                                base = trimmed
                            set_status(
                                base + String("  ·  ⏱ ") + String(secs)
                                + String("s")
                            )
                if build.pump() > 0:
                    console_sync()
            if not build.is_running() and g_build_began()[] != 0:
                g_build_began()[] = 0
                if g_spinner()[] != 0:
                    with autoreleasepool():
                        Obj["NSProgressIndicator"](
                            g_spinner()[]
                        ).stopAnimation(ObjCObject(0).ptr())
            if build.serial() != g_build_seen()[]:
                g_build_seen()[] = build.serial()
                _build_finished()
        except:
            pass

        let limit = g_autoclose()[]
        if limit != 0 and g_ticks()[] >= limit:
            print("roast: autoclose after", g_ticks()[], "ticks")
            # An unattended run closes its window rather than terminating, so
            # applicationWillTerminate: may not arrive before the process
            # goes. Save here too: writing the same document twice is free,
            # and a check that cannot observe a save cannot check one.
            save_session()
            with autoreleasepool():
                if g_window()[] != 0:
                    Obj["NSWindow"](ObjCObject(g_window()[]).addr()).close()

    # ── The sidebar's data source and delegate ─────────────────────────────
    # Items are NSStrings holding paths, so the file system is the model and
    # there is no tree to keep in step with it. These used to be registered
    # with `add_method_unchecked` and encodings written by hand -- `@@:@q@`
    # and the like -- because the handlers returned an Int standing in for an
    # object. Returning ObjCObject says the same thing in the type system, and
    # the SDK check then agrees with the encoding rather than being told to
    # look away.

    def outlineView_numberOfChildrenOfItem_(
        self, view: ObjCObject, item: ObjCObject
    ) -> Int:
        return outline_children_count(item)

    def outlineView_isItemExpandable_(
        self, view: ObjCObject, item: ObjCObject
    ) -> Bool:
        return outline_expandable(item)

    def outlineView_child_ofItem_(
        self, view: ObjCObject, index: Int, item: ObjCObject
    ) -> ObjCObject:
        return outline_child_at(index, item)

    def outlineView_objectValueForTableColumn_byItem_(
        self, view: ObjCObject, column: ObjCObject, item: ObjCObject
    ) -> ObjCObject:
        return outline_display_value(item)

    # ── Toolbar delegate ───────────────────────────────────────────────────

    def toolbarAllowedItemIdentifiers_(self, tb: ObjCObject) -> ObjCObject:
        return toolbar_ids_object()

    def toolbarDefaultItemIdentifiers_(self, tb: ObjCObject) -> ObjCObject:
        return toolbar_ids_object()

    def toolbar_itemForItemIdentifier_willBeInsertedIntoToolbar_(
        self, toolbar: ObjCObject, ident: ObjCObject, inserted: Bool
    ) -> ObjCObject:
        """Build one toolbar item on demand, by identifier."""
        try:
            with autoreleasepool():
                let key = ident
                let name = String(Obj["NSString"](key.addr()).length())
                _ = name  # length forces a real NSString; the compare is below

                let NSToolbarItem = ObjCClass.lookup["NSToolbarItem"]()
                var item = Cls["NSToolbarItem"]().alloc()
                item = Obj["NSToolbarItem"](item.addr()).initWithItemIdentifier(
                    ident
                )

                # Search is a view item, not a button: it carries an NSSearchField.
                if Obj["NSString"](key.addr()).isEqualToString(nsstring(String(TB_FIND)).ptr()):
                    let NSSearchField = ObjCClass.lookup["NSSearchField"]()
                    var field = Cls["NSSearchField"]().alloc()
                    field = Obj["NSSearchField"](field.addr()).initWithFrame(
                        rect(0.0, 0.0, 240.0, 24.0)
                    )
                    Obj["NSSearchField"](field.addr()).setPlaceholderString(
                        nsstring(String("Find")).ptr()
                    )
                    let owner = ObjCObject(g_actions()[])
                    Obj["NSControl"](field.addr()).setTarget(owner.ptr())
                    Obj["NSControl"](field.addr()).setAction(
                        sel["roastFindChanged:"]().ptr()
                    )
                    # Search as you type: NSSearchField sends its action on every
                    # edit when told to, which a plain NSTextField does not.
                    Obj["NSSearchField"](field.addr()).setSendsWholeSearchString(
                        False,
                    )
                    Obj["NSSearchField"](field.addr()).setSendsSearchStringImmediately(
                        True,
                    )
                    Obj["NSToolbarItem"](item.addr()).setView(field.ptr())
                    Obj["NSToolbarItem"](item.addr()).setLabel(
                        nsstring(String("Find")).ptr()
                    )
                    g_findfield()[] = field.addr()
                    return item

                # Which item was asked for? Compare against each identifier.
                # Declared, not initialised: the else returns, so every path
                # that continues assigns all three.
                var title: String
                var symbol: String
                var action: SEL
                if Obj["NSString"](key.addr()).isEqualToString(nsstring(String(TB_BUILD)).ptr()):
                    title = String("Build")
                    symbol = String("hammer")
                    action = sel["roastBuild:"]()
                elif Obj["NSString"](key.addr()).isEqualToString(nsstring(String(TB_RUN)).ptr()):
                    title = String("Run")
                    symbol = String("play.fill")
                    action = sel["roastRun:"]()
                elif Obj["NSString"](key.addr()).isEqualToString(nsstring(String(TB_STOP)).ptr()):
                    title = String("Stop")
                    symbol = String("stop.fill")
                    action = sel["roastStop:"]()
                # The debugger's four. Each already had a menu item and an
                # action behind it; this only puts them where the hand is.
                # The symbols read as directions rather than as pictures of a
                # debugger: along, down into, up out of.
                elif Obj["NSString"](key.addr()).isEqualToString(nsstring(String(TB_DEBUG)).ptr()):
                    title = String("Debug")
                    symbol = String("ladybug.fill")
                    action = sel["roastDebug:"]()
                elif Obj["NSString"](key.addr()).isEqualToString(nsstring(String(TB_CONTINUE)).ptr()):
                    title = String("Continue")
                    symbol = String("forward.fill")
                    action = sel["roastContinue:"]()
                elif Obj["NSString"](key.addr()).isEqualToString(nsstring(String(TB_STEP_OVER)).ptr()):
                    title = String("Step Over")
                    symbol = String("arrow.right.circle")
                    action = sel["roastStepOver:"]()
                elif Obj["NSString"](key.addr()).isEqualToString(nsstring(String(TB_STEP_IN)).ptr()):
                    title = String("Step Into")
                    symbol = String("arrow.down.circle")
                    action = sel["roastStepIn:"]()
                elif Obj["NSString"](key.addr()).isEqualToString(nsstring(String(TB_STEP_OUT)).ptr()):
                    title = String("Step Out")
                    symbol = String("arrow.up.circle")
                    action = sel["roastStepOut:"]()
                else:
                    return ObjCObject(0)

                Obj["NSToolbarItem"](item.addr()).setLabel(
                    nsstring(title).ptr()
                )
                # An SF Symbol, or the item renders as an empty bordered circle.
                # The accessibility description doubles as the tooltip source, so
                # the title serves for both rather than passing nil.
                let NSImage = ObjCClass.lookup["NSImage"]()
                let image = Cls["NSImage"]().imageWithSystemSymbolName_accessibilityDescription(
                    nsstring(symbol).ptr(),
                    nsstring(title).ptr(),
                )
                if image.addr() != 0:
                    Obj["NSToolbarItem"](item.addr()).setImage(image.ptr())
                Obj["NSToolbarItem"](item.addr()).setToolTip(
                    nsstring(title).ptr()
                )
                Obj["NSToolbarItem"](item.addr()).setTarget(
                    ObjCObject(g_actions()[]).ptr()
                )
                Obj["NSToolbarItem"](item.addr()).setAction(action.ptr())
                return item
        except:
            return ObjCObject(0)


def announce_open_documents():
    """Send didOpen for every open tab.

    load_file announces a file when the server is ready at the time -- which
    it is not at startup (the handshake takes a poll cycle), and not for any
    tab that was open when a project change swapped in a fresh server process.
    Those documents were silently unknown: no diagnostics until an edit, and
    then a didChange for a document the server was never told about, which the
    protocol does not define. This runs when the handshake completes, however
    many times that happens.
    """
    var i = 0
    var told = 0
    while i < document.count():
        let uri = document.uri_at(i)
        if uri != "":
            lsp.did_open(uri, document.text_at(i))
            document.mark_announced(i)
            told += 1
        i += 1
    lsp.set_shown_uri(document.current_uri())
    print("roast: announced", told, "documents to the server")


def zoom_font(delta: Float64):
    """⌘+ and ⌘−. Every metric downstream is arithmetic on two numbers, so a
    zoom is: new font, resize the document to the new line height, redraw."""
    set_font_size(font_size() + delta)
    if g_grid()[] != 0:
        with autoreleasepool():
            let grid = ObjCObject(g_grid()[])
            let frame = Obj["NSView"](grid.addr()).frame()
            Obj["NSView"](grid.addr()).setFrameSize(
                document_size(frame.size.width)
            )
            Obj["NSView"](grid.addr()).setNeedsDisplay(True)
    scroll_to_caret()
    var shown = String(Int(font_size()))
    set_status(String("Type: ") + shown + String(" pt"))


def refresh_grid():
    """Redraw the editor and scroll the selection into view."""
    if g_grid()[] == 0:
        return
    with autoreleasepool():
        let grid = ObjCObject(g_grid()[])
        Obj["NSView"](grid.addr()).setNeedsDisplay(True)


def scroll_to_caret():
    """Keep the match on screen. A find that jumps somewhere invisible has not
    really found anything."""
    if g_grid()[] == 0:
        return
    with autoreleasepool():
        let grid = ObjCObject(g_grid()[])
        let pos = caret_position(g_caret()[])
        let lh = line_height()
        _ = Obj["NSView"](grid.addr()).scrollRectToVisible(
            rect(pos.x - 40.0, pos.y - lh * 2.0, 200.0, lh * 5.0)
        )
        Obj["NSView"](grid.addr()).setNeedsDisplay(True)


def _report_diagnostics():
    """Say what the server found, unless a search is showing its own count."""
    if query().byte_length() > 0:
        return
    let n = lsp.visible_diagnostic_count()
    let first = lsp.first_visible_diagnostic()
    if n == 0 or first < 0:
        set_status(String("No issues"))
        return
    # The first diagnostic in full: a count alone tells you there is a problem
    # without telling you what it is.
    set_status(
        String(n)
        + String(" issue" if n == 1 else " issues")
        + String("  ·  line ")
        + String(lsp.g_diag_line()[][first] + 1)
        + String(": ")
        + lsp.g_diag_msg()[][first]
    )


def report_matches():
    let n = match_count()
    if query().byte_length() == 0:
        set_status(String("Ready"))
    elif n == 0:
        set_status(String("no matches for ") + repr(query()))
    else:
        set_status(String(n) + String(" matches for ") + repr(query()))


def load_file(path: String) -> Bool:
    """Read a file into the buffer and tell the server about it."""
    try:
        var text: String
        with open(path, "r") as f:
            text = f.read()
        let uri = String("file://") + path
        # An already-open file selects its tab rather than opening twice, and
        # the rope arrives with the document rather than being poked into a
        # global that some other tab also thinks it owns.
        _ = document.open_document(uri, Rope(text^))
        set_caret(0)
        document.set_sent_revision(g_revision()[])
        mark_clean()
        refresh_tabs()
        lsp.set_shown_uri(uri)
        set_shown_path(path)
        # The strip scrolls now, so a tab opened past its right edge would be
        # current and invisible at the same time.
        reveal_tab(document.current_index())
        if lsp.is_ready():
            lsp.did_open(uri, g_buffer_text())
        if g_grid()[] != 0:
            let grid = ObjCObject(g_grid()[])
            let frame = Obj["NSView"](grid.addr()).frame()
            Obj["NSView"](grid.addr()).setFrameSize(
                document_size(frame.size.width)
            )
            Obj["NSView"](grid.addr()).setNeedsDisplay(True)
        if g_window()[] != 0:
            Obj["NSWindow"](ObjCObject(g_window()[]).addr()).setTitle(
                nsstring(_basename(path)).ptr()
            )
        set_status(path + String("  ·  ") + String(g_buffer_lines()) + String(" lines"))
        return True
    except:
        set_status(String("could not open ") + path)
        return False


def open_path(path: String) -> Bool:
    """Open whatever the Finder handed us: a folder becomes the project, a
    file becomes a tab.

    The server is re-rooted either way. Opening a lone file from somewhere
    else on disk with a server still rooted at the last project is how you
    get diagnostics about imports that resolve fine -- lsp_root() falls back
    to the file's own directory, so this makes that fallback take effect.
    """
    if path == "":
        return False
    if is_directory(path):
        open_folder(path)
        return True
    if not load_file(path):
        return False
    after_switch()
    ensure_lsp_rooted()
    return True


def bring_to_front():
    """Come forward. Double-clicking a document in the Finder means looking
    at it, and macOS does not activate an already-running app for us."""
    try:
        with autoreleasepool():
            let NSApplication = ObjCClass.lookup["NSApplication"]()
            let app = msg_send[
                ObjCObject, "NSApplication", "sharedApplication", is_class=True
            ](NSApplication.as_object())
            _ = msg_send[
                ObjCObject, "NSApplication", "activateIgnoringOtherApps:"
            ](app, True)
            if g_window()[] != 0:
                let win = ObjCObject(g_window()[])
                _ = msg_send[ObjCObject, "NSWindow", "makeKeyAndOrderFront:"](
                    win, win.ptr()
                )
    except:
        pass


# ── Session ─────────────────────────────────────────────────────────────────
# What the editor remembers between launches. `capture` reads the live state
# into a document, `apply` puts a document back; session.mojo does the file.
#
# Both are refused for an unattended run. A check that restored the last
# session would depend on whatever ran before it, and one that SAVED would
# quietly replace whatever the person at this machine had open with three
# tabs of fern -- the second is the one that would have hurt.
def session_enabled() -> Bool:
    return g_autoclose()[] == 0 or getenv("ROAST_SESSION") != ""


def capture_session() -> JSON:
    """The live state as a document."""
    var doc = JSON.object()
    doc.set(String("version"), JSON(1))
    if project_root() != "":
        doc.set(String("project"), JSON(project_root()))

    # Paths, so an untitled buffer is simply not remembered: it has nothing
    # to reopen from, and inventing a file for it at quit is worse than
    # forgetting it.
    var tabs = JSON.array()
    var current = 0
    var i = 0
    while i < document.count():
        let path = document.path_at(i)
        if path != "":
            if i == document.current_index():
                current = tabs.count()
            tabs.push(JSON(path))
        i += 1
    doc.set(String("tabs"), tabs^)
    doc.set(String("current"), JSON(current))

    if g_window()[] != 0:
        with autoreleasepool():
            let f = msg_send[CGRect, "NSWindow", "frame"](
                ObjCObject(g_window()[])
            )
            var frame = JSON.array()
            frame.push(JSON(Int(f.origin.x)))
            frame.push(JSON(Int(f.origin.y)))
            frame.push(JSON(Int(f.size.width)))
            frame.push(JSON(Int(f.size.height)))
            doc.set(String("frame"), frame^)
    doc.set(String("font"), JSON(Int(font_size())))

    # Settings are not derived from anything live -- they are whatever was
    # read at launch plus whatever has been set since -- so they are carried
    # across rather than rebuilt.
    let held = session.document()
    if held.has("settings"):
        doc.set(String("settings"), parse(held.get("settings")[].serialize()))
    return doc^


def apply_window_frame(doc: JSON):
    """Put the window back where it was, if there is still a screen there.

    A frame is saved against the screens of the moment. Restore it blindly
    and a window that was on a second monitor comes back on a machine that
    no longer has one -- off the edge of everything, with no way to drag it
    since the title bar is off screen too. setFrame:display: does not check;
    NSScreen does.
    """
    if g_window()[] == 0 or not doc.has("frame"):
        return
    let f = doc.get("frame")[]
    if f.count() != 4:
        return
    let w = Float64(f.at(2)[].as_int())
    let h = Float64(f.at(3)[].as_int())
    if w < 400.0 or h < 300.0:
        return
    let want = rect(
        Float64(f.at(0)[].as_int()), Float64(f.at(1)[].as_int()), w, h
    )
    with autoreleasepool():
        let NSScreen = ObjCClass.lookup["NSScreen"]()
        let screens = msg_send[
            ObjCObject, "NSScreen", "screens", is_class=True
        ](NSScreen.as_object())
        let n = msg_send[Int, "NSArray", "count"](screens)
        var visible = False
        var i = 0
        while i < n:
            let sf = msg_send[CGRect, "NSScreen", "frame"](
                msg_send[ObjCObject, "NSArray", "objectAtIndex:"](screens, i)
            )
            # The title bar has to be reachable: a generous overlap of the
            # window's top edge with some screen is the whole test.
            let top = want.origin.y + want.size.height
            if (
                want.origin.x + want.size.width > sf.origin.x + 60.0
                and want.origin.x < sf.origin.x + sf.size.width - 60.0
                and top > sf.origin.y + 60.0
                and top < sf.origin.y + sf.size.height + 1.0
            ):
                visible = True
                break
            i += 1
        if not visible:
            print("roast: saved window frame is off screen, ignoring it")
            return
        _ = msg_send[ObjCObject, "NSWindow", "setFrame:display:"](
            ObjCObject(g_window()[]), want, True
        )


def restore_session() -> Int:
    """Reopen what was open. Returns how many tabs came back.

    The project first, so the sidebar and the language server are rooted
    before any file arrives; then the files, skipping any that have been
    deleted or moved since -- a session is a memory, not a claim about what
    still exists.
    """
    let doc = session.document()
    if doc.has("font"):
        let pts = doc.get("font")[].as_int()
        if pts >= 8 and pts <= 36:
            set_font_size(Float64(pts))
    apply_window_frame(doc)

    if doc.has("project"):
        let proj = doc.get("project")[].as_string()
        if proj != "" and is_directory(proj):
            open_folder(proj)

    if not doc.has("tabs"):
        return 0
    let tabs = doc.get("tabs")[]
    let want = doc.get("current")[].as_int() if doc.has("current") else 0
    var opened = 0
    var current_uri = String()
    var i = 0
    while i < tabs.count():
        let path = tabs.at(i)[].as_string()
        if path != "" and file_exists(path):
            if load_file(path):
                if opened == want:
                    current_uri = String("file://") + path
                opened += 1
        i += 1
    # The empty scratch buffer the editor starts with is the DEFAULT state,
    # not something anyone had open, so a restore replaces it rather than
    # sitting beside it. Only if it is genuinely untouched: a buffer someone
    # typed into between launch and restore is theirs.
    if opened > 0:
        var j = document.count() - 1
        while j >= 0:
            if (
                document.path_at(j) == ""
                and not document.dirty_at(j)
                and document.count() > 1
            ):
                _ = document.close_at(j)
            j -= 1

    # By uri rather than by index: files that have gone missing shift every
    # index after them, and restoring to the wrong tab is the sort of small
    # wrongness that makes a feature feel broken.
    if current_uri != "":
        let at = document.index_of(current_uri)
        if at >= 0:
            _ = switch_document(at)
    if opened > 0:
        after_switch()
    return opened


def session_path_or_none() -> String:
    """For the startup report: where the session is kept, or why it is not."""
    if not session_enabled():
        return String("(disabled for this run)")
    let p = session.session_path()
    return p if p != "" else String("(no application support directory)")


def save_session():
    if not session_enabled():
        return
    session.replace(capture_session())
    _ = session.flush()


# ── Tab bar ─────────────────────────────────────────────────────────────────
# Tabs inside the window rather than macOS window tabs. Every editor does it
# this way, and it suits the architecture: one grid view drawing whichever
# document is current, so switching a tab is an index and a redraw.
def tab_width(total: Float64) -> Float64:
    """How wide one tab is.

    Tabs shrink to share the strip until they reach `TAB_MIN`, and then stop.
    Past that point they overflow and the strip scrolls, which is the whole
    reason `TAB_MIN` is a floor rather than a suggestion: a tab narrower than
    its filename is not a tab, it is a smear.
    """
    let n = max(1, document.count())
    return max(TAB_MIN, min(TAB_MAX, total / Float64(n)))


def tabs_span(total: Float64) -> Float64:
    """The width every tab needs together."""
    return Float64(document.count()) * tab_width(total)


def tab_overflows(total: Float64) -> Bool:
    return tabs_span(total) > total


def max_tab_scroll(total: Float64) -> Float64:
    return max(0.0, tabs_span(total) - total)


def tab_scroll(total: Float64) -> Float64:
    """The offset, clamped. Clamping on read rather than on write means a
    window resize cannot leave the strip scrolled past its own end."""
    let want = Float64(g_tab_scroll()[])
    return max(0.0, min(max_tab_scroll(total), want))


def set_tab_scroll(total: Float64, to: Float64):
    g_tab_scroll()[] = Int(max(0.0, min(max_tab_scroll(total), to)))


def reveal_tab(index: Int):
    """Scroll the strip so a tab is fully visible, if it is not already.

    Switching tabs by keyboard is the case that matters: without this, ⌘⇧] past
    the right edge selects a document you cannot see.
    """
    if g_tabbar()[] == 0:
        return
    try:
        with autoreleasepool():
            let bounds = Obj["NSView"](ObjCObject(g_tabbar()[]).addr()).bounds()
            let total = bounds.size.width
            if not tab_overflows(total):
                g_tab_scroll()[] = 0
                return
            let w = tab_width(total)
            let left = Float64(index) * w
            let cur = tab_scroll(total)
            if left < cur + TAB_GUTTER:
                set_tab_scroll(total, left - TAB_GUTTER)
            elif left + w > cur + total - TAB_GUTTER:
                set_tab_scroll(total, left + w - total + TAB_GUTTER)
    except:
        pass


def close_box(x: Float64, w: Float64) -> CGRect:
    """Where the × sits inside a tab, and where a click on it lands."""
    return rect(x + w - TAB_CLOSE - 6.0, (TAB_H - TAB_CLOSE) * 0.5,
                TAB_CLOSE, TAB_CLOSE)


class RoastTabBar(NSView):
    """The tab strip.

    `drawRect_` has to declare the dirty rectangle now. The old
    registration passed the encoding `v@:{CGRect={CGPoint=dd}{CGSize=dd}}`
    while the function took only `(self, cmd)` -- harmless, because the
    rect arrives in registers the callee never reads, but it was a claim
    about a shape nothing checked. The SDK supplies the encoding now, and
    the signature has to match it.

    The label attributes are FIELDS -- the first `named_global`s migrated
    onto the box. They are built lazily on first draw, because that is what
    the v1 box contract offers: fields start zero (the runtime zero-fills the
    ivar), zero is the "not built yet" sentinel, and the only code that can
    write the box is a method -- `RoastTabBar()` returns a copy, so seeding
    from `main` would write the copy and draw with nothing.
    """

    var _attrs: Int  # label attributes, full ink: a retained NSDictionary
    var _dim: Int  # the same, secondaryLabelColor, for inactive tabs

    def _ensure_attrs(mut self):
        """Build the two attribute dictionaries, once per instance."""
        if self._attrs != 0:
            return
        let NSMutableDictionary = ObjCClass.lookup["NSMutableDictionary"]()
        var ta = Cls["NSMutableDictionary"]().dictionary()
        Obj["NSMutableDictionary"](ta.addr()).setObject_forKey(
            Cls["NSFont"]().systemFontOfSize(Float64(12.0)).ptr(),
            extern_object["NSFontAttributeName"]().ptr(),
        )
        _ = external_call["objc_retain", P](ta.ptr())
        self._attrs = ta.addr()

        var td = Cls["NSMutableDictionary"]().dictionaryWithDictionary(ta.ptr())
        Obj["NSMutableDictionary"](td.addr()).setObject_forKey(
            Cls["NSColor"]().secondaryLabelColor().ptr(),
            extern_object["NSForegroundColorAttributeName"]().ptr(),
        )
        _ = external_call["objc_retain", P](td.ptr())
        self._dim = td.addr()
        # One line, once per instance, so the smoke test can assert the box
        # actually carried the state -- drawRect_'s try would otherwise
        # swallow a failure here into tabs quietly drawn with defaults.
        print("roast: tab attributes built in the box")

    def drawRect_(mut self, dirty: CGRect):
        try:
            self._ensure_attrs()
            with autoreleasepool():
                let view = ObjCObject(self.__objc_id)
                let bounds = Obj["NSView"](view.addr()).bounds()
                let NSColorT = ObjCClass.lookup["NSColor"]()

                # The bar, a shade back from the editor so the active tab can be
                # the one that matches it.
                let back = Cls["NSColor"]().windowBackgroundColor()
                Obj["NSColor"](back.addr()).setFill()
                _ = external_call["NSRectFill", NoneType](bounds)

                let total = bounds.size.width
                let w = tab_width(total)
                let off = tab_scroll(total)
                let active = document.current_index()
                let overflow = tab_overflows(total)
                var i = 0
                while i < document.count():
                    let x = Float64(i) * w - off
                    if x + w < 0.0:
                        i += 1
                        continue
                    if x > total:
                        break
                    if i == active:
                        let front = Cls["NSColor"]().textBackgroundColor()
                        Obj["NSColor"](front.addr()).setFill()
                        _ = external_call["NSRectFill", NoneType](
                            rect(x, 0.0, w, TAB_H)
                        )
                        # The accent underline. Background alone separates
                        # active from inactive by a shade of grey nobody can
                        # name; two points of the user's own accent colour
                        # is the affordance every browser trained.
                        let mark = Cls["NSColor"]().controlAccentColor()
                        Obj["NSColor"](mark.addr()).setFill()
                        _ = external_call["NSRectFill", NoneType](
                            rect(x, TAB_H - 2.0, w, 2.0)
                        )
                    # A separator, so tabs read as tabs and not as a run of words.
                    let line = Cls["NSColor"]().separatorColor()
                    Obj["NSColor"](line.addr()).setFill()
                    _ = external_call["NSRectFill", NoneType](
                        rect(x + w - 1.0, 4.0, 1.0, TAB_H - 8.0)
                    )

                    # The label is clipped short of the close box rather than
                    # drawn under it: a filename running through the × reads as
                    # a rendering fault, and truncating is what every editor
                    # does here.
                    # Roughly seven points a character at the tab font. A
                    # measured width would be exact, but it costs an
                    # attributed-string measurement per tab per redraw, and
                    # this only decides where to put an ellipsis.
                    let room = w - TAB_CLOSE - 20.0
                    var label = document.name_at(i)
                    # Two files named main.mojo make two identical tabs, and
                    # identical tabs are a coin toss. When any other open
                    # tab shares this basename, the parent folder joins the
                    # label -- presentation only, nothing renames.
                    var j = 0
                    while j < document.count():
                        if j != i and document.name_at(j) == label:
                            let uri = document.uri_at(i)
                            let path = (
                                String(uri[byte = 7 : uri.byte_length()])
                                if uri.startswith(String("file://"))
                                else uri
                            )
                            let dir = _basename(_dirname(path))
                            if dir != "":
                                label = dir + String("/") + label
                            break
                        j += 1
                    var glyphs = 0
                    for _ in label.codepoints():
                        glyphs += 1
                    if Float64(glyphs) * 7.0 > room:
                        let keep = max(1, Int(room / 7.0) - 1)
                        label = String(label[codepoint=:keep]) + String("…")
                    Obj["NSString"](nsstring(label).addr()).drawAtPoint_withAttributes(CGPoint(x + 10.0, 6.0), ObjCObject(
                            self._attrs if i == active else self._dim
                        ).ptr())

                    # The close box. A dirty document shows a dot instead, in
                    # the same place -- which is what the eye is already
                    # looking at, and it becomes an × on hover in editors that
                    # track the mouse. This one swaps on click instead.
                    let mark = String("•") if document.dirty_at(i) else String(
                        "\u00d7"
                    )
                    let box = close_box(x, w)
                    Obj["NSString"](nsstring(mark).addr()).drawAtPoint_withAttributes(CGPoint(box.origin.x + 4.0, 6.0), ObjCObject(
                            self._attrs if i == active else self._dim
                        ).ptr())
                    i += 1

                # Overflow arrows. Faint, and only on the side that has more
                # to show -- an arrow pointing at nothing is worse than no
                # arrow, because it invites a click that does not move.
                if overflow:
                    let bar = Cls["NSColor"]().windowBackgroundColor()
                    if off > 0.5:
                        Obj["NSColor"](bar.addr()).setFill()
                        _ = external_call["NSRectFill", NoneType](
                            rect(0.0, 0.0, TAB_GUTTER, TAB_H)
                        )
                        Obj["NSString"](nsstring(String("\u2039")).addr()).drawAtPoint_withAttributes(
                            CGPoint(3.0, 5.0),
                            ObjCObject(self._dim).ptr(),
                        )
                    if off < max_tab_scroll(total) - 0.5:
                        Obj["NSColor"](bar.addr()).setFill()
                        _ = external_call["NSRectFill", NoneType](
                            rect(total - TAB_GUTTER, 0.0, TAB_GUTTER, TAB_H)
                        )
                        Obj["NSString"](nsstring(String("\u203a")).addr()).drawAtPoint_withAttributes(
                            CGPoint(total - TAB_GUTTER + 3.0, 5.0),
                            ObjCObject(self._dim).ptr(),
                        )
        except:
            pass

    def isFlipped(self) -> Bool:
        return True

    def mouseDown_(self, event: ObjCObject):
        """Click a tab to show it, or its × to close it."""
        try:
            with autoreleasepool():
                let view = ObjCObject(self.__objc_id)
                let win_pt = Obj["NSEvent"](event.addr()).locationInWindow()
                let local = Obj["NSView"](view.addr()).convertPoint_fromView(
                    win_pt, ObjCObject(0).ptr()
                )
                let bounds = Obj["NSView"](view.addr()).bounds()
                let total = bounds.size.width
                let w = tab_width(total)
                let off = tab_scroll(total)

                # The arrows first: they sit on top of whatever tab is under
                # them, so a hit there is a scroll and not a selection.
                if tab_overflows(total):
                    if local.x < TAB_GUTTER and off > 0.5:
                        set_tab_scroll(total, off - w)
                        refresh_tabs()
                        return
                    if (
                        local.x > total - TAB_GUTTER
                        and off < max_tab_scroll(total) - 0.5
                    ):
                        set_tab_scroll(total, off + w)
                        refresh_tabs()
                        return

                let index = Int((local.x + off) / w)
                if index < 0 or index >= document.count():
                    return
                let x = Float64(index) * w - off
                let box = close_box(x, w)
                if (
                    local.x >= box.origin.x
                    and local.x <= box.origin.x + box.size.width
                ):
                    close_tab_at(index)
                    return
                if switch_document(index):
                    after_switch()
        except:
            pass

    def scrollWheel_(self, event: ObjCObject):
        """Two-finger swipe across the strip.

        Both axes are read: a trackpad swiped sideways reports X, a mouse
        wheel reports Y, and a tab strip that only answered one of them would
        feel broken on whichever hardware the user has.
        """
        try:
            with autoreleasepool():
                let view = ObjCObject(self.__objc_id)
                let bounds = Obj["NSView"](view.addr()).bounds()
                let total = bounds.size.width
                if not tab_overflows(total):
                    return
                let dx = Obj["NSEvent"](event.addr()).scrollingDeltaX()
                let dy = Obj["NSEvent"](event.addr()).scrollingDeltaY()
                let delta = dx if dx != 0.0 else dy
                if delta == 0.0:
                    return
                set_tab_scroll(total, tab_scroll(total) - delta)
                refresh_tabs()
        except:
            pass


def ask_save_close(name: String) -> Int:
    """The standard question about unsaved work: 1 save, 0 close anyway,
    -1 cancel. Buttons in Cocoa's own order, so the dialog reads like every
    other editor's."""
    with autoreleasepool():
        let NSAlert = ObjCClass.lookup["NSAlert"]()
        var alert = Cls["NSAlert"]().alloc()
        alert = Obj["NSAlert"](alert.addr()).init()
        Obj["NSAlert"](alert.addr()).setMessageText(nsstring(
                String("Do you want to save the changes made to ")
                + name
                + String("?")
            ).ptr())
        Obj["NSAlert"](alert.addr()).setInformativeText(nsstring(
                String("Your changes will be lost if you don't save them.")
            ).ptr())
        _ = Obj["NSAlert"](alert.addr()).addButtonWithTitle(
            nsstring(String("Save")).ptr()
        )
        _ = Obj["NSAlert"](alert.addr()).addButtonWithTitle(
            nsstring(String("Cancel")).ptr()
        )
        _ = Obj["NSAlert"](alert.addr()).addButtonWithTitle(
            nsstring(String("Don't Save")).ptr()
        )
        let answer = Obj["NSAlert"](alert.addr()).runModal()
        if answer == 1000:  # NSAlertFirstButtonReturn: Save
            return 1
        if answer == 1002:  # third button: Don't Save
            return 0
        return -1


def close_tab_at(index: Int):
    """Close one tab, asking about unsaved work rather than losing it.

    The same rule the menu command uses, in one place so the × and ⌘W cannot
    drift apart. This used to refuse a dirty close with a status line, which
    meant a buffer could never be deliberately abandoned -- the standard
    Save / Don't Save / Cancel question is what every document app asks.
    """
    if document.dirty_at(index):
        # The question is about a document; show the document it is about.
        if switch_document(index):
            after_switch()
        if g_autoclose()[] != 0:
            # Unattended: a modal alert with nobody at the keyboard is a hang.
            # The old refusal is the right behaviour when no one can answer.
            set_status(String("Unsaved — save it first (⌘S)"))
            return
        let answer = ask_save_close(document.name_at(index))
        if answer < 0:
            return
        if answer == 1 and not save_current():
            return  # the save panel was cancelled; so is the close
    if document.close_at(index):
        after_switch()
    else:
        set_status(String("Last tab stays open"))


def refresh_tabs():
    if g_tabbar()[] == 0:
        return
    with autoreleasepool():
        Obj["NSView"](ObjCObject(g_tabbar()[]).addr()).setNeedsDisplay(True)


def flush_pending_edit():
    """Send the buffer before leaving it.

    Edits are debounced -- three idle ticks before a didChange goes out -- so a
    tab edited and left quickly would strand its text here. The server would go
    on reporting diagnostics for a version of the file that no longer exists in
    the editor or on disk, which is exactly the case that looks like the tool
    lying to you.
    """
    try:
        if not lsp.is_ready():
            return
        if g_revision()[] == document.sent_revision():
            return
        if document.current_uri() == "" or len(g_buffer()[]) == 0:
            return
        lsp.did_change(
            document.current_uri(), g_revision()[], g_buffer()[][0].to_string()
        )
        document.set_sent_revision(g_revision()[])
    except:
        pass


def switch_document(index: Int) -> Bool:
    """Change tabs, flushing the outgoing document first.

    Every tab change goes through here rather than calling
    `document.switch_to` directly, so the flush cannot be forgotten at one of
    the nine places a tab can change.
    """
    if index == document.current_index():
        return False
    flush_pending_edit()
    return document.switch_to(index)


def after_switch():
    """Everything that has to follow the current document changing."""
    # The server holds diagnostics for every open tab; tell it which one is
    # being looked at so the right set is drawn.
    lsp.set_shown_uri(document.current_uri())
    # The gutter draws breakpoints for one file; tell it which.
    set_shown_path(document.path_at(document.current_index()))
    reveal_tab(document.current_index())
    refresh_tabs()
    _show_dirty()
    if g_window()[] != 0:
        with autoreleasepool():
            Obj["NSWindow"](ObjCObject(g_window()[]).addr()).setTitle(
                nsstring(document.name_at(document.current_index())).ptr()
            )
    if g_grid()[] != 0:
        with autoreleasepool():
            let grid = ObjCObject(g_grid()[])
            let frame = Obj["NSView"](grid.addr()).frame()
            Obj["NSView"](grid.addr()).setFrameSize(
                document_size(frame.size.width)
            )
            Obj["NSView"](grid.addr()).setNeedsDisplay(True)
    # The server is told about whichever document is showing -- but only if
    # it is behind. This used to resend the full text on every switch, which
    # on a large file made changing tabs cost a copy of the buffer and the
    # server a re-parse of text it already had.
    try:
        if (
            lsp.is_ready()
            and document.current_uri() != ""
            and g_revision()[] != document.sent_revision()
        ):
            lsp.did_change(
                document.current_uri(), g_revision()[], g_buffer_text()
            )
            document.set_sent_revision(g_revision()[])
    except:
        pass
    set_status(
        document.name_at(document.current_index())
        + String("  ·  ")
        + String(g_buffer_lines())
        + String(" lines")
    )




def is_dirty() -> Bool:
    return document.dirty_at(document.current_index())


def mark_clean():
    document.mark_saved()
    _show_dirty()
    refresh_tabs()


def _show_dirty():
    """The close button's dot: AppKit's own way of saying unsaved, so it looks
    like every other document window rather than a convention of ours."""
    if g_window()[] == 0:
        return
    with autoreleasepool():
        Obj["NSWindow"](ObjCObject(g_window()[]).addr()).setDocumentEdited(
            is_dirty()
        )


def uri_to_path(uri: String) -> String:
    """`file:///a/My%20Project/x.mojo` -> `/a/My Project/x.mojo`.

    The language server answers with RFC 3986 URIs, so every character a
    path may legally contain and a URI may not arrives percent-encoded.
    Slicing off `file://` and using the rest was right until a path held a
    space -- then Go to Definition silently opened nothing, because the
    file named `Standard%20Library` does not exist. Any project folder with
    a space in its name had the same bug; the shipped stdlib copy just made
    it certain.
    """
    var rest = String(uri)
    if rest.startswith("file://"):
        let tail = String(rest[byte=7 : rest.byte_length()])
        rest = tail
    if rest.find("%") < 0:
        return rest^
    let bytes = rest.as_bytes()
    let n = len(bytes)
    var out = String()
    var i = 0
    while i < n:
        let b = Int(bytes[i])
        if b == 0x25 and i + 2 < n:
            let hi = _hex_value(Int(bytes[i + 1]))
            let lo = _hex_value(Int(bytes[i + 2]))
            if hi >= 0 and lo >= 0:
                out += chr(hi * 16 + lo)
                i += 3
                continue
        out += chr(b)
        i += 1
    return out^


def _hex_value(b: Int) -> Int:
    if b >= 0x30 and b <= 0x39:
        return b - 0x30
    if b >= 0x41 and b <= 0x46:
        return b - 0x41 + 10
    if b >= 0x61 and b <= 0x66:
        return b - 0x61 + 10
    return -1


def _dirname(path: String) -> String:
    """The path up to the last slash, or empty."""
    let cut = path.rfind(String("/"))
    if cut <= 0:
        return String()
    return String(path[byte=:cut])


def _basename(path: String) -> String:
    let cut = path.rfind(String("/"))
    if cut < 0:
        return path
    return String(path[byte = cut + 1 : path.byte_length()])


def project_root() -> String:
    if len(g_root()[]) == 0:
        return String()
    return g_root()[][0]


def set_project_root(var path: String):
    let slot = g_root()
    if len(slot[]) == 0:
        slot[].append(path^)
    else:
        slot[][0] = path^


def children_of(dir: String) -> ObjCObject:
    """The entries of a directory, as full paths, cached.

    The outline view asks for a child by index over and over while it draws,
    so listing the directory each time would turn scrolling the sidebar into a
    syscall storm. Hidden files and build output are left out: a project is the
    files someone wrote.
    """
    if g_tree_cache()[] == 0:
        let NSMutableDictionary = ObjCClass.lookup["NSMutableDictionary"]()
        let d = Cls["NSMutableDictionary"]().dictionary()
        _ = external_call["objc_retain", P](d.ptr())
        g_tree_cache()[] = d.addr()
    let cache = ObjCObject(g_tree_cache()[])
    var key = dir
    let hit = Obj["NSDictionary"](cache.addr()).objectForKey(
        nsstring(key).ptr()
    )
    if hit.addr() != 0:
        return hit

    let NSFileManager = ObjCClass.lookup["NSFileManager"]()
    let fm = Cls["NSFileManager"]().defaultManager()
    var dirpath = dir
    let names = Obj["NSFileManager"](fm.addr()).contentsOfDirectoryAtPath_error(
        nsstring(dirpath).ptr(), ObjCObject(0).ptr()
    )

    let NSMutableArray = ObjCClass.lookup["NSMutableArray"]()
    var out = Cls["NSMutableArray"]().array()
    if names.addr() != 0:
        let count = Obj["NSArray"](names.addr()).count()
        var i = 0
        while i < count:
            let nm = Obj["NSArray"](names.addr()).objectAtIndex(i)
            let name = ns_to_string(nm)
            let skip = (
                name.startswith(".")
                or name == "build"
                or name == "bazel-bin"
                or name == "bazel-out"
                or name.endswith(".o")
            )
            if not skip:
                var full = dir
                full += "/"
                full += name
                Obj["NSMutableArray"](out.addr()).addObject(
                    nsstring(full).ptr()
                )
            i += 1
        # Alphabetical, which is what a person expects and what makes a file
        # findable twice in the same place.
        Obj["NSMutableArray"](out.addr()).sortUsingSelector(
            sel["compare:"]().ptr()
        )
    Obj["NSMutableDictionary"](cache.addr()).setObject_forKey(
        out.ptr(), nsstring(key).ptr()
    )
    return out


def is_directory(path: String) -> Bool:
    with autoreleasepool():
        let NSFileManager = ObjCClass.lookup["NSFileManager"]()
        let fm = Cls["NSFileManager"]().defaultManager()
        var p2 = path
        # A bool out-parameter would be better; asking the URL is simpler and
        # does not need a pointer to a stack BOOL.
        let names = Obj["NSFileManager"](fm.addr()).contentsOfDirectoryAtPath_error(
            nsstring(p2).ptr(),
            ObjCObject(0).ptr(),
        )
        return names.addr() != 0


# ── Outline view data source ────────────────────────────────────────────────
# Items are NSStrings holding full paths. Using the path as the item means
# there is no parallel model to keep in step with the tree, and no node objects
# to own -- the file system is the model.
def outline_children_count(item: ObjCObject) -> Int:
    try:
        with autoreleasepool():
            var dir = project_root()
            if not item.is_nil():
                dir = ns_to_string(item)
            if dir == "":
                return 0
            return Obj["NSArray"](children_of(dir).addr()).count()
    except:
        return 0


def outline_expandable(item: ObjCObject) -> Bool:
    try:
        if item.is_nil():
            return True
        with autoreleasepool():
            return is_directory(ns_to_string(item))
    except:
        return False


def outline_child_at(index: Int, item: ObjCObject) -> ObjCObject:
    """The nth entry. The string belongs to the cached array, which the cache
    dictionary retains, so it outlives this call -- and no pool here, for the
    same reason as outline_value."""
    try:
        var dir = project_root()
        if not item.is_nil():
            dir = ns_to_string(item)
        let kids = children_of(dir)
        if index < 0 or index >= Obj["NSArray"](kids.addr()).count():
            return ObjCObject(0)
        return Obj["NSArray"](kids.addr()).objectAtIndex(index)
    except:
        return ObjCObject(0)


def outline_rows() -> Int:
    """How many rows the sidebar is showing, for the startup report. Rows, not
    children: a collapsed folder contributes one and an expanded one
    contributes its subtree, which is what someone looking at the window
    counts."""
    if g_outline()[] == 0:
        return 0
    return Obj["NSTableView"](ObjCObject(g_outline()[]).addr()).numberOfRows()


def outline_display_value(item: ObjCObject) -> ObjCObject:
    """What the row shows: the name, not the path.

    Deliberately not wrapped in an autorelease pool. The NSString returned here
    is autoreleased, and a pool of ours would drain it on the way out -- AppKit
    then reads freed memory, and the crash lands in
    -[NSTableView preparedCellAtColumn:row:], nowhere near the method that
    returned the object. A method that hands back an autoreleased object must
    let it autorelease into the caller's pool.
    """
    try:
        if item.is_nil():
            return ObjCObject(0)
        let path = ns_to_string(item)
        return nsstring(_basename(path))
    except:
        return ObjCObject(0)


def lsp_server_path() -> String:
    """The language server to run. An editor built by this toolchain should
    ask this toolchain's server rather than whichever one is on PATH."""
    let explicit = getenv("ROAST_LSP")
    if explicit != "":
        return explicit^
    let here = toolchain_root()
    if here == "":
        return String()
    return here + String("/bin/mojo-lsp-server")


def lsp_import_path() -> String:
    """The server's import roots -- ALL of them, comma-joined.

    The compiler gets three -I flags from bin/cocoamojo (stdlib, max,
    kernels); the server used to get one, and the difference was every
    false "unable to locate module 'max'" squiggle over an import the
    build accepted. Configuration.cpp splits this value on commas, so the
    wrapper's INC list and this string must name the same three roots.
    ROAST_IMPORTS overrides with its own comma list.
    """
    let explicit = getenv("ROAST_IMPORTS")
    if explicit != "":
        return explicit^
    let here = toolchain_root()
    if here == "":
        return String()
    return (
        stdlib_root() + String(",")
        + here + String("/lib/mojo/max,")
        + here + String("/lib/mojo/kernels")
    )


def lsp_root() -> String:
    """The workspace the server should be rooted at.

    The project, when there is one. Otherwise the folder holding the current
    document -- a server rooted at a FILE, which is what this used to pass,
    resolves imports against a workspace that does not exist.
    """
    let proj = project_root()
    if proj != "":
        return proj^
    let path = document.path_at(document.current_index())
    let cut = path.rfind("/")
    return String(path[byte=:cut]) if cut > 0 else String()


def start_lsp() -> Bool:
    """(Re)start the server rooted at the current workspace.

    Called at launch and again whenever the project changes. The open
    documents are announced when the new process finishes its handshake,
    not here -- see announce_open_documents.
    """
    let server = lsp_server_path()
    let root = lsp_root()
    if server == "" or root == "":
        return False
    if lsp.is_running() and len(g_lsp_root()[]) > 0 and g_lsp_root()[][0] == root:
        return True  # already rooted here; a restart would buy nothing
    lsp.stop()
    # The server elaborates `class` declarations, and elaboration reads the
    # Cocoa database. bin/cocoamojo exports this before every build; a
    # Finder-launched app inherits no shell environment at all, so without
    # this line the server marks the fork's own `class` keyword as an error
    # while cmd-B builds it fine.
    var env = python_env.variables(root, toolchain_root())
    let kb = toolchain_root() + String("/share/cocoa.sqlite")
    if getenv("MODULAR_MOJO_MAX_COCOAKB_PATH") == "" and file_exists(kb):
        var kb2 = kb
        env.set(String("MODULAR_MOJO_MAX_COCOAKB_PATH"), JSON(kb2^))
    if not lsp.start_with_environment(
        server,
        String("file://") + root,
        lsp_import_path(),
        env^,
    ):
        return False
    lsp.set_shown_uri(document.current_uri())
    # No didOpen here: the protocol says nothing goes out before the server
    # answers initialize, and this used to fire immediately -- with uri ""
    # when the current tab was the scratch buffer. The open documents are
    # announced when the handshake completes, in announce_open_documents.
    let slot = g_lsp_root()
    if len(slot[]) == 0:
        slot[].append(root)
    else:
        slot[][0] = root
    return True


def restart_lsp_for_python():
    """A newly created or changed site-packages belongs to future analysis."""
    lsp.stop()
    let slot = g_lsp_root()
    if len(slot[]) == 0:
        slot[].append(String())
    else:
        slot[][0] = String()
    _ = start_lsp()


def _lsp_root_now() -> String:
    let slot = g_lsp_root()
    return slot[][0] if len(slot[]) > 0 else String()


def open_folder_files(folder: String, entry: String) -> Int:
    """Open every Mojo file directly in `folder`, leaving `entry` current.

    Top level only. A project with subdirectories would otherwise put its
    whole tree in the tab bar, and the sidebar is what a tree is for.

    `entry` is opened last so it ends up the visible tab: `open_document`
    makes what it opens current, and the file someone chose from the menu is
    the one they meant to look at.
    """
    var opened = 0
    let kids = children_of(folder)
    let n = Obj["NSArray"](kids.addr()).count()
    var i = 0
    while i < n:
        let full = ns_to_string(
            Obj["NSArray"](kids.addr()).objectAtIndex(i)
        )
        if full != entry and full.endswith(".mojo"):
            if load_file(full):
                opened += 1
        i += 1
    if load_file(entry):
        opened += 1
    return opened


def cut_name(path: String) -> Int:
    """The byte offset of the last path component, so a status line can name
    the example rather than repeat its whole path."""
    let cut = path.rfind("/")
    return cut + 1 if cut >= 0 else 0


def open_example_project(folder: String, entry: String) -> Int:
    """Load an example the way opening a project does: what was open belonged
    to the previous project, so it is saved if dirty and then closed.

    Left additive, picking two examples in a row puts the first one's files
    beside the second one's -- and since every example has a main.mojo, the tab
    bar fills with identically named tabs from different projects and the
    sidebar looks like it never changed.

    The rule is the project, not the count: a tab is kept if its file lives
    under the new folder. Picking the same example twice therefore closes
    nothing, and the untitled scratch buffer, which belongs to no project, goes
    with the rest.
    """
    # Dirty buffers first, while their tabs are still there to switch to.
    let started_at = document.current_index()
    var i = 0
    while i < document.count():
        if document.dirty_at(i):
            _ = switch_document(i)
            _ = save_current()
        i += 1
    _ = switch_document(started_at)

    # Root before files: the sidebar and the build entry point are read off it,
    # so opening files against the previous project would build the wrong
    # thing.
    open_folder(folder)
    let opened = open_folder_files(folder, entry)
    if opened == 0:
        return 0

    # Now that the new project has tabs of its own, the old ones can go --
    # backwards, so an index is never invalidated under the loop, and via
    # close_at, which keeps the last tab and has nothing left to refuse.
    #
    # Still dirty means the save above did not happen -- the panel was
    # cancelled, or the write failed. Closing it anyway would discard exactly
    # the text the person just declined to write down, so it stays open
    # alongside the new project instead.
    var prefix = folder
    prefix += "/"
    var j = document.count() - 1
    while j >= 0:
        if not document.path_at(j).startswith(prefix) and not document.dirty_at(j):
            _ = document.close_at(j)
        j -= 1
    return opened


def open_folder(var path: String):
    """Make a folder the project."""
    set_project_root(path^)
    if g_tree_cache()[] != 0:
        with autoreleasepool():
            Obj["NSMutableDictionary"](ObjCObject(g_tree_cache()[]).addr()).removeAllObjects()
    if g_outline()[] != 0:
        with autoreleasepool():
            Obj["NSOutlineView"](ObjCObject(g_outline()[]).addr()).reloadData()
    ensure_lsp_rooted()
    set_status(String("Project: ") + project_root())


def ensure_lsp_rooted():
    """Point the language server at where we are now.

    A server rooted at the old project answers about files it is no longer
    looking at -- and an app launched with only its scratch buffer has no
    root at all, so its startup start_lsp() did nothing. Opening a folder, or
    a file from the Finder, is the moment a workspace exists: start a server
    if none is running, re-root one that is rooted elsewhere. Without the
    first arm, picking an example in a fresh window meant no server for the
    whole session -- no completions, no diagnostics, silently.
    """
    if not lsp.is_running():
        if start_lsp():
            print("roast: language server started at", lsp_root())
    elif lsp_root() != _lsp_root_now():
        if start_lsp():
            print("roast: language server re-rooted at", lsp_root())


def save_current() -> Bool:
    """Write the current buffer back, asking where if it has no home yet.

    A `def` rather than the action itself, because Build has to save before it
    compiles and it has no selector arguments to hand on. Returns False if the
    save panel was cancelled or the write failed.
    """
    try:
        with autoreleasepool():
            var path = document.path_at(document.current_index())
            if path == "":
                let NSSavePanel = ObjCClass.lookup["NSSavePanel"]()
                let panel = Cls["NSSavePanel"]().savePanel()
                if Obj["NSSavePanel"](panel.addr()).runModal() != 1:
                    return False
                let url = Obj["NSSavePanel"](panel.addr()).URL()
                path = ns_to_string(
                    Obj["NSURL"](url.addr()).path()
                )
                document.set_current_uri(String("file://") + path)
                # Under its new name this is a document the server has never
                # heard of; announce it so diagnostics follow the save.
                if lsp.is_ready():
                    lsp.did_open(
                        String("file://") + path, g_buffer_text()
                    )
                    document.set_sent_revision(g_revision()[])
                    lsp.set_shown_uri(String("file://") + path)
            # The rope is written from a snapshot, so a save cannot tear even
            # if the keyboard is busy -- which is the whole point of the tree
            # being immutable.
            let text = g_buffer_text()
            with open(path, "w") as f:
                f.write(text)
            mark_clean()
            set_status(
                String("Saved ")
                + _basename(path)
                + String("  ·  ")
                + String(text.byte_length())
                + String(" bytes")
            )
            return True
    except:
        set_status(String("could not save"))
        return False


# ── Toolbar delegate ─────────────────────────────────────────────────────────
def toolbar_ids_object() -> ObjCObject:
    try:
        return toolbar_ids()
    except:
        return ObjCObject(0)


# ── Menu construction ────────────────────────────────────────────────────────
def add_item(
    menu: ObjCObject,
    title: String,
    selector: String,
    key: String,
    target: Int = 0,
) -> ObjCObject:
    """Append one item to a menu and return it.

    `target` matters more than it looks. A menu item with no target sends its
    action up the responder chain -- first responder, then the window, then the
    app delegate -- which is exactly right for `cut:`, `undo:` and `terminate:`,
    because whatever is focused should handle them. It is exactly wrong for
    Roast's own commands: RoastActions is not in the responder chain, so those
    items were disabled and did nothing at all. Anything named roast* names its
    target.
    """
    let NSMenuItem = ObjCClass.lookup["NSMenuItem"]()
    var item = Cls["NSMenuItem"]().alloc()
    item = Obj["NSMenuItem"](item.addr()).initWithTitle_action_keyEquivalent(
        nsstring(title).ptr(), sel_named(selector).ptr(), nsstring(key).ptr()
    )
    if target != 0:
        Obj["NSMenuItem"](item.addr()).setTarget(ObjCObject(target).ptr())
    Obj["NSMenu"](menu.addr()).addItem(item.ptr())
    return item


def user_space_root() -> String:
    """Where the pieces a person may EDIT live: Application Support/Roast.

    An installed app's Resources are sealed by its signature -- the right
    answer to "how do I change the stdlib" cannot be "break the seal". So
    the first launch copies the standard library and the examples out to
    user space, and everything that reads them -- builds, the language
    server, the Examples menu, definition jumps -- reads the copy. The
    bundle keeps the pristine originals, which is what makes Reset a copy
    and not a download. ROAST_USERSPACE overrides for tests.
    """
    let override = getenv("ROAST_USERSPACE")
    if override != "":
        return override^
    return session.support_dir()


def user_stdlib_dir() -> String:
    let root = user_space_root()
    if root == "":
        return String()
    return root + String("/Standard Library/stdlib")


def user_ide_source_dir() -> String:
    let root = user_space_root()
    if root == "":
        return String()
    return root + String("/IDE Source")


def user_examples_dir() -> String:
    let root = user_space_root()
    if root == "":
        return String()
    return root + String("/Examples")


def stdlib_root() -> String:
    """The stdlib in use: the user-space copy when it exists, the
    toolchain's otherwise (a bare-dist Roast edits the real tree, which is
    what a developer of the toolchain wants)."""
    let mine = user_stdlib_dir()
    if mine != "" and file_exists(mine + String("/std")):
        return mine^
    let tc = toolchain_root()
    if tc == "":
        return String()
    return tc + String("/lib/mojo/stdlib")


def _copy_tree(source: String, destination: String) -> Bool:
    """NSFileManager's copy, whole-tree, refusing to overwrite."""
    try:
        with autoreleasepool():
            let NSFileManager = ObjCClass.lookup["NSFileManager"]()
            let fm = Cls["NSFileManager"]().defaultManager()
            var err = ObjCObject(0)
            return Obj["NSFileManager"](fm.addr()).copyItemAtPath_toPath_error(
                nsstring(source).ptr(),
                nsstring(destination).ptr(),
                Pointer(to=err).unsafe_bitcast[P]()[],
            )
    except:
        return False


def _remove_tree(path: String) -> Bool:
    try:
        with autoreleasepool():
            let NSFileManager = ObjCClass.lookup["NSFileManager"]()
            let fm = Cls["NSFileManager"]().defaultManager()
            var err = ObjCObject(0)
            return Obj["NSFileManager"](fm.addr()).removeItemAtPath_error(
                nsstring(path).ptr(),
                Pointer(to=err).unsafe_bitcast[P]()[],
            )
    except:
        return False


def migrate_user_space(force: Bool = False) -> Bool:
    """Copy the stdlib, examples and IDE source somewhere writable, once --
    or again, when `force` says a person asked for fresh copies.

    The test is whether the toolchain is READ-ONLY to this person, not
    whether it sits in a bundle: an app's Resources are sealed by its
    signature, and an installation under /Applications is equally not a
    place to keep edits. A development tree is neither, and is left alone
    -- someone working on the toolchain wants to edit it in place.
    """
    let tc = toolchain_root()
    if tc == "":
        return False
    let shipped = (
        tc.find("/Contents/Resources/") >= 0
        or tc.find("/Applications/Roast/") >= 0
    )
    if not shipped:
        return False  # a development tree edits itself; nothing to move
    let root = user_space_root()
    if root == "":
        return False
    var did = False
    let lib_dst_parent = root + String("/Standard Library")
    let lib_dst = user_stdlib_dir()
    if force and file_exists(lib_dst):
        _ = _remove_tree(lib_dst)
    if not file_exists(lib_dst + String("/std")):
        _ = build.ensure_dir(lib_dst_parent)
        did = _copy_tree(tc + String("/lib/mojo/stdlib"), lib_dst) or did
    let ex_dst = user_examples_dir()
    if force and file_exists(ex_dst):
        _ = _remove_tree(ex_dst)
    if not file_exists(ex_dst + String("/README.md")):
        did = _copy_tree(tc + String("/share/examples"), ex_dst) or did
    let ide_dst = user_ide_source_dir()
    if force and file_exists(ide_dst):
        _ = _remove_tree(ide_dst)
    if not file_exists(ide_dst + String("/roast.mojo")):
        did = _copy_tree(tc + String("/share/ide-source"), ide_dst) or did
    if did or force:
        print(
            "roast: user space at", root,
            "(stdlib + examples, yours to edit)",
        )
    return True


def examples_root() -> String:
    """Where the shipped example projects live.

    The distribution puts them at share/examples beside the compiler, and
    `cocoamojo` exports COCOAMOJO_ROOT so a program it launched can find the
    toolchain that built it. ROAST_EXAMPLES overrides for a working tree.
    """
    let override = getenv("ROAST_EXAMPLES")
    if override != "":
        return override^
    let root = toolchain_root()
    if root == "":
        return String()
    let mine = user_examples_dir()
    if mine != "" and file_exists(mine + String("/README.md")):
        return mine^
    return root + String("/share/examples")


def example_projects() -> List[String]:
    """Each subdirectory holding a main.mojo, in the order the filesystem
    gives them. A folder without a main.mojo is not a project and is skipped
    rather than offered and then failing to open."""
    var out = List[String]()
    let base = examples_root()
    if base == "":
        return out^
    try:
        with autoreleasepool():
            let NSFileManager = ObjCClass.lookup["NSFileManager"]()
            let fm = Cls["NSFileManager"]().defaultManager()
            var dirpath = base
            let names = Obj["NSFileManager"](fm.addr()).contentsOfDirectoryAtPath_error(
                nsstring(dirpath).ptr(),
                ObjCObject(0).ptr(),
            )
            if names.addr() == 0:
                return out^
            let n = Obj["NSArray"](names.addr()).count()
            var i = 0
            while i < n:
                let nm = ns_to_string(
                    Obj["NSArray"](names.addr()).objectAtIndex(i)
                )
                if not nm.startswith("."):
                    let main = base + String("/") + nm + String("/main.mojo")
                    if file_exists(main):
                        out.append(nm)
                i += 1
    except:
        pass
    return out^


def file_exists(path: String) -> Bool:
    try:
        with autoreleasepool():
            let NSFileManager = ObjCClass.lookup["NSFileManager"]()
            let fm = Cls["NSFileManager"]().defaultManager()
            var local = path
            return Obj["NSFileManager"](fm.addr()).fileExistsAtPath(
                nsstring(local).ptr()
            )
    except:
        return False


def fire_example_menu(app: ObjCObject, name: String) -> Bool:
    """Click an item in the Examples menu, with nobody at the mouse.

    ROAST_EXAMPLE reproduces what the menu action does; this drives the menu
    item itself. They are not the same path -- the item carries a file path
    and the action derives the folder from it -- and the path someone actually
    clicks is the one that shipped opening a single file.
    """
    with autoreleasepool():
        let bar = Obj["NSApplication"](app.addr()).mainMenu()
        if bar.addr() == 0:
            return False
        let n = Obj["NSMenu"](bar.addr()).numberOfItems()
        var i = 0
        while i < n:
            let holder = Obj["NSMenu"](bar.addr()).itemAtIndex(i)
            let sub = Obj["NSMenuItem"](holder.addr()).submenu()
            if sub.addr() != 0:
                let title = ns_to_string(
                    Obj["NSMenu"](sub.addr()).title()
                )
                if title == String("Examples"):
                    let m = Obj["NSMenu"](sub.addr()).numberOfItems()
                    var j = 0
                    while j < m:
                        let it = Obj["NSMenu"](sub.addr()).itemAtIndex(j)
                        let t = ns_to_string(
                            Obj["NSMenuItem"](it.addr()).title()
                        )
                        if t == name:
                            Obj["NSMenu"](sub.addr()).performActionForItemAtIndex(
                                j,
                            )
                            return True
                        j += 1
                    return False
            i += 1
    return False


def build_examples_menu(bar: ObjCObject, actions: Int):
    """An Examples menu, built from what actually shipped.

    Listed at startup rather than hardcoded, so adding an example project to
    the distribution is enough to make it appear. If none are found -- a
    working tree with no COCOAMOJO_ROOT, say -- the menu says so rather than
    hanging there empty and looking broken.
    """
    let menu = add_submenu(bar, String("Examples"))
    let projects = example_projects()
    if len(projects) == 0:
        let none = add_item(
            menu, String("No examples found"), String(""), String("")
        )
        Obj["NSMenuItem"](none.addr()).setEnabled(False)
        return
    let base = examples_root()
    var i = 0
    while i < len(projects):
        let name = projects[i]
        let item = add_item(
            menu, name, String("roastOpenExample:"), String(""), actions
        )
        # The path rides on the item. A tag would only carry an index, and an
        # index into a list rebuilt at startup is a bug waiting for someone to
        # reorder the folder.
        Obj["NSMenuItem"](item.addr()).setRepresentedObject(
            nsstring(base + String("/") + name + String("/main.mojo")).ptr()
        )
        i += 1


def sel_named(name: String) -> ObjCObject:
    """A selector from a runtime string. `sel[...]` needs a literal."""
    var local = name
    let p = external_call["sel_registerName", P](
        local.as_c_string_slice().ptr()
    )
    return ObjCObject(Int(p))


def add_submenu(
    parent: ObjCObject, title: String
) -> ObjCObject:
    """A titled submenu hung off the main menu bar; returns the submenu."""
    let NSMenu = ObjCClass.lookup["NSMenu"]()
    let NSMenuItem = ObjCClass.lookup["NSMenuItem"]()

    var holder = Cls["NSMenuItem"]().alloc()
    holder = Obj["NSMenuItem"](holder.addr()).init()
    Obj["NSMenu"](parent.addr()).addItem(holder.ptr())

    var sub = Cls["NSMenu"]().alloc()
    sub = Obj["NSMenu"](sub.addr()).initWithTitle(nsstring(title).ptr())
    Obj["NSMenuItem"](holder.addr()).setSubmenu(sub.ptr())
    return sub


comptime g_side_scroll = named_global["roast.side.scroll", Int]


def apply_sidebar_theme():
    """Colour the file list to match the page.

    A source-list table draws its own vibrant background and ignores a
    colour you set on it, which is why the sidebar stayed white while the
    editor went to paper. Under a theme it becomes a plain table, which
    honours one; under `System` it goes back to being a source list, which
    is what it should look like when the app is not imposing a palette.
    """
    if g_outline()[] == 0:
        return
    with autoreleasepool():
        let outline = ObjCObject(g_outline()[])
        let system = current_theme() == "System"
        # 1 is the source-list style, 0 the plain one.
        Obj["NSTableView"](outline.addr()).setStyle(Int(1) if system else Int(0))
        if not system:
            Obj["NSTableView"](outline.addr()).setBackgroundColor(
                theme_color(ROLE_SIDEBAR_BG).ptr()
            )
        if g_side_scroll()[] != 0:
            let scroll = ObjCObject(g_side_scroll()[])
            Obj["NSScrollView"](scroll.addr()).setDrawsBackground(not system)
            if not system:
                Obj["NSScrollView"](scroll.addr()).setBackgroundColor(
                    theme_color(ROLE_SIDEBAR_BG).ptr()
                )
        Obj["NSView"](outline.addr()).setNeedsDisplay(True)
        Obj["NSOutlineView"](outline.addr()).reloadData()


def apply_theme():
    """Put the chosen theme on screen: the editor, the window, the menu.

    The window's appearance is set explicitly rather than left to follow the
    system. A dark editor page inside light chrome is worse than either --
    the scrollers, the toolbar and the tab strip are all system-drawn, and
    they have to be told.
    """
    rebuild_theme()
    apply_sidebar_theme()
    let dark = theme_is_dark(current_theme())
    with autoreleasepool():
        if g_window()[] != 0:
            let win = ObjCObject(g_window()[])
            # A `System` theme takes no appearance at all, which is how it
            # goes back to following the machine.
            if current_theme() == "System":
                Obj["NSWindow"](win.addr()).setAppearance(ObjCObject(0).ptr())
            else:
                let name = String("NSAppearanceNameDarkAqua") if dark else String(
                    "NSAppearanceNameAqua"
                )
                let appearance = Cls["NSAppearance"]().appearanceNamed(
                    nsstring(name).ptr()
                )
                Obj["NSWindow"](win.addr()).setAppearance(appearance.ptr())
            Obj["NSView"](
                Obj["NSWindow"](win.addr()).contentView().addr()
            ).setNeedsDisplay(True)
        _sync_theme_menu()
    refresh_tabs()
    refresh_grid()


def _sync_theme_menu():
    """The checkmark follows the setting, not the click: a theme restored
    from the session has to show as the chosen one too."""
    with autoreleasepool():
        let bar = _main_menu()
        if bar == 0:
            return
        let view_menu = _menu_named(bar, String("View"))
        if view_menu == 0:
            return
        let themes = _menu_named(view_menu, String("Theme"))
        if themes == 0:
            return
        let chosen = current_theme()
        let n = Obj["NSMenu"](themes).numberOfItems()
        for i in range(n):
            let item = Obj["NSMenu"](themes).itemAtIndex(i)
            let name = ns_to_string(
                Obj["NSMenuItem"](item.addr()).title()
            )
            Obj["NSMenuItem"](item.addr()).setState(
                Int(1) if name == chosen else Int(0)
            )


comptime g_theme_menu_done = named_global["roast.theme.menu", Int]


def install_theme_menu():
    """Put Theme under View, once, after AppKit has finished with that menu.

    macOS treats a menu called "View" as its own: it merges Show Tab Bar,
    Show All Tabs and Enter Full Screen into it when the window appears, and
    in doing so it rebuilds the menu -- anything added at build time is gone
    by the time the window is on screen. So this runs on the first tick
    instead, when AppKit has already had its turn.
    """
    if g_theme_menu_done()[] != 0:
        return
    with autoreleasepool():
        let bar = _main_menu()
        if bar == 0:
            return
        let view_menu = _menu_named(bar, String("View"))
        if view_menu == 0:
            return
        g_theme_menu_done()[] = 1
        let actions = g_actions()[]
        Obj["NSMenu"](view_menu).addItem(
            Cls["NSMenuItem"]().separatorItem().ptr()
        )
        let theme_menu = add_submenu(ObjCObject(view_menu), String("Theme"))
        # add_submenu titles the SUBMENU; the item carrying it keeps an
        # empty title, which leaves it anonymous to anything reading titles.
        let holder = Obj["NSMenu"](view_menu).itemAtIndex(
            Obj["NSMenu"](view_menu).numberOfItems() - 1
        )
        Obj["NSMenuItem"](holder.addr()).setTitle(
            nsstring(String("Theme")).ptr()
        )
        let chosen = current_theme()
        for name in theme_names():
            let item = add_item(
                theme_menu, name, String("roastTheme:"), String(""), actions
            )
            Obj["NSMenuItem"](item.addr()).setRepresentedObject(
                nsstring(name).ptr()
            )
            Obj["NSMenuItem"](item.addr()).setState(
                Int(1) if name == chosen else Int(0)
            )


def build_menu_bar(app: ObjCObject, actions: Int):
    """The menu bar. AppKit fills in Window and Services if we point it there."""
    let NSMenu = ObjCClass.lookup["NSMenu"]()
    var bar = Cls["NSMenu"]().alloc()
    bar = Obj["NSMenu"](bar.addr()).initWithTitle(
        nsstring(String("MainMenu")).ptr()
    )

    # App menu. Its title comes from the process name, not from us.
    let app_menu = add_submenu(bar, String("Roast"))
    _ = add_item(
        app_menu, String("About Roast"), String("orderFrontStandardAboutPanel:"), String("")
    )
    Obj["NSMenu"](app_menu.addr()).addItem(
        Cls["NSMenuItem"]().separatorItem().ptr()
    )
    _ = add_item(app_menu, String("Hide Roast"), String("hide:"), String("h"))
    _ = add_item(app_menu, String("Quit Roast"), String("terminate:"), String("q"))

    # File.
    let file = add_submenu(bar, String("File"))
    _ = add_item(file, String("New Tab"), String("roastNewTab:"), String("t"), actions)
    _ = add_item(file, String("Open…"), String("roastOpen:"), String("o"), actions)
    let folder_item = add_item(
        file, String("Open Folder…"), String("roastOpenFolder:"), String("O"),
        actions,
    )
    Obj["NSMenuItem"](folder_item.addr()).setKeyEquivalentModifierMask(
        Int(0x20000 | 0x100000)
    )
    _ = add_item(file, String("Save"), String("roastSave:"), String("s"), actions)
    let save_all = add_item(
        file, String("Save All"), String("roastSaveAll:"), String("S"), actions
    )
    # A script against this session: agent-command lines or an AppleScript,
    # picked in a panel, echoed into the console. The agent's `run-script`
    # verb is the same function without the panel.
    _ = add_item(
        file, String("Run Script…"), String("roastRunScript:"), String(""),
        actions,
    )
    # The pieces a person may edit, and the way back. The stdlib opens as an
    # ordinary project -- searchable, editable, buildable-against -- because
    # it IS one once it lives in user space.
    _ = add_item(
        file, String("Open Standard Library"),
        String("roastOpenStdlib:"), String(""), actions,
    )
    _ = add_item(
        file, String("Open IDE Source"),
        String("roastOpenIDESource:"), String(""), actions,
    )
    _ = add_item(
        file, String("Reset Standard Library & Examples…"),
        String("roastResetUserSpace:"), String(""), actions,
    )
    Obj["NSMenuItem"](save_all.addr()).setKeyEquivalentModifierMask(
        Int(0x20000 | 0x100000)
    )
    _ = add_item(
        file, String("Close Tab"), String("roastCloseTab:"), String("w"), actions
    )

    # Edit — the standard responder-chain selectors, free of charge.
    let edit = add_submenu(bar, String("Edit"))
    _ = add_item(edit, String("Undo"), String("undo:"), String("z"))
    _ = add_item(edit, String("Redo"), String("redo:"), String("Z"))
    _ = add_item(edit, String("Cut"), String("cut:"), String("x"))
    _ = add_item(edit, String("Copy"), String("copy:"), String("c"))
    _ = add_item(edit, String("Paste"), String("paste:"), String("v"))
    _ = add_item(edit, String("Select All"), String("selectAll:"), String("a"))
    Obj["NSMenu"](edit.addr()).addItem(
        Cls["NSMenuItem"]().separatorItem().ptr()
    )
    # Control-space is what every editor uses for "what goes here".
    let comp = add_item(
        edit, String("Complete"), String("roastComplete:"), String(" "), actions
    )
    Obj["NSMenuItem"](comp.addr()).setKeyEquivalentModifierMask(Int(0x40000))
    _ = add_item(edit, String("Find…"), String("roastFind:"), String("f"), actions)
    _ = add_item(edit, String("Find Next"), String("roastFindNext:"), String("g"), actions)
    let prev_item = add_item(
        edit,
        String("Find Previous"),
        String("roastFindPrevious:"),
        String("G"),
        actions,
    )
    # Shift is implied by the capital, but AppKit wants it said.
    Obj["NSMenuItem"](prev_item.addr()).setKeyEquivalentModifierMask(
        Int(0x20000 | 0x100000)
    )
    _ = add_item(edit, String("Hide Find"), String("roastHideFind:"), String("\u001b"), actions)

    # Navigate.
    let nav = add_submenu(bar, String("Navigate"))
    _ = add_item(
        nav, String("Go to Definition"), String("roastGoToDefinition:"),
        String("j"), actions,
    )
    _ = add_item(
        nav, String("Quick Help"), String("roastHover:"), String("?"), actions,
    )
    let refs = add_item(
        nav, String("Find All References"), String("roastFindReferences:"),
        String("F"), actions,
    )
    _ = msg_send[ObjCObject, "NSMenuItem", "setKeyEquivalentModifierMask:"](
        refs, Int(0x20000 | 0x100000)
    )
    _ = add_item(
        nav, String("Next Reference"), String("roastNextReference:"),
        String("e"), actions,
    )
    _ = add_item(
        nav, String("Signature Help"), String("roastSignature:"),
        String("k"), actions,
    )
    _ = msg_send[ObjCObject, "NSMenu", "addItem:"](
        nav,
        msg_send[ObjCObject, "NSMenuItem", "separatorItem", is_class=True](
            ObjCClass.lookup["NSMenuItem"]().as_object()
        ).ptr(),
    )
    # Control-Command-E, which is Xcode's rename, NOT Command-R. Build > Run
    # asks for Command-R too, and AppKit resolves a duplicate key equivalent
    # by menu order: Navigate precedes Build, so this item silently took the
    # shortcut and Run had none. Rename is occasional; Run is constant.
    let rename_item = add_item(
        nav, String("Rename…"), String("roastRename:"), String("e"), actions,
    )
    Obj["NSMenuItem"](rename_item.addr()).setKeyEquivalentModifierMask(
        Int(0x40000 | 0x100000)
    )

    # Debug. Xcode's key equivalents, because the muscle memory of anyone
    # who debugs on a Mac already has them: F6 step over, F7 in, F8 out.
    let debug_menu = add_submenu(bar, String("Debug"))
    _ = add_item(
        debug_menu, String("Start Debugging"), String("roastDebug:"),
        String("y"), actions,
    )
    _ = add_item(
        debug_menu, String("Stop Debugging"), String("roastDebugStop:"),
        String("Y"), actions,
    )
    let bor = add_item(
        debug_menu, String("Break on Raise"), String("roastBreakOnRaise:"),
        String(""), actions,
    )
    if session.setting(String("debug.break_on_raise")) == "1":
        Obj["NSMenuItem"](bor.addr()).setState(Int(1))
    _ = add_item(
        debug_menu, String("Evaluate Selection"), String("roastEvaluate:"),
        String("E"), actions,
    )
    _ = msg_send[ObjCObject, "NSMenu", "addItem:"](
        debug_menu,
        msg_send[ObjCObject, "NSMenuItem", "separatorItem", is_class=True](
            ObjCClass.lookup["NSMenuItem"]().as_object()
        ).ptr(),
    )
    _ = add_item(
        debug_menu, String("Continue"), String("roastContinue:"),
        # F5, completing the row its neighbours already occupy. What was
        # here -- "\u001b[1;2A" -- is the ANSI sequence a terminal sends for
        # shift-up; NSMenuItem wants a key, so nothing was ever bound.
        String("\uf708"), actions,
    )
    _ = add_item(
        debug_menu, String("Step Over"), String("roastStepOver:"),
        String("\uf709"), actions,
    )
    _ = add_item(
        debug_menu, String("Step Into"), String("roastStepIn:"),
        String("\uf70a"), actions,
    )
    _ = add_item(
        debug_menu, String("Step Out"), String("roastStepOut:"),
        String("\uf70b"), actions,
    )
    _ = msg_send[ObjCObject, "NSMenu", "addItem:"](
        debug_menu,
        msg_send[ObjCObject, "NSMenuItem", "separatorItem", is_class=True](
            ObjCClass.lookup["NSMenuItem"]().as_object()
        ).ptr(),
    )
    _ = add_item(
        debug_menu, String("Toggle Breakpoint"),
        String("roastToggleBreakpoint:"), String("\\"), actions,
    )
    _ = add_item(
        debug_menu, String("Clear All Breakpoints"),
        String("roastClearBreakpoints:"), String("|"), actions,
    )

    # View.
    let view_menu = add_submenu(bar, String("View"))
    _ = add_item(
        view_menu, String("Zoom In"), String("roastZoomIn:"), String("="), actions
    )
    _ = add_item(
        view_menu, String("Zoom Out"), String("roastZoomOut:"), String("-"), actions
    )
    # Build.
    let build_menu = add_submenu(bar, String("Build"))
    _ = add_item(build_menu, String("Build"), String("roastBuild:"), String("b"), actions)
    _ = add_item(build_menu, String("Run"), String("roastRun:"), String("r"), actions)
    _ = add_item(build_menu, String("Stop"), String("roastStop:"), String("."), actions)
    _ = add_item(
        build_menu,
        String("Console"),
        String("roastConsole:"),
        String("0"),
        actions,
    )

    # Python. CPython runs inside the Mojo program; these commands only own
    # the project venv and pip's mutations before that program is launched.
    let python_menu = add_submenu(bar, String("Python"))
    _ = add_item(
        python_menu,
        String("Create or Repair Environment"),
        String("roastPythonEnvironment:"),
        String(""),
        actions,
    )
    _ = add_item(
        python_menu,
        String("Install Project Dependencies"),
        String("roastPythonInstallProject:"),
        String(""),
        actions,
    )
    _ = add_item(
        python_menu,
        String("Install Package…"),
        String("roastPythonInstall:"),
        String(""),
        actions,
    )
    Obj["NSMenu"](python_menu.addr()).addItem(
        Cls["NSMenuItem"]().separatorItem().ptr()
    )
    _ = add_item(
        python_menu,
        String("Show Environment Path"),
        String("roastPythonShowEnvironment:"),
        String(""),
        actions,
    )

    # Examples — built from what shipped, so the menu and the distribution
    # cannot disagree about which examples exist.
    build_examples_menu(bar, actions)

    # Window — handing AppKit the menu gets tab management for free.
    let window_menu = add_submenu(bar, String("Window"))
    let nxt = add_item(
        window_menu, String("Next Tab"), String("roastNextTab:"),
        String("]"), actions,
    )
    Obj["NSMenuItem"](nxt.addr()).setKeyEquivalentModifierMask(
        Int(0x20000 | 0x100000)
    )
    let prv = add_item(
        window_menu, String("Previous Tab"), String("roastPrevTab:"),
        String("["), actions,
    )
    Obj["NSMenuItem"](prv.addr()).setKeyEquivalentModifierMask(
        Int(0x20000 | 0x100000)
    )
    Obj["NSApplication"](app.addr()).setWindowsMenu(window_menu.ptr())

    Obj["NSApplication"](app.addr()).setMainMenu(bar.ptr())


# ── Main ─────────────────────────────────────────────────────────────────────
# ── The agent surface ────────────────────────────────────────────────────────
# Apple Events in, text out. RECEIVING an event needs no permission -- the
# grant a human makes is Automation for the SENDER, once, per sender -- which
# is what makes this reachable where screencapture and System Events are not
# (both were refused by TCC while building this, and neither can be granted
# headlessly, by design).
#
# The dispatcher is a plain String -> String function, so every command is
# testable without an event, a window, or a second process. IDE-DESIGN.md
# carries the full command set; sprint 1 is the transport plus the three
# read-only verbs.
comptime AE_CLASS = 0x526F7374    # 'Rost'
comptime AE_CMD = 0x636D6E64      # 'cmnd'
comptime AE_DIRECT = 0x2D2D2D2D   # '----', keyDirectObject

comptime g_agent_obj = named_global["roast.agent.obj", Int]
comptime g_agent_count = named_global["roast.agent.count", Int]
# `after N cmd`: commands scheduled for a later tick. Two parallel lists,
# drained by the tick -- the idiom every other deferred thing here uses.
comptime g_agent_at = named_global["roast.agent.at", List[Int]]
comptime g_agent_later = named_global["roast.agent.later", List[String]]

comptime AGENT_HELP = (
    "commands: help · status · console · show-console · hide-console"
    " · screenshot [path]"
    " · menus · menu <Title> · menu <Title> > <Item>"
    " · open <path> · save · goto <line>[:col] · caret · file"
    " · tabs · tab <n> · type <text> · find <text>"
    " · views · sidebar <pt> · console-size <pct> · setting <key> [value]"
    " · run-script <path>"
    " · debug · break <line> · continue · step-over · step-in · step-out"
    " · stopped · variables · eval <expr> · eval?"
)


def _menu_item_name(item_addr: Int) -> String:
    """What a person calls this item. A top-level item's own title is often
    empty -- the NAME lives on the submenu it carries -- so prefer that."""
    with autoreleasepool():
        if Obj["NSMenuItem"](item_addr).hasSubmenu():
            let sub = Obj["NSMenuItem"](item_addr).submenu()
            let t = ns_to_string(Obj["NSMenu"](sub.addr()).title())
            if t != "":
                return t
        return ns_to_string(Obj["NSMenuItem"](item_addr).title())


def _menu_named(bar_addr: Int, title: String) -> Int:
    """The submenu with this title off the given menu, or 0."""
    with autoreleasepool():
        let n = Obj["NSMenu"](bar_addr).numberOfItems()
        for i in range(n):
            let item = Obj["NSMenu"](bar_addr).itemAtIndex(i)
            if _menu_item_name(item.addr()) == title:
                if Obj["NSMenuItem"](item.addr()).hasSubmenu():
                    return Obj["NSMenuItem"](item.addr()).submenu().addr()
                return 0
    return 0


def _main_menu() -> Int:
    with autoreleasepool():
        let app = Cls["NSApplication"]().sharedApplication()
        return Obj["NSApplication"](app.addr()).mainMenu().addr()


def _current_rope_line() -> Int:
    """The caret's line, 1-based, or 0 with no buffer."""
    if len(g_buffer()[]) == 0:
        return 0
    let buf = g_buffer()[][0]
    return buf.line_of_offset(g_caret()[]) + 1


def agent_command(text: String) -> String:
    """One command in, one line of reply out.

    Unknown commands answer rather than failing silently: an agent that
    mistypes should be told, and `help` should always be reachable.
    """
    g_agent_count()[] = g_agent_count()[] + 1
    var cmd = text.strip()
    if cmd == "":
        return String("empty; try: help")

    if cmd == "help":
        return String(AGENT_HELP)

    if cmd == "status":
        # What the status line says, plus the facts an agent would otherwise
        # have to infer: whether a program is under the debugger, and where
        # it is stopped.
        var out = String()
        let slot = g_status_text()
        if len(slot[]) > 0:
            out = slot[][0]
        if out == "":
            out = String("idle")
        try:
            if dap.is_running():
                if dap.is_stopped():
                    out += (
                        String("  |  stopped ")
                        + _basename(dap.stop_file())
                        + String(":")
                        + String(dap.stop_line())
                        + String(" (")
                        + dap.stop_reason()
                        + String(")")
                    )
                else:
                    out += String("  |  debuggee running")
        except:
            pass
        return out

    # ── the debugger ────────────────────────────────────────────────────
    # The step verbs go through the REAL toolbar items -- looked up in the
    # live bar, action sent to the item's own target -- so an agent run is
    # also a UI test. A button missing from the bar, wired to the wrong
    # selector, or aimed at a dead target fails here exactly as it would
    # under a pointer.
    if cmd == "debug":
        try:
            _start_debug()
            return String("debug: requested")
        except:
            return String("error: could not start debugging")

    if cmd == "continue" or cmd == "step-over" or cmd == "step-in" \
            or cmd == "step-out":
        # The presser names buttons, not commands. Spelled out rather than
        # sliced: it is four cases and reads as the mapping it is.
        var which = String("continue")
        if cmd == "step-over":
            which = String("over")
        elif cmd == "step-in":
            which = String("in")
        elif cmd == "step-out":
            which = String("out")
        try:
            if not dap.is_stopped():
                return String("error: not stopped; nothing to ") + cmd
            if _press_debug_button(which):
                return cmd + String(": pressed")
            return String("error: no toolbar item for ") + cmd
        except:
            return String("error: ") + cmd + String(" raised")

    if cmd == "stopped":
        try:
            if not dap.is_running():
                return String("no")
            if not dap.is_stopped():
                return String("running")
            return (
                String("yes ")
                + _basename(dap.stop_file())
                + String(":")
                + String(dap.stop_line())
                + String(" (")
                + dap.stop_reason()
                + String(")")
            )
        except:
            return String("error: could not read debugger state")

    if cmd == "variables":
        try:
            if not dap.is_stopped():
                return String("error: not stopped")
            let n = dap.variable_count()
            if n == 0:
                return String("(no locals)")
            var out = String()
            for i in range(n):
                if i > 0:
                    out += String(" · ")
                out += dap.variable_name(i)
                let t = _pretty_type(dap.variable_type(i))
                if t != "":
                    out += String(": ") + t
                out += String(" = ") + dap.variable_value(i)
            return out
        except:
            return String("error: could not read locals")

    if cmd.startswith("break"):
        let arg = String(cmd[byte=5 : cmd.byte_length()])
        let where = String(arg.strip())
        if where == "":
            return String("usage: break <line>")
        try:
            let entry = build.entry_point(project_root(), String())
            if entry == "":
                return String("error: no entry point in this project")
            let on = dap.toggle_breakpoint(entry, Int(where))
            return (
                (String("set") if on else String("cleared"))
                + String(" ")
                + _basename(entry)
                + String(":")
                + where
            )
        except:
            return String("error: could not toggle a breakpoint at ") + where

    if cmd.startswith("eval"):
        let expr_raw = String(cmd[byte=4 : cmd.byte_length()])
        let expr = String(expr_raw.strip())
        if expr == "":
            return String("usage: eval <expression>")
        try:
            if not dap.is_stopped():
                return String("error: not stopped; eval needs a frame")
            if not dap.evaluate(expr):
                return String("error: evaluate refused")
            # The answer arrives on a later tick, through the same serial the
            # UI watches. An agent reads it back rather than blocking a
            # handler on a runloop it is itself running.
            return String("eval: requested; read it with `eval?`")
        except:
            return String("error: eval raised")

    if cmd == "eval?":
        try:
            if dap.eval_expr() == "":
                return String("(nothing evaluated yet)")
            var out = dap.eval_expr() + String(" = ") + dap.eval_result()
            if not dap.eval_ok():
                out = dap.eval_expr() + String(" ! ") + dap.eval_result()
            return out
        except:
            return String("error: could not read the last evaluation")

    if cmd.startswith("screenshot"):
        let tail = String(cmd[byte=10 : cmd.byte_length()])
        var where = String(tail.strip())
        if where == "":
            where = String("/tmp/roast.png")
        return screenshot(where)

    # ── menus: every invocable feature, by its visible name ─────────────
    if cmd == "menus":
        var out = String()
        with autoreleasepool():
            let bar = _main_menu()
            if bar == 0:
                return String("error: no menu bar")
            let n = Obj["NSMenu"](bar).numberOfItems()
            for i in range(n):
                let item = Obj["NSMenu"](bar).itemAtIndex(i)
                if i > 0:
                    out += String(" · ")
                out += _menu_item_name(item.addr())
        return out

    if cmd.startswith("menu "):
        let rest0 = String(cmd[byte=5 : cmd.byte_length()])
        let spec = String(rest0.strip())
        let gt = spec.find(">")
        if gt < 0:
            # List one menu's items, the agent's discovery step.
            let sub = _menu_named(_main_menu(), spec)
            if sub == 0:
                return String("error: no menu called ") + spec
            var out = String()
            with autoreleasepool():
                let n = Obj["NSMenu"](sub).numberOfItems()
                for i in range(n):
                    let item = Obj["NSMenu"](sub).itemAtIndex(i)
                    let t = ns_to_string(
                        Obj["NSMenuItem"](item.addr()).title()
                    )
                    if i > 0:
                        out += String(" · ")
                    out += t if t != "" else String("---")
            return out
        # Invoke:  menu Debug > Step Over
        let mt = String(spec[byte=:gt])
        let it = String(spec[byte = gt + 1 : spec.byte_length()])
        let menu_title = String(mt.strip())
        let item_title = String(it.strip())
        let sub = _menu_named(_main_menu(), menu_title)
        if sub == 0:
            return String("error: no menu called ") + menu_title
        with autoreleasepool():
            let n = Obj["NSMenu"](sub).numberOfItems()
            for i in range(n):
                let item = Obj["NSMenu"](sub).itemAtIndex(i)
                let t = ns_to_string(Obj["NSMenuItem"](item.addr()).title())
                if t == item_title:
                    # The real dispatch: highlight, validation, action --
                    # everything a click does short of the mouse.
                    Obj["NSMenu"](sub).performActionForItemAtIndex(i)
                    return (
                        String("invoked ") + menu_title + String(" > ")
                        + item_title
                    )
        return (
            String("error: no item ") + item_title + String(" in ")
            + menu_title
        )

    # ── the editor ──────────────────────────────────────────────────────
    if cmd.startswith("open "):
        let p0 = String(cmd[byte=5 : cmd.byte_length()])
        let p = String(p0.strip())
        if open_path(p):
            return String("opened ") + p
        return String("error: could not open ") + p

    if cmd == "save":
        if save_current():
            return String("saved ") + document.current_uri()
        return String("error: nothing saved")

    if cmd.startswith("goto "):
        let a0 = String(cmd[byte=5 : cmd.byte_length()])
        let a = String(a0.strip())
        if len(g_buffer()[]) == 0:
            return String("error: no buffer")
        let buf = g_buffer()[][0]
        var want_line = 0
        var want_col = 0
        let colon = a.find(":")
        try:
            if colon >= 0:
                want_line = Int(String(a[byte=:colon]))
                want_col = Int(String(a[byte = colon + 1 : a.byte_length()]))
            else:
                want_line = Int(a)
        except:
            return String("usage: goto <line>[:<col>]")
        if want_line < 1 or want_line > buf.line_count():
            return (
                String("error: line out of range 1..")
                + String(buf.line_count())
            )
        var at = buf.line_start(want_line - 1)
        if want_col > 1:
            at += want_col - 1
        set_caret(at)
        scroll_to_caret()
        refresh_grid()
        return String("caret at line ") + String(want_line)

    if cmd == "caret":
        if len(g_buffer()[]) == 0:
            return String("error: no buffer")
        let buf = g_buffer()[][0]
        let line = buf.line_of_offset(g_caret()[])
        let col = g_caret()[] - buf.line_start(line)
        return (
            String("line ") + String(line + 1) + String(" col ")
            + String(col + 1) + String(" byte ") + String(g_caret()[])
        )

    if cmd == "file":
        let uri = document.current_uri()
        if uri == "":
            return String("(untitled)")
        return uri

    if cmd == "tabs":
        var out = String()
        for i in range(document.count()):
            if i > 0:
                out += String(" · ")
            out += String(i) + String(":")
            let u = document.uri_at(i)
            out += _basename(u) if u != "" else String("untitled")
        return out

    if cmd.startswith("tab "):
        let t0 = String(cmd[byte=4 : cmd.byte_length()])
        try:
            let idx = Int(String(t0.strip()))
            if switch_document(idx):
                after_switch()
                return String("tab ") + String(idx)
            return String("error: no tab ") + String(idx)
        except:
            return String("usage: tab <index>")

    if cmd.startswith("type "):
        # Everything after the single space, verbatim -- an agent may well
        # want to type leading spaces.
        let ins = String(cmd[byte=5 : cmd.byte_length()])
        if len(g_buffer()[]) == 0:
            return String("error: no buffer")
        replace_selection(ins)
        refresh_grid()
        return (
            String("typed ") + String(ins.byte_length())
            + String(" byte(s), caret at line ")
            + String(_current_rope_line())
        )

    if cmd.startswith("find "):
        let q0 = String(cmd[byte=5 : cmd.byte_length()])
        let q = String(q0.strip())
        set_query(q)
        let hit = find_next()
        scroll_to_caret()
        refresh_grid()
        if not hit:
            return String("0 matches")
        return (
            String(match_count()) + String(" match(es), caret at line ")
            + String(_current_rope_line())
        )

    # ── views and dividers ──────────────────────────────────────────────
    if cmd == "views":
        var out = String()
        with autoreleasepool():
            if g_window()[] == 0:
                return String("error: no window")
            let wf = Obj["NSWindow"](ObjCObject(g_window()[]).addr()).frame()
            out += (
                String("window ") + String(wf.size.width) + String("x")
                + String(wf.size.height)
            )
            if g_hsplit()[] != 0:
                let subs = Obj["NSView"](g_hsplit()[]).subviews()
                let n = Obj["NSArray"](subs.addr()).count()
                out += String(" · sidebar|editor")
                for i in range(n):
                    let v = Obj["NSArray"](subs.addr()).objectAtIndex(i)
                    out += (
                        String(" ")
                        + String(Obj["NSView"](v.addr()).frame().size.width)
                    )
            if g_vsplit()[] != 0:
                let subs2 = Obj["NSView"](g_vsplit()[]).subviews()
                let n2 = Obj["NSArray"](subs2.addr()).count()
                out += String(" · editor|console")
                for i in range(n2):
                    let v2 = Obj["NSArray"](subs2.addr()).objectAtIndex(i)
                    out += (
                        String(" ")
                        + String(Obj["NSView"](v2.addr()).frame().size.height)
                    )
        return out

    if cmd.startswith("sidebar "):
        let w0 = String(cmd[byte=8 : cmd.byte_length()])
        try:
            let pts = Int(String(w0.strip()))
            if g_hsplit()[] == 0:
                return String("error: no split")
            with autoreleasepool():
                Obj["NSSplitView"](g_hsplit()[]).setPosition_ofDividerAtIndex(
                    Float64(pts), Int(0)
                )
            return String("sidebar ") + String(pts) + String(" pt")
        except:
            return String("usage: sidebar <points>")

    if cmd.startswith("console-size "):
        let f0 = String(cmd[byte=13 : cmd.byte_length()])
        try:
            let pct = Int(String(f0.strip()))
            if pct < 0 or pct > 90:
                return String("usage: console-size <0..90 percent>")
            if g_vsplit()[] == 0:
                return String("error: no split")
            with autoreleasepool():
                let b = Obj["NSView"](g_vsplit()[]).bounds()
                Obj["NSSplitView"](g_vsplit()[]).setPosition_ofDividerAtIndex(
                    b.size.height * Float64(100 - pct) / 100.0, Int(0)
                )
            g_console_open()[] = 1 if pct > 0 else 0
            return String("console ") + String(pct) + String("%")
        except:
            return String("usage: console-size <0..90 percent>")

    # ── settings ────────────────────────────────────────────────────────
    if cmd.startswith("setting "):
        let s0 = String(cmd[byte=8 : cmd.byte_length()])
        let spec2 = String(s0.strip())
        let sp = spec2.find(" ")
        if sp < 0:
            let v = session.setting(spec2)
            if v == "":
                return String("(unset)")
            return v
        let key = String(spec2[byte=:sp])
        let val0 = String(spec2[byte = sp + 1 : spec2.byte_length()])
        session.set_setting(String(key), String(val0.strip()))
        return String("set ") + key

    if cmd.startswith("after "):
        # after 120 screenshot /tmp/x.png -- run a command that many ticks
        # from now. What makes asynchronous effects testable: invoke, wait,
        # look. In a Run Script file it reads as a pause.
        let a0 = String(cmd[byte=6 : cmd.byte_length()])
        let spec3 = String(a0.strip())
        let sp3 = spec3.find(" ")
        if sp3 < 0:
            return String("usage: after <ticks> <command>")
        try:
            let dt = Int(String(spec3[byte=:sp3]))
            let later = String(spec3[byte = sp3 + 1 : spec3.byte_length()])
            g_agent_at()[].append(g_ticks()[] + dt)
            g_agent_later()[].append(later)
            return String("scheduled in ") + String(dt) + String(" tick(s)")
        except:
            return String("usage: after <ticks> <command>")

    if cmd.startswith("run-script "):
        let rs0 = String(cmd[byte=11 : cmd.byte_length()])
        return run_agent_script(String(rs0.strip()))

    if cmd == "show-console":
        show_console(True)
        return String("console shown")

    if cmd == "hide-console":
        show_console(False)
        return String("console hidden")

    if cmd == "console":
        # Read back from the text view, not from the buffer it was built
        # from, so this answers what is actually on screen.
        let text_out = console_text()
        if text_out == "":
            return String("(console empty)")
        return text_out

    return String("unknown command: ") + cmd + String("; try: help")


def screenshot(path: String) -> String:
    """Photograph the window into a PNG at `path`. Returns a reply line.

    The app draws ITSELF: `cacheDisplayInRect:toBitmapImageRep:` renders a
    view hierarchy into a bitmap. That is view drawing, not screen capture --
    no CGWindowList, no display stream -- so it needs no Screen Recording
    grant, which is the point. `screencapture` was refused by TCC on this
    machine while the toolbar was being built, and that grant cannot be given
    headlessly, by design.

    The view rendered is contentView's SUPERVIEW, the window's frame view, so
    the picture includes the titlebar and the toolbar. Photographing
    contentView alone would leave out the buttons this was written to look at.
    """
    with autoreleasepool():
        if g_window()[] == 0:
            return String("error: no window")
        let win = ObjCObject(g_window()[])
        let content = Obj["NSWindow"](win.addr()).contentView()
        if content.addr() == 0:
            return String("error: no content view")
        # The frame view, when there is one: titlebar and toolbar live there.
        # Carried as an address rather than an object: Obj is a typed handle
        # and not copyable, so the choice is made on the addr and rewrapped.
        var view_addr = content.addr()
        let above = Obj["NSView"](content.addr()).superview()
        if above.addr() != 0:
            view_addr = above.addr()

        let b = Obj["NSView"](view_addr).bounds()
        if b.size.width < 1.0 or b.size.height < 1.0:
            return String("error: view has no size")
        let r = rect(0.0, 0.0, b.size.width, b.size.height)

        let rep = Obj["NSView"](view_addr).bitmapImageRepForCachingDisplayInRect(r)
        if rep.addr() == 0:
            return String("error: could not make a bitmap")
        Obj["NSView"](view_addr).cacheDisplayInRect_toBitmapImageRep(r, rep.ptr())

        # 4 is NSBitmapImageFileTypePNG. An empty properties dictionary rather
        # than nil: the parameter is typed as a dictionary and nil is the sort
        # of thing that works until a release where it does not.
        let props = Cls["NSMutableDictionary"]().dictionary()
        let data = Obj["NSBitmapImageRep"](rep.addr()).representationUsingType_properties(
            UInt64(4), props.ptr()
        )
        if data.addr() == 0:
            return String("error: PNG encoding failed")
        let wrote = Obj["NSData"](data.addr()).writeToFile_atomically(
            nsstring(path).ptr(), True
        )
        if not wrote:
            return String("error: could not write ") + path
        let w = Obj["NSBitmapImageRep"](rep.addr()).pixelsWide()
        let h = Obj["NSBitmapImageRep"](rep.addr()).pixelsHigh()
        return (
            path + String(" (") + String(w) + String("x") + String(h)
            + String(" px)")
        )


def run_agent_script(path: String) -> String:
    """Run a script file against this session, echoing into the console.

    Two languages, told apart by extension. `.applescript` and `.scpt` run
    through NSAppleScript IN this process -- events an app sends itself need
    no Automation grant, so a user's script drives Roast with no dialog. And
    with the sdef shipped, `tell application "Roast" to do command "..."`
    reads like it should. Anything else is agent-command lines: one command
    per line, `#` comments, the exact language `help` describes -- so a
    session someone drove by hand can be saved and replayed.
    """
    if not file_exists(path):
        return String("error: no script at ") + path
    build.append_output(
        String("\n─── script ") + _basename(path) + String(" ───\n")
    )
    var lower = String(path)
    let is_osa = lower.endswith(".applescript") or lower.endswith(".scpt")
    var failures = 0
    var ran = 0
    if is_osa:
        with autoreleasepool():
            let url = Cls["NSURL"]().fileURLWithPath(nsstring(path).ptr())
            var err = ObjCObject(0)
            var script = Cls["NSAppleScript"]().alloc()
            script = Obj["NSAppleScript"](
                script.addr()
            ).initWithContentsOfURL_error(
                url.ptr(), Pointer(to=err).unsafe_bitcast[P]()[]
            )
            if script.addr() == 0:
                build.append_output(String("could not load the script\n"))
                console_sync()
                return String("error: could not load ") + path
            var err2 = ObjCObject(0)
            let result = Obj["NSAppleScript"](
                script.addr()
            ).executeAndReturnError(
                Pointer(to=err2).unsafe_bitcast[P]()[]
            )
            if result.addr() == 0:
                build.append_output(String("script error (see Script Editor")
                    + String(" for details)\n"))
                console_sync()
                return String("error: script failed")
            var out = String("(no result)")
            let sv = Obj["NSAppleEventDescriptor"](result.addr()).stringValue()
            if sv.addr() != 0:
                out = ns_to_string(sv)
            build.append_output(out + String("\n"))
            console_sync()
            return String("applescript ok: ") + out
    # Agent-command lines.
    try:
        var text: String
        with open(path, "r") as f:
            text = f.read()
        var rest = text
        while rest != "":
            var line_text = rest
            let nl = rest.find("\n")
            if nl >= 0:
                line_text = String(rest[byte=:nl])
                let t2 = String(rest[byte = nl + 1 : rest.byte_length()])
                rest = t2
            else:
                rest = String("")
            let one = String(line_text.strip())
            if one == "" or one.startswith("#"):
                continue
            ran += 1
            build.append_output(String("> ") + one + String("\n"))
            let reply = agent_command(one)
            build.append_output(String("  ") + reply + String("\n"))
            if reply.startswith("error"):
                failures += 1
        console_sync()
    except:
        return String("error: could not read ") + path
    return (
        String("script ok: ") + String(ran) + String(" command(s), ")
        + String(failures) + String(" error(s)")
    )


fn _agent_ae_handler(obj: P, cmd: P, event: P, reply: P, /) -> None:
    """`handleEvent:withReplyEvent:` -- unwrap, dispatch, wrap the reply.

    A plain `fn`, because this is an IMP the runtime calls directly: it takes
    the four raw pointers an Objective-C method really receives. Every failure
    is swallowed into a reply rather than raised -- an exception crossing back
    into the runtime would take the process with it, and an agent is better
    told that something went wrong than left holding a dead connection.
    """
    try:
        with autoreleasepool():
            var answer = String("error: no direct parameter")
            let ev = ObjCObject(Int(event))
            if ev.addr() != 0:
                let param = Obj["NSAppleEventDescriptor"](
                    ev.addr()
                ).paramDescriptorForKeyword(UInt32(AE_DIRECT))
                if param.addr() != 0:
                    answer = agent_command(
                        ns_to_string(
                            Obj["NSAppleEventDescriptor"](
                                param.addr()
                            ).stringValue()
                        )
                    )
            let rep = ObjCObject(Int(reply))
            if rep.addr() != 0:
                let d = Cls["NSAppleEventDescriptor"]().descriptorWithString(
                    nsstring(answer).ptr()
                )
                Obj["NSAppleEventDescriptor"](
                    rep.addr()
                ).setParamDescriptor_forKeyword(d.ptr(), UInt32(AE_DIRECT))
    except:
        pass


def register_agent_events():
    """Register the handler for Rost/cmnd.

    The selector is one no SDK class declares, so its encoding is given here
    rather than looked up -- `v@:@@`, the shape every Apple Event handler has.
    That is also why this is an ObjCClassBuilder and not a `class`: the
    compiler takes encodings from the SDK, and there is nothing there to take.

    With no sender this is inert: a registration nobody posts to costs one
    object and an entry in the manager's table.
    """
    try:
        with autoreleasepool():
            var b = ObjCClassBuilder("RoastAgent")
            b.add_method["handleEvent:withReplyEvent:", encoding="v@:@@"](
                _agent_ae_handler
            )
            let cls = b^.register()
            let target = new_instance(cls)
            g_agent_obj()[] = target.addr()
            let mgr = Cls["NSAppleEventManager"]().sharedAppleEventManager()
            Obj["NSAppleEventManager"](
                mgr.addr()
            ).setEventHandler_andSelector_forEventClass_andEventID(
                target.ptr(),
                sel["handleEvent:withReplyEvent:"]().ptr(),
                UInt32(AE_CLASS),
                UInt32(AE_CMD),
            )
            print("roast: agent events registered (Rost/cmnd)")
    except:
        print("roast: agent events FAILED to register")


def agent_send_self(command: String) -> String:
    """Post `command` to this process as a Rost/cmnd event and return the
    reply. The transport an external agent uses, minus only the cross-process
    hop that TCC gates -- registration, unpack, dispatch and reply are the
    same code either way."""
    try:
        with autoreleasepool():
            let me = Cls[
                "NSAppleEventDescriptor"
            ]().descriptorWithProcessIdentifier(
                Int32(external_call["getpid", Int32]())
            )
            let ev = Cls[
                "NSAppleEventDescriptor"
            ]().appleEventWithEventClass_eventID_targetDescriptor_returnID_transactionID(
                UInt32(AE_CLASS), UInt32(AE_CMD), me.ptr(), Int16(-1), Int32(0)
            )
            let arg = Cls["NSAppleEventDescriptor"]().descriptorWithString(
                nsstring(command).ptr()
            )
            Obj["NSAppleEventDescriptor"](
                ev.addr()
            ).setParamDescriptor_forKeyword(arg.ptr(), UInt32(AE_DIRECT))
            var err = ObjCObject(0)
            let reply = Obj["NSAppleEventDescriptor"](
                ev.addr()
            ).sendEventWithOptions_timeout_error(
                UInt64(0x00000003),
                Float64(5.0),
                Pointer(to=err).unsafe_bitcast[P]()[],
            )
            if reply.addr() == 0:
                return String("error: no reply")
            let back = Obj["NSAppleEventDescriptor"](
                reply.addr()
            ).paramDescriptorForKeyword(UInt32(AE_DIRECT))
            if back.addr() == 0:
                return String("error: reply had no parameter")
            return ns_to_string(
                Obj["NSAppleEventDescriptor"](back.addr()).stringValue()
            )
    except:
        return String("error: send raised")


def agent_self_test() -> Bool:
    """Post a Rost/cmnd event to this very process and check the reply.

    The whole path -- registration, unpack, dispatch, reply -- with no second
    process and no TCC grant, because a process may always send to itself.
    The manager dispatches inline, so this returns rather than waiting on a
    runloop; the timeout is there so a future change that breaks that shows up
    as a failure and not as a hang.
    """
    try:
        with autoreleasepool():
            let me = Cls[
                "NSAppleEventDescriptor"
            ]().descriptorWithProcessIdentifier(
                Int32(external_call["getpid", Int32]())
            )
            let ev = Cls[
                "NSAppleEventDescriptor"
            ]().appleEventWithEventClass_eventID_targetDescriptor_returnID_transactionID(
                UInt32(AE_CLASS), UInt32(AE_CMD), me.ptr(), Int16(-1), Int32(0)
            )
            let arg = Cls["NSAppleEventDescriptor"]().descriptorWithString(
                nsstring(String("help")).ptr()
            )
            Obj["NSAppleEventDescriptor"](
                ev.addr()
            ).setParamDescriptor_forKeyword(arg.ptr(), UInt32(AE_DIRECT))
            var err = ObjCObject(0)
            let reply = Obj["NSAppleEventDescriptor"](
                ev.addr()
            ).sendEventWithOptions_timeout_error(
                UInt64(0x00000003),
                Float64(5.0),
                Pointer(to=err).unsafe_bitcast[P]()[],
            )
            if reply.addr() == 0:
                print("roast: agent self-test FAILED (no reply)")
                return False
            let back = Obj["NSAppleEventDescriptor"](
                reply.addr()
            ).paramDescriptorForKeyword(UInt32(AE_DIRECT))
            if back.addr() == 0:
                print("roast: agent self-test FAILED (reply had no parameter)")
                return False
            let got = ns_to_string(
                Obj["NSAppleEventDescriptor"](back.addr()).stringValue()
            )
            if got.find("commands:") < 0:
                print("roast: agent self-test FAILED (reply was:", got, ")")
                return False
            print("roast: agent self-test OK, round trip through Rost/cmnd")
            return True
    except:
        print("roast: agent self-test FAILED (raised)")
        return False


def main() raises:
    # AppKit is not linked into a JIT process; without this NSApplication is nil
    # and the app exits silently having drawn nothing.
    if not load_framework["AppKit"]():
        print("roast: FATAL — could not load AppKit")
        return

    # Before anything else reads a root: the language server, the Examples
    # menu and the first build all resolve paths at startup, and every one
    # of them must see the user-space copy or the seams show -- the server
    # indexing the sealed bundle while builds compile the editable copy is
    # exactly the split this exists to prevent.
    _ = migrate_user_space()

    let env = getenv("ROAST_AUTOCLOSE_TICKS")
    if env != "":
        g_autoclose()[] = Int(env)

    with autoreleasepool():
        let NSApplication = ObjCClass.lookup["NSApplication"]()
        let app = Cls["NSApplication"]().sharedApplication()
        # Regular -- a Dock icon and a menu bar, like any Mac app -- unless
        # this is an unattended run. A harness launch is still a real GUI
        # process on a real desktop, so as a Regular app it took the screen
        # from whoever was working: window in front, focus stolen, tabs
        # opening and closing under their hands. Indistinguishable from the
        # editor doing it by itself, and impossible to argue with while it is
        # happening. Accessory (1) gives the same window and the same
        # AppKit behaviour with no Dock icon and no claim on the front.
        let headless = g_autoclose()[] != 0
        _ = Obj["NSApplication"](app.addr()).setActivationPolicy(
            Int(1) if headless else Int(0)
        )

        # Delegate.
        # Instantiating a class registers it, so both of these exist in the
        # runtime by the time AppKit is handed them.
        let delegate = ObjCObject(RoastAppDelegate().__objc_id)
        Obj["NSApplication"](app.addr()).setDelegate(delegate.ptr())

        let actions = ObjCObject(RoastActions().__objc_id)
        g_actions()[] = actions.addr()

        build_menu_bar(app, actions.addr())

        # Window. Titled|Closable|Miniaturizable|Resizable = 15.
        let NSWindow = ObjCClass.lookup["NSWindow"]()
        var win = Cls["NSWindow"]().alloc()
        # Start at a readable fraction of the main screen instead of a frame
        # typed into the source, which is wrong on every display but one.
        let NSScreen = ObjCClass.lookup["NSScreen"]()
        let screen = Cls["NSScreen"]().mainScreen()
        var vis = rect(0.0, 0.0, 1440.0, 900.0)
        if screen.addr() != 0:
            vis = Obj["NSScreen"](screen.addr()).visibleFrame()
        let init_w = min(1400.0, vis.size.width * 0.78)
        let init_h = min(900.0, vis.size.height * 0.84)
        win = Obj["NSWindow"](win.addr()).initWithContentRect_styleMask_backing_defer(
            rect(0.0, 0.0, init_w, init_h),
            Int(15),
            Int(2),
            Bool(False),
        )
        # Below which the layout stops meaning anything.
        Obj["NSWindow"](win.addr()).setMinSize(CGSize(640.0, 400.0))
        Obj["NSWindow"](win.addr()).setTitle(nsstring(String("Roast")).ptr())
        # Native tabbing: windows sharing an identifier tab together, and the
        # Window menu gets the tab commands automatically.
        Obj["NSWindow"](win.addr()).setTabbingIdentifier(
            nsstring(String("roast.editor")).ptr()
        )
        Obj["NSWindow"](win.addr()).setTabbingMode(Int(0))
        # Remember where the user put it. AppKit restores the saved frame
        # here if there is one, so centring only applies to a first run.
        let restored = Obj["NSWindow"](win.addr()).setFrameUsingName(
            nsstring(String("roast.main")).ptr()
        )
        if not restored:
            Obj["NSWindow"](win.addr()).center()
        _ = Obj["NSWindow"](win.addr()).setFrameAutosaveName(
            nsstring(String("roast.main")).ptr()
        )
        g_window()[] = win.addr()

        let content = Obj["NSWindow"](win.addr()).contentView()

        # Toolbar FIRST, because installing one changes the content view's
        # height -- by 32 points on this system, measured, not assumed. Every
        # frame below is computed from `h`, so reading it before the toolbar
        # existed laid the whole window out against a height the content view
        # never had: the tab strip sat 32 points below the top of the content
        # and the gap between it and the toolbar was the error, made visible.
        let NSToolbar = ObjCClass.lookup["NSToolbar"]()
        var toolbar = Cls["NSToolbar"]().alloc()
        toolbar = Obj["NSToolbar"](toolbar.addr()).initWithIdentifier(
            nsstring(String("roast.toolbar")).ptr()
        )
        Obj["NSToolbar"](toolbar.addr()).setDelegate(actions.ptr())
        # Icon-only, which is what Xcode, Finder and Safari ship: labels on
        # eleven items overflow a modest window into the >> chevron -- and
        # the first thing the chevron swallowed was Find. Tooltips carry
        # the names.
        Obj["NSToolbar"](toolbar.addr()).setDisplayMode(Int(2))
        Obj["NSWindow"](win.addr()).setToolbar(toolbar.ptr())

        let bounds = Obj["NSView"](content.addr()).bounds()
        let w = bounds.size.width
        let h = bounds.size.height

        # Status bar: a label pinned to the bottom, and a hairline above it.
        comptime STATUS_H = 22.0
        let NSTextField = ObjCClass.lookup["NSTextField"]()
        let status = Cls["NSTextField"]().labelWithString(
            nsstring(String("Ready")).ptr()
        )
        Obj["NSView"](status.addr()).setFrame(
            rect(10.0, 3.0, w - 150.0, STATUS_H - 6.0)
        )
        # Width-resizable, pinned to the bottom. Secondary, because the
        # status line is chrome: it informs, it does not compete with code.
        Obj["NSView"](status.addr()).setAutoresizingMask(Int(2))
        Obj["NSTextField"](status.addr()).setTextColor(
            Cls["NSColor"]().secondaryLabelColor().ptr()
        )
        Obj["NSView"](content.addr()).addSubview(status.ptr())
        g_status()[] = status.addr()

        # The hairline the comment above always promised. Without it the
        # status text reads as a stray caption floating under the editor.
        let NSBox = ObjCClass.lookup["NSBox"]()
        var hairline = Cls["NSBox"]().alloc()
        hairline = Obj["NSBox"](hairline.addr()).initWithFrame(
            rect(0.0, STATUS_H, w, 1.0)
        )
        Obj["NSBox"](hairline.addr()).setBoxType(Int(2))
        Obj["NSView"](hairline.addr()).setAutoresizingMask(Int(2))
        Obj["NSView"](content.addr()).addSubview(hairline.ptr())

        # Ln/Col at the right edge, where every editor keeps it. The grid
        # owns the caret, so the field is handed over and kept true there.
        let lncol = Cls["NSTextField"]().labelWithString(
            nsstring(String("")).ptr()
        )
        Obj["NSView"](lncol.addr()).setFrame(
            rect(w - 130.0, 3.0, 100.0, STATUS_H - 6.0)
        )
        # Pinned to the bottom-right corner.
        Obj["NSView"](lncol.addr()).setAutoresizingMask(Int(1))
        Obj["NSTextField"](lncol.addr()).setTextColor(
            Cls["NSColor"]().secondaryLabelColor().ptr()
        )
        Obj["NSTextField"](lncol.addr()).setAlignment(Int(2))
        Obj["NSView"](content.addr()).addSubview(lncol.ptr())
        _ = external_call["objc_retain", P](lncol.ptr())
        set_lncol_field(lncol.addr())

        # The compiler-is-running spinner, sitting just left of the status
        # text. Small, indeterminate, and hidden whenever it is stopped --
        # so idle costs nothing and nobody asks what a frozen spinner means.
        let NSProgressIndicator = ObjCClass.lookup["NSProgressIndicator"]()
        var spin = Cls["NSProgressIndicator"]().alloc()
        spin = Obj["NSProgressIndicator"](spin.addr()).initWithFrame(
            rect(w - 26.0, 3.0, 16.0, 16.0)
        )
        Obj["NSProgressIndicator"](spin.addr()).setStyle(Int(1))
        Obj["NSProgressIndicator"](spin.addr()).setIndeterminate(True)
        Obj["NSProgressIndicator"](spin.addr()).setControlSize(Int(1))
        Obj["NSProgressIndicator"](spin.addr()).setDisplayedWhenStopped(False)
        # Pinned to the bottom-right corner.
        Obj["NSView"](spin.addr()).setAutoresizingMask(Int(1))
        Obj["NSView"](content.addr()).addSubview(spin.ptr())
        _ = external_call["objc_retain", P](spin.ptr())
        g_spinner()[] = spin.addr()

        # Split view: sidebar on the left, editor area on the right.
        let NSSplitView = ObjCClass.lookup["NSSplitView"]()
        var split = Cls["NSSplitView"]().alloc()
        split = Obj["NSSplitView"](split.addr()).initWithFrame(
            rect(0.0, STATUS_H, w, h - STATUS_H - TAB_H)
        )
        Obj["NSSplitView"](split.addr()).setVertical(True)
        # Thin divider, the source-list look.
        Obj["NSSplitView"](split.addr()).setDividerStyle(Int(2))
        Obj["NSView"](split.addr()).setAutoresizingMask(Int(18))
        Obj["NSView"](content.addr()).addSubview(split.ptr())

        # Sidebar: a scrolling outline view. Milestone 1 gives it a data source
        # over a real project tree; for now it is the shape, not the content.
        let NSScrollView = ObjCClass.lookup["NSScrollView"]()
        var side_scroll = Cls["NSScrollView"]().alloc()
        side_scroll = Obj["NSScrollView"](side_scroll.addr()).initWithFrame(
            rect(0.0, 0.0, 240.0, h - STATUS_H - TAB_H)
        )
        Obj["NSScrollView"](side_scroll.addr()).setHasVerticalScroller(True)
        let NSOutlineView = ObjCClass.lookup["NSOutlineView"]()
        var outline = Cls["NSOutlineView"]().alloc()
        outline = Obj["NSOutlineView"](outline.addr()).initWithFrame(
            rect(0.0, 0.0, 240.0, h - STATUS_H - TAB_H)
        )
        # Source-list styling: SidebarStyle = 1 on modern AppKit.
        Obj["NSTableView"](outline.addr()).setStyle(Int(1))
        # A column, or the view has nowhere to draw. One column, no header:
        # this is a file list, not a table.
        let NSTableColumn = ObjCClass.lookup["NSTableColumn"]()
        var column = Cls["NSTableColumn"]().alloc()
        column = Obj["NSTableColumn"](column.addr()).initWithIdentifier(
            nsstring(String("name")).ptr()
        )
        Obj["NSTableColumn"](column.addr()).setWidth(Float64(220.0))
        # A column made in code has no data cell, and a cell-based table view
        # dereferences it on the first draw -- the crash is inside
        # -[NSTableView preparedCellAtColumn:row:], a long way from the column
        # that lacks one. The view is cell-based because the delegate does not
        # implement outlineView:viewForTableColumn:item:, which is what AppKit
        # looks for to decide.
        let NSTextFieldCell = ObjCClass.lookup["NSTextFieldCell"]()
        var cell = Cls["NSTextFieldCell"]().alloc()
        cell = Obj["NSTextFieldCell"](cell.addr()).initTextCell(
            nsstring(String("")).ptr()
        )
        Obj["NSCell"](cell.addr()).setEditable(False)
        Obj["NSTableColumn"](column.addr()).setDataCell(cell.ptr())
        Obj["NSTableView"](outline.addr()).addTableColumn(column.ptr())
        Obj["NSOutlineView"](outline.addr()).setOutlineTableColumn(column.ptr())
        Obj["NSTableView"](outline.addr()).setHeaderView(ObjCObject(0).ptr())
        Obj["NSOutlineView"](outline.addr()).setDataSource(actions.ptr())
        Obj["NSOutlineView"](outline.addr()).setDelegate(actions.ptr())
        Obj["NSTableView"](outline.addr()).setRowHeight(Float64(20.0))
        g_outline()[] = outline.addr()
        g_side_scroll()[] = side_scroll.addr()
        Obj["NSScrollView"](side_scroll.addr()).setDocumentView(outline.ptr())
        apply_sidebar_theme()
        Obj["NSSplitView"](split.addr()).addSubview(side_scroll.ptr())

        # Editor area: an empty scroll view where GridView lands in milestone 1.
        var edit_scroll = Cls["NSScrollView"]().alloc()
        edit_scroll = Obj["NSScrollView"](edit_scroll.addr()).initWithFrame(
            rect(240.0, 0.0, w - 240.0, h - STATUS_H - TAB_H)
        )
        Obj["NSScrollView"](edit_scroll.addr()).setHasVerticalScroller(True)
        Obj["NSScrollView"](edit_scroll.addr()).setHasHorizontalScroller(True)

        # The editor surface. Load something real: with no file to open yet,
        # Roast shows its own source, which is the shortest path to seeing the
        # rope, the gutter and the scrolling all work on a genuine file.
        # A folder to open on the way up, so `ROAST_PROJECT=examples/fern`
        # starts in a project rather than needing the panel every time.
        let proj = getenv("ROAST_PROJECT")
        if proj != "":
            open_folder(proj)

        var text: String
        let path = getenv("ROAST_OPEN")
        if path != "":
            try:
                with open(path, "r") as f:
                    text = f.read()
            except:
                text = String("could not read ") + path
        else:
            # An empty untitled document, which is what every other editor
            # opens with. It used to be a page of milestone notes and
            # benchmark figures -- useful to whoever was building the thing,
            # and to nobody who wants to start typing.
            text = String()
        # Through the same door as every other open, so there is exactly one
        # way a document comes into being. Setting the rope directly here is
        # what left the tab bar with nothing to draw.
        _ = document.open_document(
            String("file://") + path if path != "" else String(""),
            Rope(text^),
        )

        let grid = make_grid_view(
            rect(0.0, 0.0, w - 240.0, h - STATUS_H - TAB_H)
        )
        let doc = document_size(w - 240.0)
        Obj["NSView"](grid.addr()).setFrameSize(doc)
        Obj["NSScrollView"](edit_scroll.addr()).setDocumentView(grid.ptr())
        # A text editor scrolls its own way: no elastic bounce past the ends.
        Obj["NSScrollView"](edit_scroll.addr()).setVerticalScrollElasticity(
            Int(1)
        )
        # `make_grid_view` already parked this: the view's own accessors read
        # it to find their box, so it cannot wait until here.

        # The editor and the console share the right-hand side, stacked. A
        # nested split rather than a view that gets resized by hand: the
        # divider is then draggable, which is what anyone will try first.
        var vsplit = Cls["NSSplitView"]().alloc()
        vsplit = Obj["NSSplitView"](vsplit.addr()).initWithFrame(
            rect(240.0, 0.0, w - 240.0, h - STATUS_H - TAB_H)
        )
        Obj["NSSplitView"](vsplit.addr()).setVertical(False)
        Obj["NSSplitView"](vsplit.addr()).setDividerStyle(Int(2))
        Obj["NSSplitView"](vsplit.addr()).addSubview(edit_scroll.ptr())

        # The console: a plain text view, the editor's face, not editable.
        var out_scroll = Cls["NSScrollView"]().alloc()
        out_scroll = Obj["NSScrollView"](out_scroll.addr()).initWithFrame(
            rect(0.0, 0.0, w - 240.0, 160.0)
        )
        Obj["NSScrollView"](out_scroll.addr()).setHasVerticalScroller(True)
        let NSTextView = ObjCClass.lookup["NSTextView"]()
        var console = Cls["NSTextView"]().alloc()
        console = Obj["NSTextView"](console.addr()).initWithFrame(
            rect(0.0, 0.0, w - 240.0, 160.0)
        )
        Obj["NSTextView"](console.addr()).setEditable(False)
        Obj["NSTextView"](console.addr()).setRichText(False)
        Obj["NSTextView"](console.addr()).setFont(
            Cls["NSFont"]().monospacedSystemFontOfSize_weight(Float64(11.0), Float64(0.0)).ptr(),
        )
        Obj["NSTextView"](console.addr()).setString(nsstring(
                String("Build ⌘B · Run ⌘R · Stop ⌘. · this pane ⌘0\n")
            ).ptr())
        Obj["NSScrollView"](out_scroll.addr()).setDocumentView(console.ptr())
        _ = external_call["objc_retain", P](console.ptr())
        g_console()[] = console.addr()

        Obj["NSSplitView"](vsplit.addr()).addSubview(out_scroll.ptr())
        _ = external_call["objc_retain", P](vsplit.ptr())
        g_vsplit()[] = vsplit.addr()

        _ = external_call["objc_retain", P](split.ptr())
        g_hsplit()[] = split.addr()
        Obj["NSSplitView"](split.addr()).addSubview(vsplit.ptr())
        # Closed until something is built. The editor is what the window is
        # for; an empty console taking a third of it is a worse first sight.
        show_console(False)
        # Added to the window's content view, above the split, so it spans the
        # editor pane and stays put while the editor scrolls.
        # Already allocated and initialised, so the frame is set rather than
        # passed to initWithFrame:.
        var realtabs = ObjCObject(RoastTabBar().__objc_id)
        Obj["NSView"](realtabs.addr()).setFrame(
            rect(240.0, h - TAB_H, w - 240.0, TAB_H)
        )
        Obj["NSView"](realtabs.addr()).setAutoresizingMask(Int(2 | 8))
        Obj["NSView"](content.addr()).addSubview(realtabs.ptr())
        g_tabbar()[] = realtabs.addr()

        # The tab labels' attribute dictionaries live on RoastTabBar itself
        # now -- fields, built lazily on first draw. Nothing to set up here.

        # A tick, only so the autoclose path exists for CI.
        let NSTimer = ObjCClass.lookup["NSTimer"]()
        _ = Cls["NSTimer"]().scheduledTimerWithTimeInterval_target_selector_userInfo_repeats(
            Float64(0.1),
            actions.ptr(),
            sel["timerTick:"]().ptr(),
            actions.ptr(),
            Bool(True),
        )

        # The language server, from the distribution beside us. An editor
        # built by this toolchain should ask this toolchain's server rather
        # than whichever one is on PATH.
        if lsp_server_path() == "":
            print("roast: no language server (set ROAST_LSP or COCOAMOJO_ROOT)")
        elif start_lsp():
            print("roast: language server started at", lsp_root())

        # A project, if one was named. ROAST_PROJECT is a folder; use the
        # sandbox rather than the source tree, which tools/roast-sandbox.sh
        # exists to make.
        let project = getenv("ROAST_PROJECT")
        if project != "":
            open_folder(project)

        # Headless doors for the two state-changing Python paths. They drive
        # the same functions as the menu: package checks can prove venv -> pip
        # sequencing without attempting to automate a modal NSAlert.
        let python_install = getenv("ROAST_PYTHON_INSTALL")
        if python_install != "":
            print("roast: Python install asked:", python_install)
            _install_python_requirement(python_install^)
        elif getenv("ROAST_PYTHON_CREATE") != "":
            print("roast: Python environment asked for", _python_project())
            _ = _start_python_environment()

        # The same thing the Examples menu does, reachable without a click.
        # This shipped opening one file of three because nothing could test
        # it; now something can.
        let example = getenv("ROAST_EXAMPLE")
        if example != "":
            # The count of files the EXAMPLE contributed, not the tab total:
            # the scratch buffer the editor starts with is still there, and
            # opening an example should not close what someone already had.
            print(
                "roast: example files:",
                open_example_project(
                    example, example + String("/main.mojo")
                ),
            )

        # Last session, if nothing more specific was asked for. Anything
        # named on the way in -- a project, an example, a file -- is a
        # statement about what to look at NOW, and beats a memory of what was
        # open before; so this runs only when none of them said anything.
        # ROAST_OPEN is checked too, though it is handled far above: it puts
        # its file in the first tab before the window exists.
        session.load()
        if (
            session_enabled()
            and getenv("ROAST_PROJECT") == ""
            and getenv("ROAST_EXAMPLE") == ""
            and getenv("ROAST_EXAMPLE_MENU") == ""
            and getenv("ROAST_OPEN_FILE") == ""
            and getenv("ROAST_OPEN") == ""
        ):
            let back = restore_session()
            if back > 0:
                print(
                    "roast: restored",
                    back,
                    "tabs from the last session, showing",
                    document.name_at(document.current_index()),
                )
                set_status(
                    String("Restored ") + String(back) + String(" files")
                )

        # Rename, reachable without a prompt: line:col:newname. The alert
        # needs a hand on the keyboard, so the door skips it and calls the
        # request directly -- what is worth checking is the WorkspaceEdit
        # coming back and being applied, not that an NSAlert can be typed in.
        let ren = getenv("ROAST_RENAME")
        if ren != "":
            let c1 = ren.find(":")
            if c1 > 0:
                let rest = String(ren[byte = c1 + 1 : ren.byte_length()])
                let c2 = rest.find(":")
                if c2 > 0:
                    g_probe_line()[] = Int(String(ren[byte=:c1]))
                    g_probe_col()[] = Int(String(rest[byte=:c2]))
                    _put_rename_name(
                        String(rest[byte = c2 + 1 : rest.byte_length()])
                    )
                    g_probe_kind()[] = 3
                    print("roast: rename asked at", ren)

        # Find-all-references and signature help, reachable without a
        # mouse. Same line:col shape as ROAST_DEFINE, and the same wait for
        # the server to have the document.
        let refs_at = getenv("ROAST_REFS")
        if refs_at != "":
            let rcut = refs_at.find(":")
            if rcut > 0:
                g_probe_line()[] = Int(String(refs_at[byte=:rcut]))
                g_probe_col()[] = Int(
                    String(refs_at[byte = rcut + 1 : refs_at.byte_length()])
                )
                g_probe_kind()[] = 1
                print("roast: references asked at", refs_at)
        let sig_at = getenv("ROAST_SIGNATURE")
        if sig_at != "":
            let scut = sig_at.find(":")
            if scut > 0:
                g_probe_line()[] = Int(String(sig_at[byte=:scut]))
                g_probe_col()[] = Int(
                    String(sig_at[byte = scut + 1 : sig_at.byte_length()])
                )
                g_probe_kind()[] = 2
                print("roast: signature asked at", sig_at)

        # Go to definition, reachable without a mouse. ROAST_DEFINE is
        # line:col in the entry point, one-based as an editor counts; the
        # caret goes there and the request is made a few ticks later, once
        # the server has had the document.
        let define_at = getenv("ROAST_DEFINE")
        if define_at != "":
            let cut = define_at.find(":")
            if cut > 0:
                g_define_line()[] = Int(String(define_at[byte=:cut]))
                g_define_col()[] = Int(
                    String(define_at[byte = cut + 1 : define_at.byte_length()])
                )
                print("roast: definition asked at", define_at)

        # Debugging, reachable without a mouse: set a breakpoint at
        # ROAST_DEBUG_LINE in the project's entry point and press Debug. The
        # whole path runs -- build with debug info, launch the adapter, bind,
        # stop, follow -- so the check covers what someone actually does
        # rather than the pieces separately.
        let dbg_line = getenv("ROAST_DEBUG_LINE")
        if dbg_line != "":
            let entry = build.entry_point(project_root(), String())
            if entry != "":
                _ = dap.toggle_breakpoint(entry, Int(dbg_line))
                print(
                    "roast: debug breakpoint at",
                    _basename(entry) + String(":") + dbg_line,
                )
                _start_debug()
            else:
                print("roast: debug: no entry point")

        # What the Finder does when a .mojo is double-clicked, reachable
        # without one: the delegate method itself, not a reimplementation of
        # it, so the check covers the path AppKit actually takes.
        let dropped = getenv("ROAST_OPEN_FILE")
        if dropped != "":
            # Two halves, because they fail apart. Whether AppKit can FIND
            # the method is selector derivation -- application_openFile_ has
            # to have become `application:openFile:` -- and respondsToSelector
            # is the same question AppKit asks before it sends. Whether the
            # method WORKS is open_path, called here directly. (Sending the
            # message would cover both, but `send` derives its argument
            # classes from the SDK and the database carries class selectors,
            # not protocol ones: "the Cocoa metadata has no
            # selector_arg_classes for application:openFile:".)
            print(
                "roast: openFile responds:",
                msg_send[Bool, "NSObject", "respondsToSelector:"](
                    delegate, sel["application:openFile:"]().ptr()
                ),
                msg_send[Bool, "NSObject", "respondsToSelector:"](
                    delegate, sel["application:openFiles:"]().ptr()
                ),
            )
            print("roast: openFile:", open_path(dropped))

        # The same thing again, through the menu item rather than around it.
        # Comma-separated, because picking a second example is a different
        # thing from picking a first one: the tree cache, the project root and
        # the language server all have to let go of the previous project.
        let clicked = getenv("ROAST_EXAMPLE_MENU")
        if clicked != "":
            let names = clicked.split(",")
            var k = 0
            while k < len(names):
                let name = String(names[k])
                let hit = fire_example_menu(app, name)
                print(
                    "roast: example menu:",
                    name,
                    hit,
                    "rows",
                    outline_rows(),
                    "tabs",
                    document.count(),
                )
                k += 1

        _ = Obj["NSWindow"](win.addr()).makeFirstResponder(grid.ptr())
        Obj["NSWindow"](win.addr()).makeKeyAndOrderFront(win.ptr())
        if not headless:
            Obj["NSApplication"](app.addr()).activateIgnoringOtherApps(True)
        var what = String("untitled")
        if path != "":
            what = path
        set_status(
            what
            + String("  ·  ")
            + String(g_buffer_lines())
            + String(" lines")
        )

        # Report what AppKit actually thinks it has, so a headless run says
        # whether the shell came up rather than leaving it to a screenshot.
        let visible = Obj["NSWindow"](win.addr()).isVisible()
        let frame = Obj["NSWindow"](win.addr()).frame()
        let tb = Obj["NSWindow"](win.addr()).toolbar()
        let subviews = Obj["NSView"](split.addr()).subviews()
        let n_split = Obj["NSArray"](subviews.addr()).count()
        let menu = Obj["NSApplication"](app.addr()).mainMenu()
        let n_menus = Obj["NSMenu"](menu.addr()).numberOfItems()
        print("roast: window visible:", visible)
        print(
            "roast: frame:",
            frame.size.width,
            "x",
            frame.size.height,
            "at",
            frame.origin.x,
            frame.origin.y,
        )
        print("roast: toolbar:", tb.addr() != 0)
        print("roast: tabs:", document.count())
        # What the sidebar is actually showing. The outline had no reporting
        # at all, which is how "the example opened one file" survived a green
        # suite: the tab bar was checked and the file list was not.
        print("roast: project:", project_root())
        print("roast: project rows:", outline_rows())
        # The strip has to sit flush under the toolbar. Installing a toolbar
        # changes the content view's height, so laying out against the height
        # read before it existed leaves a band of window background above the
        # tabs -- visible, and easy to reintroduce. Report the distance so a
        # regression is a failed check rather than something someone notices.
        if g_tabbar()[] != 0:
            let strip = Obj["NSView"](ObjCObject(g_tabbar()[]).addr()).frame()
            let ch = Obj["NSView"](Obj["NSWindow"](win.addr()).contentView().addr()).bounds().size.height
            print("roast: tab gap:", ch - (strip.origin.y + strip.size.height))
        # The items come from the factory method on RoastActions -- a count of
        # zero means identifiers registered but the factory never produced.
        print(
            "roast: toolbar items:",
            Obj["NSArray"](Obj["NSToolbar"](tb.addr()).items().addr()).count(),
        )
        print("roast: split panes:", n_split)
        let n_vsplit = Obj["NSArray"](Obj["NSView"](ObjCObject(g_vsplit()[]).addr()).subviews().addr()).count()
        let vsubs = Obj["NSView"](ObjCObject(g_vsplit()[]).addr()).subviews()
        print(
            "roast: editor panes:",
            n_vsplit,
            "heights",
            Obj["NSView"](Obj["NSArray"](vsubs.addr()).objectAtIndex(0).addr()).frame().size.height,
            Obj["NSView"](Obj["NSArray"](vsubs.addr()).objectAtIndex(1).addr()).frame().size.height,
        )
        print("roast: entry point:", build.entry_point(
            project_root(), document.path_at(document.current_index())
        ))
        print("roast: menu bar items:", n_menus)
        let tc = toolchain_root()
        print("roast: toolchain:", tc if tc != "" else String("(none found)"))
        print("roast: session:", session_path_or_none())
        let gframe = Obj["NSView"](grid.addr()).frame()
        print(
            "roast: document:",
            gframe.size.width,
            "x",
            gframe.size.height,
            "for",
            g_buffer_lines(),
            "lines",
        )

    register_agent_events()
    print("roast: entering [NSApp run]")
    with autoreleasepool():
        let NSApplication2 = ObjCClass.lookup["NSApplication"]()
        let app2 = Cls["NSApplication"]().sharedApplication()
        Obj["NSApplication"](app2.addr()).run()
    print("roast: exited run loop")
