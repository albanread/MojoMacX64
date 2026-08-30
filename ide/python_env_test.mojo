# Pure checks for the path and pip decisions behind Roast's Python manager.
# ROAST_PYTHON_ENV_ROOT is supplied by check-ide.sh, keeping this suite out of
# the user's real Application Support directory.
from std.os import getenv

from python_env import (
    environment_dir,
    package_arguments,
    project_key,
    project_location,
)


def check(name: String, got: String, want: String) -> Int:
    if got == want:
        print("  OK  ", name)
        return 0
    print("  FAIL", name, "-- got", repr(got), "want", repr(want))
    return 1


def check_int(name: String, got: Int, want: Int) -> Int:
    if got == want:
        print("  OK  ", name)
        return 0
    print("  FAIL", name, "-- got", got, "want", want)
    return 1


def main():
    var failures = 0
    failures += check(
        "project root wins",
        project_location(String("/project/a"), String("/other/main.mojo")),
        String("/project/a"),
    )
    failures += check(
        "loose file uses its folder",
        project_location(String(), String("/loose/main.mojo")),
        String("/loose"),
    )
    failures += check(
        "stable project key",
        project_key(String("/project/a")),
        String("f1659aa827aec143"),
    )
    let root = getenv("ROAST_PYTHON_ENV_ROOT")
    if root == "":
        print("  FAIL environment root -- test override missing")
        failures += 1
    else:
        failures += check(
            "venv is outside the project",
            environment_dir(String("/project/a")),
            root + String("/f1659aa827aec143/py-3.14"),
        )

    var one = package_arguments(String("numpy==2.3.1"), String("/project/a"))
    failures += check_int("one requirement argc", len(one), 4)
    if len(one) == 4:
        failures += check("one requirement", one[3], String("numpy==2.3.1"))

    var req = package_arguments(
        String("-r requirements-dev.txt"), String("/project/a")
    )
    failures += check_int("requirements argc", len(req), 5)
    if len(req) == 5:
        failures += check("requirements flag", req[3], String("-r"))
        failures += check(
            "relative requirements",
            req[4],
            String("/project/a/requirements-dev.txt"),
        )

    print()
    if failures == 0:
        print("python environment OK")
    else:
        print("python environment FAILED --", failures, "checks")
