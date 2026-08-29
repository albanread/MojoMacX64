# Class fields, end to end: per-instance Mojo state that Objective-C methods
# read and write, with nothing declared but the fields themselves.
#
# The compiler reserves the object's one ivar with sizeof(Self), caches where
# the runtime put it, and every trampoline moves the incoming id along by that
# offset -- so `self` inside a method IS the box. The registrar seeds the id
# into the box's first field at instantiation, which is why methods can reach
# their own object. COCOA_CLASS_DESIGN.md, sprint 3.
from std.objc import ObjCObject, msg_send, send, NSRange


class Tally(NSObject):
    var hits: Int
    var high_water: Int

    # Mutating methods declare `mut self`, exactly as on a struct.
    def isProxy(mut self) -> Bool:
        self.hits += 1
        if self.hits > self.high_water:
            self.high_water = self.hits
        return True

    # The state crossing a struct return, for good measure.
    def selectedRange(self) -> NSRange:
        return NSRange(self.hits, self.high_water)


def main() raises:
    var a = Tally()
    var b = Tally()
    var oa = ObjCObject(a.__objc_id)
    var ob = ObjCObject(b.__objc_id)
    if oa.addr() == 0 or ob.addr() == 0:
        print("FAIL registration")
        return

    # Three pokes at a, one at b -- through the runtime, not through Mojo.
    _ = msg_send[Bool, "NSObject", "isProxy"](oa)
    _ = msg_send[Bool, "NSObject", "isProxy"](oa)
    _ = msg_send[Bool, "NSObject", "isProxy"](oa)
    _ = msg_send[Bool, "NSObject", "isProxy"](ob)

    var ra = send[NSRange, "selectedRange"](oa)
    var rb = send[NSRange, "selectedRange"](ob)
    print("  a:", ra.location, "hits, high water", ra.length)
    print("  b:", rb.location, "hits, high water", rb.length)

    if ra.location == 3 and rb.location == 1 and ra.length == 3:
        print("class fields OK")
    else:
        print("class fields FAILED")
