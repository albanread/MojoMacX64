# std.objc P2: an NSString round-trip on the host, dispatched through the
# database-selected stub. No selector or ABI stub is written by hand.
from std.objc import ObjCClass, ObjCObject, msg_send, autoreleasepool
from std.ffi import external_call, c_char
from std.memory import OpaquePointer


def main():
    with autoreleasepool():
        # +[NSString stringWithUTF8String:] -- a class method returning id.
        var NSString = ObjCClass.lookup["NSString"]()
        if NSString.is_nil():
            print("FAIL: NSString not registered (Foundation not linked?)")
            return

        var msg = String("Hello from Cocoa, via Mojo")
        var greeting = msg.as_c_string_slice()
        var s = msg_send[
            ObjCObject, "NSString", "stringWithUTF8String:", is_class=True
        ](NSString.as_object(), greeting)
        if s.is_nil():
            print("FAIL: stringWithUTF8String: returned nil")
            return

        # -[NSString length] -> NSUInteger
        var n = msg_send[Int, "NSString", "length"](s)
        print("length:", n)

        # -[NSString characterAtIndex:] -> unichar (one checked argument)
        var ch = msg_send[UInt16, "NSString", "characterAtIndex:"](s, UInt(0))
        print("first char code:", Int(ch))

        # -[NSString UTF8String] -> const char *
        var back = msg_send[
            OpaquePointer[MutUntrackedOrigin], "NSString", "UTF8String"
        ](s)
        var rt = String(unsafe_from_utf8_ptr=back.bitcast[c_char]())
        print("round-trip:", rt)

        if n == 26 and rt == "Hello from Cocoa, via Mojo":
            print("OBJC-SMOKE: PASS")
        else:
            print("OBJC-SMOKE: FAIL")
