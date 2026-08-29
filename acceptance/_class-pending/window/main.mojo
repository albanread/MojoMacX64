# A Cocoa window, in Mojo. The button's action is a method on a `class` -- an
# Objective-C class the compiler declares, registers and instantiates. No
# Objective-C, no bridging header, and nothing written by hand about selectors
# or type encodings.
from std.objc import (
    load_framework,
    ObjCClass,
    ObjCObject,
    msg_send,
    nsstring,
    autoreleasepool,
    named_global,
    sel,
)

comptime clicks = named_global["example.clicks", Int]
comptime label_addr = named_global["example.label", Int]


@fieldwise_init
struct CGPoint(ImplicitlyCopyable, Movable):
    var x: Float64
    var y: Float64


@fieldwise_init
struct CGSize(ImplicitlyCopyable, Movable):
    var width: Float64
    var height: Float64


@fieldwise_init
struct CGRect(ImplicitlyCopyable, Movable):
    var origin: CGPoint
    var size: CGSize


class ExampleActions:
    """The button's target.

    `buttonClicked_` becomes the selector `buttonClicked:` -- an underscore is
    a colon -- and the compiler derives its `v@:@` encoding, because this is a
    selector we invented rather than one the SDK declares. There is no `_cmd`
    argument to write and no IMP to register: `ExampleActions()` builds the
    class in the runtime and hands back an instance.

    The body may raise; the boundary catches. That is why there is no `try`
    wrapped around a method that plainly cannot fail.
    """

    def buttonClicked_(self, sender: ObjCObject):
        clicks()[] += 1
        with autoreleasepool():
            _ = msg_send[ObjCObject, "NSTextField", "setStringValue:"](
                ObjCObject(label_addr()[]),
                nsstring(String("clicked ") + String(clicks()[])).ptr(),
            )


def main() raises:
    # AppKit is not linked into a JIT process; without this NSApplication is
    # nil and the app exits having drawn nothing.
    if not load_framework["AppKit"]():
        raise Error("could not load AppKit")

    with autoreleasepool():
        let NSApplication = ObjCClass.lookup["NSApplication"]()
        let app = msg_send[
            ObjCObject, "NSApplication", "sharedApplication", is_class=True
        ](NSApplication.as_object())
        _ = msg_send[Bool, "NSApplication", "setActivationPolicy:"](app, Int(0))

        let actions = ObjCObject(ExampleActions().__objc_id)

        let NSWindow = ObjCClass.lookup["NSWindow"]()
        var win = msg_send[ObjCObject, "NSWindow", "alloc", is_class=True](
            NSWindow.as_object()
        )
        win = msg_send[
            ObjCObject,
            "NSWindow",
            "initWithContentRect:styleMask:backing:defer:",
        ](
            win,
            CGRect(CGPoint(240.0, 240.0), CGSize(360.0, 140.0)),
            Int(15),
            Int(2),
            Bool(False),
        )
        _ = msg_send[ObjCObject, "NSWindow", "setTitle:"](
            win, nsstring(String("Mojo")).ptr()
        )
        let content = msg_send[ObjCObject, "NSWindow", "contentView"](win)

        let NSTextField = ObjCClass.lookup["NSTextField"]()
        let label = msg_send[
            ObjCObject, "NSTextField", "labelWithString:", is_class=True
        ](NSTextField.as_object(), nsstring(String("not clicked yet")).ptr())
        _ = msg_send[ObjCObject, "NSView", "setFrame:"](
            label, CGRect(CGPoint(20.0, 84.0), CGSize(320.0, 24.0))
        )
        label_addr()[] = label.addr()
        _ = msg_send[ObjCObject, "NSView", "addSubview:"](content, label.ptr())

        let NSButton = ObjCClass.lookup["NSButton"]()
        let button = msg_send[
            ObjCObject, "NSButton", "buttonWithTitle:target:action:",
            is_class=True,
        ](
            NSButton.as_object(),
            nsstring(String("Click me")).ptr(),
            actions.ptr(),
            sel["buttonClicked:"]().ptr(),
        )
        _ = msg_send[ObjCObject, "NSView", "setFrame:"](
            button, CGRect(CGPoint(20.0, 30.0), CGSize(160.0, 32.0))
        )
        _ = msg_send[ObjCObject, "NSView", "addSubview:"](content, button.ptr())

        _ = msg_send[ObjCObject, "NSWindow", "makeKeyAndOrderFront:"](
            win, win.ptr()
        )
        _ = msg_send[ObjCObject, "NSApplication", "activateIgnoringOtherApps:"](
            app, True
        )

    print("Close the window to quit.")
    with autoreleasepool():
        let NSApplication2 = ObjCClass.lookup["NSApplication"]()
        _ = msg_send[ObjCObject, "NSApplication", "run"](
            msg_send[
                ObjCObject, "NSApplication", "sharedApplication", is_class=True
            ](NSApplication2.as_object())
        )
