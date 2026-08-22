# The argument-count check is a compile error, not a runtime surprise.
from std.objc import ObjCClass, msg_send
def main():
    var cls = ObjCClass.lookup["NSString"]()
    # characterAtIndex: needs an index; forgetting it is caught at comptime.
    var c = msg_send[Int, "NSString", "characterAtIndex:"](cls.as_object())
    print(c)
