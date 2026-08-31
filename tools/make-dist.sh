#!/usr/bin/env bash
# Build dist/MojoMacX64 -- a self-contained toolchain with no bazel in it.
#
# Ported from the sister fork's tools/make-dist.sh. The STRUCTURE is theirs and
# deliberately unchanged -- same bin/lib/share/include layout, same inventory,
# same refusals. Four things differ because they have to: the distribution's
# name, the architecture passed to clang, the GPU runtime (VegaRT here,
# CocoaMojoGPU there -- different sources, same job), and where the Cocoa
# database is generated from. Everything else, including the checks that make a
# silent failure loud, is theirs.
#
# Bazel builds the compiler. It has no business being in the way afterwards, and
# it was: handing a build action one environment variable via --action_env re-keys
# every action in the graph, so changing where the SDK database lives rebuilt LLVM.
# That is what this script removes. Run it once after a compiler build; from then
# on `cocoamojo --build` and `--run` are the whole interface.
#
#   ./tools/make-dist.sh
#   dist/MojoMacX64/bin/cocoamojo --run examples/mandelbrot/main.mojo
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
B="$(readlink bazel-bin || echo bazel-bin)"
# Where the distribution goes. Overridable, and that is not a convenience:
# rewriting dist/MojoMacX64 pulls the binaries and the stdlib out from under a
# running Roast, which is a genuinely unpleasant thing to do to someone who is
# using the IDE at the time. Compiler work that only needs something to test
# against should point this somewhere private:
#   DIST_DIR=/tmp/mine ./tools/make-dist.sh
D="${DIST_DIR:-$ROOT/dist/MojoMacX64}"
KB="${COCOAKB:-/Volumes/S/CocoaBaseMCP/cocoa.sqlite}"

# Our own cache of built components, so a release does not depend on bazel
# having kept its scratch tree. See tools/components.sh.
. "$ROOT/tools/components.sh"
HEAD_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"

[ -x "$B/KGEN/tools/mojo/mojo" ] || { echo "build the compiler first:"; \
  echo "  ./bazelw build --config=build-mojo //KGEN:mojo"; exit 1; }

mkdir -p "$D"/{bin,lib,share}

echo "== compiler =="
cp -f "$B/KGEN/tools/mojo/mojo" "$D/bin/cocoamojo-compiler"
cp -f "$ROOT/tools/cocoamojo" "$D/bin/cocoamojo"; chmod +x "$D/bin/cocoamojo"

# The language server, for editors. It speaks LSP on stdin/stdout and shares
# libLLVM.dylib with the compiler rather than carrying a second copy.
LSP_B="$B/KGEN/tools/mojo-lsp-server/mojo-lsp-server"
if [ -f "$LSP_B" ]; then
  cp -f "$LSP_B" "$D/bin/"
  components_store lsp "$HEAD_COMMIT" "$LSP_B:bin" \
    || echo "   (could not write the component cache)"
  echo "   mojo-lsp-server"
elif components_have lsp && ! components_stale lsp KGEN; then
  components_restore lsp "$D" \
    && echo "   mojo-lsp-server (cached, built $(components_built lsp))" \
    || echo "   no mojo-lsp-server (cache unreadable)"
elif components_have lsp; then
  echo "   no mojo-lsp-server: the cached one is from $(components_commit lsp)"
  echo "   and KGEN has changed since -- ./tools/mojo-build.sh lsp"
else
  echo "   no mojo-lsp-server (./tools/mojo-build.sh lsp)"
fi

