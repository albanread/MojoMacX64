# The box: per-instance Mojo state hanging off an Objective-C object.
#
# A class's fields do not become Objective-C ivars one apiece. The object gets
# ONE ivar holding a pointer to a Mojo struct, so a field can be any Mojo type
# rather than only what ivar layout can describe. This proves the mechanism by
# hand -- reserve the ivar, allocate a box, hang it off two instances, and
# check they do not share -- before the compiler synthesizes any of it.
from std.objc import (
    ObjCClassRegistrar, ObjCClass, ObjCObject, box_offset, new_instance,
    named_global,
)
from std.memory import OpaquePointer
from std.ffi import external_call

comptime P = OpaquePointer[MutUntrackedOrigin]


@fieldwise_init
struct Box(ImplicitlyCopyable, Movable):
    """What a `class Counter: var hits: Int; var tag: Int` would carry."""

    var hits: Int
    var tag: Int


def box_of(obj: ObjCObject, offset: Int) -> Pointer[Box, MutUntrackedOrigin]:
    var slot = Pointer[Int, MutUntrackedOrigin](
        unsafe_from_address=obj.addr() + offset
    )
    return Pointer[Box, MutUntrackedOrigin](unsafe_from_address=slot[])


def attach_box(obj: ObjCObject, offset: Int, value: Box):
    var raw = external_call["calloc", P](Int(1), Int(16))
    var box = Pointer[Box, MutUntrackedOrigin](unsafe_from_address=Int(raw))
    box[] = value
    var slot = Pointer[Int, MutUntrackedOrigin](
        unsafe_from_address=obj.addr() + offset
    )
    slot[] = Int(raw)


def main() raises:
    var r = ObjCClassRegistrar("BoxProbe", "NSObject", "Foundation")
    # add_box takes a raw index -- the compiler's sizeof hands one over --
    # so the by-hand caller converts.
    if not r.add_box(Int(16).__mlir_index__(), "BoxProbe"):
        print("FAIL could not reserve the ivar")
        return
    var cls = r.register()
    if cls.as_object().addr() == 0:
        print("FAIL class did not register")
        return

    var offset = box_offset(cls, "BoxProbe")
    print("  OK   box ivar at offset", offset)
    if offset <= 0:
        print("FAIL the ivar has no offset")
        return

    var a = new_instance(cls)
    var b = new_instance(cls)
    attach_box(a, offset, Box(41, 7))
    attach_box(b, offset, Box(1759, 9))

    var ba = box_of(a, offset)
    var bb = box_of(b, offset)
    print("  OK   a:", ba[].hits, ba[].tag, " b:", bb[].hits, bb[].tag)

    # Per instance, not per class: the whole point.
    ba[].hits += 1
    var shared = bb[].hits == 1760

    if ba[].hits == 42 and bb[].hits == 1759 and not shared:
        print("box OK")
    else:
        print("box FAILED")
