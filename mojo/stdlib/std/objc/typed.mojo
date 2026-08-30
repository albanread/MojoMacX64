# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, Modular Inc. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ===----------------------------------------------------------------------=== #
"""Calling Cocoa: `view.setFrameSize(size)` rather than `msg_send[...]`.

The other half of `class`. COCOA_CLASS_DESIGN.md made declaring an
Objective-C class a declaration; this makes calling one a call.

    var view = Obj["NSView"](id)
    view.setFrameSize(size)              # setFrameSize:
    var w = view.window()                # Obj["NSWindow"], from the SDK
    var flipped = view.isFlipped()       # Bool, from the SDK

Everything is checked at compile time and nothing is written down twice:

* **the selector must exist.** `view.setFrmeSize(s)` is a compile error
  naming the class and the name, not a runtime `doesNotRecognizeSelector:`.
* **the name maps like `class`'s, backwards.** Underscores are colons and the
  arguments supply the last one, so `insertText_replacementRange(t, r)` is
  `insertText:replacementRange:`. One rule, both directions.
* **the result is typed by the SDK.** `length()` is an `Int`, `isFlipped()` a
  `Bool`, `frame()` a `CGRect`, `window()` an `Obj["NSWindow"]`.

The class of a returned object comes from the runtime's PROPERTY metadata,
which is the one place it is recorded -- a method's own encoding says `@` and
nothing more. Where it is not recorded the answer is `Obj["NSObject"]`, which
is true of every object: precise where the SDK knows, sound where it does not.

What this is not: a wrapper for every Cocoa class. There are no generated
files and nothing to regenerate when the SDK moves. `Obj["NSView"]` is a
parameter, so the surface is whatever the database knows, which is all of it.
"""

from std.sys._cocoakb import (
    cocoakb_p_selector_for,
    cocoakb_p_ret_kind_for,
    cocoakb_p_ret_class_for,
    cocoakb_p_ret_class_for_str,
)
from std.memory import OpaquePointer
from .runtime import ObjCObject, ObjCClass, msg_send
from .geometry import CGRect, CGPoint, CGSize, NSRange


# The kinds, as code points, because a conditional type can branch on an
# integer and not on a string. See `method_ret_kind` in CocoaBaseMCP.
comptime _VOID = 118      # v
comptime _OBJECT = 64     # @
comptime _CLASS = 35      # #
comptime _SEL = 58        # :
comptime _CHARP = 42      # *
comptime _POINTER = 94    # ^
comptime _BOOL = 66       # B
comptime _DOUBLE = 100    # d
comptime _RECT = 82       # R
comptime _POINT = 80      # P
comptime _SIZE = 83       # S
comptime _RANGE = 78      # N
comptime _STRUCT = 123    # {
comptime _NOSUCH = 0
"""No such selector on this class: the kind query answers 0 rather than
failing, so the error can be a sentence instead of an unevaluated type."""


comptime _Kind[
    cls: StringLiteral, name: StringLiteral, isc: StringLiteral,
    nargs: StringLiteral,
] = cocoakb_p_ret_kind_for[cls, name, isc, nargs]


comptime _Result[
    cls: StringLiteral, name: StringLiteral, isc: StringLiteral,
    nargs: StringLiteral,
]: AnyType = (
    NoneType if _Kind[cls, name, isc, nargs] == _VOID
    else Bool if _Kind[cls, name, isc, nargs] == _BOOL
    else Float64 if _Kind[cls, name, isc, nargs] == _DOUBLE
    else CGRect if _Kind[cls, name, isc, nargs] == _RECT
    else CGPoint if _Kind[cls, name, isc, nargs] == _POINT
    else CGSize if _Kind[cls, name, isc, nargs] == _SIZE
    else NSRange if _Kind[cls, name, isc, nargs] == _RANGE
    else Obj[
        StringLiteral[cocoakb_p_ret_class_for_str[cls, name, isc, nargs]]()
    ] if _Kind[cls, name, isc, nargs] == _OBJECT
    # A Class, a SEL, a char* and a bare pointer are all one word, and there
    # is nothing more useful to say about them than that.
    else ObjCObject if _Kind[cls, name, isc, nargs] == _CLASS
    else ObjCObject if _Kind[cls, name, isc, nargs] == _SEL
    else ObjCObject if _Kind[cls, name, isc, nargs] == _CHARP
    else ObjCObject if _Kind[cls, name, isc, nargs] == _POINTER
    # Everything left is an integer of some width, which is an Int here. A
    # struct this does not name is refused in `__call__` rather than silently
    # read as one -- see the constraint there.
    else Int
)


