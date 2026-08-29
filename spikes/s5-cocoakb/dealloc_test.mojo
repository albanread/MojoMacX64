# The box is emptied when the object dies.
#
# Mojo's ownership machinery has always destroyed a field REASSIGNED through
# the box -- that fell out of the box being ordinary Mojo memory. What did not
# happen was destruction when the object itself died, so the last value in
# every field leaked. This is the compiler emitting `add_dealloc`, and
# std.objc's `_box_dealloc_imp` doing the two things that matter in the one
# order that works: run T's destructor over the box, THEN `[super dealloc]`,
# which is what actually frees the instance. Either half alone is a bug --
# skip the super call and every object leaks; do it first and the destructor
# runs over freed memory.
from std.objc import (
    ObjCObject, ObjCClass, msg_send, load_framework, named_global,
)
from std.ffi import external_call
from std.memory import alloc

comptime g_dead = named_global["dealloc.dead", Int]


struct Tracer(Copyable, Movable):
    """Counts its own destructions, which is the only way to see this work."""

    var tag: Int

    def __init__(out self):
        self.tag = 0

    def __del__(deinit self):
        g_dead()[] += 1


class Owner(NSObject):
    var t: Tracer
    var name: String

    def isProxy(mut self) -> Bool:
        self.t.tag += 1
        self.name = String("a string long enough that it must go to the heap")
        return True


class NeverAssigned(NSObject):
    """The box's ground state is ZEROES, not a constructed value, and now that
    destruction actually runs, that rule has teeth: a field's type must
    survive having its destructor run over zeros. String and List do -- an
    empty one is all-zero -- and that is the documented contract, not luck we
    are relying on quietly."""

    var name: String

    def isProxy(self) -> Bool:
        return True


def _maxrss() -> Int:
    """Resident high-water mark, in bytes. `getrusage(RUSAGE_SELF, &buf)`;
    ru_maxrss is the third word on Darwin."""
    var buf = alloc[Int](32)
    for i in range(32):
        buf[i] = 0
    _ = external_call["getrusage", Int](Int(0), buf)
    return buf[2]


def main() raises:
    # A field that never got a value: the destructor runs over zeros.
    var n = NeverAssigned()
    _ = msg_send[NoneType, "NSObject", "release"](ObjCObject(n.__objc_id))

    # One object, used and released: exactly one box destruction.
    var before = g_dead()[]
    var o = Owner()
    var obj = ObjCObject(o.__objc_id)
    _ = msg_send[Bool, "NSObject", "isProxy"](obj)
    var mid = g_dead()[]
    _ = msg_send[NoneType, "NSObject", "release"](obj)
    var after = g_dead()[]

    if after != mid + 1:
        print("box destructions on release:", after - mid, "want 1")
        raise Error("the box was not destroyed when the object died")

    # And `[super dealloc]` really ran. Address reuse is NOT the test -- the
    # allocator is under no obligation to hand the same block back, and it
    # does not -- so measure the thing that actually matters: two hundred
    # thousand objects, each with a String that goes to the heap, created and
    # released. If the super call were missing, every one of them would still
    # be alive.
    var start = _maxrss()
    for _ in range(200000):
        var each = Owner()
        var handle = ObjCObject(each.__objc_id)
        _ = msg_send[Bool, "NSObject", "isProxy"](handle)
        _ = msg_send[NoneType, "NSObject", "release"](handle)
    var grew = (_maxrss() - start) // 1024

    # A megabyte of slack: this is a high-water mark, and the loop itself
    # touches memory. A leak here is 200k objects plus 200k strings -- tens of
    # megabytes -- so the signal is not subtle.
    if grew > 1024:
        print("maxrss grew by", grew, "KB over 200k create/release cycles")
        raise Error("instances are not being freed -- [super dealloc] did not "
                    "run, and every object leaks")

    print("box lifecycle OK, destructions:", after - before, "leak:", grew, "KB")
