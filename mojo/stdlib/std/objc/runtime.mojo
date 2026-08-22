# ===----------------------------------------------------------------------=== #
# The Objective-C runtime seam.
#
# `id`, `Class`, and `SEL` are all pointers at the C ABI. std.objc keeps them
# as distinct wrapper structs so a selector can't be passed where an object is
# expected, but they lower to the same `objc_msgSend(id, SEL, ...)` call.
# ===----------------------------------------------------------------------=== #

from std.ffi import external_call, c_char
from std.memory import OpaquePointer
from std.sys.info import TrivialRegisterPassable
from std.sys._cocoakb import cocoakb_msgsend_variant


comptime _RawPtr = OpaquePointer[MutUntrackedOrigin]


@fieldwise_init
struct SEL(TrivialRegisterPassable):
    """A registered Objective-C selector (an interned string pointer)."""

    var _addr: Int

    def ptr(self) -> _RawPtr:
        return _RawPtr(unsafe_from_address=self._addr)


def sel[name: StaticString]() -> SEL:
    """Register (once) and return the selector for `name`.

    `sel_registerName` interns the name, so repeated calls return the same
    `SEL`.
    """
    return SEL(
        Int(external_call["sel_registerName", _RawPtr](name.unsafe_ptr()))
    )


@fieldwise_init
struct ObjCClass(TrivialRegisterPassable):
    """A handle on an Objective-C class object, looked up by name."""

    var _addr: Int

    @staticmethod
    def lookup[name: StaticString]() -> ObjCClass:
        return ObjCClass(
            Int(external_call["objc_getClass", _RawPtr](name.unsafe_ptr()))
        )

    def is_nil(self) -> Bool:
        return self._addr == 0

    def as_object(self) -> ObjCObject:
        return ObjCObject(self._addr)


@fieldwise_init
struct ObjCObject(TrivialRegisterPassable):
    """A borrowed `id`. Ownership arrives in P3 (ObjCRef); this is the raw
    handle the dispatch layer traffics in."""

    var _addr: Int

    def is_nil(self) -> Bool:
        return self._addr == 0

    def addr(self) -> Int:
        return self._addr

    def ptr(self) -> _RawPtr:
        return _RawPtr(unsafe_from_address=self._addr)


# ===----------------------------------------------------------------------=== #
# The message send.
#
# The variant is chosen at COMPILE time from the database. On x86-64:
#   objc_msgSend        -- integer/pointer/small returns
#   objc_msgSend_fpret  -- long double returns (x87)
#   objc_msgSend_stret  -- MEMORY returns (aggregates > 16 bytes): a hidden
#                          buffer pointer is passed in rdi, shifting self->rsi.
# P2 implements the register paths (plain + fpret). A struct return is a
# comptime error here until P2.1 wires the sret slot -- caught at compile
# time, never miscompiled into a silent stack corruption.
# ===----------------------------------------------------------------------=== #


# The dispatch problem: `objc_msgSend` is one C symbol called with a different
# signature at every call site, but a module can only declare a symbol once.
# So we take the ADDRESS of objc_msgSend once and call it through a
# per-signature function-pointer cast -- exactly what a C ObjC bridge does with
# `((R(*)(id,SEL,...))objc_msgSend)(...)`, and what std.ffi's own DLHandle
# callable does. No two call sites share a declared signature, so nothing
# collides.
#
# The variant (plain / fpret / stret) is still chosen at COMPILE time from the
# database; a struct-return or unmodelable send is a compile error, never a
# silent miscompile.


@always_inline
def _stub_addr[cls: StaticString, selector: StaticString, is_class: Bool]() -> (
    Int
):
    """Resolve, at comptime, WHICH objc_msgSend variant this send needs, and
    return the runtime address of that stub. A non-register return is a
    compile error."""
    comptime variant = cocoakb_msgsend_variant[cls, selector, is_class]()
    comptime assert variant != "?", (
        "std.objc: '"
        + selector
        + "' on "
        + cls
        + " has an @encode signature the ABI classifier could not model, so"
        + " std.objc cannot pick a dispatch stub for it. Call it by hand with"
        + " a checked external_call if you know the layout."
    )
    # objc_msgSend / _fpret / _stret are all reached through the same
    # per-signature function-pointer cast below; the C ABI does the register
    # allocation, the x87 return, or the hidden sret pointer + self/_cmd shift
    # according to the RETURN TYPE R the caller declares. The database only has
    # to tell us WHICH entry point, which it does.
    # RTLD_DEFAULT is (void*)-2 on macOS.
    var rtld_default = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=Int(-2)
    )
    var name = String(variant)
    var stub_fn = external_call["dlsym", OpaquePointer[MutUntrackedOrigin]](
        rtld_default, name.as_c_string_slice()
    )
    return Int(stub_fn)


def msg_send[
    R: AnyType, cls: StaticString, selector: StaticString, is_class: Bool = False, *Ts: AnyType
](obj: ObjCObject, *args: *Ts) -> R:
    """Send `selector` to `obj`, returning `R`.

    The ABI stub is chosen from the metadata for (`cls`, `selector`); an
    unknown selector on `cls` or its superclasses, or a struct-return that the
    register path cannot carry, is a compile error.

    Parameters:
        R: The return type (register-passable).
        cls: The class the selector is looked up on.
        selector: The selector to send.
        is_class: True for a class (+) method.
        Ts: The argument types.
    """
    var stub = _stub_addr[cls, selector, is_class]()
    var s = sel[selector]().ptr()
    # Cast the stub address to the exact function-pointer type for this call
    # site and invoke it. `id, SEL` precede the message arguments.
    var call = Pointer(to=stub).unsafe_bitcast[
        def(_RawPtr, _RawPtr, /, *a: *Ts) thin abi("C") -> R
    ]()[]
    return call(obj.ptr(), s, *args)
# ===----------------------------------------------------------------------=== #
# Autorelease pools.
# ===----------------------------------------------------------------------=== #


struct autoreleasepool:
    """A scoped Objective-C autorelease pool.

    ```mojo
    with autoreleasepool():
        # autoreleased objects created here are drained on exit
        ...
    ```
    """

    var _token: Int

    def __init__(out self):
        self._token = 0

    def __enter__(mut self):
        self._token = Int(
            external_call["objc_autoreleasePoolPush", _RawPtr]()
        )

    def __exit__(mut self):
        external_call["objc_autoreleasePoolPop", NoneType](
            _RawPtr(unsafe_from_address=self._token)
        )
