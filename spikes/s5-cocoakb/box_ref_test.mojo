# Reaching a class's fields from outside a method.
#
# `self` points at the box, but a method is the only place that is true.
# Anything else holding an `id` -- a free function, another class's method,
# another module -- had no way to reach those fields at all. That is why so
# much state that belongs to an object ends up parked in process globals
# beside it instead.
#
# `box_ref[T](id)` is the way back in, and it is a pointer, so writing through
# it writes the OBJECT. That is the difference between it and `T()`, whose
# result is a copy of the box and whose field writes go nowhere.
from std.objc import (
    ObjCObject, msg_send, box_ref, named_global, load_framework,
)
from std.collections.optional import OptionalReg

comptime g_id = named_global["boxref.id", Int]
comptime g_other = named_global["boxref.other", Int]


class Editor(NSObject):
    var caret: Int = 7
    var label: String = String("start")

    def isProxy(self) -> Bool:
        """The object's own view of its box, for comparison."""
        return self.caret == 42 and self.label == String("moved")


def move_caret(to: Int):
    """A FREE FUNCTION writing an object's field. This is the whole point."""
    box_ref[Editor](g_id()[]).value()[].caret = to


def rename(to: String):
    box_ref[Editor](g_id()[]).value()[].label = to


def read_caret() -> Int:
    return box_ref[Editor](g_id()[]).value()[].caret


def main() raises:
    var e = Editor()
    g_id()[] = e.__objc_id

    # The field initializer is visible from outside.
    if read_caret() != 7:
        print("initial caret:", read_caret(), "want 7")
        raise Error("box_ref did not see the field initializer")

    # A write from a free function reaches the object, not a copy.
    move_caret(42)
    rename(String("moved"))
    if read_caret() != 42:
        raise Error("a write through box_ref did not stick")
    if not msg_send[Bool, "NSObject", "isProxy"](ObjCObject(e.__objc_id)):
        raise Error("the object does not see what box_ref wrote")

    # Per instance, not per class: a second object has its own box, and the
    # first one's edits did not follow it.
    var f = Editor()
    g_other()[] = f.__objc_id
    var saved = g_id()[]
    g_id()[] = g_other()[]
    if read_caret() != 7:
        print("second instance caret:", read_caret(), "want 7")
        raise Error("box_ref reached the wrong instance")
    g_id()[] = saved
    if read_caret() != 42:
        raise Error("the first instance lost its value")

    # Nil is a state, not a hazard. `id + offset` on a nil id is a pointer
    # into the first page, and returning one while documenting the danger is
    # not the same as being safe.
    if box_ref[Editor](0):
        raise Error("a nil id answered with a box")

    print("box_ref OK")
