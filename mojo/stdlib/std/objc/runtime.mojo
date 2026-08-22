# ===----------------------------------------------------------------------=== #
# The Objective-C runtime seam.
#
# `id`, `Class`, and `SEL` are all pointers at the C ABI. std.objc keeps them
# as distinct wrapper structs so a selector can't be passed where an object is
# expected, but they lower to the same `objc_msgSend(id, SEL, ...)` call.
# ===----------------------------------------------------------------------=== #

from std.ffi import external_call, c_char, _get_global_or_null
from std.memory import OpaquePointer
from std.reflection import reflect
from std.sys.info import TrivialRegisterPassable
from std.collections.string.string_span import _get_kgen_string
from std.sys._cocoakb import (
    cocoakb_msgsend_variant,
    cocoakb_method_arg_classes,
    cocoakb_selector_variant,
    cocoakb_selector_arg_classes,
)


comptime _RawPtr = OpaquePointer[MutUntrackedOrigin]


@fieldwise_init
struct SEL(TrivialRegisterPassable):
    """A registered Objective-C selector (an interned string pointer)."""

    var _addr: Int

    def ptr(self) -> _RawPtr:
        return _RawPtr(unsafe_from_address=self._addr)


@always_inline
def _sel_slot[name: StaticString]() -> Pointer[Int, MutUntrackedOrigin]:
    """A persistent, per-selector global holding the resolved SEL (0 until
    first resolved). Deduped by name in the KGEN lowering, so every call site
    for a given selector shares one slot -- a single load, not a hash lookup."""
    comptime slot_name = StaticString(
        _get_kgen_string["vega.objc.selslot/", name]()
    )
    return Pointer[Int, MutUntrackedOrigin](
        _mlir_value=__mlir_op.`pop.global_alloc`[
            name=_get_kgen_string[slot_name](),
            count=Int(1).__mlir_index__(),
            _type=Pointer[Int, MutUntrackedOrigin]._mlir_type,
            alignment=Int(8).__mlir_index__(),
        ]()
    )


@always_inline
def sel[name: StaticString]() -> SEL:
    """Register (once) and return the selector for `name`.

    The resolved SEL is cached in a per-selector global slot, so after the
    first send the cost is one load and a branch-predicted-away null check --
    no hash lookup, no runtime registry.
    """
    var slot = _sel_slot[name]()
    var cached = slot[]
    if cached != 0:
        return SEL(cached)
    var registered = Int(
        external_call["sel_registerName", _RawPtr](name.unsafe_ptr())
    )
    slot[] = registered
    return SEL(registered)


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
def _count_arg_classes(classes: StaticString) -> Int:
    """Count the message arguments a selector takes, from its comma-separated
    SysV class string ("" = none, "g" = one, "g,g" = two). Runs at comptime."""
    var bytes = classes.as_bytes()
    if len(bytes) == 0:
        return 0
    var n = 1
    for i in range(len(bytes)):
        if bytes[i] == UInt8(ord(",")):
            n += 1
    return n


# Classify the n-th comma-separated ABI field of `classes` without building a
# substring (awkward at comptime): 0 = absent, 1 = purely SSE (every eightbyte
# 'f', a float register), 2 = anything else (integer/pointer/struct/memory).
@always_inline
def _nth_class_kind(classes: StaticString, n: Int) -> Int:
    var bytes = classes.as_bytes()
    var field = 0
    var start = 0
    for i in range(len(bytes) + 1):
        var at_sep = i == len(bytes) or bytes[i] == UInt8(ord(","))
        if at_sep:
            if field == n:
                if i == start:
                    return 0  # empty field
                var all_f = True
                for j in range(start, i):
                    if bytes[j] != UInt8(ord("f")):
                        all_f = False
                return 1 if all_f else 2
            field += 1
            start = i + 1
    return 0


@always_inline
def _type_is_float(name: StaticString) -> Bool:
    """A conservative float test on a reflected type name: true only for the
    scalar float SIMD types, so we never mis-flag a pointer or integer."""
    return (
        name == "SIMD[DType.float64, 1]"
        or name == "SIMD[DType.float32, 1]"
        or name == "SIMD[DType.float16, 1]"
        or name == "SIMD[DType.bfloat16, 1]"
    )


@always_inline
def _type_is_scalar_int(name: StaticString) -> Bool:
    """True only for the plain scalar integer types we can be sure about."""
    return name == "SIMD[DType.int, 1]" or name == "SIMD[DType.index, 1]"


