# The CALL direction, proved in the library.
#
# COCOA_LET_DESIGN.md's plan for `win.setTitle(s)` ends with a phase 3 marked
# "the one speculative compiler change here. Propose, don't assume": a
# comptime-parameter `__getattr__[name: StaticString]` hook, without which
# every wrapped method needs a hand-written declaration line.
#
# It is not speculative and it is not missing. `__getattr_param__` has been in
# the parser all along (ExprNodes.cpp: the same mechanism as
# `__getitem_param__`, which Tuple uses for static indices). A plain
# `__getattr__` takes the name as a runtime String -- the PythonObject shape,
# useless here, because a runtime string cannot feed a parameter list and so
# cannot reach the database. `__getattr_param__` takes it as a PARAMETER, so
# the selector is known at compile time and everything the database knows
# about it is available before the program runs.
#
# What that means: the call direction needs no compiler work at all.
from std.sys._cocoakb import cocoakb_method_encoding
from std.objc import (
    ObjCObject, ObjCClass, msg_send, load_framework, nsstring, ns_to_string,
)


@fieldwise_init
struct Bound[cls: StaticString, sel: StaticString](Copyable, Movable):
    """`obj.selector` -- bound to a receiver, not yet sent.

    Two parameters and no fields but the id, so this costs nothing at run
    time: it exists to carry the selector from the attribute reference to the
    call, in the type system.
    """

    var id: Int

    def __call__(self) -> Int:
        return msg_send[Int, Self.cls, Self.sel](ObjCObject(self.id))

    def object(self) -> ObjCObject:
        """A nullary selector returning an object. Separate for now: which
        `__call__` to pick has to come from the SDK's encoding, and that is
        the next piece of design rather than a missing capability."""
        return msg_send[ObjCObject, Self.cls, Self.sel](ObjCObject(self.id))

    def send(self, arg: ObjCObject) -> None:
        _ = msg_send[ObjCObject, Self.cls, Self.sel](
            ObjCObject(self.id), arg.ptr()
        )


@fieldwise_init
struct Obj[cls: StaticString](Copyable, Movable):
    """A typed Objective-C reference: `cls` is the name the database is asked.

    The type has to be declared, not inferred, and that is forced rather than
    chosen -- see the note on return types below.
    """

    var id: Int

    def __getattr_param__[name: StaticString](self) -> Bound[Self.cls, name]:
        return Bound[Self.cls, name](self.id)


def main() raises:
    if not load_framework["AppKit"]():
        raise Error("no AppKit")

    var s = Obj["NSString"](nsstring(String("hello")).addr())

    # The selector reached the database at COMPILE time.
    comptime enc = cocoakb_method_encoding["NSString", "length", False]()
    if enc != StaticString("Q16@0:8"):
        print("encoding:", enc)
        raise Error("the selector's encoding did not come from the SDK")

    # ...and the call is a real message.
    if s.length() != 5:
        print("length ->", s.length())
        raise Error("obj.selector() did not send the message")

    # An object result, and a chained call written the only way it can be:
    # with the receiver's class named again. The SDK cannot tell us what
    # `uppercaseString` returns -- see below -- so nothing can infer it.
    var upper = Obj["NSString"](s.uppercaseString.object().addr())
    if ns_to_string(ObjCObject(upper.id)) != String("HELLO"):
        raise Error("an object result did not come back")

    print("call direction OK")
