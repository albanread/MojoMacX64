#!/usr/bin/env python3
"""Check AsyncRT ABI symbol parity in both directions.

Every `AsyncRT_*` name Mojo reaches through `external_call` must be defined by
our runtime, or the first build that reaches that path fails to link. The
reverse direction is reported but not failed: an ABI may legitimately offer
more than one tree uses.

This is a script rather than a bazel test on purpose -- the scan crosses the
whole Mojo tree, which is not a dependency a test target can express honestly.

The trap that makes a naive version of this useless: Mojo formats most of these
with the symbol on the line AFTER `external_call[`, so a same-line grep finds a
small fraction and quietly reports success. The scan below is multi-line.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RUNTIME = ROOT / "AsyncRT" / "lib" / "MojoBindings"
MOJO_TREES = [ROOT / "max", ROOT / "mojo"]

# `external_call[` then, possibly after a newline and indentation, "SYMBOL".
CALL_RE = re.compile(r'external_call\s*\[\s*"(AsyncRT_[A-Za-z0-9_]+)"', re.S)
# Definitions: plain extern "C" functions and every VR_STUB_* macro form.
# Note the return type is usually clang-format-wrapped onto its own line, so
# `extern "C"` and the symbol are NOT on the same line -- the gap may contain
# newlines, but never `{` or `;`, which is what bounds the match. Headers are
# excluded so a match means a definition; a symbol declared but never defined
# is the linker's job to catch, not this script's.
DEF_RE = re.compile(
    r'(?:extern\s+"C"[^{;]*?\b(AsyncRT_[A-Za-z0-9_]+)\s*\()'
    r'|(?:VR_STUB_(?:ERR|VOID|ZERO|[A-Z0-9_]+)\s*\(\s*(AsyncRT_[A-Za-z0-9_]+))',
    re.S,
)


def scan(paths, pattern, suffixes):
    found = {}
    for base in paths:
        for path in base.rglob("*"):
            if path.suffix not in suffixes or not path.is_file():
                continue
            try:
                text = path.read_text(errors="ignore")
            except OSError:
                continue
            for match in pattern.finditer(text):
                name = next(g for g in match.groups() if g)
                found.setdefault(name, path.relative_to(ROOT))
    return found


called = scan(MOJO_TREES, CALL_RE, {".mojo"})
defined = scan([RUNTIME], DEF_RE, {".cpp", ".mm"})

print(f"external_call sites reaching AsyncRT: {len(called)}")
print(f"symbols defined by the runtime:       {len(defined)}")

missing = sorted(set(called) - set(defined))
extra = sorted(set(defined) - set(called))

if extra:
    print(f"\ndefined but never called ({len(extra)}) -- reported, not failed:")
    for name in extra:
        print(f"  {name}")

if missing:
    print(f"\nMISSING -- called from Mojo, not defined ({len(missing)}):")
    for name in missing:
        print(f"  {name}  <- {called[name]}")
    sys.exit(1)

print("\nparity OK: every symbol Mojo calls is defined.")
