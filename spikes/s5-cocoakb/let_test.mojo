# The revived let: immutable, scope-bound bindings -- Cocoa objects and values.
from std.objc import (
    ObjCClass,
    ObjCObject,
    ObjCRef,
    ObjCWeakRef,
    autoreleasepool,
    msg_send,
    nsstring,
    ns_to_string,
)


def make_object() -> ObjCRef:
    var cls = ObjCClass.lookup["NSObject"]()
    var o = msg_send[ObjCObject, "NSObject", "alloc", is_class=True](
        cls.as_object()
    )
    return ObjCRef(adopt=msg_send[ObjCObject, "NSObject", "init"](o))


def watch() raises -> ObjCWeakRef:
    let scoped = make_object()
    var weak = ObjCWeakRef(scoped.object())
    if weak.load().is_nil():
        raise Error("FAIL: weak nil while let binding alive")
    # A use after the check keeps `scoped` alive to here under ASAP
    # destruction; it dies at return, which is what main verifies.
    if scoped.is_nil():
        raise Error("unreachable")
    return weak^


def main() raises:
    with autoreleasepool():
        # A let-bound Cocoa object: the ARC ownership rides ObjCRef exactly as
        # with var; let adds the immutability of the BINDING.
        let obj = make_object()
        if obj.is_nil():
            raise Error("FAIL: let-bound object is nil")

        # The OBJECT stays mutable through a let binding -- Swift's rule.
        let s = nsstring("hello let")
        if ns_to_string(s) != "hello let":
            raise Error("FAIL: let-bound NSString round trip")

        # let works for plain values too (general immutable binding).
        let n = 41 + 1
        if n != 42:
            raise Error("FAIL: let value binding")

        # let releases at scope end like var: prove via a weak observer.
        # (A helper scope, not `var weak: ObjCWeakRef` + late assignment --
        # assigning into an uninitialised var of a __deinit__ type destroys
        # garbage first and crashes; pre-existing issue, noted in the commit.)
        var weak = watch()
        if not weak.load().is_nil():
            raise Error("FAIL: let binding did not release at scope end")
    print("LET: PASS")
