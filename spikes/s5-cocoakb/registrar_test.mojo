# Prove the runtime half of class registration, by hand, before the compiler
# emits any of it: build a class from strings known only at run time, message
# it, and check the answer came from our method.
from std.objc import (
    ObjCClassRegistrar, ObjCClass, ObjCObject,
    msg_send, new_instance, sel, named_global,
)
from std.memory import OpaquePointer

comptime P = OpaquePointer[MutUntrackedOrigin]
comptime hits = named_global["registrar.hits", Int]


fn is_flipped(self_: P, cmd: P) -> Bool:
    hits()[] += 1
    return True


def main() raises:
    # The registrar loads the framework itself, which is the point: the
    # superclass cannot be resolved before AppKit is in the process.
    var r = ObjCClassRegistrar("RegistrarProbeView", "NSView", "AppKit")
    var added = r.add_method("isFlipped", "B16@0:8", is_flipped)
    var conformed = r.add_protocol("NSTextInputClient")
    var cls = r.register()

    if cls.as_object().addr() == 0:
        print("FAIL class did not register")
        return
    print("  OK   registered, method added:", added, "protocol adopted:", conformed)

    var obj = new_instance(cls)
    var answer = msg_send[Bool, "NSView", "isFlipped"](obj)
    print("  OK   isFlipped ->", answer, "| our method ran", hits()[], "time(s)")

    if answer and hits()[] == 1:
        print("registrar OK")
    else:
        print("registrar FAILED")
