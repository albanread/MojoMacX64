# Does a CGRect survive the trampoline? AppKit sends drawRect: with the rect
# by value in v0-v3; the trampoline stores the registers to a local and passes
# the borrow. If any lane is misrouted these numbers come out wrong.
from std.objc import (
    ObjCObject, ObjCClass, msg_send, load_framework, named_global,
    autoreleasepool,
)

comptime g_w = named_global["probe.w", Int]
comptime g_h = named_global["probe.h", Int]
comptime g_x = named_global["probe.x", Int]
comptime g_called = named_global["probe.called", Int]

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


class ProbeView(NSView):
    def drawRect_(self, dirty: CGRect):
        g_called()[] += 1
        g_x()[] = Int(dirty.origin.x)
        g_w()[] = Int(dirty.size.width)
        g_h()[] = Int(dirty.size.height)


def main() raises:
    if not load_framework["AppKit"]():
        raise Error("no AppKit")
    with autoreleasepool():
        let NSWindow = ObjCClass.lookup["NSWindow"]()
        var win = msg_send[ObjCObject, "NSWindow", "alloc", is_class=True](
            NSWindow.as_object()
        )
        win = msg_send[
            ObjCObject, "NSWindow", "initWithContentRect:styleMask:backing:defer:"
        ](win, CGRect(CGPoint(0.0, 0.0), CGSize(321.0, 87.0)), Int(0), Int(2),
          Bool(False))

        var view = ObjCObject(ProbeView().__objc_id)
        _ = msg_send[ObjCObject, "NSView", "setFrame:"](
            view, CGRect(CGPoint(0.0, 0.0), CGSize(321.0, 87.0))
        )
        _ = msg_send[ObjCObject, "NSWindow", "setContentView:"](win, view.ptr())
        # Send drawRect: ourselves -- the same four v-registers AppKit would
        # load, without needing the window on screen. What is under test is
        # the trampoline's register-to-memory materialisation, and a direct
        # send exercises exactly that.
        _ = msg_send[ObjCObject, "NSView", "drawRect:"](
            view, CGRect(CGPoint(7.0, 9.0), CGSize(321.0, 87.0))
        )

    print("drawRect_ called", g_called()[], "time(s)")
    print("dirty rect seen by the method:", g_x()[], g_w()[], "x", g_h()[])
    if g_x()[] == 7 and g_w()[] == 321 and g_h()[] == 87:
        print("rect OK")
    else:
        print("rect FAILED")
