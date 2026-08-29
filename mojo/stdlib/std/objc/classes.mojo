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
from std.memory import OpaquePointer, MutPointer, unsafe_destroy_n
from std.collections.string.string_span import _get_kgen_string
from std.sys._cocoakb import cocoakb_selector_encoding
from .runtime import ObjCClass, ObjCObject, msg_send, sel, load_framework_dynamic
from std.reflection import reflect


comptime P = OpaquePointer[MutUntrackedOrigin]

# The IMP shapes a Cocoa callback takes: (self, _cmd) then the message args.
# The revived `fn` in type position: sugar for `def(...) thin abi("C")`, i.e.
# exactly what an IMP is. (self, _cmd) precede the message arguments.
comptime IMP0 = fn(P, P, /) -> None
comptime IMP1 = fn(P, P, P, /) -> None
comptime IMP0Bool = fn(P, P, /) -> Bool
comptime IMP1Bool = fn(P, P, P, /) -> Bool
comptime IMP2 = fn(P, P, P, P, /) -> None

# Methods that answer with an object. Every shape above returns void or BOOL,
# which covers actions and lifecycle callbacks but not the delegate protocols
# that are asked *for* something -- a toolbar delegate returns an NSArray of
# identifiers and then an NSToolbarItem, an outline view's data source returns
# each child.
#
# These return `Int`, not a pointer, and the reason is a real disagreement
# between the two type systems rather than a shortcut. Objective-C delegates
# must be able to answer nil -- "I have no item for that identifier" is a
# normal answer, not an error -- and Mojo's Pointer is non-nullable by
# construction: `Pointer(unsafe_from_address=0)` is rejected at comptime with
# "use Optional[Pointer] to model nullability". Optional is the right answer
# inside Mojo and the wrong one at an ABI boundary, where the C signature is a
# single pointer-sized register.
#
# So the return is an `id` as an address: `obj.addr()` for an object, plain `0`
# for nil. Identical ABI, and the nullability stays where Objective-C put it.
comptime IMP1Obj = fn(P, P, P, /) -> Int
comptime IMP2Obj = fn(P, P, P, P, /) -> Int
comptime IMP3Obj = fn(P, P, P, P, P, /) -> Int

# The counting half of a data source -- numberOfChildrenOfItem: and relatives
# -- has the same shape, since an NSInteger and an id-as-address are the same
# register. Aliases rather than distinct types, so the name at a call site can
# say which one is meant without adding an ambiguous overload.
comptime IMP1Int = IMP1Obj
comptime IMP2Int = IMP2Obj

