# ===----------------------------------------------------------------------=== #
# VEGA-FORK: Cocoa metadata, queried while compiling.
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
# See COCOA_DESIGN.md for the design, and abi_sysv.py in CocoaBaseMCP for the
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
    """Which objc_msgSend entry point this send must go through on x86-64.

    On arm64 every send is plain objc_msgSend; on x86-64 a MEMORY-class
    return must use objc_msgSend_stret (hidden buffer pointer in rdi, self
    shifted to rsi) and a long-double return must use objc_msgSend_fpret.
    Getting this wrong corrupts the stack silently, so no human picks it:
    the metadata's SysV classification does.

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
    """The SysV x86-64 return classification of a method (token vocabulary)."""
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
    """The SysV x86-64 classifications of a method's arguments, comma-joined
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
    """The SysV x86-64 argument classes of a selector, from any implementing
    class -- the selector-keyed counterpart of cocoakb_method_arg_classes."""
    var res = __mlir_attr[
        `#kgen.param.expr<cocoakb_query, `,
        _get_kgen_string["selector_arg_classes"](),
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
    """The SysV x86-64 return classification of a libc function."""
    var res = __mlir_attr[
        `#kgen.param.expr<cocoakb_query, `,
        _get_kgen_string["posix_ret_class"](),
        `, `,
        _get_kgen_string[name](),
        `> : !kgen.string`,
    ]
    return StaticString(res)


def cocoakb_posix_arg_classes[name: StaticString]() -> StaticString:
    """The SysV x86-64 classifications of a libc function's arguments."""
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
