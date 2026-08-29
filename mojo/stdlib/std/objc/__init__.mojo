# ===----------------------------------------------------------------------=== #
# std.objc -- calling Cocoa from Mojo, checked against the SDK.
#
# The Objective-C runtime is a C ABI: a message send is a C call to
# objc_msgSend(id self, SEL op, ...). Binding that by hand is not hard because
# of the call; it is hard because every fact it depends on -- does this class
# have this selector, what does it return, how big is that struct, where does
# that field sit -- lives in the SDK and gets hand-transcribed, once, wrongly.
#
# std.objc reads those facts from cocoa.sqlite at COMPILE time (via
# std.sys._cocoakb): a typo in a selector is a compile error, a struct that
# drifts from the SDK fails to build, and the dispatch stub is never picked by
# a human. On arm64 the stub is always objc_msgSend (AAPCS64 has no _stret or
# _fpret); on x86-64 it is a genuine per-method choice. Same query, same API.
# ===----------------------------------------------------------------------=== #

from .runtime import ObjCClass, ObjCObject, SEL, sel, msg_send, send, autoreleasepool, load_framework, load_framework_dynamic
from .geometry import CGPoint, CGSize, CGRect, NSRange
from .ownership import ObjCRef, ObjCWeakRef
from .foundation import NSString, nsstring, extern_object, ns_to_string
from .error import msg_send_raising, msg_send_raising_check
from .classes import (
    ObjCClassBuilder,
    ObjCClassRegistrar,
    box_offset,
    IMP0,
    IMP1,
    IMP0Bool,
    IMP1Bool,
    IMP2,
    IMP1Obj,
    IMP2Obj,
    IMP3Obj,
    IMP1Int,
    IMP2Int,
    IMP2ObjBool,
    new_instance,
    named_global,
    sel_dynamic,
)
