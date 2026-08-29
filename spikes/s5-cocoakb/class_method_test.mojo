# `@staticmethod` in a class is a `+` method.
#
# This CRASHED the compiler before -- not diagnosed, not mis-registered:
# crashed. Everything in the trampoline assumed the callee's argument 0 was
# the receiver, and a class method's argument 0 is its first real argument,
# or for a nullary one does not exist at all.
#
# A class method is actually the simplest thing here. The C ABI still hands
# over two leading words, but the first is the CLASS object rather than an
# instance, and with no `self` there is no box to find and nothing to convert:
# both are dropped and the rest forwarded straight through.
#
# Where it goes is the part that is easy to get backwards. A `+` method lives
# on the METACLASS -- the class object's own class -- so `[Factory make]`
# works and `[instance make]` does not. Registering it on the class would
# reverse exactly that, and would look like it worked.
from std.objc import (
    ObjCObject, ObjCClass, msg_send, load_framework, named_global, sel_dynamic,
)

comptime g_calls = named_global["classmethod.calls", Int]


class Factory(NSObject):
    var made: Int = 0

    @staticmethod
    def isProxy() -> Bool:
        """A nullary class method: no self, no arguments at all."""
        g_calls()[] += 1
        return True

    @staticmethod
    def isEqual_(other: ObjCObject) -> Bool:
        """And one that takes an argument, to check the forwarding lines up
        once `self` is not there to shift it."""
        g_calls()[] += 1
        return other.addr() != 0

    def hash(mut self) -> Int:
        """An ordinary instance method alongside them, unaffected -- and it
        still finds its own box."""
        self.made += 1
        return 1000 + self.made


def main() raises:
    var f = Factory()
    var cls = ObjCClass.lookup["Factory"]()
    if cls.is_nil():
        raise Error("the class never reached the runtime")

    # The class side answers.
    if not msg_send[Bool, "NSObject", "isProxy", is_class=True](
        cls.as_object()
    ):
        raise Error("a nullary class method did not answer")
    if not msg_send[Bool, "NSObject", "isEqual:", is_class=True](
        cls.as_object(), cls.as_object()
    ):
        raise Error("a class method with an argument did not answer")
    if g_calls()[] != 2:
        print("class method calls:", g_calls()[], "want 2")
        raise Error("a class method body did not run")

    # And the INSTANCE side does not, which is the half that would look like
    # it worked if the IMP had gone on the class rather than the metaclass.
    # NSObject supplies -isProxy, so an instance answers it -- with NSObject's
    # answer, False, not ours. The call count settles it either way.
    var before = g_calls()[]
    _ = msg_send[Bool, "NSObject", "isProxy"](ObjCObject(f.__objc_id))
    if g_calls()[] != before:
        raise Error("a + method was reachable from an instance: it went onto "
                    "the class instead of the metaclass")

    # The instance method beside them still works, and still finds its box.
    if msg_send[Int, "NSObject", "hash"](ObjCObject(f.__objc_id)) != 1001:
        raise Error("an instance method broke when a class method joined it")

    print("class methods OK")