# One mixed shape the toolbar needs by name: the trailing BOOL of
# toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:.
comptime IMP2ObjBool = fn(P, P, P, P, Bool, /) -> Int


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

    def add_method[
        selector: StaticString, encoding: StaticString = ""
    ](mut self, imp: IMP1Obj):
        self._add(selector, _encoding_for[selector, encoding](), _imp_ptr(imp))

    def add_method[
        selector: StaticString, encoding: StaticString = ""
    ](mut self, imp: IMP2Obj):
        self._add(selector, _encoding_for[selector, encoding](), _imp_ptr(imp))

    def add_method[
        selector: StaticString, encoding: StaticString = ""
    ](mut self, imp: IMP3Obj):
        self._add(selector, _encoding_for[selector, encoding](), _imp_ptr(imp))

    def add_method[
        selector: StaticString, encoding: StaticString = ""
    ](mut self, imp: IMP2ObjBool):
        self._add(selector, _encoding_for[selector, encoding](), _imp_ptr(imp))

    def add_method_unchecked[
        selector: StaticString, encoding: StaticString = "", F: AnyType = NoneType
    ](mut self, imp: F):
        """Add a method of any signature, with no shape checking.

        The typed overloads above cover what Cocoa mostly asks for. They cannot
        cover everything: NSTextInputClient's `selectedRange` returns an NSRange
        by value, `insertText:replacementRange:` takes one, and
        `firstRectForCharacterRange:actualRange:` returns an NSRect. Struct
        arguments and returns are ordinary arm64 register passing, but each is a
        distinct function type and enumerating them in the stdlib would be a
        list with no end.

        So this takes the function as-is. The encoding is what tells the runtime
        the real signature, and getting it wrong is a mis-marshalled call rather
        than a compile error -- which is why this is named for what it does not
        do. Prefer a typed overload where one fits.
        """
        self._add(selector, _encoding_for[selector, encoding](), _imp_ptr(imp))

    def add_protocol[name: StaticString](mut self) -> Bool:
        """Declare that this class conforms to a protocol.

        Implementing a protocol's methods is not the same as conforming to it.
        AppKit asks `conformsToProtocol:` in places -- NSTextInputClient among
        them -- and a class that only responds to the selectors is refused.
        Returns False if the protocol is not registered in this process, which
        usually means the framework defining it has not been loaded.
        """
        var proto = external_call["objc_getProtocol", P](
            _leak_cstr(String(name))
        )
        if Int(proto) == 0:
            return False
        return external_call["class_addProtocol", Bool](
            P(unsafe_from_address=self._cls), proto
        )

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
            # Ask the runtime, do not assume. Everything else on this path is
            # skipped for an already-registered class -- the ivar, the
            # methods, the protocols are all there from the first instance --
            # but the BOX still has to be constructed, once per instance, and
            # `box_of` will not hand out its address unless this says there is
            # one. Getting this wrong gave the first instance its field
            # initializers and every instance after it a box of zeroes.
            #
            # Offset zero means no box: an ivar can never live there, because
            # that is where the isa pointer is.
            self._has_box = box_offset(ObjCClass(Int(already)), name) != 0
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

    def __init__(
        out self,
        name: StringSlice,
        superclass: StringSlice,
        frameworks: StringSlice,
        ensure_super: fn () -> None,
    ):
        """As above, but the superclass is another Mojo `class`.

        A Mojo class does not exist in the runtime until something registers
        it, and registration is lazy: it happens the first time that class is
        instantiated. So `class B(A)` instantiated before any `A` ever was
        would resolve its superclass to nil and allocate its pair against
        nothing -- a root class, answering nothing, with no diagnostic. This
        is where that is prevented.

        `ensure_super` is compiler-synthesized and does exactly one thing:
        construct an instance of the base, which registers it. It is called
        only when the runtime does not have the class yet, so the cost is one
        base instance per PROCESS, not per subclass instantiation. That
        instance is not released -- there is no one to release it -- which is
        the same bargain the class objects themselves make.
        """
        if (
            Int(external_call["objc_getClass", P](_leak_cstr(String(superclass))))
            == 0
        ):
            ensure_super()
        self = Self(name, superclass, frameworks)


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

    def add_class_method[
        F: AnyType
    ](mut self, selector: StringSlice, encoding: StringSlice, imp: F) -> Bool:
        """A `+` method, which lives on the METACLASS.

        `objc_getClass("NSView")` answers the class object; the class object's
        own class is the metaclass, and that is where a class method's IMP
        belongs. Adding it to the class instead would make `[view foo]` work
        and `[NSView foo]` fail, which is exactly backwards and exactly the
        kind of thing that looks like it worked.

        The receiver such a method is sent is the CLASS object, not an
        instance, so there is no box to find and nothing to convert -- the
        compiler's trampoline for one is the simplest in the file.
        """
        if not self._ok or self._existing:
            return False
        var meta = external_call["object_getClass", P](
            P(unsafe_from_address=self._cls)
        )
        return external_call["class_addMethod", Bool](
            meta,
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

    def add_box(
        mut self, size: __mlir_type.index, class_name: StringSlice
    ) -> Bool:
        """Reserve the instance variable that holds a class's fields.

        One ivar, a pointer to a Mojo struct -- not one ivar per field. The
        box is ordinary Mojo memory, so a field can be any Mojo type rather
        than only what Objective-C ivar layout can describe, and construction
        and destruction happen where Mojo expects them. See
        COCOA_CLASS_DESIGN.md.

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
            _leak_cstr(box_ivar_name(class_name)),
            Int(SIMDLength(mlir_value=size)),
            UInt8(3),  # log2 alignment: 8 bytes
            _leak_cstr(String("^v")),
        )

    def add_dealloc[T: Deinitable](mut self, ref witness: T) -> Bool:
        """Register the `dealloc` that destroys this class's box.

        `witness` is never read. It is there because the box's type is what
        this needs and the compiler has no way to spell an explicit type
        parameter in a synthesized call -- but it does have `self`, and a
        borrow of it carries the type. Every other parameter on this struct
        arrived the same way `add_method`'s did: inferred from an argument.

        Must come before `register`, like everything else here.
        """
        if not self._ok or self._existing or not self._has_box:
            return False
        # The channel to the IMP: see `_DEFINING_CLASS_PREFIX`.
        comptime slot = StaticString(
            _get_kgen_string[_DEFINING_CLASS_PREFIX, reflect[T].base_name()]()
        )
        named_global[slot, Int]()[] = self._cls
        return self.add_method("dealloc", "v@:", _box_dealloc_imp[T])

    def box_of(
        mut self, id: Int, size: __mlir_type.index, class_name: StringSlice
    ) -> P:
        """Where an instance's box lives, as a POINTER.

        The compiler needs to construct the fields into the box, and for that
        it needs an address it can offset and bitcast. It has the `id` as a
        Mojo `Int`, and there is no int-to-pointer operation at that level --
        Mojo itself spells it as a bitcast through a local -- so the crossing
        happens here, once, in a language that can say it in a line.

        On the failure path -- a class that would not register, so a nil
        instance -- this returns `size` bytes of scratch instead. It cannot
        return nothing: `Pointer` is non-nullable by construction, and the
        caller is compiler-emitted straight-line code with nowhere to branch
        to. The fields are constructed into memory that is then abandoned,
        which costs one allocation in a program that is already broken (its
        class does not exist) and avoids writing through a null pointer to
        say so.
        """
        var bytes = Int(SIMDLength(mlir_value=size))
        # Looked up by NAME on the instance's class, not gated on `_has_box`:
        # a derived class also constructs its BASE's box, and that ivar
        # belongs to the base. The runtime walks the chain to find it.
        if id != 0 and self._ok:
            var off = box_offset(ObjCClass(self._cls), class_name)
            if off != 0:
                return P(unsafe_from_address=id + off)
        return P(
            unsafe_from_address=Int(
                external_call["malloc", P](bytes)
            )
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


    def box_offset_of(mut self, class_name: StringSlice) -> Int:
        """Where this class's box sits inside an instance.

        Read after registration, when the runtime has settled it; the compiler
        caches the answer in a per-class global because a trampoline has only
        an `id` to work from and cannot afford three runtime calls per message.
        """
        if not self._ok:
            return 0
        return box_offset(ObjCClass(self._cls), class_name)

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
        # The box needs no seeding here: the runtime zero-fills ivars at
        # alloc -- every field in its named_global-like ground state -- and
        # the id is written into the box's own id field by each trampoline on
        # the way in, which is position-independent where a write at "offset
        # zero" turned out not to be (the id field is not first; the parser
        # places author fields before synthesized ones).
        return new_instance(cls).addr()


@fieldwise_init
struct _ObjCSuper(TrivialRegisterPassable):
    """The two words `objc_msgSendSuper` reads to start its search one class up.

    `struct objc_super { id receiver; Class super_class; }` -- and note what
    the second field means: not the class to send to, but the class to start
    LOOKING ABOVE. Passing the object's own class here would find the same
    method again and recurse until the stack is gone, which is the classic way
    to write an infinite loop in Objective-C.
    """

    var receiver: Int
    var super_class: Int


def objc_super_send_void(id: Int, defining_class: Int, selector: P):
    """`[super <selector>]`, for a selector returning nothing.

    Needed by any override that has to let its superclass do the real work.
    Ordinary dispatch cannot express it: `objc_msgSend` on `self` finds the
    override again.

    `defining_class` is the class the CALLING METHOD IS DEFINED ON, and it
    must not be `object_getClass(id)`. The difference is invisible until a
    Mojo class inherits from another and then it is total: for an instance of
    `Leaf`, a method defined on `Middle` that asked the instance for its class
    would look above LEAF, find `Middle` -- itself -- and call itself forever.
    That is the classic Objective-C infinite loop, and it cost a stack
    overflow in `dealloc` before this argument existed.

    `objc_super`'s second word is not the class to send to. It is the class to
    start looking ABOVE.
    """
    if id == 0 or defining_class == 0:
        return
    var sup = external_call["class_getSuperclass", P](
        P(unsafe_from_address=defining_class)
    )
    var frame = _ObjCSuper(id, Int(sup))
    external_call["objc_msgSendSuper", NoneType](
        MutPointer(to=frame), selector
    )


comptime _DEFINING_CLASS_PREFIX = "boxclass/"
"""Where `add_dealloc` leaves the class it registered a dealloc on.

A plain function pointer closes over nothing, so the IMP cannot be told which
class it belongs to -- and it must know, both to find its own box and to send
`[super dealloc]` one level up rather than into itself. The type parameter is
the key: it is the class, at compile time, so a global named for it is an
exact and allocation-free channel between registration and dispatch."""


fn _box_dealloc_imp[T: Deinitable](self_: P, _cmd: P):
    """The IMP registered for `dealloc` on any class that has a box.

    Two things, in this order, and the order is the whole point:

    1. Run T's destructor over the box, so a field owning heap memory gives
       it back. Mojo's ownership machinery already destroys a field when it
       is REASSIGNED through the box -- that has always worked -- but nothing
       ran when the object itself died, which is the gap this closes.
    2. `[super dealloc]`, which is what actually frees the instance. Skipping
       it leaks every object; doing it first would run the destructor over
       freed memory.

    Everything here keys off the class this IMP was REGISTERED ON, which
    `add_dealloc` left in a global named for T, and never off the instance's
    dynamic class. With inheritance the two differ, and both uses would be
    wrong: `object_getClass` on an instance of a derived class answers the
    derived class, so this would destroy the derived box a second time while
    its own was never touched, and then send `[super dealloc]` to itself
    forever.

    Inheritance then falls out: the derived dealloc empties the derived box
    and passes `[super dealloc]` up, which reaches the base's dealloc, which
    empties the base box and passes it on again.

    `fn`, not `def`: an IMP is C-ABI and may not raise. The runtime calls this
    with (self, _cmd) and ignores the result.
    """
    comptime name = reflect[T].base_name()
    comptime cls_slot = StaticString(
        _get_kgen_string[_DEFINING_CLASS_PREFIX, name]()
    )
    comptime off_slot = StaticString(
        _get_kgen_string["boxoffset.dealloc/", name]()
    )
    var defining = named_global[cls_slot, Int]()[]
    if defining == 0:
        return  # Never registered by us; nothing here is ours to free.

    # Cached, because the lookup leaks a C string and a dealloc is not rare.
    var cache = named_global[off_slot, Int]()
    var off = cache[]
    if off == 0:
        off = box_offset(ObjCClass(defining), name)
        cache[] = off
    if off != 0:
        unsafe_destroy_n(
            MutPointer[T, MutUntrackedOrigin](
                unsafe_from_address=Int(self_) + off
            ),
            1,
        )
    objc_super_send_void(Int(self_), defining, sel_dynamic("dealloc"))


comptime BOX_IVAR_PREFIX = "__mojo_box_"
"""Every class's box is its OWN ivar, named for the class.

One shared name would be ambiguous the moment a Mojo `class` inherits from
another: `class_getInstanceVariable` walks the superclass chain and answers
with the nearest, so a base's dealloc looking up "__mojo_box" on an instance
of a derived class would find the DERIVED box and destroy it a second time
while the base's own was never touched. Naming the ivar for the class it
belongs to removes the question rather than reasoning about it."""


def box_ivar_name(class_name: StringSlice) -> String:
    """The ivar name for a class's box. See `BOX_IVAR_PREFIX`."""
    return String(BOX_IVAR_PREFIX) + String(class_name)


def box_offset(cls: ObjCClass, class_name: StringSlice) -> Int:
    """Where the box pointer sits inside an instance, in bytes.

    Read once per class after registration and cached by the caller: the
    runtime settles it when the class is registered, and it does not move.
    Returns 0 if the class has no box, which no caller should be asking about.
    """
    var ivar = external_call["class_getInstanceVariable", P](
        P(unsafe_from_address=cls.as_object().addr()),
        _leak_cstr(box_ivar_name(class_name)),
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
