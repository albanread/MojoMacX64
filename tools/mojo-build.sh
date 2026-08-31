#!/usr/bin/env bash
# Build the toolchain the one right way, so it cannot be built a wrong one.
#
#   ./tools/mojo-build.sh              the whole toolchain, ready for make-dist
#   ./tools/mojo-build.sh compiler     just //KGEN/tools/mojo:mojo
#   ./tools/mojo-build.sh debugger     lldb, lldb-dap, the MojoLLDB plugin
#   ./tools/mojo-build.sh libs         libLLVM, libMLIR, libMojoCompiler
#   ./tools/mojo-build.sh //some:target   any target, with the right configs
#
# Why this exists, in one sentence: `./bazelw build //KGEN:mojo` -- the obvious
# command, the one in muscle memory -- is WRONG, and wrong in a way that does
# not fail. It builds under --compilation_mode=dbg with -fvisibility=hidden, so
# libLLVM.dylib comes out exporting 192 symbols instead of 37,000 and the
# compiler comes out without the class support the IDE needs. Both look built.
# Both pass a smoke test. The failure surfaces an hour later, in make-dist or in
# a linker error nobody connects back to the missing --config.
#
# It has now cost one release three attempts. The fix is not to remember two
# flags every time; it is to stop typing bazel by hand. The correct build is
#
#   ./bazelw build --config=build-mojo --config=release <targets>
#
# and this script is the only thing that should ever run it. --config=release
# gets its own output tree (darwin_x86_64-opt here), so this never disturbs a working
# dbg toolchain, and it is where make-dist's bazel-bin points.
set -uo pipefail
cd "$(dirname "$0")/.."

CONFIGS=(--config=build-mojo --config=release)

# The toolchain, as make-dist needs it: the compiler, the shared libraries the
# IDE links, the language server, and the debugger set. Grouped so a person can
# ask for one part without knowing the label.
GROUP_compiler=(//KGEN/tools/mojo:mojo)
GROUP_libs=(//bazel/llvm-shared:LLVM //bazel/mlir-shared:MLIR //KGEN:MojoCompilerShared)
GROUP_lsp=(//KGEN/tools/mojo-lsp-server:mojo-lsp-server)
GROUP_debugger=(//KGEN:MojoLLDB
  @llvm-project//lldb:lldb @llvm-project//lldb:lldb-dap @llvm-project//lldb:lldb-argdumper)
GROUP_all=("${GROUP_compiler[@]}" "${GROUP_libs[@]}" "${GROUP_lsp[@]}" "${GROUP_debugger[@]}")

arg="${1:-all}"
case "$arg" in
  -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  compiler|libs|lsp|debugger|all)
    var="GROUP_$arg[@]"
    targets=("${!var}")
    shift
    ;;
  //*|@*)                       # an explicit target: still gets the configs
    targets=("$@")
    set --
    ;;
  *) echo "mojo-build: unknown group '$arg' (try: compiler libs lsp debugger all, or a //target)" >&2
     exit 64 ;;
esac

echo "== building with ${CONFIGS[*]} =="
printf '   %s\n' "${targets[@]}"
./bazelw build "${CONFIGS[@]}" "${targets[@]}" "$@"
rc=$?

if [ "$rc" -ne 0 ]; then
  echo "mojo-build: bazel failed ($rc). The dbg toolchain, if any, is untouched." >&2
  exit "$rc"
fi

# Prove the libraries came out usable, when they were part of this build. A
# dylib that exports nothing is the exact failure the configs prevent, so the
# wrapper that enforces the configs also checks the result -- belt and braces,
# because this is the failure that keeps coming back.
B="$(readlink bazel-bin 2>/dev/null || echo bazel-bin)"
check() {
  local path="$1" pattern="$2" min="$3" name="$4"
  [ -f "$path" ] || return 0
  local n; n="$(nm -gU "$path" 2>/dev/null | grep -c "$pattern")"
  if [ "$n" -le "$min" ]; then
    echo "mojo-build: $name exports $n $pattern symbols, wanted > $min" >&2
    echo "   this is the visibility regression --config=release exists to prevent;" >&2
    echo "   the build 'succeeded' but the artifact is unusable. Not a warning." >&2
    exit 1
  fi
  printf '   %-24s %s %s symbols\n' "$name" "$n" "$pattern"
}
case "$arg" in libs|all)
  echo "== verifying exported symbols =="
  L="$(find "$B" -name libLLVM.dylib -type f 2>/dev/null | head -1)"
  M="$(find "$B" -name libMLIR.dylib -type f 2>/dev/null | head -1)"
  check "$L" '4llvm' 10000 "libLLVM.dylib"
  check "$M" '4mlir' 10000 "libMLIR.dylib"
  check "$B/KGEN/libMojoCompiler.dylib" 'MojoParserContext' 10 "libMojoCompiler.dylib"
  ;;
esac
echo "== done =="
