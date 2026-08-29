# ===----------------------------------------------------------------------=== #
# COCOA: Cocoa metadata, queried while compiling.
#
# macOS is described precisely -- struct layouts, enum values, every selector
# with its @encode signature, and the x86-64 dispatch stub each send must go
# through -- in cocoa.sqlite (sister repo CocoaBaseMCP), and the compiler reads
# it during elaboration. So a binding states a name and the compiler supplies
# the rest, instead of a generator restating 400,000 method signatures that
# then have to be kept in step with the SDK by hand.
#
# Every function here resolves to a constant before any code is generated. A
# name the metadata does not know is a compile error, not a wrong answer.
#
# See COCOA_DESIGN.md for the design, and derive_method_abi.py (AAPCS64) in
# CocoaBaseMCP for the
# ABI token vocabulary (v g f gg gf fg ff x s m ?).
# ===----------------------------------------------------------------------=== #

from std.collections.string.string_span import _get_kgen_string


def cocoakb_struct_size[name: StaticString]() -> Int:
    """The size in bytes of a Cocoa struct on x86-64, from the metadata.

    Parameters:
        name: The struct name as the runtime spells it, e.g. "CGRect".

    Returns:
        The size in bytes.
    """
    return Int(
        mlir_value=__mlir_attr[
            `#kgen.param.expr<cocoakb_query, `,
            _get_kgen_string["struct_size"](),
            `, `,
            _get_kgen_string[name](),
            `> : index`,
        ]
    )


def cocoakb_struct_align[name: StaticString]() -> Int:
    """The alignment in bytes of a Cocoa struct on x86-64.

    Parameters:
        name: The struct name, e.g. "CGRect".

    Returns:
        The alignment in bytes.
    """
    return Int(
        mlir_value=__mlir_attr[
            `#kgen.param.expr<cocoakb_query, `,
            _get_kgen_string["struct_align"](),
            `, `,
            _get_kgen_string[name](),
            `> : index`,
        ]
    )


def cocoakb_field_offset[
    type_name: StaticString, field: StaticString
]() -> Int:
    """The byte offset of a field within a Cocoa struct on x86-64.

    This is what makes a declaration checkable rather than merely plausible:
    a Mojo struct can assert that its own layout agrees with what the SDK
    expects, and fail to build if it does not.

    Parameters:
        type_name: The struct name, e.g. "CGRect".
        field: The field name within it, e.g. "size".

    Returns:
        The offset in bytes from the start of the struct.
    """
    return Int(
        mlir_value=__mlir_attr[
            `#kgen.param.expr<cocoakb_query, `,
            _get_kgen_string["field_offset"](),
            `, `,
            _get_kgen_string[type_name](),
            `, `,
            _get_kgen_string[field](),
            `> : index`,
        ]
    )


def cocoakb_enum_value[name: StaticString]() -> Int:
    """The value of a Cocoa enum member, from BridgeSupport.

    The signed reading: a value that must sign-extend as a pointer does, and a
    flag mask narrowed by the caller keeps its bits either way.

    Parameters:
        name: The member name, e.g. "NSWindowStyleMaskTitled".

    Returns:
        The value.
    """
    return Int(
        mlir_value=__mlir_attr[
            `#kgen.param.expr<cocoakb_query, `,
            _get_kgen_string["enum_value"](),
            `, `,
            _get_kgen_string[name](),
            `> : index`,
        ]
    )


def cocoakb_constant_type[name: StaticString]() -> StaticString:
    """The declared type of an extern-symbol Cocoa constant.

    Constants like NSFontAttributeName are runtime addresses, not comptime
    values: the metadata supplies the type encoding here, and the binding
    dlsyms the symbol at runtime.

    Parameters:
        name: The constant name.

    Returns:
        The type64 encoding, e.g. "@" for an object.
    """
    var res = __mlir_attr[
        `#kgen.param.expr<cocoakb_query, `,
        _get_kgen_string["constant_type"](),
        `, `,
        _get_kgen_string[name](),
        `> : !kgen.string`,
    ]
    return StaticString(res)


def cocoakb_superclass[name: StaticString]() -> StaticString:
    """The superclass of an Objective-C class.

    Parameters:
        name: The class name.

    Returns:
        The superclass name.
    """
    var res = __mlir_attr[
        `#kgen.param.expr<cocoakb_query, `,
        _get_kgen_string["superclass"](),
        `, `,
        _get_kgen_string[name](),
        `> : !kgen.string`,
    ]
    return StaticString(res)


def _kind[is_class: Bool]() -> StaticString:
    comptime if is_class:
        return "1"
    else:
        return "0"


