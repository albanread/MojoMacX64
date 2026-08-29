# The runtime half of `class` registration, provable on its own.
#
# ObjCClassRegistrar is what the compiler will emit calls to (sprint 2b). It
# takes every value as an ordinary argument -- name, superclass, frameworks --
# because emitting a call with plain arguments is far simpler than emitting a
# parametric one, which is exactly the opposite of what ObjCClassBuilder wants.
#
# Testing it here, driven by hand, means the compiler-emission work lands
# against something already known to work.
from std.objc import ObjCClass, ObjCObject, ObjCClassRegistrar, send, load_framework
from std.memory import OpaquePointer

comptime P = OpaquePointer[MutUntrackedOrigin]


def is_flipped_imp(self_: P, cmd: P) abi("C") -> Bool:
    return True


def main() raises:
    if not load_framework["AppKit"]():
        print("FATAL: could not load AppKit")
        return

    # Frameworks first: objc_getClass returns nil for a superclass whose
    # framework is not in the process, and allocating a pair against nil gives
    # a root class that answers nothing. The registrar loads them in __init__
    # so the ordering cannot be skipped.
    var r = ObjCClassRegistrar("VegaRegistrarProbe", "NSView", "AppKit")
    var added = r.add_method("isFlipped", "c@:", is_flipped_imp)
    var adopted = r.add_protocol("NSTextInputClient")
    var cls = r.register()

    print("registered:", Int(cls.as_object().addr()) != 0)
    print("method added:", added)
    print("protocol adopted:", adopted)

    # The runtime must agree the class is real, is a subclass of NSView, and
    # answers the method we gave it.
    var found = ObjCClass.lookup["VegaRegistrarProbe"]()
    var obj = send[ObjCObject, "alloc"](found.as_object())
    obj = send[ObjCObject, "init"](obj)
    var flipped = send[Bool, "isFlipped"](obj)
    print("instance answers isFlipped:", flipped)

    # The failure this guards against is silent: registering against a nil
    # superclass builds a ROOT class that answers nothing and reports nothing.
    # So check the runtime actually put NSView above us, rather than trusting
    # that register() returned a non-null pointer.
    var sup = send[ObjCObject, "superclass"](found.as_object())
    var sup_name = ObjCClass.lookup["NSView"]()
    var real_subclass = Int(sup.addr()) == Int(sup_name.as_object().addr())
    print("superclass is NSView:", real_subclass)

    var ok = (
        real_subclass
        and
        Int(cls.as_object().addr()) != 0
        and added
        and Int(found.as_object().addr()) != 0
        and flipped
    )
    print("REGISTRAR:", "PASS" if ok else "FAIL")
