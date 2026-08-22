# ===----------------------------------------------------------------------=== #
# A thin, leak-safe Foundation surface built on the std.objc primitives.
#
# This is convenience, not new mechanism: every call goes through `msg_send`
# with a database-selected stub, and every owned object is an `ObjCRef`, so
# nothing here can leak or pick the wrong ABI. It exists to show what binding
# a Cocoa class looks like once the machinery underneath is doing its job --
# a wrapper is a handful of typed methods, not a generated blob.
# ===----------------------------------------------------------------------=== #

from std.ffi import external_call, c_char
from std.memory import OpaquePointer, Pointer
from std.collections.string.string_span import _get_kgen_string
from .runtime import ObjCClass, ObjCObject, msg_send
from .ownership import ObjCRef


comptime _RawPtr = OpaquePointer[MutUntrackedOrigin]


struct NSString(Movable):
    """A leak-safe handle on an `NSString`. Owns its object via `ObjCRef`, so
    it is released when the Mojo value dies."""

    var _ref: ObjCRef

    def __init__(out self, *, adopt: ObjCObject):
        """Wrap an already-owned (+1) NSString."""
        self._ref = ObjCRef(adopt=adopt)

    def __init__(out self, text: String):
        """Create an NSString from a Mojo `String`.

        `+[NSString stringWithUTF8String:]` returns an autoreleased object, so
        we retain it into our own +1 -- the resulting handle is not tied to any
        pool.
        """
        var cls = ObjCClass.lookup["NSString"]()
        var local = text
        var c = local.as_c_string_slice()
        var s = msg_send[
            ObjCObject, "NSString", "stringWithUTF8String:", is_class=True
        ](cls.as_object(), c)
        self._ref = ObjCRef(retain=s)

    def object(self) -> ObjCObject:
        return self._ref.object()

    def length(self) -> Int:
        """`-[NSString length]` -- the number of UTF-16 code units."""
        return msg_send[Int, "NSString", "length"](self.object())

    def to_string(self) -> String:
        """Read the contents back as a Mojo `String` via `-UTF8String`."""
        var p = msg_send[
            OpaquePointer[MutUntrackedOrigin], "NSString", "UTF8String"
        ](self.object())
        return String(unsafe_from_utf8_ptr=p.unsafe_bitcast[c_char]())

    def equals(self, other: NSString) -> Bool:
        """`-[NSString isEqualToString:]`."""
        return msg_send[Bool, "NSString", "isEqualToString:"](
            self.object(), other.object().ptr()
        )

    def appending(self, other: NSString) -> NSString:
        """`-[NSString stringByAppendingString:]` -> a new autoreleased string,
        retained into a fresh owned handle."""
        var s = msg_send[
            ObjCObject, "NSString", "stringByAppendingString:"
        ](self.object(), other.object().ptr())
        # +1 the autoreleased result into our own owned handle.
        _ = external_call["objc_retain", _RawPtr](s.ptr())
        return NSString(adopt=s)


def nsstring(s: String) -> ObjCObject:
    """An autoreleased NSString for `s` -- for handing to AppKit setters
    (which retain), inside an autorelease pool."""
    var cls = ObjCClass.lookup["NSString"]()
    var local = s
    return msg_send[
        ObjCObject, "NSString", "stringWithUTF8String:", is_class=True
    ](cls.as_object(), local.as_c_string_slice())


def extern_object[name: StaticString]() -> ObjCObject:
    """The object held in an extern Cocoa constant, e.g.
    `NSForegroundColorAttributeName`.

    These constants are `NSString *` (or other object) GLOBALS, not values the
    metadata can hand over at compile time -- `cocoakb_constant_type` reports
    their type (`@`), and the address is resolved by the linker. So take a
    link-time reference to the data symbol and load the pointer out of it.
    """
    var slot = Pointer[Int, MutUntrackedOrigin](
        _mlir_value=__mlir_op.`pop.extern_ptr_symbol`[
            name=_get_kgen_string[name](),
            alignment=Int(8).__mlir_index__(),
            _type=Pointer[Int, MutUntrackedOrigin]._mlir_type,
        ]()
    )
    return ObjCObject(slot[])
