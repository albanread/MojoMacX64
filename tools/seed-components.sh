#!/usr/bin/env bash
# Seed the component cache from a CocoaMojo tree that is known to be good.
#
#   ./tools/seed-components.sh /Volumes/Roast/payload/CocoaMojo cc63149b
#   ./tools/seed-components.sh /Applications/Roast.app/Contents/Resources/CocoaMojo
#
# For when bazel-out no longer holds a usable component but a shipped release
# does. That is not hypothetical: a release was cut this morning whose
# libLLVM.dylib exports 37,113 symbols, and by the afternoon the only copy in
# bazel-out was a stub exporting none. The good one existed the whole time --
# inside the image we had already shipped.
#
# Everything is checked before it is stored. A component that fails its own
# test is refused rather than cached, because a cache that will hold a stub is
# a way to ship the regression forever.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
. "$ROOT/tools/components.sh"

SRC="${1:?usage: seed-components.sh <CocoaMojo dir> [commit]}"
COMMIT="${2:-unknown}"
[ -d "$SRC/lib" ] || { echo "seed: $SRC does not look like a CocoaMojo tree" >&2; exit 1; }

export COMPONENT_SOURCE="seeded from $SRC"
count=0

symbols() { nm -gU "$1" 2>/dev/null | grep -c "$2" || true; }

# seed <group> <file> <destsubdir> <pattern> <minimum>
seed() {
  local group="$1" file="$2" dest="$3" pattern="$4" min="$5"
  local path="$SRC/$dest/$file"
  if [ ! -f "$path" ]; then
    printf '   %-14s absent\n' "$group"
    return
  fi
  if [ -n "$pattern" ]; then
    local n; n="$(symbols "$path" "$pattern")"
    if [ "$n" -le "$min" ]; then
      printf '   %-14s REFUSED: exports %s %s symbols, wanted more than %s\n' \
        "$group" "$n" "$pattern" "$min"
      return
    fi
    printf '   %-14s %s symbols, stored\n' "$group" "$n"
  else
    printf '   %-14s stored\n' "$group"
  fi
  components_store "$group" "$COMMIT" "$path:$dest" || {
    printf '   %-14s cache write failed\n' "$group"; return; }
  count=$((count + 1))
}

echo "== seeding the component cache from a known-good tree =="
seed llvm          libLLVM.dylib         lib '4llvm'            10000
seed mlir          libMLIR.dylib         lib '4mlir'            10000
seed mojocompiler  libMojoCompiler.dylib lib 'MojoParserContext'   10
seed lsp           mojo-lsp-server       bin ''                     0

# The debugger is a set, not a file: the plugin and the libraries it loads
# have to come from the same build or the plugin will not bind.
DBG=("$SRC/bin/lldb-dap:bin" "$SRC/bin/lldb:bin"
     "$SRC/lib/liblldb24.0.0git.dylib:lib" "$SRC/lib/lldb-argdumper:lib"
     "$SRC/lib/libMojoLLDB.dylib:lib")
ok=1
for spec in "${DBG[@]}"; do [ -f "${spec%%:*}" ] || ok=0; done
if [ "$ok" = 1 ]; then
  components_store debugger "$COMMIT" "${DBG[@]}" \
    && { echo "   debugger       five artifacts, stored"; count=$((count + 1)); } \
    || echo "   debugger       cache write failed"
else
  echo "   debugger       incomplete in $SRC, not stored"
fi

echo "   $count component groups cached at ${COCOAMOJO_COMPONENTS:-$ROOT/.components}"
