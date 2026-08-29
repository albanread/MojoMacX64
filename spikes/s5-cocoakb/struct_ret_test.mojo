# Struct RETURNS through a `class` method, at register level.
#
# AAPCS returns NSRange in x0/x1 and CGRect (a four-double HFA) in v0-v3.
# A Mojo memory-only result is a by-ref slot -- neither -- which is why these
# were refused until std.objc.geometry declared the geometry types
# TrivialRegisterPassable and made Mojo and the C ABI agree. The msg_send
# side already handles struct returns (stret_test); this closes the loop:
# Cocoa asks OUR class for a range and a rect, and the numbers survive.
from std.objc import (
    ObjCObject, send, NSRange, CGRect, CGPoint, CGSize,
)


class RangeSource(NSObject):
    # NSTextInputClient's shape: the SDK declares selectedRange as
    # {_NSRange=QQ}16@0:8, so the encoding is looked up, and the return
    # crosses in x0/x1.
    def selectedRange(self) -> NSRange:
        return NSRange(41, 1759)

    # And the HFA case, four doubles in v0-v3. The SDK knows this selector
    # from NSScreen and friends; the class of the receiver does not matter to
    # the encoding.
    def visibleFrame(self) -> CGRect:
        return CGRect(CGPoint(11.0, 22.0), CGSize(1280.0, 720.0))


def main() raises:
    var obj = ObjCObject(RangeSource().__objc_id)
    if obj.addr() == 0:
        print("FAIL did not register")
        return

    # Selector-keyed dispatch: the receiver's class is ours, which the
    # database has never heard of, but a selector's ABI is consistent across
    # every class that implements it.
    var r = send[NSRange, "selectedRange"](obj)
    print("  range ->", r.location, ",", r.length)

    var f = send[CGRect, "visibleFrame"](obj)
    print("  rect  ->", f.origin.x, f.origin.y, f.size.width, "x", f.size.height)

    if (
        r.location == 41 and r.length == 1759
        and f.origin.x == 11.0 and f.origin.y == 22.0
        and f.size.width == 1280.0 and f.size.height == 720.0
    ):
        print("struct returns OK")
    else:
        print("struct returns FAILED")
