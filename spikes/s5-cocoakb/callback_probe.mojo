# std.objc: Cocoa calling BACK into Mojo. A class allocated at runtime whose
# method is a Mojo abi("C") function (the IMP), type-encoded from the database.
# This is the target/action + delegate mechanism every real app needs.
from std.objc import ObjCClass, ObjCObject, msg_send, send, sel
from std.ffi import external_call
from std.memory import OpaquePointer
comptime P = OpaquePointer[MutUntrackedOrigin]

# Mojo implementation of a delegate method. IMP ABI: (id self, SEL _cmd, id arg).
# Uses a REAL AppKit delegate selector so the database knows its ABI (v@:@).
def mojo_did_finish(self_: P, cmd: P, note: P) abi("C"):
    print("  >> Cocoa called into Mojo: applicationDidFinishLaunching:")

def main():
    var NSObject = ObjCClass.lookup["NSObject"]()
    var name = String("MojoDelegate")
    var cls = external_call["objc_allocateClassPair", P](
        P(unsafe_from_address=NSObject.as_object().addr()), name.as_c_string_slice(), Int(0))
    print("allocated class:", Int(cls) != 0)

    # Function pointer -> opaque IMP, the same bitcast trick DLHandle uses in reverse.
    var imp_fn: def(P, P, P, /) thin abi("C") -> None = mojo_did_finish
    var imp = Pointer(to=imp_fn).unsafe_bitcast[P]()[]

    var s = sel["applicationDidFinishLaunching:"]().ptr()
    var types = String("v@:@")   # the DB's encoding for this selector, sans offsets
    var added = external_call["class_addMethod", Bool](cls, s, imp, types.as_c_string_slice())
    print("method added:", added)
    external_call["objc_registerClassPair", NoneType](cls)

    var inst = msg_send[ObjCObject, "NSObject", "new", is_class=True](ObjCObject(Int(cls)))
    var responds = msg_send[Bool, "NSObject", "respondsToSelector:"](inst, s)
    print("respondsToSelector:", responds)
    # Cocoa -> Mojo: send the delegate message (selector-keyed, ABI from DB).
    _ = send[ObjCObject, "applicationDidFinishLaunching:"](inst, inst.ptr())
    print("CALLBACK-PROBE: PASS" if responds else "CALLBACK-PROBE: FAIL")