@always_inline
def _stub_ptr[cls: StaticString, selector: StaticString, is_class: Bool]() -> (
    _RawPtr
):
    """A link-time reference to the objc_msgSend variant this send needs.

    The variant is chosen at COMPILE time from the database; the stub is a
    linked libobjc symbol, so `pop.extern_ptr_symbol` resolves its address as a
    relocation -- no dlsym, no cache, no per-call cost. (The KGEN lowering was
    fixed to dedup a shared external name across call sites; before that, the
    symbol uniquer renamed it to objc_msgSend_0/_1 and it failed to link.) Only
    an unmodelable ("?") signature is a compile error.
    """
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
    # per-signature function-pointer cast at the call site; the C ABI does the
    # register allocation, x87 return, or hidden sret pointer according to the
    # RETURN TYPE the caller declares. The database only picks WHICH symbol.
    return _RawPtr(
        _mlir_value=__mlir_op.`pop.extern_ptr_symbol`[
            name=_get_kgen_string[variant](),
            alignment=Int(1).__mlir_index__(),
            _type=_RawPtr._mlir_type,
        ]()
    )

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
    # The selector's declared argument count, from the database. A call that
    # passes the wrong number of message arguments would otherwise read
    # garbage from an unset register or the stack -- caught here at comptime.
    comptime expected = _count_arg_classes(
        cocoakb_method_arg_classes[cls, selector, is_class]()
    )
    comptime assert args.__len__() == expected, (
        "std.objc: '"
        + selector
        + "' on "
        + cls
        + " takes "
        + String(expected)
        + " argument(s), but "
        + String(args.__len__())
        + " were passed."
    )
    # Per-argument register-file check: a float passed where the ABI wants an
    # integer register (or the reverse) is a silent xmm-vs-rdi corruption. We
    # only flag the cases we are certain of -- a scalar float vs a purely-SSE
    # class -- and skip structs/unknowns, so there are no false positives.
    comptime arg_classes = cocoakb_method_arg_classes[cls, selector, is_class]()
    comptime for i in range(args.__len__()):
        comptime name = reflect[Ts[i]].name()
        comptime kind = _nth_class_kind(arg_classes, i)
        # kind: 1 = float register expected, 2 = integer/pointer/struct.
        comptime if _type_is_float(name) and kind == 2:
            comptime assert False, (
                "std.objc: argument "
                + String(i)
                + " of '"
                + selector
                + "' on "
                + cls
                + " is a float, but the ABI expects an integer/pointer"
                + " register here. Check the argument type."
            )
        comptime if _type_is_scalar_int(name) and kind == 1:
            comptime assert False, (
                "std.objc: argument "
                + String(i)
                + " of '"
                + selector
                + "' on "
                + cls
                + " is an integer, but the ABI expects a float register here."
                + " Pass a Float32/Float64."
            )
    var stub = _stub_ptr[cls, selector, is_class]()
    var s = sel[selector]().ptr()
    # Cast the stub symbol to the exact function-pointer type for this call site
    # and invoke it. `id, SEL` precede the message arguments.
    var call = Pointer(to=stub).unsafe_bitcast[
        def(_RawPtr, _RawPtr, /, *a: *Ts) thin abi("C") -> R
    ]()[]
    return call(obj.ptr(), s, *args)
@always_inline
def _sel_stub_ptr[selector: StaticString]() -> _RawPtr:
    """The objc_msgSend variant for a selector, resolved from the database by
    selector alone (for protocol-typed receivers). A link-time symbol, same as
    the class-keyed path."""
    comptime variant = cocoakb_selector_variant[selector]()
    comptime assert variant != "?" and variant != "", (
        "std.objc: no class in the metadata implements selector '"
        + selector
        + "', so its dispatch ABI is unknown. Check the selector spelling."
    )
    return _RawPtr(
        _mlir_value=__mlir_op.`pop.extern_ptr_symbol`[
            name=_get_kgen_string[variant](),
            alignment=Int(1).__mlir_index__(),
            _type=_RawPtr._mlir_type,
        ]()
    )


def send[
    R: AnyType, selector: StaticString, *Ts: AnyType
](obj: ObjCObject, *args: *Ts) -> R:
    """Send `selector` to a PROTOCOL-typed object, returning `R`.

    Like `msg_send`, but the receiver's concrete class is unknown at compile
    time -- as for every Metal object (`id<MTLDevice>`, `id<MTLTexture>`, ...)
    and Cocoa delegate. The ABI stub and argument classes come from the
    database keyed by the SELECTOR (consistent across implementing classes), so
    dispatch, arg count and register file are still checked; only the receiver
    class is not.
    """
    comptime arg_classes = cocoakb_selector_arg_classes[selector]()
    comptime expected = _count_arg_classes(arg_classes)
    comptime assert args.__len__() == expected, (
        "std.objc: selector '"
        + selector
        + "' takes "
        + String(expected)
        + " argument(s), but "
        + String(args.__len__())
        + " were passed."
    )
    comptime for i in range(args.__len__()):
        comptime name = reflect[Ts[i]].name()
        comptime kind = _nth_class_kind(arg_classes, i)
        comptime if _type_is_float(name) and kind == 2:
            comptime assert False, (
                "std.objc: argument " + String(i) + " of '" + selector
                + "' is a float, but the ABI expects an integer/pointer"
                + " register here."
            )
        comptime if _type_is_scalar_int(name) and kind == 1:
            comptime assert False, (
                "std.objc: argument " + String(i) + " of '" + selector
                + "' is an integer, but the ABI expects a float register here."
            )
    var stub = _sel_stub_ptr[selector]()
    var s = sel[selector]().ptr()
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