@fieldwise_init
struct Bound[cls: StringLiteral, name: StringLiteral](Copyable, Movable):
    """`obj.name` -- a selector bound to a receiver, not yet sent.

    Two parameters and one field, so it costs nothing at run time: it exists
    to carry the name from the attribute reference to the call, in the type
    system, which is the only place the argument count is known in time to
    finish the selector.
    """

    var id: Int

    def __call__(self) -> _Result[Self.cls, Self.name, "0", "0"]:
        comptime sel = cocoakb_p_selector_for[Self.cls, Self.name, "0", "0"]
        comptime assert _Kind[Self.cls, Self.name, "0", "0"] != _NOSUCH, (
            "no such method on this class taking this many arguments: the"
            " selector it would send is not one the SDK records. Check the"
            " spelling, the argument count, and that underscores line up with"
            " the selector's colons"
        )
        comptime assert _Kind[Self.cls, Self.name, "0", "0"] != _STRUCT, (
            "this selector returns a struct std.objc does not name; send it"
            " with msg_send and a register-passable result type"
        )
        return msg_send[
            _Result[Self.cls, Self.name, "0", "0"], Self.cls, sel,
        ](ObjCObject(self.id))

    def __call__[
        T0: AnyType
    ](self, a0: T0) -> _Result[Self.cls, Self.name, "0", "1"]:
        comptime sel = cocoakb_p_selector_for[Self.cls, Self.name, "0", "1"]
        comptime assert _Kind[Self.cls, Self.name, "0", "1"] != _NOSUCH, (
            "no such method on this class taking this many arguments: the"
            " selector it would send is not one the SDK records. Check the"
            " spelling, the argument count, and that underscores line up with"
            " the selector's colons"
        )
        comptime assert _Kind[Self.cls, Self.name, "0", "1"] != _STRUCT, (
            "this selector returns a struct std.objc does not name; send it"
            " with msg_send and a register-passable result type"
        )
        return msg_send[
            _Result[Self.cls, Self.name, "0", "1"], Self.cls, sel,
        ](ObjCObject(self.id), a0)

    def __call__[
        T0: AnyType, T1: AnyType
    ](self, a0: T0, a1: T1) -> _Result[Self.cls, Self.name, "0", "2"]:
        comptime sel = cocoakb_p_selector_for[Self.cls, Self.name, "0", "2"]
        comptime assert _Kind[Self.cls, Self.name, "0", "2"] != _NOSUCH, (
            "no such method on this class taking this many arguments: the"
            " selector it would send is not one the SDK records. Check the"
            " spelling, the argument count, and that underscores line up with"
            " the selector's colons"
        )
        comptime assert _Kind[Self.cls, Self.name, "0", "2"] != _STRUCT, (
            "this selector returns a struct std.objc does not name; send it"
            " with msg_send and a register-passable result type"
        )
        return msg_send[
            _Result[Self.cls, Self.name, "0", "2"], Self.cls, sel,
        ](ObjCObject(self.id), a0, a1)

    def __call__[
        T0: AnyType, T1: AnyType, T2: AnyType
    ](self, a0: T0, a1: T1, a2: T2) -> _Result[Self.cls, Self.name, "0", "3"]:
        comptime sel = cocoakb_p_selector_for[Self.cls, Self.name, "0", "3"]
        comptime assert _Kind[Self.cls, Self.name, "0", "3"] != _NOSUCH, (
            "no such method on this class taking this many arguments: the"
            " selector it would send is not one the SDK records. Check the"
            " spelling, the argument count, and that underscores line up with"
            " the selector's colons"
        )
        comptime assert _Kind[Self.cls, Self.name, "0", "3"] != _STRUCT, (
            "this selector returns a struct std.objc does not name; send it"
            " with msg_send and a register-passable result type"
        )
        return msg_send[
            _Result[Self.cls, Self.name, "0", "3"], Self.cls, sel,
        ](ObjCObject(self.id), a0, a1, a2)

    def __call__[
        T0: AnyType, T1: AnyType, T2: AnyType, T3: AnyType
    ](self, a0: T0, a1: T1, a2: T2, a3: T3) -> _Result[Self.cls, Self.name, "0", "4"]:
        comptime sel = cocoakb_p_selector_for[Self.cls, Self.name, "0", "4"]
        comptime assert _Kind[Self.cls, Self.name, "0", "4"] != _NOSUCH, (
            "no such method on this class taking this many arguments: the"
            " selector it would send is not one the SDK records. Check the"
            " spelling, the argument count, and that underscores line up with"
            " the selector's colons"
        )
        comptime assert _Kind[Self.cls, Self.name, "0", "4"] != _STRUCT, (
            "this selector returns a struct std.objc does not name; send it"
            " with msg_send and a register-passable result type"
        )
        return msg_send[
            _Result[Self.cls, Self.name, "0", "4"], Self.cls, sel,
        ](ObjCObject(self.id), a0, a1, a2, a3)

    def __call__[
        T0: AnyType, T1: AnyType, T2: AnyType, T3: AnyType, T4: AnyType
    ](self, a0: T0, a1: T1, a2: T2, a3: T3, a4: T4) -> _Result[Self.cls, Self.name, "0", "5"]:
        comptime sel = cocoakb_p_selector_for[Self.cls, Self.name, "0", "5"]
        comptime assert _Kind[Self.cls, Self.name, "0", "5"] != _NOSUCH, (
            "no such method on this class taking this many arguments: the"
            " selector it would send is not one the SDK records. Check the"
            " spelling, the argument count, and that underscores line up with"
            " the selector's colons"
        )
        comptime assert _Kind[Self.cls, Self.name, "0", "5"] != _STRUCT, (
            "this selector returns a struct std.objc does not name; send it"
            " with msg_send and a register-passable result type"
        )
        return msg_send[
            _Result[Self.cls, Self.name, "0", "5"], Self.cls, sel,
        ](ObjCObject(self.id), a0, a1, a2, a3, a4)

    def __call__[
        T0: AnyType, T1: AnyType, T2: AnyType, T3: AnyType, T4: AnyType, T5: AnyType
    ](self, a0: T0, a1: T1, a2: T2, a3: T3, a4: T4, a5: T5) -> _Result[Self.cls, Self.name, "0", "6"]:
        comptime sel = cocoakb_p_selector_for[Self.cls, Self.name, "0", "6"]
        comptime assert _Kind[Self.cls, Self.name, "0", "6"] != _NOSUCH, (
            "no such method on this class taking this many arguments: the"
            " selector it would send is not one the SDK records. Check the"
            " spelling, the argument count, and that underscores line up with"
            " the selector's colons"
        )
        comptime assert _Kind[Self.cls, Self.name, "0", "6"] != _STRUCT, (
            "this selector returns a struct std.objc does not name; send it"
            " with msg_send and a register-passable result type"
        )
        return msg_send[
            _Result[Self.cls, Self.name, "0", "6"], Self.cls, sel,
        ](ObjCObject(self.id), a0, a1, a2, a3, a4, a5)