# The debugger: our lldb-dap with the MojoLLDB plugin beside it, which is
# what turns "breakpoints bind and the editor follows" into "frame variable
# answers" (spikes/MOJOLLDB-SPIKE.md records the whole story). The layout is
# load-bearing and free: liblldb's install name is @rpath/... and the
# binaries already carry @loader_path/../lib as their first rpath, so
# bin/ + lib/ resolves everything with no install_name_tool and no
# re-signing. lldb-argdumper goes in lib/ because LLDB's support-executable
# directory is the directory liblldb lives in -- the CLI's `run` shells out
# to it; DAP launches do not.
echo "== debugger =="
LLDB_B="$B/external/+llvm_configure+llvm-project/lldb"
# Warning and carrying on is not an option here: DIST_DIR is usually reused,
# so a missing build would leave the PREVIOUS libMojoLLDB.dylib in place and
# every subsequent test would silently exercise a stale plugin. That produces
# confident, wrong answers -- the exact failure this script must not enable.
# Set NO_DEBUGGER=1 to deliberately build a toolchain without one.
if [ "${NO_DEBUGGER:-0}" = 1 ]; then
  echo "   skipped (NO_DEBUGGER=1)"
  rm -f "$D/bin/lldb" "$D/bin/lldb-dap" "$D/lib/libMojoLLDB.dylib" \
        "$D/lib/liblldb24.0.0git.dylib" "$D/lib/lldb-argdumper"
else
  have_all=1
  for f in "$LLDB_B/lldb-dap" "$LLDB_B/lldb" "$LLDB_B/liblldb24.0.0git.dylib" \
           "$LLDB_B/lldb-argdumper" "$B/KGEN/libMojoLLDB.dylib"; do
    [ -f "$f" ] || have_all=0
  done
  if [ "$have_all" = 1 ]; then
    cp -f "$LLDB_B/lldb-dap" "$LLDB_B/lldb" "$D/bin/"
    cp -f "$LLDB_B/liblldb24.0.0git.dylib" "$D/lib/"
    cp -f "$LLDB_B/lldb-argdumper" "$D/lib/"
    cp -f "$B/KGEN/libMojoLLDB.dylib" "$D/lib/"
    components_store debugger "$HEAD_COMMIT" \
      "$LLDB_B/lldb-dap:bin" "$LLDB_B/lldb:bin" \
      "$LLDB_B/liblldb24.0.0git.dylib:lib" "$LLDB_B/lldb-argdumper:lib" \
      "$B/KGEN/libMojoLLDB.dylib:lib" \
      || echo "   (could not write the component cache)"
  elif components_have debugger && ! components_stale debugger KGEN bazel; then
    # The set restores together or not at all: the plugin and the libraries it
    # loads must come from one build, or it will not bind.
    components_restore debugger "$D" \
      || { echo "   component cache unreadable"; exit 1; }
    echo "   from the component cache, built $(components_built debugger)"
    echo "   at $(components_commit debugger); KGEN and bazel/ unchanged since"
  else
    if components_have debugger; then
      echo "   the cached debugger is from $(components_commit debugger), and"
      echo "   KGEN or bazel/ has changed since -- it would be a stale plugin"
    fi
    echo "   MISSING debugger components; ./tools/mojo-build.sh debugger"
    echo "   (refusing to leave a stale debugger in $D; NO_DEBUGGER=1 to skip)"
    exit 1
  fi
  # Prove what landed, so a stale-artifact claim can be checked, not asserted.
  for f in "$D/bin/lldb-dap" "$D/bin/lldb" "$D/lib/libMojoLLDB.dylib"; do
    printf "   %s  %s\n" "$(shasum -a 256 "$f" | cut -c1-12)" "$(basename "$f")"
  done
fi

echo "== runtime dylibs =="
for l in KGEN/libKGENCompilerRTShared.dylib \
         AsyncRT/libAsyncRTRuntimeGlobals.dylib \
         Support/libMSupportGlobals.dylib; do
  cp -f "$B/$l" "$D/lib/"
done

