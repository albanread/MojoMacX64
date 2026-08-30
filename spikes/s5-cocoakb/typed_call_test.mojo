# Calling Cocoa as calls: `view.setFrameSize(size)`.
#
# The other half of `class`. COCOA_CLASS_DESIGN.md made DECLARING an
# Objective-C class a declaration; this makes CALLING one a call, and it needed
# no compiler work beyond the folding fix -- `__getattr_param__` has been in
# the parser all along, and the SDK database already knew everything else.
#
# What is checked here is not that the syntax parses. It is that the selector,
# its existence, and the TYPE of its result are all settled before the program
# runs, from the SDK rather than from anything written down twice.
from std.objc import (
    Obj, ObjCObject, ObjCClass, msg_send, load_framework, nsstring,
    ns_to_string, CGRect, CGSize, CGPoint,
)


def main() raises:
    if not load_framework["AppKit"]():
        raise Error("no AppKit")

    var s = Obj["NSString"](nsstring(String("hello")).addr())

    # A scalar result, typed Int by the SDK and usable as one.
    if s.length() + 1 != 6:
        print("length ->", s.length())
        raise Error("a scalar result was not typed as a scalar")

    # A predicate, typed Bool -- not an Int that happens to be 0 or 1.
    if not s.isEqual(ObjCObject(s.id)):
        raise Error("a boolean result was not typed as a boolean")

    # An object result. NSString.uppercaseString is a method rather than a
    # property, so the SDK does not record its class and the answer is
    # NSObject -- true of every object, and the honest upper bound.
    var upper = s.uppercaseString()
    if ns_to_string(upper.object()) != String("HELLO"):
        raise Error("an object result did not come back")

    # A real view, for the results only a view has.
    var NSView = ObjCClass.lookup["NSView"]()
    var raw = msg_send[ObjCObject, "NSView", "alloc", is_class=True](
        NSView.as_object()
    )
    raw = msg_send[ObjCObject, "NSView", "initWithFrame:"](
        raw, CGRect(CGPoint(0.0, 0.0), CGSize(320.0, 200.0))
    )
    var view = Obj["NSView"](raw.addr())

    # A struct result, typed CGRect from the encoding -- the case that would
    # read the wrong registers if the type were guessed.
    if view.frame().size.width != 320.0:
        print("frame width ->", view.frame().size.width)
        raise Error("a struct result was not typed as a struct")

    # An argument, and the name mapping: `setFrameSize` + one argument is
    # `setFrameSize:`. The same underscore rule `class` uses, read backwards,
    # with the argument count supplying the last colon.
    view.setFrameSize(CGSize(640.0, 480.0))
    if view.frame().size.width != 640.0:
        raise Error("a call with an argument did not reach the object")

    # And the class of a returned object, where the SDK records it. This is
    # the piece that was missing until properties were ingested: a method's
    # own encoding says `@` and nothing more, but a property's attribute
    # string says `T@"NSWindow"`. A view with no window answers nil, which is
    # the answer, not a failure.
    var window = view.window()
    if not window.is_nil():
        raise Error("a fresh view should not have a window")
    comptime window_class = type_of(window).cls
    if StaticString(window_class.value) != StaticString("NSWindow"):
        print("window() returns ->", StaticString(window_class.value))
        raise Error("the returned class did not come from the SDK")

    print("typed calls OK")