@fieldwise_init
struct BoundClass[cls: StringLiteral, name: StringLiteral](Copyable, Movable):
    """`Cls["NSString"].stringWithUTF8String(p)` -- the `+` side.

    Separate from `Bound` rather than a parameter on it because `is_class`
    reaches the database as a literal "0" or "1", and a parameter would have
    to be turned into one at comptime -- which is string surgery, which does
    not fold. Two types is the cheaper answer.
    """

    var cls_id: Int

    def __call__(self) -> _Result[Self.cls, Self.name, "1", "0"]:
        comptime sel = cocoakb_p_selector_for[Self.cls, Self.name, "1", "0"]
        comptime assert _Kind[Self.cls, Self.name, "1", "0"] != _NOSUCH, (
            "no such CLASS method on this class taking this many arguments: the"
            " selector it would send is not one the SDK records. Check the"
            " spelling, the argument count, and that underscores line up with"
            " the selector's colons"
        )
        comptime assert _Kind[Self.cls, Self.name, "1", "0"] != _STRUCT, (
            "this selector returns a struct std.objc does not name; send it"
            " with msg_send and a register-passable result type"
        )
        return msg_send[
            _Result[Self.cls, Self.name, "1", "0"], Self.cls, sel, is_class=True,
        ](ObjCObject(self.cls_id))

    def __call__[
        T0: AnyType
    ](self, a0: T0) -> _Result[Self.cls, Self.name, "1", "1"]:
        comptime sel = cocoakb_p_selector_for[Self.cls, Self.name, "1", "1"]
        comptime assert _Kind[Self.cls, Self.name, "1", "1"] != _NOSUCH, (
            "no such CLASS method on this class taking this many arguments: the"
            " selector it would send is not one the SDK records. Check the"
            " spelling, the argument count, and that underscores line up with"
            " the selector's colons"
        )
        comptime assert _Kind[Self.cls, Self.name, "1", "1"] != _STRUCT, (
            "this selector returns a struct std.objc does not name; send it"
            " with msg_send and a register-passable result type"
        )
        return msg_send[
            _Result[Self.cls, Self.name, "1", "1"], Self.cls, sel, is_class=True,
        ](ObjCObject(self.cls_id), a0)

    def __call__[
        T0: AnyType, T1: AnyType
    ](self, a0: T0, a1: T1) -> _Result[Self.cls, Self.name, "1", "2"]:
        comptime sel = cocoakb_p_selector_for[Self.cls, Self.name, "1", "2"]
        comptime assert _Kind[Self.cls, Self.name, "1", "2"] != _NOSUCH, (
            "no such CLASS method on this class taking this many arguments: the"
            " selector it would send is not one the SDK records. Check the"
            " spelling, the argument count, and that underscores line up with"
            " the selector's colons"
        )
        comptime assert _Kind[Self.cls, Self.name, "1", "2"] != _STRUCT, (
            "this selector returns a struct std.objc does not name; send it"
            " with msg_send and a register-passable result type"
        )
        return msg_send[
            _Result[Self.cls, Self.name, "1", "2"], Self.cls, sel, is_class=True,
        ](ObjCObject(self.cls_id), a0, a1)

    def __call__[
        T0: AnyType, T1: AnyType, T2: AnyType
    ](self, a0: T0, a1: T1, a2: T2) -> _Result[Self.cls, Self.name, "1", "3"]:
        comptime sel = cocoakb_p_selector_for[Self.cls, Self.name, "1", "3"]
        comptime assert _Kind[Self.cls, Self.name, "1", "3"] != _NOSUCH, (
            "no such CLASS method on this class taking this many arguments: the"
            " selector it would send is not one the SDK records. Check the"
            " spelling, the argument count, and that underscores line up with"
            " the selector's colons"
        )
        comptime assert _Kind[Self.cls, Self.name, "1", "3"] != _STRUCT, (
            "this selector returns a struct std.objc does not name; send it"
            " with msg_send and a register-passable result type"
        )
        return msg_send[
            _Result[Self.cls, Self.name, "1", "3"], Self.cls, sel, is_class=True,
        ](ObjCObject(self.cls_id), a0, a1, a2)

    def __call__[
        T0: AnyType, T1: AnyType, T2: AnyType, T3: AnyType
    ](self, a0: T0, a1: T1, a2: T2, a3: T3) -> _Result[Self.cls, Self.name, "1", "4"]:
        comptime sel = cocoakb_p_selector_for[Self.cls, Self.name, "1", "4"]
        comptime assert _Kind[Self.cls, Self.name, "1", "4"] != _NOSUCH, (
            "no such CLASS method on this class taking this many arguments: the"
            " selector it would send is not one the SDK records. Check the"
            " spelling, the argument count, and that underscores line up with"
            " the selector's colons"
        )
        comptime assert _Kind[Self.cls, Self.name, "1", "4"] != _STRUCT, (
            "this selector returns a struct std.objc does not name; send it"
            " with msg_send and a register-passable result type"
        )
        return msg_send[
            _Result[Self.cls, Self.name, "1", "4"], Self.cls, sel, is_class=True,
        ](ObjCObject(self.cls_id), a0, a1, a2, a3)

    def __call__[
        T0: AnyType, T1: AnyType, T2: AnyType, T3: AnyType, T4: AnyType
    ](self, a0: T0, a1: T1, a2: T2, a3: T3, a4: T4) -> _Result[Self.cls, Self.name, "1", "5"]:
        comptime sel = cocoakb_p_selector_for[Self.cls, Self.name, "1", "5"]
        comptime assert _Kind[Self.cls, Self.name, "1", "5"] != _NOSUCH, (
            "no such CLASS method on this class taking this many arguments: the"
            " selector it would send is not one the SDK records. Check the"
            " spelling, the argument count, and that underscores line up with"
            " the selector's colons"
        )
        comptime assert _Kind[Self.cls, Self.name, "1", "5"] != _STRUCT, (
            "this selector returns a struct std.objc does not name; send it"
            " with msg_send and a register-passable result type"
        )
        return msg_send[
            _Result[Self.cls, Self.name, "1", "5"], Self.cls, sel, is_class=True,
        ](ObjCObject(self.cls_id), a0, a1, a2, a3, a4)

    def __call__[
        T0: AnyType, T1: AnyType, T2: AnyType, T3: AnyType, T4: AnyType, T5: AnyType
    ](self, a0: T0, a1: T1, a2: T2, a3: T3, a4: T4, a5: T5) -> _Result[Self.cls, Self.name, "1", "6"]:
        comptime sel = cocoakb_p_selector_for[Self.cls, Self.name, "1", "6"]
        comptime assert _Kind[Self.cls, Self.name, "1", "6"] != _NOSUCH, (
            "no such CLASS method on this class taking this many arguments: the"
            " selector it would send is not one the SDK records. Check the"
            " spelling, the argument count, and that underscores line up with"
            " the selector's colons"
        )
        comptime assert _Kind[Self.cls, Self.name, "1", "6"] != _STRUCT, (
            "this selector returns a struct std.objc does not name; send it"
            " with msg_send and a register-passable result type"
        )
        return msg_send[
            _Result[Self.cls, Self.name, "1", "6"], Self.cls, sel, is_class=True,
        ](ObjCObject(self.cls_id), a0, a1, a2, a3, a4, a5)


