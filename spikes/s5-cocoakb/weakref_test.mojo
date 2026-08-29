# ObjCWeakRef: sees the object while it lives, nil after, survives copies.
from std.objc import ObjCRef, ObjCWeakRef, ObjCObject, ObjCClass, msg_send, autoreleasepool


def make_object() -> ObjCRef:
    var cls = ObjCClass.lookup["NSObject"]()
    var o = msg_send[ObjCObject, "NSObject", "alloc", is_class=True](
        cls.as_object()
    )
    return ObjCRef(adopt=msg_send[ObjCObject, "NSObject", "init"](o))


def main() raises:
    with autoreleasepool():
        # Alive: a weak ref loads the object.
        var strong = make_object()
        var weak = ObjCWeakRef(strong.object())
        var loaded = weak.load()
        if loaded.is_nil():
            raise Error("FAIL: weak ref is nil while the object is alive")
        _ = loaded^

        # A copy is an independent registration of the same object.
        var weak2 = weak.copy()
        if weak2.load().is_nil():
            raise Error("FAIL: copied weak ref is nil while object is alive")

        # Dead: after the last strong ref goes, both load nil.
        _ = strong^
        if not weak.load().is_nil():
            raise Error("FAIL: weak ref still loads after last release")
        if not weak2.load().is_nil():
            raise Error("FAIL: copied weak ref still loads after last release")

        # A weak ref to nil is legal and loads nil.
        var weak_nil = ObjCWeakRef(ObjCObject(0))
        if not weak_nil.load().is_nil():
            raise Error("FAIL: nil weak ref loaded something")
    print("WEAKREF: PASS")
