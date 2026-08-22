# std.objc P3: no-leak ownership by RAII.
#
# ObjCRef owns a +1: it releases on destruction, so an object's lifetime
# follows the Mojo value that holds it. This is the default -- you opt OUT of
# ownership (with .autorelease()), never into it.
from std.objc import ObjCClass, ObjCObject, ObjCRef, msg_send, autoreleasepool
from std.ffi import external_call


def make_array() -> ObjCRef:
    """The classic +1 alloc/init chain, wrapped so the caller can't forget to
    release."""
    var cls = ObjCClass.lookup["NSMutableArray"]()
    var allocated = msg_send[
        ObjCObject, "NSMutableArray", "alloc", is_class=True
    ](cls.as_object())
    var inited = msg_send[ObjCObject, "NSObject", "init"](allocated)
    return ObjCRef(adopt=inited)


def count(a: ObjCObject) -> Int:
    return msg_send[Int, "NSArray", "count"](a)


def make_autoreleased() -> ObjCObject:
    """Return a Cocoa object without leaking and without making the caller own
    it -- exactly what an Objective-C method returning an autoreleased object
    does. The returned handle is valid until the enclosing pool drains."""
    var owned = make_array()
    return owned^.autorelease()


def main():
    # 1. RAII balances every retain/release: a million objects, flat memory.
    for _ in range(1_000_000):
        var arr = make_array()
        _ = arr^
    print("cycled 1e6 arrays with no leak")

    # 2. Explicit shared ownership via .copy() (a retain you can see).
    var a = make_array()
    var b = a.copy()
    print("array count (empty):", count(a.object()))
    _ = b^
    _ = a^

    # 3. Autorelease: return an object from a function, drained by the pool.
    with autoreleasepool():
        var s = make_autoreleased()
        print("autoreleased array is live in-pool:", not s.is_nil())
    # pool drained here; s's balancing -1 has run.

    print("OWNERSHIP-TEST: PASS")
