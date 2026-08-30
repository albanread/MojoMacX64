# Fixture for the Cocoa completion check in check-dist.sh. The positions are
# hardcoded there by line and column, so adding lines above means updating them.
from std.objc import ObjCClass, msg_send, ObjCObject


def main():
    let cls = ObjCClass.lookup["NSWin"]()
    let a = msg_send[ObjCObject, "NSWindow", "setTit"](cls)
    let b = msg_send[ObjCObject, "NSWindow", "allo", is_class=True](cls)
