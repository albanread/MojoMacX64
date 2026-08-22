# Step 1: prove an NSWindow can be created and the AppKit event loop pumped
# from Mojo, entirely through std.objc. Headless-safe: it creates the objects,
# pumps a few event cycles, and exits without requiring a visible display.
from std.objc import ObjCClass, ObjCObject, msg_send, autoreleasepool
from std.ffi import external_call
from std.memory import OpaquePointer

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


def main():
    with autoreleasepool():
        # [NSApplication sharedApplication]
        var NSApplication = ObjCClass.lookup["NSApplication"]()
        var app = msg_send[
            ObjCObject, "NSApplication", "sharedApplication", is_class=True
        ](NSApplication.as_object())
        print("NSApp:", not app.is_nil())

        # [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular(0)]
        _ = msg_send[Bool, "NSApplication", "setActivationPolicy:"](app, Int(0))

        # NSWindow alloc + initWithContentRect:styleMask:backing:defer:
        var NSWindow = ObjCClass.lookup["NSWindow"]()
        var win_alloc = msg_send[
            ObjCObject, "NSWindow", "alloc", is_class=True
        ](NSWindow.as_object())
        var frame = CGRect(CGPoint(100.0, 100.0), CGSize(640.0, 480.0))
        # styleMask: Titled(1)|Closable(2)|Miniaturizable(4)|Resizable(8) = 15
        # backing: NSBackingStoreBuffered = 2
        var win = msg_send[
            ObjCObject,
            "NSWindow",
            "initWithContentRect:styleMask:backing:defer:",
        ](win_alloc, frame, Int(15), Int(2), Bool(False))
        print("NSWindow:", not win.is_nil())

        # [win setTitle:@"..."]
        var NSString = ObjCClass.lookup["NSString"]()
        var title_str = String("Mojo Mandelbrot")
        var title = msg_send[
            ObjCObject, "NSString", "stringWithUTF8String:", is_class=True
        ](NSString.as_object(), title_str.as_c_string_slice())
        _ = msg_send[ObjCObject, "NSWindow", "setTitle:"](win, title.ptr())

        # Read the frame back to prove the struct arg landed correctly.
        var back = msg_send[CGRect, "NSWindow", "frame"](win)
        print("window frame:", back.size.width, "x", back.size.height)

        # Pump a few event cycles (headless-safe: distantPast returns immediately).
        var NSDate = ObjCClass.lookup["NSDate"]()
        var past = msg_send[
            ObjCObject, "NSDate", "distantPast", is_class=True
        ](NSDate.as_object())
        var mode_str = String("kCFRunLoopDefaultMode")
        var mode = msg_send[
            ObjCObject, "NSString", "stringWithUTF8String:", is_class=True
        ](NSString.as_object(), mode_str.as_c_string_slice())

        var pumped = 0
        for _ in range(5):
            var ev = msg_send[
                ObjCObject,
                "NSApplication",
                "nextEventMatchingMask:untilDate:inMode:dequeue:",
            ](app, UInt64.MAX, past.ptr(), mode.ptr(), Bool(True))
            if not ev.is_nil():
                _ = msg_send[ObjCObject, "NSApplication", "sendEvent:"](
                    app, ev.ptr()
                )
                pumped += 1
        print("event cycles pumped, events seen:", pumped)

        var ok = not win.is_nil() and back.size.width == 640.0
        print("WINDOW-SMOKE: PASS" if ok else "WINDOW-SMOKE: FAIL")
