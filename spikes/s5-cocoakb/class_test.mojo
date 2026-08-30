# `class` end to end: declare an Objective-C class in Mojo, instantiate it, and
# have the runtime dispatch to its methods.
#
# Everything below is the compiler's work. There is no ObjCClassBuilder, no
# encoding string, no IMP, and no `cmd: P` slot -- the declaration is the whole
# of it. COCOA_CLASS_DESIGN.md is why each piece is where it is.
from std.objc import ObjCObject, msg_send, named_global, sel_dynamic

comptime hits = named_global["class_test.hits", Int]


class Probe(NSObject):
    # A selector the SDK knows, so its encoding is looked up rather than
    # guessed at.
    def isProxy(self) -> Bool:
        hits()[] += 1
        return True

    # One that takes an argument, so the trampoline has something to forward.
    def isEqual_(self, other: Int) -> Bool:
        hits()[] += 1
        return other == 0

    # A selector the SDK has never heard of, because we invented it: the
    # encoding is derived rather than looked up, and this is the target/action
    # shape every Cocoa button uses -- see examples/window.
    def buttonClicked_(self, sender: ObjCObject):
        hits()[] += 1


def main() raises:
    var probe = Probe()
    var obj = ObjCObject(probe.__objc_id)
    if obj.addr() == 0:
        print("FAIL the class did not register")
        return
    print("  OK   registered and instantiated")

    var proxied = msg_send[Bool, "NSObject", "isProxy"](obj)
    print("  OK   isProxy ->", proxied)

    var equal = msg_send[Bool, "NSObject", "isEqual:"](obj, Int(0))
    print("  OK   isEqual: ->", equal)

    # The invented selector. It cannot be sent with msg_send -- that checks
    # the selector against the SDK, and this one is ours -- but the runtime
    # can be asked whether the class answers it, which is what a button will
    # ask before it sends anything.
    var responds = msg_send[Bool, "NSObject", "respondsToSelector:"](
        obj, sel_dynamic("buttonClicked:")
    )
    print("  OK   responds to buttonClicked: ->", responds)

    # A second instance must find the class already there rather than build it
    # again.
    var second = Probe()
    var ok = ObjCObject(second.__objc_id).addr() != 0
    print("  OK   second instance:", ok)

    if proxied and equal and ok and responds and hits()[] == 2:
        print("class OK")
    else:
        print("class FAILED -- methods ran", hits()[], "times")
