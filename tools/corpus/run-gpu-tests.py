#!/usr/bin/env python3
"""Census of the GPU kernel tests on this port: what actually runs, and passes.

Why not `bazel test`: our platform does not satisfy the mojo_gpu_toolchains
`has_gpu` constraint, so every GPU test target is "incompatible" and refuses to
build. Bazel therefore reports nothing rather than a failure, and the disabled
backlog silently leaves the denominator -- coverage appears to improve as more
of it is switched off.

We do not need it. These tests build directly with the vega-sdk wrapper once
`max/kernels/src` is on the import path, which is the entire reason the direct
path looked broken.

Outcome taxonomy follows the M4 Max port's, so the two censuses are
comparable:

    pass        ran real work, no skip marker, no failure text
    vacuous     exited clean but every path was skipped
    partial     ran some work and skipped some
    fail        ran and failed an assertion, or raised
    pso         the driver refused the pipeline
    crash       killed by a signal
    timeout     exceeded the per-test limit
    build_fail  did not compile, cause unclassified

Build failures are split rather than pooled, because for a backend port they
are four different bugs with four different owners:

    generic_deref     our own static checker refused the module: a generic
                      addrspace(0) pointer is dereferenced and AIR has no
                      generic address space. A real port defect, precisely
                      located -- this is the capture-pack family.
    unsupported_tgt   the test hardcodes another backend (amdgcn-amd-amdhsa,
                      nvptx). Not our path; out of scope rather than broken.
    metallib_fail     the AIR module was rejected when packed. Backend defect,
                      but a later and different one than generic_deref.
    unverified  ran clean, but the SOURCE has nothing that could fail it

`unverified` proves the absence of a failure mechanism, not the strength of one
that exists: a test with no assertion cannot go red, so its pass is worth
nothing as evidence.

EXIT CODE IS NOT ENOUGH. The rms_norm test prints
"Unhandled exception ... AssertionError" and still exits 0, so the classifier
reads output as well. Trusting the code alone would have scored a numerically
wrong kernel as a pass.
"""

import argparse
import concurrent.futures
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
MOJO = ROOT / "vega-sdk" / "bin" / "mojo"
IMPORTS = ROOT / "max" / "kernels" / "src"

# Vendor-specific tests that cannot apply here. Matched against the path.
OUT_OF_SCOPE = re.compile(
    r"(sm_?90|sm_?100|h100|b200|hopper|blackwell|nvshmem|cutlass|"
    r"gfx94|mi300|mi325|tma_|_tma|cuda_graph|multi_gpu|nccl|"
    r"cluster)", re.I)   # thread-block clusters are sm_90+ only

FAIL_TEXT = re.compile(
    r"(AssertionError|Unhandled exception|error:|Traceback|"
    r"FAILED|assert.*failed)", re.I)
PSO_TEXT = re.compile(
    r"(newComputePipelineStateWithFunction|SC compilation failure|"
    r"undefined label|XPC_ERROR|MTLCompiler)", re.I)
SKIP_TEXT = re.compile(r"\b(SKIP|SKIPPED|not supported|unsupported)\b")
# Something in the source that could actually fail the test.
ASSERT_SRC = re.compile(
    r"(assert_|CHECK|raise\b|abort\(|testing\.assert|\bassert\b)")


def discover(limit=None, subdir=None):
    base = ROOT / "max" / "kernels" / "test" / "gpu"
    if subdir:
        base = base / subdir
    files = sorted(p for p in base.rglob("*.mojo") if p.is_file())
    files = [f for f in files if not OUT_OF_SCOPE.search(str(f))]
    return files[:limit] if limit else files


GENERIC_DEREF = re.compile(r"generic \(addrspace\(0\)\) pointer")
UNSUPPORTED_TGT = re.compile(r"target '[^']+' is not supported by this build")
METALLIB_FAIL = re.compile(r"xcrun metallib failed")


