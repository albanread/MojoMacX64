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
from .runtime import ObjCClass, ObjCObject, msg_send, sel


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
