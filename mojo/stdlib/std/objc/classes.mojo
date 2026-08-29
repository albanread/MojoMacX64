# ===----------------------------------------------------------------------=== #
# Defining Objective-C classes from Mojo -- so Cocoa can call BACK into Mojo.
#
# Target/action, delegates, notification observers and timers all work by
# Cocoa sending a selector to an object you supplied. To supply one, define a
# class at runtime (objc_allocateClassPair), add methods whose implementations
# are Mojo `abi("C")` functions (class_addMethod), and register it. The method
# type encoding -- the string that tells the runtime the ABI -- comes from the
# SDK database for any known selector, so even a callback's signature is not
# hand-typed; custom selectors pass theirs explicitly.
# ===----------------------------------------------------------------------=== #

from std.ffi import external_call
from std.memory import OpaquePointer
from std.collections.string.string_span import _get_kgen_string
from std.sys._cocoakb import cocoakb_selector_encoding
from .runtime import (
    ObjCClass,
    ObjCObject,
    msg_send,
    sel,
    load_framework_dynamic,
)


comptime P = OpaquePointer[MutUntrackedOrigin]

# The IMP shapes a Cocoa callback takes: (self, _cmd) then the message args.
comptime IMP0 = def(P, P, /) thin abi("C") -> None
comptime IMP1 = def(P, P, P, /) thin abi("C") -> None
comptime IMP0Bool = def(P, P, /) thin abi("C") -> Bool
comptime IMP1Bool = def(P, P, P, /) thin abi("C") -> Bool
comptime IMP2 = def(P, P, P, P, /) thin abi("C") -> None


def _strip_offsets(enc: StaticString) -> String:
    """"v24@0:8@16" -> "v@:@": the runtime's @encode carries frame offsets
    that class_addMethod does not want."""
    var out = String()
    var b = enc.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
            continue
        out += chr(Int(c))
    return out


def _leak_cstr(s: String) -> P:
    """A heap copy that lives for the process: class_addMethod keeps the
    types pointer, so it must outlive any Mojo value."""
    var local = s
    return external_call["strdup", P](local.as_c_string_slice())


struct ObjCClassBuilder[superclass: StaticString = "NSObject"]:
    """Builds an Objective-C class at runtime.

    ```mojo
    var b = ObjCClassBuilder("MyDelegate")            # subclass of NSObject
    var v = ObjCClassBuilder["NSView"]("MyView")      # or any other class
    b.add_method["applicationDidFinishLaunching:"](did_launch)   # encoding from the SDK
    b.add_method["buttonClicked:", encoding="v@:@"](clicked)      # custom selector
    var cls = b^.register()
    var delegate = new_instance(cls)
    ```
    """

    var _cls: Int
    var _name: String

    def __init__(out self, name: String):
        var sup = ObjCClass.lookup[Self.superclass]()
        var local = name
        var cls = external_call["objc_allocateClassPair", P](
            P(unsafe_from_address=sup.as_object().addr()),
            local.as_c_string_slice(),
            Int(0),
        )
        self._cls = Int(cls)
        self._name = name

    def _add(mut self, selector: StaticString, encoding: String, imp: P):
        var s = sel_dynamic(selector)
        var types = _leak_cstr(encoding)
        _ = external_call["class_addMethod", Bool](
            P(unsafe_from_address=self._cls), s, imp, types
        )

    # One overload per IMP shape. The encoding defaults to the SDK's for the
    # selector; pass `encoding=` for a selector the SDK does not know.
    def add_method[
        selector: StaticString, encoding: StaticString = ""
    ](mut self, imp: IMP0):
        self._add(selector, _encoding_for[selector, encoding](), _imp_ptr(imp))

    def add_method[
        selector: StaticString, encoding: StaticString = ""
    ](mut self, imp: IMP1):
        self._add(selector, _encoding_for[selector, encoding](), _imp_ptr(imp))

    def add_method[
        selector: StaticString, encoding: StaticString = ""
    ](mut self, imp: IMP0Bool):
        self._add(selector, _encoding_for[selector, encoding](), _imp_ptr(imp))

    def add_method[
        selector: StaticString, encoding: StaticString = ""
    ](mut self, imp: IMP1Bool):
        self._add(selector, _encoding_for[selector, encoding](), _imp_ptr(imp))

    def add_method[
        selector: StaticString, encoding: StaticString = ""
    ](mut self, imp: IMP2):
        self._add(selector, _encoding_for[selector, encoding](), _imp_ptr(imp))

    def register(deinit self) -> ObjCClass:
        """Finish the class; it can be instantiated after this."""
        external_call["objc_registerClassPair", NoneType](
            P(unsafe_from_address=self._cls)
        )
        return ObjCClass(self._cls)


