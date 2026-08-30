#!/usr/bin/env bash
# Copy the expensive build outputs somewhere bazel will not delete them.
#
#   ./tools/cache-toolchain.sh            save bazel-bin -> the cache
#   ./tools/cache-toolchain.sh --restore  put the cache back into bazel-bin
#   CACHE_DIR=/somewhere ./tools/cache-toolchain.sh
#
# WHY. libLLVM and libMLIR are ~26 minutes of Xeon and 264 MB, and they live in
# bazel's output base -- which `bazel clean`, a disk-pressure sweep, or a bazel
# version change will remove without asking. Rebuilding them is the single
# longest thing this project does, and nothing about them changes between
# releases unless LLVM itself does.
#
# So they are copied out, with a manifest recording the sha256 and the source
# path of each. --restore puts them back, which turns a `bazel clean` from half
# an hour into thirty seconds.
#
# This is a CACHE, not a distribution: it holds build outputs in bazel's own
# layout, and make-dist.sh is still what arranges them into something usable.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="${CACHE_DIR:-/Volumes/S/toolchain-cache}"
B="$(readlink "$ROOT/bazel-bin" || echo "$ROOT/bazel-bin")"
EXEC="$(cd "$ROOT" && ./bazelw info execution_root 2>/dev/null)"
LLDB_B="$B/external/+llvm_configure+llvm-project/lldb"

# path-under-bazel-bin  ->  what it is
ITEMS=(
  "bazel/llvm-shared/libLLVM.dylib"
  "bazel/mlir-shared/libMLIR.dylib"
  "KGEN/libMojoCompiler.dylib"
  "KGEN/libMojoLLDB.dylib"
  "KGEN/libKGENCompilerRTShared.dylib"
  "KGEN/tools/mojo/mojo"
  "KGEN/tools/mojo-lsp-server/mojo-lsp-server"
  "external/+llvm_configure+llvm-project/lldb/lldb"
  "external/+llvm_configure+llvm-project/lldb/lldb-dap"
  "external/+llvm_configure+llvm-project/lldb/lldb-argdumper"
  "external/+llvm_configure+llvm-project/lldb/liblldb24.0.0git.dylib"
)

if [ "${1:-}" = "--restore" ]; then
  [ -d "$CACHE" ] || { echo "no cache at $CACHE" >&2; exit 1; }
  n=0
  for rel in "${ITEMS[@]}"; do
    src="$CACHE/$rel"
    [ -f "$src" ] || { echo "   missing from cache: $rel"; continue; }
    mkdir -p "$(dirname "$B/$rel")"
    cp -f "$src" "$B/$rel" && n=$((n+1))
  done
  echo "restored $n artifacts into $B"
  exit 0
fi

mkdir -p "$CACHE"
: > "$CACHE/MANIFEST"
total=0; n=0
for rel in "${ITEMS[@]}"; do
  src="$B/$rel"
  if [ ! -f "$src" ]; then
    echo "   NOT BUILT: $rel"
    continue
  fi
  mkdir -p "$(dirname "$CACHE/$rel")"
  cp -f "$src" "$CACHE/$rel"
  sz=$(stat -Lf%z "$src")
  total=$((total + sz)); n=$((n+1))
  printf '%s  %s  %s\n' "$(shasum -a 256 "$src" | cut -c1-16)" \
    "$(printf '%9d' "$sz")" "$rel" >> "$CACHE/MANIFEST"
done
# Which build produced this, so a cache from a different configuration is
# recognisable rather than silently restored over a good tree.
{
  echo "# built from: $B"
  echo "# config:     $(grep -c 'build:release' "$ROOT/.bazelrc" 2>/dev/null) release flags in .bazelrc"
} >> "$CACHE/MANIFEST"
echo "cached $n artifacts, $(( total / 1048576 )) MB -> $CACHE"