def cocoakb_method_encoding[
    cls: StaticString, selector: StaticString, is_class: Bool = False
]() -> StaticString:
    """The verbatim @encode signature of a method, inheritance-resolved.

    The lookup walks the superclass chain in the metadata, so asking
    NSMutableString about `length` finds NSString's definition.

    Parameters:
        cls: The class the send targets.
        selector: The selector, e.g. "isEqualToString:".
        is_class: True for a class method (+), False for instance (-).

    Returns:
        The raw encoding, e.g. "Q16@0:8".
    """
    var res = __mlir_attr[
        `#kgen.param.expr<cocoakb_query, `,
        _get_kgen_string["method_encoding"](),
        `, `,
        _get_kgen_string[cls](),
        `, `,
        _get_kgen_string[selector](),
        `, `,
        _get_kgen_string[_kind[is_class]()](),
        `> : !kgen.string`,
    ]
    return StaticString(res)


def cocoakb_msgsend_variant[
    cls: StaticString, selector: StaticString, is_class: Bool = False
]() -> StaticString:
    """Which objc_msgSend entry point this send must go through.

    On arm64 the answer is always plain objc_msgSend: AAPCS64 has neither
    objc_msgSend_stret nor objc_msgSend_fpret, because an aggregate return
    travels in x0-x1, in v0-v3 when it is a homogeneous float aggregate, or
    through the x8 indirect-result register. (On x86-64 this is a real
    choice: a MEMORY-class return there must use objc_msgSend_stret, with a
    hidden buffer pointer in rdi and self shifted to rsi.)

    The query is kept on both, because its other job survives: a signature
    the ABI pass could not model answers "?" and fails the build rather than
    being guessed at.

    Parameters:
        cls: The class the send targets.
        selector: The selector.
        is_class: True for a class method.

    Returns:
        "objc_msgSend", "objc_msgSend_stret", or "objc_msgSend_fpret".
        ("?" marks an unmodelable signature; assert against it.)
    """
    var res = __mlir_attr[
        `#kgen.param.expr<cocoakb_query, `,
        _get_kgen_string["msgsend_variant"](),
        `, `,
        _get_kgen_string[cls](),
        `, `,
        _get_kgen_string[selector](),
        `, `,
        _get_kgen_string[_kind[is_class]()](),
        `> : !kgen.string`,
    ]
    return StaticString(res)


def cocoakb_method_ret_class[
    cls: StaticString, selector: StaticString, is_class: Bool = False
]() -> StaticString:
    """The AAPCS64 return classification of a method (token vocabulary)."""
    var res = __mlir_attr[
        `#kgen.param.expr<cocoakb_query, `,
        _get_kgen_string["method_ret_class"](),
        `, `,
        _get_kgen_string[cls](),
        `, `,
        _get_kgen_string[selector](),
        `, `,
        _get_kgen_string[_kind[is_class]()](),
        `> : !kgen.string`,
    ]
    return StaticString(res)


def cocoakb_method_arg_classes[
    cls: StaticString, selector: StaticString, is_class: Bool = False
]() -> StaticString:
    """The AAPCS64 classifications of a method's arguments, comma-joined
    (arguments beyond self and _cmd)."""
    var res = __mlir_attr[
        `#kgen.param.expr<cocoakb_query, `,
        _get_kgen_string["method_arg_classes"](),
        `, `,
        _get_kgen_string[cls](),
        `, `,
        _get_kgen_string[selector](),
        `, `,
        _get_kgen_string[_kind[is_class]()](),
        `> : !kgen.string`,
    ]
    return StaticString(res)


def cocoakb_selector_variant[selector: StaticString]() -> StaticString:
    """Which objc_msgSend variant a selector uses, from any class implementing
    it -- for protocol-typed receivers whose concrete class is unknown at
    compile time (id<MTLTexture>, a Cocoa delegate, ...)."""
    var res = __mlir_attr[
        `#kgen.param.expr<cocoakb_query, `,
        _get_kgen_string["selector_variant"](),
        `, `,
        _get_kgen_string[selector](),
        `> : !kgen.string`,
    ]
    return StaticString(res)


def cocoakb_selector_arg_classes[selector: StaticString]() -> StaticString:
    """The AAPCS64 argument classes of a selector, from any implementing
    class -- the selector-keyed counterpart of cocoakb_method_arg_classes."""
    var res = __mlir_attr[
        `#kgen.param.expr<cocoakb_query, `,
        _get_kgen_string["selector_arg_classes"](),
        `, `,
        _get_kgen_string[selector](),
        `> : !kgen.string`,
    ]
    return StaticString(res)


