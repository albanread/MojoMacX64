# Tests for the build driver: which file gets compiled, where the binary goes,
# and taking the compiler's diagnostics apart.
#
# The process side is not tested here -- launching a compiler needs a
# distribution and a window's timer -- but everything that decides *what* to
# launch is arithmetic on strings, and that is where the bugs are.
from build import (
    entry_point,
    binary_for,
    parse_issues,
    first_error,
)
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


def main() raises:
    var failures = 0

    print("build: where the binary goes")
    failures += check(
        "beside the entry point",
        binary_for(String("/p/fern/main.mojo")),
        String("/p/fern/build/main"),
    )
    failures += check(
        "stem keeps its name",
        binary_for(String("/p/tools/roast.mojo")),
        String("/p/tools/build/roast"),
    )
    failures += check(
        "a bare file still lands somewhere",
        binary_for(String("hello.mojo")),
        String("./build/hello"),
    )

    print("build: choosing the entry point")
    let repo = getenv("ROAST_REPO")
    if repo == "":
        print("  SKIP  entry point -- set ROAST_REPO to the checkout")
    else:
        # main.mojo wins, and it wins over the file being edited.
        failures += check(
            "main.mojo in the root",
            entry_point(
                repo + String("/examples/fern"),
                repo + String("/examples/fern/png.mojo"),
            ),
            repo + String("/examples/fern/main.mojo"),
        )
        # No project: the file being edited is the answer.
        failures += check(
            "a loose file builds itself",
            entry_point(String(), repo + String("/examples/fern/png.mojo")),
            repo + String("/examples/fern/png.mojo"),
        )
        # Self-hosting: `ide/` has no main.mojo and six files that declare a
        # main, five of them tests. The project's entry point is the app.
        failures += check(
            "tests are not entry points",
            entry_point(repo + String("/ide"), String()),
            repo + String("/ide/roast.mojo"),
        )
        # ...unless the test is the file being looked at, in which case it is
        # obviously the thing meant to be built.
        failures += check(
            "the file on screen wins",
            entry_point(
                repo + String("/ide"), repo + String("/ide/rope_test.mojo")
            ),
            repo + String("/ide/rope_test.mojo"),
        )
        # A file in the project that is not an entry point does not become one.
        failures += check(
            "a plain module is not an entry point",
            entry_point(
                repo + String("/ide"), repo + String("/ide/rope.mojo")
            ),
            repo + String("/ide/roast.mojo"),
        )
        # A folder with no .mojo in its root falls through to the same place,
        # rather than guessing at something in a subfolder.
        failures += check(
            "no entry point in the root",
            entry_point(
                repo + String("/examples"),
                repo + String("/examples/hello/main.mojo"),
            ),
            repo + String("/examples/hello/main.mojo"),
        )

    print("build: reading diagnostics")
    var log = String(
        "/p/fern/main.mojo:12:6: error: unable to locate module 'ifs'\n"
        "from ifs import Affine\n"
        "     ^\n"
        "/p/fern/png.mojo:70:20: warning: unused variable 'n'\n"
        "/p/fern/main.mojo:88:26: error: cannot call function that may raise\n"
        "cocoamojo-compiler: error: failed to parse the provided Mojo source\n"
    )
    var issues = parse_issues(log)
    # Four diagnostics: three with a location and the compiler's own summary,
    # which has no line and column and is therefore not one.
    failures += check_int("diagnostics found", len(issues), 3)
    if len(issues) == 3:
        failures += check("first path", issues[0].path, String("/p/fern/main.mojo"))
        failures += check_int("first line", issues[0].line, 12)
        failures += check_int("first column", issues[0].col, 6)
        failures += check_int("first severity", issues[0].severity, 1)
        failures += check(
            "first message",
            issues[0].message,
            String("unable to locate module 'ifs'"),
        )
        failures += check_int("second is a warning", issues[1].severity, 2)
        failures += check("second path", issues[1].path, String("/p/fern/png.mojo"))
        failures += check_int("third line", issues[2].line, 88)

    let e = first_error(log)
    failures += check("first error skips nothing", e.path, String("/p/fern/main.mojo"))
    failures += check_int("first error line", e.line, 12)

    # A log with only warnings has no error to jump to.
    let clean = first_error(String("/p/a.mojo:1:1: warning: nothing\n"))
    failures += check_int("no error means no jump", clean.line, 0)

    # A path with a colon in it: the numbers are read from the right, so this
    # survives. Directories like that exist and are nobody's fault.
    var odd = parse_issues(
        String("/Volumes/x:y/a.mojo:3:9: error: boom\n")
    )
    failures += check_int("colon in the path: count", len(odd), 1)
    if len(odd) == 1:
        failures += check("colon in the path: path", odd[0].path, String("/Volumes/x:y/a.mojo"))
        failures += check_int("colon in the path: line", odd[0].line, 3)

    print()
    if failures == 0:
        print("build OK")
    else:
        print("build FAILED --", failures, "checks")