@always_inline
def _encoding_for[selector: StaticString, encoding: StaticString]() -> String:
    comptime if encoding == "":
        # Known selector: the SDK's @encode, offsets stripped. An unknown
        # selector here is a compile error ("pass encoding=").
        comptime enc = cocoakb_selector_encoding[selector]()
        return _strip_offsets(enc)
    else:
        return String(encoding)


@always_inline
def _imp_ptr[F: AnyType](imp: F) -> P:
    """A function value as an opaque IMP pointer (the DLHandle bitcast trick,
    in reverse)."""
    return Pointer(to=imp).unsafe_bitcast[P]()[]


comptime BOX_IVAR = "__mojo_box"


def box_offset(cls: ObjCClass) -> Int:
    """Where the box pointer sits inside an instance, in bytes.

    Read once per class after registration and cached by the caller: the
    runtime settles it when the class is registered, and it does not move.
    Returns 0 if the class has no box, which no caller should be asking about.
    """
    var ivar = external_call["class_getInstanceVariable", P](
        P(unsafe_from_address=cls.as_object().addr()),
        _leak_cstr(String(BOX_IVAR)),
    )
    if Int(ivar) == 0:
        return 0
    return external_call["ivar_getOffset", Int](ivar)


def sel_dynamic(name: StaticString) -> P:
    """Register a selector by name at runtime (custom selectors included)."""
    return external_call["sel_registerName", P](name.unsafe_ptr())


def new_instance(cls: ObjCClass) -> ObjCObject:
    """`+[cls new]` -- an owned (+1) instance of a runtime-defined class."""
    return msg_send[ObjCObject, "NSObject", "new", is_class=True](
        cls.as_object()
    )


def named_global[name: StaticString, T: AnyType]() -> Pointer[
    T, MutUntrackedOrigin
]:
    """A zero-initialised process global of type T, shared by name across every
    call site -- app state that Cocoa callbacks (which get no closure) can
    reach. One storage location per name (KGEN dedups the global)."""
    comptime slot = StaticString(_get_kgen_string["vega.objc.global/", name]())
    return Pointer[T, MutUntrackedOrigin](
        _mlir_value=__mlir_op.`pop.global_alloc`[
            name=_get_kgen_string[slot](),
            count=Int(1).__mlir_index__(),
            _type=Pointer[T, MutUntrackedOrigin]._mlir_type,
            alignment=Int(8).__mlir_index__(),
        ]()
    )

