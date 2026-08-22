# P0 of the Mojo Mac Playground: Cocoa calling Mojo, the real run loop.
#
# A window with a button and a label. The button's action, an NSTimer's tick,
# and the app delegate's lifecycle methods are all Mojo functions, reached by
# Cocoa through classes defined at runtime. The app uses `[NSApp run]` -- the
# real AppKit event loop -- not a hand-pumped one.
#
# Set P0_AUTOCLOSE_TICKS=N to have the timer close the window after N ticks so
# the whole lifecycle (launch -> ticks -> close -> terminate) runs unattended.
from std.objc import (
    ObjCClass,
    ObjCObject,
    msg_send,
    nsstring,
    autoreleasepool,
    ObjCClassBuilder,
    IMP1,
    IMP1Bool,
    new_instance,
    named_global,
    sel,
)
from std.memory import OpaquePointer
from std.os import getenv

comptime P = OpaquePointer[MutUntrackedOrigin]


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


# ── App state reachable from callbacks (they get no closure) ─────────────────
# Each is a named process global: zero until set in main().
comptime clicks = named_global["p0.clicks", Int]
comptime ticks = named_global["p0.ticks", Int]
comptime label_addr = named_global["p0.label", Int]
comptime window_addr = named_global["p0.window", Int]
comptime autoclose = named_global["p0.autoclose", Int]


def set_label(text: String):
    with autoreleasepool():
        var label = ObjCObject(label_addr()[])
        _ = msg_send[ObjCObject, "NSTextField", "setStringValue:"](
            label, nsstring(text).ptr()
        )


# ── Mojo implementations of Cocoa methods ─────────────────────────────────────


def did_finish_launching(self_: P, cmd: P, note: P) abi("C"):
    print("delegate: applicationDidFinishLaunching: (Cocoa -> Mojo)")


def should_terminate_after_last_window(self_: P, cmd: P, app: P) abi("C") -> Bool:
    # Closing the window ends the app: this is what makes [NSApp run] finish.
    return True


def will_terminate(self_: P, cmd: P, note: P) abi("C"):
    print(
        "delegate: applicationWillTerminate: after",
        ticks()[],
        "ticks and",
        clicks()[],
        "clicks",
    )
    print("P0-WINDOW: PASS" if ticks()[] > 0 else "P0-WINDOW: FAIL")


def button_clicked(self_: P, cmd: P, sender: P) abi("C"):
    clicks()[] += 1
    print("action: buttonClicked: (Cocoa -> Mojo), clicks =", clicks()[])
    set_label(String("Clicked ") + String(clicks()[]) + " times")


def timer_tick(self_: P, cmd: P, timer: P) abi("C"):
    ticks()[] += 1
    set_label(
        String("ticks: ")
        + String(ticks()[])
        + "   clicks: "
        + String(clicks()[])
    )
    var limit = autoclose()[]
    if limit > 0 and ticks()[] >= limit:
        print("timer: autoclosing after", ticks()[], "ticks")
        var win = ObjCObject(window_addr()[])
        _ = msg_send[ObjCObject, "NSWindow", "performClose:"](win, win.ptr())


def main() raises:
    var env = getenv("P0_AUTOCLOSE_TICKS")
    if env != "":
        autoclose()[] = Int(env)

    with autoreleasepool():
        var NSApplication = ObjCClass.lookup["NSApplication"]()
        var app = msg_send[
            ObjCObject, "NSApplication", "sharedApplication", is_class=True
        ](NSApplication.as_object())
        _ = msg_send[Bool, "NSApplication", "setActivationPolicy:"](app, Int(0))

        # The app delegate: three lifecycle methods, encodings from the SDK.
        var db = ObjCClassBuilder("PlaygroundAppDelegate")
        db.add_method["applicationDidFinishLaunching:"](did_finish_launching)
        db.add_method["applicationShouldTerminateAfterLastWindowClosed:"](
            should_terminate_after_last_window
        )
        db.add_method["applicationWillTerminate:"](will_terminate)
        var delegate = new_instance(db^.register())
        _ = msg_send[ObjCObject, "NSApplication", "setDelegate:"](
            app, delegate.ptr()
        )

        # The action target: custom selectors, so encodings are given.
        var ab = ObjCClassBuilder("PlaygroundActions")
        ab.add_method["buttonClicked:", encoding="v@:@"](button_clicked)
        ab.add_method["timerTick:", encoding="v@:@"](timer_tick)
        var actions = new_instance(ab^.register())

        # Window.
        var NSWindow = ObjCClass.lookup["NSWindow"]()
        var win = msg_send[ObjCObject, "NSWindow", "alloc", is_class=True](
            NSWindow.as_object()
        )
        win = msg_send[
            ObjCObject,
            "NSWindow",
            "initWithContentRect:styleMask:backing:defer:",
        ](
            win,
            CGRect(CGPoint(200.0, 200.0), CGSize(420.0, 160.0)),
            Int(15),
            Int(2),
            Bool(False),
        )
        _ = msg_send[ObjCObject, "NSWindow", "setTitle:"](
            win, nsstring(String("Mojo Mac Playground — P0")).ptr()
        )
        window_addr()[] = win.addr()
        var content = msg_send[ObjCObject, "NSWindow", "contentView"](win)

        # Label + button (AppKit's convenience constructors).
        var NSTextField = ObjCClass.lookup["NSTextField"]()
        var label = msg_send[
            ObjCObject, "NSTextField", "labelWithString:", is_class=True
        ](NSTextField.as_object(), nsstring(String("waiting…")).ptr())
        _ = msg_send[ObjCObject, "NSView", "setFrame:"](
            label, CGRect(CGPoint(20.0, 100.0), CGSize(380.0, 24.0))
        )
        label_addr()[] = label.addr()
        _ = msg_send[ObjCObject, "NSView", "addSubview:"](content, label.ptr())

        var NSButton = ObjCClass.lookup["NSButton"]()
        var button = msg_send[
            ObjCObject,
            "NSButton",
            "buttonWithTitle:target:action:",
            is_class=True,
        ](
            NSButton.as_object(),
            nsstring(String("Click me (Mojo)")).ptr(),
            actions.ptr(),
            sel["buttonClicked:"]().ptr(),
        )
        _ = msg_send[ObjCObject, "NSView", "setFrame:"](
            button, CGRect(CGPoint(20.0, 40.0), CGSize(180.0, 32.0))
        )
        _ = msg_send[ObjCObject, "NSView", "addSubview:"](content, button.ptr())

        # A repeating timer whose tick is a Mojo method.
        var NSTimer = ObjCClass.lookup["NSTimer"]()
        _ = msg_send[
            ObjCObject,
            "NSTimer",
            "scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:",
            is_class=True,
        ](
            NSTimer.as_object(),
            Float64(0.1),
            actions.ptr(),
            sel["timerTick:"]().ptr(),
            actions.ptr(),
            Bool(True),
        )

        _ = msg_send[ObjCObject, "NSWindow", "makeKeyAndOrderFront:"](
            win, app.ptr()
        )
        _ = msg_send[
            ObjCObject, "NSApplication", "activateIgnoringOtherApps:"
        ](app, Bool(True))

    print("entering [NSApp run]")
    var app2 = msg_send[
        ObjCObject, "NSApplication", "sharedApplication", is_class=True
    ](ObjCClass.lookup["NSApplication"]().as_object())
    _ = msg_send[ObjCObject, "NSApplication", "run"](app2)
    # Not reached: -terminate: exits the process after applicationWillTerminate:.
