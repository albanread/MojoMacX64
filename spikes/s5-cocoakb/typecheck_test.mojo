# std.objc: per-argument register-file checking, plus NSNumber round-trips.
# A float passed where the ABI wants an integer register (or vice versa) is a
# silent xmm-vs-rdi corruption at runtime; std.objc makes it a compile error.
# The correct calls below all run.
from std.objc import ObjCClass, ObjCObject, msg_send


def main():
    var NSNumber = ObjCClass.lookup["NSNumber"]()

    # +[NSNumber numberWithDouble:] expects a float register -- Float64 is right.
    var d = msg_send[
        ObjCObject, "NSNumber", "numberWithDouble:", is_class=True
    ](NSNumber.as_object(), Float64(3.14159))
    var back_d = msg_send[Float64, "NSNumber", "doubleValue"](d)
    print("double round-trip:", back_d)

    # +[NSNumber numberWithInteger:] expects an integer register -- Int is right.
    var n = msg_send[
        ObjCObject, "NSNumber", "numberWithInteger:", is_class=True
    ](NSNumber.as_object(), Int(42))
    var back_i = msg_send[Int, "NSNumber", "integerValue"](n)
    print("integer round-trip:", back_i)

    # -[NSString characterAtIndex:] expects an integer index -- UInt is right.
    var NSString = ObjCClass.lookup["NSString"]()
    var hi = String("Hi")
    var s = msg_send[
        ObjCObject, "NSString", "stringWithUTF8String:", is_class=True
    ](NSString.as_object(), hi.as_c_string_slice())
    var ch = msg_send[UInt16, "NSString", "characterAtIndex:"](s, UInt(1))
    print("second char code:", Int(ch))

    var ok = back_d == 3.14159 and back_i == 42 and Int(ch) == 105  # 'i'
    print("TYPECHECK-TEST: PASS" if ok else "TYPECHECK-TEST: FAIL")
