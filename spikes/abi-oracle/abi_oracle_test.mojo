# The ABI oracle: clang on one side, Mojo on the other.
#
# Every other Cocoa test in this tree has Mojo at both ends and proves only
# that we agree with ourselves. This one puts the compiler that built AppKit on
# the far side, so whatever it does with a struct by value IS the ABI.
#
# The x86-64 cases differ from arm64 in kind, not in register names: a struct
# over 16 bytes goes on the stack rather than behind a caller-owned pointer,
# and a struct return over 16 bytes goes through a DIFFERENT ENTRY POINT,
# objc_msgSend_stret, which does not exist on arm64 at all. A binding that is
# correct on Apple silicon can be silently wrong here for that reason alone.
#
# Direction A (below) is Mojo sending to a clang class -- our msg_send variant
# selection. Direction B is clang sending to a Mojo class -- the trampolines,
# which phase 1 adds.

from std.objc import ObjCClass, ObjCObject, send, load_framework
from std.ffi import external_call
from std.memory import OpaquePointer
from std.sys._cocoakb import cocoakb_msgsend_variant

comptime P = OpaquePointer[MutUntrackedOrigin]


@fieldwise_init
struct NSPoint(Copyable, Movable):
    var x: Float64
    var y: Float64


@fieldwise_init
struct NSSize(Copyable, Movable):
    var width: Float64
    var height: Float64


@fieldwise_init
struct NSRect(Copyable, Movable):
    var origin: NSPoint
    var size: NSSize


def main() raises:
    if not load_framework["AppKit"]():
        print("FATAL: could not load AppKit")
        return

    # The oracle is a dylib clang built; dlopen it the same way.
    var h = external_call["dlopen", P](
        StaticString("/tmp/libabioracle.dylib").unsafe_ptr(), Int(2)
    )
    if Int(h) == 0:
        print("FATAL: could not load the oracle dylib")
        return
    # dlopen registered the class with the Objective-C runtime, so it can be
    # found by name -- no symbol from the dylib is needed at link time, which
    # is the point: the Mojo binary knows nothing about the oracle but the
    # runtime does.
    var cls = ObjCClass.lookup["ABIOracle"]()
    if Int(cls.as_object().addr()) == 0:
        print("FATAL: ABIOracle did not register")
        return
    var obj = send[ObjCObject, "alloc"](cls.as_object())
    obj = send[ObjCObject, "init"](obj)
    print("oracle instance:", Int(obj.addr()) != 0)

    # What the database says these should use, before we rely on it.
    print("  setFrameSize: ->", cocoakb_msgsend_variant["NSView", "setFrameSize:"]())
    print("  setFrame:     ->", cocoakb_msgsend_variant["NSView", "setFrame:"]())
    print("  frame         ->", cocoakb_msgsend_variant["NSView", "frame"]())

    var ok = True

    # 16-byte struct argument: two doubles, SSE registers.
    _ = send[NoneType, "setFrameSize:"](obj, NSSize(10.5, 20.5))
    var s1 = send[Float64, "alphaValue"](obj)
    print("  setFrameSize: sum =", s1, "(expect 31.0)")
    ok = ok and s1 == Float64(31.0)

    # 32-byte struct argument: MEMORY class, passed on the stack.
    _ = send[NoneType, "setFrame:"](
        obj, NSRect(NSPoint(1.5, 2.5), NSSize(3.5, 4.5))
    )
    var s2 = send[Float64, "alphaValue"](obj)
    print("  setFrame:     sum =", s2, "(expect 12.0)")
    ok = ok and s2 == Float64(12.0)

    # 32-byte struct RETURN, through objc_msgSend_stret. This is the case
    # arm64 does not have at all, so it is the one most likely to be wrong in a
    # binding ported from there -- and it is correct here.
    var r = send[NSRect, "frame"](obj)
    var s3 = r.origin.x + r.origin.y + r.size.width + r.size.height
    print("  frame         sum =", s3, "(expect 17.0)")
    ok = ok and s3 == Float64(17.0)

    print("ABI-ORACLE-SEND:", "PASS" if ok else "FAIL")
