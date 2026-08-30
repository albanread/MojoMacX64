# What Roast remembers between launches.
#
# The editor forgot everything: quit and relaunch and the tabs were gone, the
# project was gone, the window had moved and the type was 13 points again.
# That is its own annoyance, but the reason to fix it first is that three
# other features queue behind it -- a Python interpreter has to be written
# down somewhere, a debugger needs per-project run arguments, and recovering
# from a crash means knowing what was open. All of them want a settings file
# that did not exist.
#
# One JSON document in ~/Library/Application Support/Roast/session.json,
# read at launch and written on quit. The shape:
#
#   { "version": 1,
#     "project": "/path/to/folder",
#     "tabs": ["/path/a.mojo", "/path/b.mojo"], "current": 1,
#     "frame": [x, y, w, h], "font": 13,
#     "settings": { "python.home": "...", "python.library": "..." } }
#
# Everything is optional and everything is checked on the way in. A session
# file is not a contract with a program that wrote it -- it is a file on a
# disk that may have been edited, truncated, or written by a version of
# Roast that thought about the world differently. `read` returns an empty
# object rather than failing when any of that turns out to be true.
#
# This module does not open files or move windows: it reads and writes a
# document, and `roast.mojo` decides what the document means. The dependency
# runs one way -- roast imports session, session imports json -- so this can
# be tested with no window, which session_test.mojo does.
from json import JSON, parse
from std.objc import (
    ObjCClass,
    ObjCObject,
    msg_send,
    nsstring,
    ns_to_string,
    autoreleasepool,
    named_global,
)
from std.memory import OpaquePointer
from std.ffi import external_call
from std.os import getenv

comptime P = OpaquePointer[MutUntrackedOrigin]

# The document currently in memory. A one-element list for the reason every
# other buffer here is one: a zero-initialised global List is a valid empty
# list, and a zero-initialised JSON is not a valid JSON.
comptime g_doc = named_global["roast.session.doc", List[JSON]]
# Whether anything has been loaded yet, so a `setting` read before `load`
# does not silently answer from an empty document and cache that answer.
comptime g_loaded = named_global["roast.session.loaded", Int]


def support_dir() -> String:
    """~/Library/Application Support/Roast, created if it is not there.

    NSSearchPathForDirectoriesInDomains rather than $HOME: the former is what
    the platform says the answer is, and it stays right for a sandboxed app,
    which this may one day be.
    """
    with autoreleasepool():
        let dirs = external_call["NSSearchPathForDirectoriesInDomains", ObjCObject](
            Int(14), Int(1), Bool(True)  # ApplicationSupport, UserDomain, expand
        )
        var base = String()
        if dirs.addr() != 0 and msg_send[Int, "NSArray", "count"](dirs) > 0:
            base = ns_to_string(
                msg_send[ObjCObject, "NSArray", "objectAtIndex:"](dirs, 0)
            )
        if base == "":
            return String()
        let dir = base + String("/Roast")
        let NSFileManager = ObjCClass.lookup["NSFileManager"]()
        let fm = msg_send[
            ObjCObject, "NSFileManager", "defaultManager", is_class=True
        ](NSFileManager.as_object())
        var d = dir
        _ = msg_send[
            Bool,
            "NSFileManager",
            "createDirectoryAtPath:withIntermediateDirectories:attributes:error:",
        ](fm, nsstring(d).ptr(), True, ObjCObject(0).ptr(), ObjCObject(0).ptr())
        return dir^


def session_path() -> String:
    """The file. ROAST_SESSION points somewhere else, which is what lets the
    checks exercise saving and restoring without touching whatever the person
    at this machine had open."""
    let override = getenv("ROAST_SESSION")
    if override != "":
        return override^
    let dir = support_dir()
    if dir == "":
        return String()
    return dir + String("/session.json")


