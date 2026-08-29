# `class B(A)` where A is another Mojo class.
#
# The design grammar has promised this since the first draft -- "the first
# base names the superclass: an ObjC class the database knows, OR another Mojo
# class" -- and the compiler rejected it outright.
#
# It needs no new runtime machinery, and that is not luck: ivar offsets are
# per class, so an instance of B carries A's box at A's offset and B's at B's,
# and A's methods find A's box in a B exactly as they would in an A. What it
# needs is three things the compiler now does.
#
#   ORDER.        A does not exist in the runtime until something instantiates
#                 it, and registration is lazy. B registered first would
#                 allocate its pair against nil and become a ROOT class that
#                 answers nothing, silently. The registrar takes a thunk and
#                 calls it when the superclass is missing.
#   ANCESTOR BOXES. Nothing else will ever construct A's box inside a B: A's
#                 own __init__ runs when an A is made. B's constructor now
#                 walks the chain.
#   PER-CLASS IVARS. One shared box name would be ambiguous the moment this
#                 existed -- class_getInstanceVariable answers with the
#                 nearest -- so A's dealloc would destroy B's box a second
#                 time and never touch its own.
from std.objc import (
    ObjCObject, ObjCClass, msg_send, load_framework, named_global,
)

comptime g_base_dead = named_global["inherit.base.dead", Int]
comptime g_mid_dead = named_global["inherit.mid.dead", Int]


struct BaseTracer(Copyable, Movable):
    var n: Int

    def __init__(out self):
        self.n = 0

    def __del__(deinit self):
        g_base_dead()[] += 1


struct MidTracer(Copyable, Movable):
    var n: Int

    def __init__(out self):
        self.n = 0

    def __del__(deinit self):
        g_mid_dead()[] += 1


class Base(NSObject):
    var tag: Int = 5
    var t: BaseTracer

    def isProxy(self) -> Bool:
        """Inherited unchanged by everything below."""
        return self.tag == 5


class Middle(Base):
    var extra: Int = 9
    var t: MidTracer

    def isEqual_(self, other: ObjCObject) -> Bool:
        return self.extra == 9


class Leaf(Middle):
    """Two levels up, and no fields of its own: a class with no box at all
    still has to construct its ancestors'."""

    def isSelectorExcludedFromWebScript_(self, sel: Int) -> Bool:
        return True


def main() raises:
    # A base on its own, unchanged by any of this.
    var b = Base()
    if not msg_send[Bool, "NSObject", "isProxy"](ObjCObject(b.__objc_id)):
        raise Error("a plain class stopped working")

    # One level. The derived class's own method, and the inherited one, which
    # reads the BASE's box inside a derived instance.
    var m = Middle()
    var mo = ObjCObject(m.__objc_id)
    if not msg_send[Bool, "NSObject", "isEqual:"](mo, mo):
        raise Error("the derived class's own method did not work")
    if not msg_send[Bool, "NSObject", "isProxy"](mo):
        raise Error("an inherited method did not find its own base box")

    # Two levels, and a leaf with no box of its own -- it still has to
    # construct both ancestors'.
    var l = Leaf()
    var lo = ObjCObject(l.__objc_id)
    if not msg_send[Bool, "NSObject", "isProxy"](lo):
        raise Error("a two-level inherited method did not find the base box")
    if not msg_send[Bool, "NSObject", "isEqual:"](lo, lo):
        raise Error("a one-level inherited method did not find the mid box")

    # The runtime agrees about the relationships, which is the point of using
    # real classes rather than flattening them.
    var base_cls = ObjCClass.lookup["Base"]()
    var mid_cls = ObjCClass.lookup["Middle"]()
    if base_cls.is_nil() or mid_cls.is_nil():
        raise Error("a class in the chain never reached the runtime")
    if not msg_send[Bool, "NSObject", "isKindOfClass:"](
        lo, base_cls.as_object()
    ):
        raise Error("the runtime does not see Leaf as a kind of Base")

    # And dealloc walks the chain: each class's dealloc empties ITS OWN box
    # and passes [super dealloc] on. Exactly one destruction per box, which
    # is what a shared ivar name would have got wrong in both directions.
    var base_before = g_base_dead()[]
    var mid_before = g_mid_dead()[]
    var doomed = Leaf()
    _ = msg_send[NoneType, "NSObject", "release"](ObjCObject(doomed.__objc_id))
    var base_runs = g_base_dead()[] - base_before
    var mid_runs = g_mid_dead()[] - mid_before

    # One per box for the object, plus one per box for the constructor's local
    # copy -- the documented doubling, not a leak.
    if base_runs != 2 or mid_runs != 2:
        print("destructions on release: base", base_runs, "mid", mid_runs)
        print("(want 2 each: the object's box, and the constructor's local)")
        raise Error("the dealloc chain did not empty each box exactly once")

    print("mojo class inheritance OK")