struct ObjCClassRegistrar:
    """Builds an Objective-C class from values known only at run time.

    This is the compiler's entry point for `class` (COCOA_CLASS_DESIGN.md).
    `ObjCClassBuilder` above is the one to use by hand: its selector and
    superclass are compile-time parameters, so it can check them against the
    SDK and pick an IMP overload. The compiler has already done all of that --
    it derived the selector, looked the encoding up in the database, and found
    the framework -- so what it needs is the opposite shape: every value an
    ordinary argument, because emitting a call with plain arguments is far
    simpler than emitting a parametric one.

    Order matters and is the compiler's responsibility: frameworks first, or
    `objc_getClass` returns nil for the superclass and the pair is allocated
    against nothing, which yields a root class that silently does nothing.
    """

    var _cls: Int
    var _ok: Bool
    var _existing: Bool
    var _has_box: Bool

    def __init__(
        out self,
        name: StringSlice,
        superclass: StringSlice,
        frameworks: StringSlice = "",
    ):
        """`frameworks` is a comma-separated list, loaded before anything else.

        One argument rather than a separate call per framework, and the order
        is not a detail: `objc_getClass` returns nil for a superclass whose
        framework is not in the process, and allocating a pair against nil
        yields a root class that answers nothing. Loading has to happen before
        the lookup below, so it happens here.
        """
        for framework in frameworks.split(","):
            if framework.byte_length() > 0:
                _ = load_framework_dynamic(framework)

        # A class is registered once per process, but the synthesized __init__
        # that registers it runs once per instance. Finding it already there is
        # the ordinary case after the first, and costs one lookup.
        var already = external_call["objc_getClass", P](
            _leak_cstr(String(name))
        )
        if Int(already) != 0:
            self._cls = Int(already)
            self._ok = True
            self._existing = True
            self._has_box = False
            return
        self._existing = False
        self._has_box = False

        var sup = external_call["objc_getClass", P](
            _leak_cstr(String(superclass))
        )
        if Int(sup) == 0:
            # Registering against a nil superclass would build a root class
            # that answers nothing. Refuse, and let `register` report it.
            self._cls = 0
            self._ok = False
            self._existing = False
            self._has_box = False
            return
        var cls = external_call["objc_allocateClassPair", P](
            sup, _leak_cstr(String(name)), Int(0)
        )
        self._cls = Int(cls)
        self._ok = Int(cls) != 0
        self._has_box = False

    def add_method[
        F: AnyType
    ](mut self, selector: StringSlice, encoding: StringSlice, imp: F) -> Bool:
        """`imp` is the C-ABI trampoline the compiler synthesized.

        Taken as a function value rather than an already-converted pointer so
        that `_imp_ptr` -- which is a bitcast Mojo knows how to spell and the
        compiler would otherwise have to emit five operations for -- stays on
        this side of the boundary.
        """
        if not self._ok or self._existing:
            return False
        return external_call["class_addMethod", Bool](
            P(unsafe_from_address=self._cls),
            external_call["sel_registerName", P](
                _leak_cstr(String(selector))
            ),
            _imp_ptr(imp),
            _leak_cstr(String(encoding)),
        )

    def add_protocol(mut self, name: StringSlice) -> Bool:
        """Conformance is not the same as implementing the methods: AppKit
        asks `conformsToProtocol:` -- NSTextInputClient among them -- and
        refuses a class that only responds to the selectors."""
        if not self._ok or self._existing:
            return False
        var proto = external_call["objc_getProtocol", P](
            _leak_cstr(String(name))
        )
        if Int(proto) == 0:
            return False
        return external_call["class_addProtocol", Bool](
            P(unsafe_from_address=self._cls), proto
        )

    def add_box(mut self, size: __mlir_type.index) -> Bool:
        """Reserve the instance variable that holds a class's fields.

        One ivar, a pointer to a Mojo struct -- not one ivar per field. The
        box is ordinary Mojo memory, so a field can be any Mojo type rather
        than only what Objective-C ivar layout can describe, and construction
        and destruction happen where Mojo expects them.

        Must be called before `register`: the runtime refuses to add an ivar
        to a registered class, and says so by returning false.

        `size` is a raw `index` because the compiler hands it over as
        `#kgen.param.expr<get_sizeof, ...>` -- a comptime expression the
        elaborator resolves after layout -- and an unresolved expression will
        not wrap in an `Int` the way a literal would.
        """
        if not self._ok or self._existing:
            return False
        self._has_box = True
        return external_call["class_addIvar", Bool](
            P(unsafe_from_address=self._cls),
            _leak_cstr(String(BOX_IVAR)),
            Int(SIMDLength(mlir_value=size)),
            UInt8(3),  # log2 alignment: 8 bytes
            _leak_cstr(String("^v")),
        )

    def register(mut self) -> ObjCClass:
        """Finish the class. Returns a null ObjCClass if anything above
        failed, which is what a caller should check before instantiating."""
        if not self._ok:
            return ObjCClass(0)
        if not self._existing:
            external_call["objc_registerClassPair", NoneType](
                P(unsafe_from_address=self._cls)
            )
        return ObjCClass(self._cls)

    def box_offset_of(mut self) -> Int:
        """Where this class's box sits inside an instance.

        Read after registration, when the runtime has settled it; the compiler
        caches the answer in a per-class global because a trampoline has only
        an `id` to work from and cannot afford three runtime calls per message.
        """
        if not self._ok:
            return 0
        return box_offset(ObjCClass(self._cls))

    def register_and_instantiate(mut self) -> Int:
        """Finish the class and return the `id` of a fresh instance.

        One call because it is what a class's synthesized `__init__` needs and
        nothing else does: every step the compiler would otherwise emit --
        register, allocate, unwrap -- with no intermediate value it has to
        find a type for. Returns 0 if the class could not be built, which the
        caller sees as a nil instance rather than a crash.
        """
        var cls = self.register()
        if cls.as_object().addr() == 0:
            return 0
        return new_instance(cls).addr()
