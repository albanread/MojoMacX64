# ===----------------------------------------------------------------------=== #
# VEGA-FORK: std.objc -- calling Cocoa from Mojo, checked against the SDK.
#
# The Objective-C runtime is a C ABI: a message send is a C call to
# objc_msgSend(id self, SEL op, ...). What makes it hard to bind by hand is
# not the call, it is knowing -- per (class, selector) -- which objc_msgSend
# VARIANT to use on x86-64, because a struct return larger than 16 bytes goes
# through objc_msgSend_stret and a long double through objc_msgSend_fpret.
#
# std.objc reads that decision from cocoa.sqlite at COMPILE time (via
# std.sys._cocoakb), so the programmer never picks a stub and a typo in a
# selector is a compile error.
# ===----------------------------------------------------------------------=== #

from .runtime import (
    ObjCClass,
    ObjCObject,
    SEL,
    sel,
    msg_send,
    send,
    autoreleasepool,
    load_framework,
)
from .ownership import ObjCRef
from .foundation import NSString, nsstring, extern_object
from .classes import (
    ObjCClassBuilder,
    ObjCClassRegistrar,
    box_offset,
    IMP0,
    IMP1,
    IMP0Bool,
    IMP1Bool,
    IMP2,
    new_instance,
    named_global,
    sel_dynamic,
)
