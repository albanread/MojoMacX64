# An Objective-C class declared in Mojo, instantiated, and messaged BY THE
# RUNTIME -- not by us calling the Mojo method directly.
#
# No ObjCClassBuilder, no encoding string written by hand, no IMP, no _cmd
# slot. The compiler synthesizes an __init__ that drives ObjCClassRegistrar
# and a C-ABI trampoline per method that drops _cmd and forwards the rest.
from std.objc import ObjCClass, ObjCObject, send, load_framework


class Probe(NSObject):
    def isProxy(self) -> Bool:
        return True

    def isEqual_(self, other: Int) -> Bool:
        return other == 0


def main() raises:
    _ = load_framework["Foundation"]()

    # Constructing it registers the class and makes an instance.
    var p = Probe()

    # Ask the runtime, not Mojo: look the class up by name and send it
    # messages. If the trampolines are wrong this is where it shows.
    var cls = ObjCClass.lookup["Probe"]()
    print("class registered:", Int(cls.as_object().addr()) != 0)

    var obj = send[ObjCObject, "alloc"](cls.as_object())
    obj = send[ObjCObject, "init"](obj)

    var proxied = send[Bool, "isProxy"](obj)
    print("runtime -> isProxy:", proxied)

    var eq0 = send[Bool, "isEqual:"](obj, Int(0))
    var eq7 = send[Bool, "isEqual:"](obj, Int(7))
    print("runtime -> isEqual:(0):", eq0)
    print("runtime -> isEqual:(7):", eq7)

    var ok = Int(cls.as_object().addr()) != 0 and proxied and eq0 and not eq7
    print("CLASS:", "PASS" if ok else "FAIL")