def cocoakb_selector_encoding[selector: StaticString]() -> StaticString:
    """The verbatim @encode signature of a selector (majority across the
    classes implementing it), e.g. "v24@0:8@16" -- for typing a Mojo method
    when defining an Objective-C class at runtime."""
    var res = __mlir_attr[
        `#kgen.param.expr<cocoakb_query, `,
        _get_kgen_string["selector_encoding"](),
        `, `,
        _get_kgen_string[selector](),
        `> : !kgen.string`,
    ]
    return StaticString(res)


def cocoakb_posix_sig[name: StaticString]() -> StaticString:
    """The full C type of a POSIX/BSD libc function, as clang reports it.

    Parameters:
        name: The function name, e.g. "open".

    Returns:
        The qualtype, e.g. "int (const char *, int, ...)".
    """
    var res = __mlir_attr[
        `#kgen.param.expr<cocoakb_query, `,
        _get_kgen_string["posix_sig"](),
        `, `,
        _get_kgen_string[name](),
        `> : !kgen.string`,
    ]
    return StaticString(res)


def cocoakb_posix_ret_class[name: StaticString]() -> StaticString:
    """The AAPCS64 return classification of a libc function."""
    var res = __mlir_attr[
        `#kgen.param.expr<cocoakb_query, `,
        _get_kgen_string["posix_ret_class"](),
        `, `,
        _get_kgen_string[name](),
        `> : !kgen.string`,
    ]
    return StaticString(res)


def cocoakb_posix_arg_classes[name: StaticString]() -> StaticString:
    """The AAPCS64 classifications of a libc function's arguments."""
    var res = __mlir_attr[
        `#kgen.param.expr<cocoakb_query, `,
        _get_kgen_string["posix_arg_classes"](),
        `, `,
        _get_kgen_string[name](),
        `> : !kgen.string`,
    ]
    return StaticString(res)


def cocoakb_db_hash() -> StaticString:
    """The SHA-256 of the metadata database this compilation consulted.

    The reproducibility pin: a binary can record exactly which metadata
    revision it was built against.

    Returns:
        The hash, lowercase hex.
    """
    var res = __mlir_attr[
        `#kgen.param.expr<cocoakb_query, `,
        _get_kgen_string["db_hash"](),
        `> : !kgen.string`,
    ]
    return StaticString(res)


# ===----------------------------------------------------------------------=== #
# Foldable queries
# ===----------------------------------------------------------------------=== #
#
# The queries above are `def`s, and a `def` call cannot be evaluated in a TYPE
# position -- so a conditional type cannot branch on one:
#
#     comptime T: AnyType = Int if cocoakb_struct_size["CGSize"]() == 16
#                           else Bool          # stays symbolic
#
# Two things were in the way and both are gone. `cocoakb_query` now folds at
# attribute level (KGENAttrs.cpp) rather than only in the elaborator, which is
# far too late to choose a type. And the name reaches the query as a
# `!kgen.string` PARAMETER here, taken from `StringLiteral`'s own parameter,
# rather than through `_get_kgen_string` -- whose `data_to_str` expression does
# not fold at attribute level, and would have blocked the chain one link down.
#
# The result is that a database answer is an ordinary compile-time constant,
# and a call site can be typed from the SDK.


comptime cocoakb_p_struct_size[name: StringLiteral] = Int(
    mlir_value=__mlir_attr[
        `#kgen.param.expr<cocoakb_query, "struct_size" : !kgen.string, `,
        name.value,
        `> : index`,
    ]
)
"""`cocoakb_struct_size`, foldable in a parameter position."""


comptime cocoakb_p_method_ret_kind[
    cls: StringLiteral, sel: StringLiteral, is_class: StringLiteral
] = Int(
    mlir_value=__mlir_attr[
        `#kgen.param.expr<cocoakb_query, "method_ret_kind" : !kgen.string, `,
        cls.value,
        `, `,
        sel.value,
        `, `,
        is_class.value,
        `> : index`,
    ]
)
"""The code point of the result KIND of `cls`'s `sel` -- see method_ret_kind.

A code point rather than a character so that it folds: an integer comparison
is something the parameter evaluator can decide, and choosing a type is
exactly what that decision is for.
"""


comptime cocoakb_p_selector_ret_kind[sel: StringLiteral] = Int(
    mlir_value=__mlir_attr[
        `#kgen.param.expr<cocoakb_query, "selector_ret_kind" : !kgen.string, `,
        sel.value,
        `> : index`,
    ]
)
"""The same, keyed on the selector alone: the majority reading across every
class that implements it, for a receiver whose class is not known."""


