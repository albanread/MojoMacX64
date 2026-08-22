# std.objc P4: struct returns and struct arguments through msg_send, dispatched
# by the database. NSRect is 32 bytes -> objc_msgSend_stret on x86-64; the
# programmer never names the stub, and passing/returning the struct is just a
# typed Mojo value.
from std.objc import ObjCClass, ObjCObject, msg_send
from std.sys._cocoakb import cocoakb_struct_size, cocoakb_field_offset
from std.sys import size_of


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
    # Layout is checked against the SDK before any call happens.
    comptime assert size_of[CGRect]() == cocoakb_struct_size["CGRect"]()
    comptime assert cocoakb_field_offset["CGRect", "size"]() == 16

    var NSValue = ObjCClass.lookup["NSValue"]()

    # +[NSValue valueWithRect:] -- a 32-byte struct passed BY VALUE (SysV
    # MEMORY arg, on the stack), returning id. Plain objc_msgSend.
    var r = CGRect(CGPoint(10.0, 20.0), CGSize(30.0, 40.0))
    var v = msg_send[
        ObjCObject, "NSValue", "valueWithRect:", is_class=True
    ](NSValue.as_object(), r)
    print("NSValue created:", not v.is_nil())

    # -[NSValue rectValue] -- a 32-byte struct RETURN. The database routes this
    # to objc_msgSend_stret; the C ABI inserts the hidden sret pointer because
    # the return type is CGRect. No stub named by hand.
    var back = msg_send[CGRect, "NSValue", "rectValue"](v)
    print(
        "rect back:",
        back.origin.x,
        back.origin.y,
        back.size.width,
        back.size.height,
    )

    var ok = (
        back.origin.x == 10.0
        and back.origin.y == 20.0
        and back.size.width == 30.0
        and back.size.height == 40.0
    )
    print("STRET-TEST: PASS" if ok else "STRET-TEST: FAIL")