def build_failure_kind(err):
    if GENERIC_DEREF.search(err):
        return "generic_deref"
    if UNSUPPORTED_TGT.search(err):
        return "unsupported_tgt"
    if METALLIB_FAIL.search(err):
        return "metallib_fail"
    return "build_fail"


def build(src, outdir):
    out = pathlib.Path(outdir) / (src.stem + ".bin")
    env = dict(os.environ)
    env["MODULAR_MOJO_MAX_IMPORT_PATH"] = str(IMPORTS)
    env.setdefault("MODULAR_CACHE_DIR", tempfile.mkdtemp(prefix="census."))
    try:
        r = subprocess.run(
            [str(MOJO), "build", "--target-accelerator=metal-vega2",
             "-o", str(out), str(src)],
            capture_output=True, text=True, timeout=600, env=env)
    except subprocess.TimeoutExpired:
        return None, "build timed out"
    if r.returncode != 0 or not out.exists():
        err = "\n".join(l for l in (r.stderr or "").splitlines()
                        if "error:" in l or "addrspace(0)" in l)[:600]
        return None, err or "build failed"
    return out, ""


def classify(src, binary, timeout):
    try:
        r = subprocess.run([str(binary)], capture_output=True, text=True,
                           timeout=timeout)
    except subprocess.TimeoutExpired:
        return "timeout", ""
    out = ((r.stdout or "") + (r.stderr or ""))
    out = "\n".join(l for l in out.splitlines() if "Crashpad" not in l)

    if r.returncode is not None and r.returncode < 0:
        return "crash", f"signal {-r.returncode}"
    if PSO_TEXT.search(out):
        return "pso", PSO_TEXT.search(out).group(0)
    if FAIL_TEXT.search(out):
        m = re.search(r"(AssertionError[^\n]{0,120})", out)
        return "fail", (m.group(1) if m else FAIL_TEXT.search(out).group(0))
    if r.returncode != 0:
        return "fail", f"exit {r.returncode}"

    skipped = bool(SKIP_TEXT.search(out))
    did_work = len([l for l in out.splitlines() if l.strip()]) > 0
    if skipped and not did_work:
        return "vacuous", ""
    if skipped:
        return "partial", ""
    if not ASSERT_SRC.search(src.read_text(errors="ignore")):
        return "unverified", "source has no failure path"
    return "pass", ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int)
    ap.add_argument("--subdir")
    ap.add_argument("--timeout", type=int, default=180)
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--out", default="/tmp/gpu-census.json")
    args = ap.parse_args()

    files = discover(args.limit, args.subdir)
    print(f"scope: {len(files)} GPU test files", flush=True)
    outdir = tempfile.mkdtemp(prefix="census-bin.")
    results = []

    # Builds parallelise; runs must not -- there is one GPU.
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        built = list(pool.map(lambda f: (f,) + build(f, outdir), files))

    for i, (src, binary, err) in enumerate(built, 1):
        rel = str(src.relative_to(ROOT))
        if binary is None:
            outcome, detail = build_failure_kind(err), err
        else:
            outcome, detail = classify(src, binary, args.timeout)
        results.append({"test": rel, "outcome": outcome, "detail": detail})
        print(f"[{i}/{len(built)}] {outcome:<11} {rel}", flush=True)

    counts = {}
    for r in results:
        counts[r["outcome"]] = counts.get(r["outcome"], 0) + 1
    print("\n== census ==")
    for k in ("pass", "unverified", "partial", "vacuous", "fail", "pso",
              "crash", "timeout", "generic_deref", "metallib_fail",
              "unsupported_tgt", "build_fail"):
        if counts.get(k):
            print(f"  {k:<11} {counts[k]:>4}")
    print(f"  {'TOTAL':<11} {len(results):>4}")
    pathlib.Path(args.out).write_text(json.dumps(results, indent=1))
    print(f"\nwritten to {args.out}")


if __name__ == "__main__":
    main()