comptime cocoakb_p_method_ret_class[
    cls: StringLiteral, sel: StringLiteral, is_class: StringLiteral
] = StaticString(
    __mlir_attr[
        `#kgen.param.expr<cocoakb_query, "method_ret_objc_class" : !kgen.string, `,
        cls.value,
        `, `,
        sel.value,
        `, `,
        is_class.value,
        `> : !kgen.string`,
    ]
)
"""WHICH object `cls`'s `sel` returns, where that is knowable.

The method's own encoding never says -- every object is a bare `@` -- but a
PROPERTY's attribute string does, and a property is read by a selector. That
plus the instancetype family covers a little over half of every
object-returning instance method; the rest needs the SDK headers.

An answer of `@self` is the instancetype rule and means the receiver's own
class. `alloc`, `new` and the `init` family are declared on NSObject, so
resolving them through the superclass chain would otherwise say that
`[NSString alloc]` is an NSObject.
"""


comptime cocoakb_p_ret_class_str[
    cls: StringLiteral, sel: StringLiteral, is_class: StringLiteral
] = __mlir_attr[
    `#kgen.param.expr<cocoakb_query, "method_ret_objc_class" : !kgen.string, `,
    cls.value,
    `, `,
    sel.value,
    `, `,
    is_class.value,
    `> : !kgen.string`,
]
"""`cocoakb_p_method_ret_class` as a raw `!kgen.string` rather than a
`StaticString`.

The difference is what it can be used FOR. `StringLiteral`'s own parameter is
a `!kgen.string`, so this form can parameterize a type -- `Obj[
StringLiteral[cocoakb_p_ret_class_str[...]]]` -- which is how a call's result
gets the class the SDK says it has, without anyone writing it down. A
`StaticString` is a value and cannot.
"""


# The call direction's three queries, keyed on the MOJO-side name and the
# argument count rather than on a selector. The name mapping -- underscores to
# colons, with the argument count supplying the last one -- happens in SQL,
# because string surgery does not fold during parameter evaluation and a type
# conditioned on the result would stay symbolic.


comptime cocoakb_p_selector_for[
    cls: StringLiteral, name: StringLiteral, is_class: StringLiteral,
    nargs: StringLiteral,
] = StaticString(
    __mlir_attr[
        `#kgen.param.expr<cocoakb_query, "selector_for_name" : !kgen.string, `,
        cls.value, `, `, name.value, `, `, is_class.value, `, `, nargs.value,
        `> : !kgen.string`,
    ]
)
"""The selector `cls.name(...)` means, verified to exist on `cls` or above it.

A name the class does not answer is a compile error rather than a runtime
`doesNotRecognizeSelector:` -- which is the entire reason the database is
consulted at compile time.
"""


comptime cocoakb_p_ret_kind_for[
    cls: StringLiteral, name: StringLiteral, is_class: StringLiteral,
    nargs: StringLiteral,
] = Int(
    mlir_value=__mlir_attr[
        `#kgen.param.expr<cocoakb_query, "ret_kind_for_name" : !kgen.string, `,
        cls.value, `, `, name.value, `, `, is_class.value, `, `, nargs.value,
        `> : index`,
    ]
)
"""The result KIND's code point -- see `method_ret_kind`. An integer, because
that is what a conditional type can branch on."""


comptime cocoakb_p_ret_class_for[
    cls: StringLiteral, name: StringLiteral, is_class: StringLiteral,
    nargs: StringLiteral,
] = StaticString(
    __mlir_attr[
        `#kgen.param.expr<cocoakb_query, "ret_class_for_name" : !kgen.string, `,
        cls.value, `, `, name.value, `, `, is_class.value, `, `, nargs.value,
        `> : !kgen.string`,
    ]
)
"""WHICH object comes back, or `NSObject` when the SDK does not record it --
true of every object, and the honest upper bound. Always answers, so a caller
can ask unconditionally and use it only when the kind says object."""


comptime cocoakb_p_ret_class_for_str[
    cls: StringLiteral, name: StringLiteral, is_class: StringLiteral,
    nargs: StringLiteral,
] = __mlir_attr[
    `#kgen.param.expr<cocoakb_query, "ret_class_for_name" : !kgen.string, `,
    cls.value, `, `, name.value, `, `, is_class.value, `, `, nargs.value,
    `> : !kgen.string`,
]
"""`cocoakb_p_ret_class_for` as a raw `!kgen.string`.

`StringLiteral`'s own parameter is a `!kgen.string`, so only this form can
parameterise a type through it -- `Obj[StringLiteral[...]()]`, which is how a
call's result gets the class the SDK says it has."""