def read() -> JSON:
    """The session on disk, or an empty object.

    Absent, unreadable, malformed and "not an object at all" are the same
    answer on purpose: there is nothing a caller could usefully do
    differently, and every one of them means "start fresh".
    """
    let path = session_path()
    if path == "":
        return JSON.object()
    try:
        var text = String()
        with open(path, "r") as f:
            text = f.read()
        if text == "":
            return JSON.object()
        # The parser is lenient: handed `{"version":1,"tabs":["` it returns
        # what it managed to read rather than refusing, so a truncated file
        # parses into a plausible-looking document with half a session in it.
        # That is reasonable for a language server's wire, where a short read
        # means "wait for the rest", and wrong for a file, where it means the
        # write was cut off. So the FILE is checked before the parse: a whole
        # JSON object ends in a closing brace, and one that does not is not
        # one. Writes here are atomic, so this only ever catches damage from
        # somewhere else -- which is the damage worth catching.
        var end = text.byte_length()
        let bytes = text.as_bytes()
        while end > 0 and (
            bytes[end - 1] == 32 or bytes[end - 1] == 10
            or bytes[end - 1] == 13 or bytes[end - 1] == 9
        ):
            end -= 1
        if end == 0 or bytes[end - 1] != 125:  # '}'
            return JSON.object()
        var doc = parse(text^)
        if doc.count() == 0 and not doc.has("version"):
            # parse() answers null for anything it could not read; an object
            # with no members is also nothing worth restoring.
            return JSON.object()
        return doc^
    except:
        return JSON.object()


def write(var doc: JSON) -> Bool:
    """Write the session, atomically.

    Through a temporary and a rename, because the alternative is a window in
    which the file is half a document -- and the moment it is written is
    quit, which is exactly when a machine is most likely to be shutting down
    underneath us. rename(2) is atomic on the same filesystem, so a reader
    sees the old file or the new one and never a partial one.
    """
    let path = session_path()
    if path == "":
        return False
    let tmp = path + String(".tmp")
    try:
        let text = doc.serialize()
        with open(tmp, "w") as f:
            f.write(text)
        var a = tmp
        var b = path
        return external_call["rename", Int32](
            a.as_c_string_slice().ptr(), b.as_c_string_slice().ptr()
        ) == 0
    except:
        return False


# ── The document in memory ──────────────────────────────────────────────────
def load():
    """Read the session into memory. Safe to call more than once; the second
    call re-reads, which is what a caller asking again would mean."""
    let slot = g_doc()
    var doc = read()
    if len(slot[]) == 0:
        slot[].append(doc^)
    else:
        slot[][0] = doc^
    g_loaded()[] = 1


def loaded() -> Bool:
    return g_loaded()[] != 0


def document() -> JSON:
    """A copy of the document in memory. Empty before `load`."""
    let slot = g_doc()
    if len(slot[]) == 0:
        return JSON.object()
    return parse(slot[][0].serialize())


def replace(var doc: JSON):
    """Put a document in memory without writing it."""
    let slot = g_doc()
    if len(slot[]) == 0:
        slot[].append(doc^)
    else:
        slot[][0] = doc^
    g_loaded()[] = 1


def flush() -> Bool:
    """Write what is in memory."""
    let slot = g_doc()
    if len(slot[]) == 0:
        return False
    return write(parse(slot[][0].serialize()))


# ── Settings ────────────────────────────────────────────────────────────────
# A dotted key in one flat object rather than a tree: "python.library" is a
# key, not a path through nested objects. Nothing here needs the tree, and a
# flat map cannot disagree with itself about whether "python" is a string or
# an object.
def setting(key: String, fallback: String = String()) -> String:
    let slot = g_doc()
    if len(slot[]) == 0:
        return fallback
    let settings = slot[][0].get("settings")[]
    if not settings.has(key):
        return fallback
    let v = settings.get(key)[]
    if v.is_null():
        return fallback
    return v.as_string()


def setting_int(key: String, fallback: Int) -> Int:
    let s = setting(key)
    if s != "":
        try:
            return Int(s)
        except:
            return fallback
    let slot = g_doc()
    if len(slot[]) == 0:
        return fallback
    let settings = slot[][0].get("settings")[]
    if not settings.has(key):
        return fallback
    let v = settings.get(key)[]
    if v.is_null():
        return fallback
    return v.as_int()


def set_setting(var key: String, var value: String):
    """Set a setting in memory. The write happens at `flush`."""
    let slot = g_doc()
    if len(slot[]) == 0:
        slot[].append(JSON.object())
        g_loaded()[] = 1
    var doc = parse(slot[][0].serialize())
    var settings = JSON.object()
    if doc.has("settings"):
        settings = parse(doc.get("settings")[].serialize())
    settings.set(key^, JSON(value^))
    doc.set(String("settings"), settings^)
    slot[][0] = doc^
