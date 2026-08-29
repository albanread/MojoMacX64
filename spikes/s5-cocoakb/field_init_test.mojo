# `var count: Int = 3` -- a field initializer on a class.
#
# The grammar in COCOA_CLASS_DESIGN.md promised these from the first draft and
# the parser rejected them with "unknown tokens at the end of a declaration",
# which is true and unhelpful. A struct still refuses them, deliberately: a
# struct's initial values belong in its `__init__`, where Mojo checks that
# every field is set exactly once. A class has no such place -- its `__init__`
# IS the compiler's registration function -- so the declaration is the only
# place left to say it.
#
# What is being checked here is not that the syntax parses. It is that the
# value reaches the BOX, which is the memory a message actually reads, and
# that each instance gets its own.
from std.objc import (
    ObjCObject, ObjCClass, msg_send, load_framework, named_global,
)

comptime g_dead = named_global["fieldinit.dead", Int]


struct Tracer(Copyable, Movable):
    var tag: Int

    def __init__(out self):
        self.tag = 0

    def __del__(deinit self):
        g_dead()[] += 1


class Configured(NSObject):
    var hits: Int = 41              # a literal
    var scale: Float64 = 1.5 + 1.0  # an expression, folded or not
    var label: String = String("configured")  # heap, so dealloc must free it
    var plain: Int                  # no initializer: still default-constructed
    var t: Tracer                   # nor this one

    def isProxy(mut self) -> Bool:
        self.hits += 1
        return (
            self.hits == 42
            and self.scale == 2.5
            and self.label == String("configured")
            and self.plain == 0
        )

    def isEqual_(mut self, other: ObjCObject) -> Bool:
        """Reads without mutating, to tell two instances apart."""
        return self.hits == 41


def main() raises:
    var c = Configured()
    var obj = ObjCObject(c.__objc_id)

    # The initializers reached the box: every field checked through a real
    # message, which reads the object's memory rather than the local copy.
    if not msg_send[Bool, "NSObject", "isProxy"](obj):
        raise Error("a field initializer did not reach the box")

    # And the local the constructor handed back agrees with it. It is a copy
    # -- writing through it writes the copy -- but reading 0 from it while the
    # object holds 41 would be a worse lie than evaluating the expression
    # twice, so both are initialised.
    if c.hits != 41 or c.scale != 2.5:
        print("local copy:", c.hits, c.scale, "want 41 2.5")
        raise Error("the constructor's local did not get the initializers")

    # Per instance, not per class: the first was bumped to 42 above, and a
    # second one must still start at 41.
    var d = Configured()
    if not msg_send[Bool, "NSObject", "isEqual:"](
        ObjCObject(d.__objc_id), obj
    ):
        raise Error("a second instance did not get its own initial values")
    if msg_send[Bool, "NSObject", "isEqual:"](obj, ObjCObject(d.__objc_id)):
        raise Error("the first instance's mutation did not stick")

    # A heap initializer is still destroyed when the object dies -- the box
    # lifecycle does not care where a field's value came from.
    var before = g_dead()[]
    var e = Configured()
    _ = msg_send[NoneType, "NSObject", "release"](ObjCObject(e.__objc_id))
    if g_dead()[] <= before:
        raise Error("an initialised box was not destroyed at dealloc")

    print("field initializers OK")
