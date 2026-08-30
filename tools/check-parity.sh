#!/bin/sh
# Fail if this fork has drifted from MojoCocoa anywhere it should not have.
#
# The prize is consistency, not innovation (PARITY_SPRINT.md). Divergence that
# x86-64 genuinely requires is fine and goes in parity-allowlist.txt; divergence
# that crept in because someone reworded a comment, renamed a function or
# "improved" a diagnostic is the failure this catches.
#
# It exists because that failure happened four times in one sprint: a renamed
# attributeObjCBases, a rewritten body, three reworded comment blocks, a helper
# never ported at all, and -- the expensive one -- a BOOL encoding changed
# locally to work around a check upstream had already fixed.
#
# Compared against tools/parity-base.txt: the commit in THEIR history this fork
# claims parity with. Bump it when a step lands, never to silence a failure.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 2
BASE=$(cat tools/parity-base.txt)
ALLOW=tools/parity-allowlist.txt
fails=0

allowed() {  # path, symbol
  grep -v '^#' "$ALLOW" | grep -q "^$1|$2|" && return 0
  grep -v '^#' "$ALLOW" | grep -q "^$1|WHOLEFILE|" && return 0
  return 1
}

# --- Whole files that must match exactly ---------------------------------
# A file with a symbol-level allowlist entry is not simply excused. Their
# version of the allowed symbol is spliced back into our copy, and what remains
# must be identical -- so drift ELSEWHERE in an allowlisted file still fails.
python3 - "$BASE" <<'PY' || fails=$((fails+1))
import re, subprocess, sys, pathlib
base = sys.argv[1]
files = ["mojo/stdlib/std/objc/classes.mojo", "mojo/stdlib/std/objc/runtime.mojo",
         "mojo/stdlib/std/objc/error.mojo", "mojo/stdlib/std/objc/ownership.mojo",
         "mojo/stdlib/std/objc/foundation.mojo", "mojo/stdlib/std/objc/geometry.mojo",
         "mojo/stdlib/std/objc/dispatch.mojo", "mojo/stdlib/std/objc/__init__.mojo",
         "mojo/stdlib/std/objc/typed.mojo",
         "KGEN/lib/MojoParser/Signatures.cpp", "KGEN/lib/MojoParser/ParserExprs.cpp",
         "KGEN/lib/MojoParser/ParserStmts.cpp"]
allow = [l.strip().split("|") for l in open("tools/parity-allowlist.txt")
         if l.strip() and not l.startswith("#")]
def body(src, sig):
    try: i = src.index(sig)
    except ValueError: return None
    m = re.search(r"\n\}\n", src[i:]) or re.search(r"\n\n\n", src[i:])
    return src[i:i+m.end()] if m else None
bad = 0
for f in files:
    r = subprocess.run(["git","show",f"{base}:{f}"],capture_output=True,text=True)
    if r.returncode:
        print(f"  MISSING UPSTREAM  {f}"); bad += 1; continue
    theirs, ours = r.stdout, pathlib.Path(f).read_text()
    if theirs == ours:
        continue
    if any(p == f and sym == "WHOLEFILE" for p, sym, _h, _r in allow):
        print(f"  allowed (whole)   {f}"); continue
    # Splice their version of each allowed symbol into our copy.
    patched = ours
    syms = [sym for p, sym, _h, _r in allow if p == f and sym != "WHOLEFILE"]
    for sym in syms:
        for sig in (f"def {sym}(", f"static {sym}(", sym + "("):
            a, b = body(theirs, sig), body(patched, sig)
            if a and b:
                patched = patched.replace(b, a, 1); break
    if patched == theirs:
        print(f"  allowed ({', '.join(syms)})  {f}")
    else:
        n = sum(1 for l in __import__("difflib").unified_diff(
            theirs.splitlines(), patched.splitlines(), n=0)
            if l.startswith(("+","-")) and not l.startswith(("+++","---")))
        print(f"  DRIFT  {f}: {n} lines differ beyond the allowlisted symbols")
        bad += 1
sys.exit(1 if bad else 0)
PY

# --- Named symbols inside files the two forks legitimately share ---------
# DeclResolution.cpp carries far more than the Objective-C work, so it is
# compared function by function rather than whole.
python3 - "$BASE" <<'PY' || fails=$((fails+1))
import re, subprocess, sys, pathlib
base = sys.argv[1]
targets = {
 "KGEN/lib/MojoParser/DeclResolution.cpp": [
   "static bool objcClassHasBox(", "static Value objcBoxOffsetGlobal(",
   "static Value objcRefAtByteOffset(", "static FnOp synthesizeObjCTrampoline(",
   "static void synthesizeObjCIdField(", "static void synthesizeObjCRegistration(",
   "static void attributeObjCBases(", "static std::optional<StringRef> encodeObjCType(",
   "static SmallVector<StringRef> splitObjCEncoding(",
   "static void checkAgainstSDKEncoding(", "static void checkObjCABISupport(",
   "objcMethodEncoding(SharedState", "deriveObjCSelector(SharedState",
   "void FnSigDecorators::applyObjCSelector(",
   "static FnOp synthesizeObjCSuperThunk("],
 "mojo/stdlib/std/objc/runtime.mojo": ["def _nth_class_kind("],
}
allow = [l.strip().split("|") for l in open("tools/parity-allowlist.txt")
         if l.strip() and not l.startswith("#")]
