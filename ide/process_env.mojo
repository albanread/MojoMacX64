# Environment overlays for processes launched by the IDE.
#
# NSTask inherits the editor's environment until setEnvironment: is called.
# The moment one setting has to change, handing it a fresh dictionary would
# otherwise discard PATH, HOME, TMPDIR, proxy settings, and everything else
# inherited from launchd or the terminal.  Keep that merge in one place.
from std.objc import Cls, Obj, ObjCObject, nsstring

from json import JSON


def apply(task: ObjCObject, overlay: JSON):
    """Apply the string members of `overlay` over NSTask's inherited env."""
    if overlay.count() == 0:
        return
    let info = Cls["NSProcessInfo"]().processInfo()
    let inherited = Obj["NSProcessInfo"](info.addr()).environment()
    var env = Cls["NSMutableDictionary"]().dictionaryWithDictionary(
        inherited.ptr()
    )
    var i = 0
    while i < len(overlay.keys):
        let value = overlay.items[i][].as_string()
        if value != "":
            var key = overlay.keys[i]
            var text = value
            Obj["NSMutableDictionary"](env.addr()).setObject_forKey(
                nsstring(text).ptr(), nsstring(key).ptr()
            )
        i += 1
    Obj["NSTask"](task.addr()).setEnvironment(env.ptr())
