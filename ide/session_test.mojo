# The session file, without a window.
#
# What is worth pinning here is not "does a round trip work" -- it does, and
# a check that only proves that is a check that passes forever. It is the
# other half: a session file is a file on a disk that may have been edited,
# truncated, or written by a Roast that thought about the world differently,
# and every one of those has to end in "start fresh" rather than in a crash.
#
# ROAST_SESSION points these at a scratch file, which is the same door the
# windowed check uses and the reason none of this touches whatever the person
# at this machine had open.
from session import (
    session_path,
    read,
    write,
    load,
    document,
    replace,
    flush,
    setting,
    setting_int,
    set_setting,
)
from json import JSON, parse
from std.os import getenv


def check(name: String, got: String, want: String) -> Int:
    if got == want:
        print("  OK  ", name)
        return 0
    print("  FAIL", name, "-- got", repr(got), "want", repr(want))
    return 1


def check_int(name: String, got: Int, want: Int) -> Int:
    if got == want:
        print("  OK  ", name, "=", got)
        return 0
    print("  FAIL", name, "-- got", got, "want", want)
    return 1


def put(text: String) raises:
    """Write raw bytes to the session path, so the reader meets what a
    damaged file actually looks like rather than a mock of one."""
    with open(session_path(), "w") as f:
        f.write(text)


def main() raises:
    var failures = 0
    if getenv("ROAST_SESSION") == "":
        print("session: set ROAST_SESSION to a scratch path")
        raise Error("ROAST_SESSION not set")

    print("session: a document survives the round trip")
    var doc = JSON.object()
    doc.set(String("version"), JSON(1))
    doc.set(String("project"), JSON(String("/tmp/proj")))
    var tabs = JSON.array()
    tabs.push(JSON(String("/tmp/a.mojo")))
    tabs.push(JSON(String("/tmp/b.mojo")))
    doc.set(String("tabs"), tabs^)
    doc.set(String("current"), JSON(1))
    failures += check_int("write", 1 if write(doc^) else 0, 1)
    var back = read()
    failures += check_int("version", back.get("version")[].as_int(), 1)
    failures += check("project", back.get("project")[].as_string(), String("/tmp/proj"))
    failures += check_int("tab count", back.get("tabs")[].count(), 2)
    failures += check(
        "second tab", back.get("tabs")[].at(1)[].as_string(), String("/tmp/b.mojo")
    )
    failures += check_int("current", back.get("current")[].as_int(), 1)

    print("session: damage all ends the same way")
    # Each of these is a real thing that happens to a file: a write cut off
    # by a shutdown, an editor that saved something else over it, an empty
    # file left by a full disk. None may raise, and all must answer "nothing
    # worth restoring" so the caller starts fresh.
    # The parser is lenient -- this one used to come back as a two-member
    # object with half a session in it -- so `read` checks the file closes
    # before it parses.
    put(String('{"version":1,"tabs":["'))
    failures += check_int("truncated is empty", read().count(), 0)
    put(String('{"version":1,"tabs":[]'))
    failures += check_int("unclosed object is empty", read().count(), 0)
    put(String('{"version":1,"tabs":[]}   \n'))
    failures += check_int(
        "trailing whitespace is fine", read().get("version")[].as_int(), 1
    )
    put(String("not json at all {{{"))
    failures += check_int("garbage is empty", read().count(), 0)
    put(String(""))
    failures += check_int("empty file is empty", read().count(), 0)
    put(String("[1,2,3]"))
    failures += check_int(
        "an array where an object belongs", read().get("tabs")[].count(), 0
    )
    put(String('{"tabs":"not-an-array"}'))
    failures += check_int(
        "a string where an array belongs", read().get("tabs")[].count(), 0
    )
    put(String('{"version":1}'))
    failures += check_int(
        "a missing key reads as absent", read().get("frame")[].count(), 0
    )

    print("session: settings")
    put(String('{"version":1}'))
    load()
    failures += check(
        "absent setting falls back",
        setting(String("python.library"), String("none")),
        String("none"),
    )
    set_setting(String("python.library"), String("/usr/lib/libpython3.13.dylib"))
    set_setting(String("theme"), String("dark"))
    failures += check(
        "set then read",
        setting(String("python.library")),
        String("/usr/lib/libpython3.13.dylib"),
    )
    failures += check_int("flush", 1 if flush() else 0, 1)
    load()
    failures += check(
        "settings survive a reload", setting(String("theme")), String("dark")
    )
    failures += check(
        "and so does the other one",
        setting(String("python.library")),
        String("/usr/lib/libpython3.13.dylib"),
    )
    # A number written as a number, not as a string: an integer setting has
    # to read back whichever way it went in, because a hand-edited file will
    # have one and a program-written file the other.
    var d2 = document()
    var st = JSON.object()
    st.set(String("tab.width"), JSON(4))
    d2.set(String("settings"), st^)
    replace(d2^)
    failures += check_int("int setting", setting_int(String("tab.width"), 0), 4)
    failures += check_int(
        "int setting falls back", setting_int(String("nope"), 8), 8
    )

    print("session: the settings a save carries across")
    # capture_session() in roast.mojo rebuilds every other key from live
    # state but copies settings across, because nothing live derives them.
    # This is that contract in miniature: replace the document, keep the
    # settings, and they are still there.
    var fresh = JSON.object()
    fresh.set(String("version"), JSON(1))
    let held = document()
    if held.has("settings"):
        fresh.set(String("settings"), parse(held.get("settings")[].serialize()))
    replace(fresh^)
    failures += check_int("tabs gone", document().get("tabs")[].count(), 0)
    failures += check_int(
        "settings kept", setting_int(String("tab.width"), 0), 4
    )

    print()
    if failures == 0:
        print("session OK")
    else:
        print("session FAILED:", failures)
        raise Error("session tests failed")