def fn(src, sig):
    try: i = src.index(sig)
    except ValueError: return None
    m = re.search(r'\n\}\n', src[i:]) or re.search(r'\n\n\n', src[i:])
    return src[i:i+m.end()] if m else None
bad = 0
for path, sigs in targets.items():
    theirs = subprocess.run(["git","show",f"{base}:{path}"],capture_output=True,text=True).stdout
    ours = pathlib.Path(path).read_text()
    for s in sigs:
        name = s.split()[-1].rstrip("(").lstrip("*")
        a, b = fn(theirs, s), fn(ours, s)
        ok = any(p == path and (sym == name or sym == "WHOLEFILE") for p, sym, _h, _r in allow)
        if a is None:
            print(f"  {name}: absent upstream -- ours only, and not allowlisted" if not ok else f"  allowed  {name}")
            if not ok: bad += 1
        elif b is None:
            print(f"  DRIFT    {name}: present upstream, ABSENT here"); bad += 1
        elif a != b and not ok:
            n = sum(1 for l in __import__("difflib").unified_diff(a.splitlines(), b.splitlines(), n=0)
                    if l.startswith(("+","-")) and not l.startswith(("+++","---")))
            print(f"  DRIFT    {name}: {n} lines differ from upstream"); bad += 1
        elif a != b:
            import hashlib
            want = next((h for p2, s2, h, _ in allow
                         if p2 == path and s2 == name), None)
            got = hashlib.sha256(b.encode()).hexdigest()[:16]
            if want and want != "-" and want != got:
                print(f"  DRIFT    {name}: allowlisted, but OUR version changed "
                      f"({got}, recorded {want}). If the change is intended, "
                      f"update tools/parity-allowlist.txt.")
                bad += 1
            else:
                print(f"  allowed  {name}")
sys.exit(1 if bad else 0)
PY

# --- The spike suite, compared as a DIRECTORY ----------------------------
# The acceptance tests are the signal that the port works, so they drift like
# any other file -- and worse, silently, because a stale test still passes.
#
# Compared as a directory rather than a list, because a list only catches the
# third of the three ways this actually went wrong in one morning:
#   drifted   -- class_test.mojo and registrar_test.mojo sat at an older
#                revision for the whole sprint while passing every run
#   unported  -- typed_call_test.mojo, the test for the feature being ported
#   invented  -- typed_test.mojo, a name upstream never had, empty, and the
#                only reason it was noticed is that an empty file cannot run
python3 - "$BASE" <<'SPIKES' || fails=$((fails+1))
import subprocess, sys, pathlib
base = sys.argv[1]
D = "spikes/s5-cocoakb"
allow = [l.strip().split("|") for l in open("tools/parity-allowlist.txt")
         if l.strip() and not l.startswith("#")]
def ok(path):
    return any(p == path for p, _s, _h, _r in allow)
theirs = set(subprocess.run(["git", "ls-tree", "-r", "--name-only", base, "--", D],
                            capture_output=True, text=True).stdout.split())
ours = {D + "/" + p.name for p in pathlib.Path(D).iterdir() if p.is_file()}
bad = 0
for f in sorted(theirs - ours):
    if ok(f): print("  allowed (absent)  " + f); continue
    print("  NOT PORTED        " + f); bad += 1
for f in sorted(ours - theirs):
    if ok(f): print("  allowed (extra)   " + f); continue
    print("  INVENTED          " + f + "  (upstream has no such file)"); bad += 1
for f in sorted(theirs & ours):
    t = subprocess.run(["git", "show", base + ":" + f],
                       capture_output=True, text=True).stdout
    if t == pathlib.Path(f).read_text(): continue
    if ok(f): print("  allowed (whole)   " + f); continue
    print("  DRIFT             " + f + "  (differs from upstream)"); bad += 1
sys.exit(1 if bad else 0)
SPIKES

# --- Property checks: invariants a diff cannot express -------------------
# Every ABI query must read an x86-64 table. This is the divergence that is
# REQUIRED, so it is asserted rather than diffed.
# x86-64 has three send entry points. Upstream answers a constant because arm64
# has one; a literal surviving here means a struct return would be fetched from
# a register that was never written.
if grep -n "'objc_msgSend'" KGEN/lib/CocoaKB/CocoaKBDatabase.cpp >/dev/null 2>&1; then
  echo "DRIFT  CocoaKBDatabase.cpp hard-codes a send variant; x86-64 must read m.msgsend"
  grep -n "'objc_msgSend'" KGEN/lib/CocoaKB/CocoaKBDatabase.cpp
  fails=$((fails+1))
fi

if grep -nE "FROM (method_abi|posix_function_abi)\b" KGEN/lib/CocoaKB/CocoaKBDatabase.cpp >/dev/null 2>&1; then
  echo "DRIFT  CocoaKBDatabase.cpp reads an arm64 ABI table; every ABI query must use the _x64 form"
  grep -nE "FROM (method_abi|posix_function_abi)\b" KGEN/lib/CocoaKB/CocoaKBDatabase.cpp
  fails=$((fails+1))
fi

if [ "$fails" -eq 0 ]; then
  echo "parity OK against $BASE"
  exit 0
fi
echo
echo "$fails parity failure(s). Either port the upstream form, or add an entry to"
echo "tools/parity-allowlist.txt WITH EVIDENCE. Do not bump parity-base.txt to hide it."
exit 1
