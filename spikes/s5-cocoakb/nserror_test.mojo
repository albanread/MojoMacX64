# NSError -> raises: both Cocoa failure conventions, both directions.
from std.objc import (
    ObjCObject,
    ObjCClass,
    msg_send,
    msg_send_raising,
    msg_send_raising_check,
    nsstring,
    ns_to_string,
    autoreleasepool,
)


def main() raises:
    with autoreleasepool():
        var ns_string_cls = ObjCClass.lookup["NSString"]().as_object()

        # Object convention, failure path: reading a file that does not exist
        # must RAISE, and the message must carry Cocoa's diagnosis.
        var raised = False
        var message = String("")
        try:
            _ = msg_send_raising[
                "NSString", "stringWithContentsOfFile:encoding:error:",
                is_class=True,
            ](
                ns_string_cls,
                nsstring("/nonexistent/really-not-here.txt").ptr(),
                Int(4),  # NSUTF8StringEncoding
            )
        except e:
            raised = True
            message = String(e)
        if not raised:
            raise Error("FAIL: reading a nonexistent file did not raise")
        if message.byte_length() < 10:
            raise Error("FAIL: error message carries no diagnosis: " + message)

        # Bool convention + success paths: write a file (BOOL, must succeed),
        # read it back (object, must succeed), remove it (BOOL, must succeed),
        # remove it again (BOOL, must raise).
        var path = nsstring("/tmp/mojo-nserror-check.txt")
        msg_send_raising_check[
            "NSString", "writeToFile:atomically:encoding:error:"
        ](nsstring("round trip"), path.ptr(), Bool(True), Int(4))

        var read_back = msg_send_raising[
            "NSString", "stringWithContentsOfFile:encoding:error:",
            is_class=True,
        ](ns_string_cls, path.ptr(), Int(4))
        if ns_to_string(read_back) != "round trip":
            raise Error("FAIL: round trip mismatch")

        var fm = msg_send[
            ObjCObject, "NSFileManager", "defaultManager", is_class=True
        ](ObjCClass.lookup["NSFileManager"]().as_object())
        msg_send_raising_check["NSFileManager", "removeItemAtPath:error:"](
            fm, path.ptr()
        )
        var raised2 = False
        try:
            msg_send_raising_check["NSFileManager", "removeItemAtPath:error:"](
                fm, path.ptr()
            )
        except e2:
            raised2 = True
        if not raised2:
            raise Error("FAIL: removing a removed file did not raise")
    print("NSERROR: PASS")