struct Cls[cls: StringLiteral](Copyable, Movable):
    """The class object itself, for `+` methods: `Cls["NSColor"].blackColor()`.

    Constructed by looking the class up, which is why it takes no argument --
    a class is one thing in the process, not a value anyone holds.
    """

    var cls_id: Int

    def __init__(out self):
        self.cls_id = ObjCClass.lookup[StaticString(Self.cls.value)]().as_object().addr()

    def __getattr_param__[
        name: StringLiteral
    ](self) -> BoundClass[Self.cls, name]:
        return BoundClass[Self.cls, name](self.cls_id)

    def object(self) -> ObjCObject:
        return ObjCObject(self.cls_id)

    def is_nil(self) -> Bool:
        return self.cls_id == 0


@fieldwise_init
struct Obj[cls: StringLiteral](Copyable, Movable):
    """A reference to an Objective-C object, carrying its class in its type.

    The class is DECLARED, never inferred, because the only thing the runtime
    can be asked at compile time is what the database records. It is a
    parameter rather than a generated wrapper type, so every class the
    database knows is reachable without anything being generated.
    """

    var id: Int

    def __getattr_param__[name: StringLiteral](self) -> Bound[Self.cls, name]:
        """`obj.anything` -- the name arrives as a PARAMETER, which is what
        makes all of this possible.

        A plain `__getattr__` receives the name as a runtime `String`, and a
        runtime string cannot reach the database at compile time. This hook
        (the same mechanism `Tuple` uses for static indices) receives it as a
        parameter, so the selector, its existence, and the type of its result
        are all settled before the program runs.
        """
        return Bound[Self.cls, name](self.id)

    def object(self) -> ObjCObject:
        """The bare `id`, for the paths that still want one."""
        return ObjCObject(self.id)

    # ObjCObject's whole surface, so a typed result drops into code written
    # for an untyped one without that code changing. This is what makes
    # porting a call at a time possible instead of all at once.
    def is_nil(self) -> Bool:
        return self.id == 0

    def addr(self) -> Int:
        return self.id

    def ptr(self) -> OpaquePointer[MutUntrackedOrigin]:
        return ObjCObject(self.id).ptr()