# LLVM. The compiler links against this rather than absorbing it, and it is here
# to be linked against by other things too -- an IDE or language server can use
# it without building LLVM at all. bazel puts the real file under _solib_*, so
# find it rather than guessing the path.
echo "== LLVM =="
LLVMLIB="$(find "$B" -name 'libLLVM.dylib' -type f 2>/dev/null | head -1)"
MLIRLIB="$(find "$B" -name 'libMLIR.dylib' -type f 2>/dev/null | head -1)"
# The external repo holding LLVM's sources. It sits beside execroot/ in the
# output base, not inside it, and the +llvm_configure+ prefix is bzlmod's and can
# change -- so cut the path at /execroot/ and glob for the repo.
LLVMSRC="$(echo "${B%%/execroot/*}"/external/*llvm_configure*llvm-project)"
if [ -n "$LLVMLIB" ]; then
  cp -f "$LLVMLIB" "$D/lib/"
  components_store llvm "$HEAD_COMMIT" "$LLVMLIB:lib" \
    || echo "   (could not write the component cache)"
elif components_have llvm && ! components_stale llvm bazel; then
  components_restore llvm "$D" || { echo "   component cache unreadable"; exit 1; }
  echo "   from the component cache ($(components_source llvm), $(components_built llvm))"
else
  echo "   no libLLVM.dylib -- ./tools/mojo-build.sh libs"; exit 1
fi
nexp=$(nm -gU "$D/lib/libLLVM.dylib" | grep -c '4llvm') || true
# Under the toolchain's default -fvisibility=hidden this lands near 200 rather
# than tens of thousands, and the dylib is useless to anything outside. That is
# a silent failure, so it is checked rather than assumed -- fresh OR cached.
[ "$nexp" -gt 10000 ] || { echo "   libLLVM.dylib exports only $nexp llvm:: symbols -- visibility regression"; exit 1; }
echo "   $(du -h "$D/lib/libLLVM.dylib" | cut -f1), $nexp llvm:: symbols exported"

# MLIR, on top of LLVM. The compiler links both; an in-process consumer that
# wants to build IR rather than shell out needs this one too.
if [ -n "$MLIRLIB" ]; then
  cp -f "$MLIRLIB" "$D/lib/"
  components_store mlir "$HEAD_COMMIT" "$MLIRLIB:lib" \
    || echo "   (could not write the component cache)"
elif components_have mlir && ! components_stale mlir bazel; then
  components_restore mlir "$D" || { echo "   component cache unreadable"; exit 1; }
  echo "   from the component cache ($(components_source mlir), $(components_built mlir))"
else
  echo "   no libMLIR.dylib -- ./tools/mojo-build.sh libs"; exit 1
fi
mexp=$(nm -gU "$D/lib/libMLIR.dylib" | grep -c '4mlir') || true
[ "$mexp" -gt 10000 ] || { echo "   libMLIR.dylib exports only $mexp mlir:: symbols -- visibility regression"; exit 1; }
echo "   $(du -h "$D/lib/libMLIR.dylib" | cut -f1), $mexp mlir:: symbols exported"

# The Mojo front end. Without this the distribution shipped the parser's headers
# and no parser -- it was statically linked inside the binaries and nothing
# out-of-tree could call it.
echo "== Mojo front end =="
FE="$B/KGEN/libMojoCompiler.dylib"
if [ -f "$FE" ]; then
  cp -f "$FE" "$D/lib/"
  components_store frontend "$HEAD_COMMIT" "$FE:lib" \
    || echo "   (could not write the component cache)"
elif components_have frontend && ! components_stale frontend KGEN Support bazel; then
  components_restore frontend "$D" || { echo "   component cache unreadable"; exit 1; }
  echo "   from the component cache ($(components_source frontend), $(components_built frontend))"
else
  echo "   no libMojoCompiler.dylib -- ./tools/mojo-build.sh libs"; exit 1
fi
fexp=$(nm -gU "$D/lib/libMojoCompiler.dylib" | grep -c 'MojoParserContext') || true
[ "$fexp" -gt 10 ] || { echo "   exports only $fexp MojoParserContext symbols -- visibility regression"; exit 1; }
echo "   $(du -h "$D/lib/libMojoCompiler.dylib" | cut -f1), parser API exported"

# LLVM headers, so the dylib is something another project can actually compile
# against. Two trees have to be merged, and the order matters:
#
#   1. the checked-out headers, which reach the build as a symlink farm into the
#      llvm-raw repo -- hence 'cp -RL' rather than rsync, to follow them
#   2. the generated ones on top: llvm-config.h, abi-breaking.h and the Config
#      .def files that record which targets this LLVM was built with. The source
#      tree carries .in templates for these; the generated versions must win, or
#      a consumer gets a Targets.def listing backends that are not in the dylib.
echo "== LLVM headers =="
rm -rf "$D/include"
mkdir -p "$D/include"
cp -RL "$LLVMSRC/llvm/include/llvm" "$LLVMSRC/llvm/include/llvm-c" "$D/include/" 2>/dev/null
GEN="$B/external/+llvm_configure+llvm-project/llvm/include"
[ -d "$GEN" ] && cp -RL "$GEN/llvm" "$D/include/" 2>/dev/null
nhdr=$(find "$D/include" -type f | wc -l | tr -d ' ')

# MLIR headers, same two-tree merge. The generated half is much larger here --
# MLIR's dialects are tablegen'd, so .inc files carry the actual declarations
# and a consumer cannot compile without them.
cp -RL "$LLVMSRC/mlir/include/mlir" "$LLVMSRC/mlir/include/mlir-c" "$D/include/" 2>/dev/null
MGEN="$B/external/+llvm_configure+llvm-project/mlir/include"
[ -d "$MGEN" ] && cp -RL "$MGEN/mlir" "$D/include/" 2>/dev/null

# The compiler's own headers: the phases an embedder calls into. Support, Init
# and Config come too -- KGEN's public headers include them, so an embedder
# needs them whether or not it names them.
cp -RL "$ROOT/KGEN/include/KGEN" "$D/include/" 2>/dev/null
for tree in Support Init Config Cache AsyncRT; do
  [ -d "$ROOT/$tree/include" ] && cp -RL "$ROOT/$tree/include/." "$D/include/" 2>/dev/null
done
# ...and their generated halves. KGEN and Support are tablegen'd the same way
# MLIR is: the .h.inc files carry real declarations, and MTypes.h includes
# MTypes.h.inc unconditionally, so nothing compiles without them.
for tree in KGEN Support Init Config Cache AsyncRT; do
  [ -d "$B/$tree/include" ] && cp -RL "$B/$tree/include/." "$D/include/" 2>/dev/null
done

nhdr=$(find "$D/include" -type f | wc -l | tr -d ' ')
echo "   $nhdr headers ($(du -sh "$D/include" | cut -f1))"
# The generated Config headers are the ones a consumer cannot do without.
for f in llvm/Config/llvm-config.h llvm/Config/abi-breaking.h llvm/Config/Targets.def; do
  [ -f "$D/include/$f" ] || { echo "   missing $f -- consumers will not compile"; exit 1; }
done

# The GPU runtime, built here rather than taken from bazel-out on purpose.
#
# Bazel compiles these two files with -fvisibility=hidden, so every
# AsyncRT_DeviceContext_* entry point lands in the object as a *private* extern.
# Statically linked into one binary that is invisible; the moment you want them
# from a JIT or a dylib they are simply not there, which is why `mojo run` on a
# GPU program failed with "Symbols not found: [_AsyncRT_DeviceContext_create...]"
# and why -force_load and `ld -r -keep_private_externs` could not rescue it --
# none of them can un-hide a symbol. Recompiling with default visibility can, and
# does: 125 exported symbols instead of none.
#
# Ours is VegaRT rather than CocoaMojoGPU: different sources, the same job, and
# the same reason for being built here by hand rather than taken from bazel --
# the toolchain's -fvisibility=hidden makes a dylib that links and exports
# nothing, and no amount of -force_load can un-hide a symbol.
#
# Built exactly as bin/cocoamojo expects to link it, and the symbol count is
# checked rather than assumed: the tracked copy of this dylib has drifted from
# its source before, and the parity checker cannot see binaries.
echo "== GPU runtime (libVegaRT) =="
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
M="$ROOT/AsyncRT/lib/MojoBindings"
clang++ -dynamiclib -std=c++17 -O2 -arch x86_64 -fPIC -fvisibility=default \
        -install_name '@rpath/libVegaRT.dylib' \
        -I "$M" -o "$D/lib/libVegaRT.dylib" \
        "$M/VegaRT.cpp" "$M/VegaRTMetal.cpp" \
        -framework Metal -framework Foundation -framework CoreFoundation -lobjc
n=$(nm -gU "$D/lib/libVegaRT.dylib" | grep -c 'AsyncRT') || true
[ "$n" -gt 100 ] || { echo "GPU runtime exported only $n AsyncRT symbols -- visibility regression"; exit 1; }
echo "   $n AsyncRT symbols exported"

echo "== packages =="
# Sources, not .mojoc: a precompiled package records a compiler version and this
# tree's compiler rejects packages built by a different one.
mkdir -p "$D/lib/mojo"
rsync -a --delete "$ROOT/mojo/stdlib/"      "$D/lib/mojo/stdlib/"
rsync -a --delete "$ROOT/max/mojo/"         "$D/lib/mojo/max/"
rsync -a --delete "$ROOT/max/kernels/src/"  "$D/lib/mojo/kernels/"

echo "== examples =="
# Shipped with the toolchain because they are the answer to "what does a
# project look like" -- each folder is one, with its main.mojo, and Roast
# opens them as they are. Copied without build/ or anything a previous run
# left behind, so a fresh distribution is sources only.
# --delete-excluded as well as --delete: without it rsync protects excluded
# files that are already in the destination, so a build/ from an earlier run
# would survive every rebuild of the distribution.
rsync -a --delete --delete-excluded \
      --exclude 'build/' --exclude '*.png' --exclude '.DS_Store' \
      "$ROOT/examples/" "$D/share/examples/"
echo "   $(find "$D/share/examples" -name '*.mojo' | wc -l | tr -d ' ') files in $(ls "$D/share/examples" | grep -vc README) projects"

echo "== the IDE's source =="
# Roast is written in the language it edits, so its source ships as a
# project people can open, read and build -- the most complete example the
# toolchain has, and the answer to "how would I write something like this".
rsync -a --delete "$ROOT/ide/"*.mojo "$D/share/ide-source/"
cat > "$D/share/ide-source/README.md" <<'IDEREADME'
# Roast, in Roast

The source of the editor you are reading it in. Roast is written in
cocoa-mojo and talks to AppKit directly -- no bridge, no wrapper library --
so this doubles as the largest worked example of `class`, `msg_send`, the
Cocoa database and the debugger APIs.

Build it with cmd-B; `roast.mojo` is the entry point. The copy in
Application Support is yours: edit it freely, and File > Reset Standard
Library & Examples restores the shipped one.

Files worth opening first:

- `roast.mojo`      the window, menus, toolbar, agent surface
- `gridview.mojo`   the editor view: NSTextInputClient, drawing, the lexer
- `rope.mojo`       the text engine, with its own test suite
- `dap.mojo`        the debug adapter conversation
- `lsp.mojo`        the language server conversation
IDEREADME
echo "   $(ls "$D/share/ide-source"/*.mojo | wc -l | tr -d ' ') files"

echo "== the IDE =="
# Roast, built with the compiler this distribution just assembled -- the same
# toolchain someone opening it will compile with. It ships because
# share/examples ships: the Examples menu resolves them through
# COCOAMOJO_ROOT, which only points somewhere real for a Roast that lives
# here. Built rather than copied, because a hand-placed binary is stale the
# moment the IDE changes, which is exactly what it was.
# A failure here fails the distribution, the same bargain as the debugger
# above: a dist that says "ready" without its IDE is a lie that scrolls past
# in a release log. NO_IDE=1 skips it for compiler-only work.
if [ "${NO_IDE:-0}" = 1 ]; then
  echo "   skipped (NO_IDE=1)"
  rm -f "$D/bin/roast"
elif COCOAMOJO_ROOT="$D" "$D/bin/cocoamojo" --build "$ROOT/ide/roast.mojo" \
     -o "$D/bin/roast" \
     -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
     -Xlinker "$ROOT/tools/roast-info.plist" \
     -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __sdef \
     -Xlinker "$ROOT/ide/Roast.sdef" \
     >"$D/bin/.roast.log" 2>&1; then
  rm -f "$D/bin/.roast.log"
  echo "   roast ($(stat -f%z "$D/bin/roast" | awk '{printf "%.0f KB", $1/1024}'))"
else
  echo "   FAILED -- roast did not build:"
  grep -m3 'error' "$D/bin/.roast.log" | sed 's/^/     /'
  echo "   full log: $D/bin/.roast.log  (NO_IDE=1 to build a dist without the IDE)"
  rm -f "$D/bin/roast"
  exit 1
fi

echo "== python =="
# CPython belongs to the TOOLCHAIN, not to the editor. Roast has always
# looked for it at <toolchain>/Python (python_env.runtime_home), and while
# the app carried a whole toolchain the two happened to coincide. A thin
# app has no Resources to hide it in, and the database generator needs an
# interpreter before any editor runs, so it lives here where both can
# reach it.
if [ -x "$D/Python/Python.framework/Versions/Current/bin/python3" ] \
   && [ "${PYTHON_REBUILD:-0}" != 1 ]; then
  echo "   already present ($(du -sh "$D/Python" | cut -f1)) -- PYTHON_REBUILD=1 to redo"
else
  # The system Python here is 3.9, which predates Py_NewRef and aborts
  # std.python at load. Homebrew's 3.12 is a framework build, which is what
  # bundle-python.sh requires -- Mojo loads CPython in-process. Named rather
  # than discovered, because `python3` on this machine is the 3.9 that does
  # not work, and a distribution built against it fails at run time rather
  # than here.
  ROAST_PYTHON="${ROAST_PYTHON:-/usr/local/bin/python3.12}" \
    "$ROOT/tools/bundle-python.sh" "$D/Python"
fi

# An interpreter nothing can reach is freight, not a feature. Roast finds it
# by framework path, and so does the database generator, but a person opening
# Terminal had no way to run the Python they had just installed -- and the
# only place the installer ever mentioned Python was the dialog offering to
# delete it. bin/python3 is the entry point, beside cocoamojo and lldb,
# where the rest of the toolchain keeps its commands.
#
# PYTHONHOME is the relocation contract: a copied framework still carries its
# build prefix, and without this the interpreter looks for its standard
# library where it was built rather than where it is.
cat > "$D/bin/python3" <<'PYWRAP'
#!/usr/bin/env bash
# The CocoaMojo Python -- the same interpreter Roast uses for its per-project
# environments, and the one that builds share/cocoa.sqlite at install time.
#
#   python3                     a REPL
#   python3 -m venv myenv       an environment that stays yours
#   python3 script.py
#
# This does NOT go on your PATH and does not shadow any Python you already
# have; it is reachable by this path, deliberately and only.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOME_DIR="$HERE/Python/Python.framework/Versions/Current"
[ -x "$HOME_DIR/bin/python3" ] || {
  echo "python3: no interpreter at $HOME_DIR" >&2; exit 1; }
exec env PYTHONHOME="$HOME_DIR" "$HOME_DIR/bin/python3" "$@"
PYWRAP
chmod +x "$D/bin/python3"
echo "   bin/python3: reachable beside cocoamojo"

echo "== cocoa database generator =="
# The 343 MB database is no longer shipped: the installer builds it on the
# machine it installs to, in about fifteen seconds, from that machine's own
# SDK. So what ships is the generator -- 112 KB of stdlib-only Python --
# and the database it produces describes the frameworks the person actually
# has, rather than a snapshot of whichever Mac cut the release.
KBSRC="${COCOAKB_SRC:-/Volumes/S/CocoaBaseMCP}"
if [ -f "$KBSRC/build.py" ]; then
  mkdir -p "$D/share/cocoakb"
  # schema.sql is not optional: build.py reads it to create the tables.
  # --delete would take the generated cocoa.sqlite with it on a rebuild,
  # so protect it -- regenerating 350 MB to stage 112 KB is a poor trade.
  rsync -a --delete --filter 'P cocoa.sqlite' \
        --include '*.py' --include '*.sql' --include '*/' --exclude '*' \
        "$KBSRC/" "$D/share/cocoakb/"
  echo "   $(ls "$D/share/cocoakb"/*.py | wc -l | tr -d ' ') modules + schema"
else
  echo "   WARNING: no generator at $KBSRC -- the database cannot be built"
fi

echo "== cocoa database =="
if [ -f "$KB" ]; then cp -f "$KB" "$D/share/cocoa.sqlite"
else echo "   WARNING: no cocoa.sqlite at $KB -- set COCOAKB=..."; fi

echo
echo "$D ready ($(du -sh "$D" | cut -f1))"
echo "  dist/MojoMacX64/bin/cocoamojo --run examples/mandelbrot/main.mojo"
