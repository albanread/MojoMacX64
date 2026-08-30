#!/usr/bin/env bash
# Verify a CocoaMojo distribution: build every demo, run the ones that finish,
# and check the GPU runtime still exports its symbols.
#
#   ./tools/check-dist.sh
set -uo pipefail
cd "$(dirname "$0")/.."
# `timeout` is GNU coreutils and macOS does not ship it. Where it is missing
# the command does not run AT ALL, produces no output, and every check built on
# it reports the product broken: the language server "returned 0 capabilities",
# the debugger "did not bind". Both were fine; nothing had run. Use the real one
# when it exists, and perl's alarm otherwise -- perl is in the base system.
if command -v timeout >/dev/null 2>&1; then
  run_for() { timeout "$@"; }
elif command -v gtimeout >/dev/null 2>&1; then
  run_for() { gtimeout "$@"; }
else
  run_for() { local s="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }
fi

CM="dist/MojoMacX64/bin/cocoamojo"
[ -x "$CM" ] || { echo "no distribution -- run ./tools/release.sh first"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
ok()   { printf '  OK   %-16s %s\n' "$1" "${2:-}"; }
bad()  { printf '  FAIL %-16s %s\n' "$1" "${2:-}"; fail=1; }

# The symbol count is checked first because everything GPU depends on it and the
# failure is silent: a hidden-visibility regression links fine and dies at run
# time with "Symbols not found". See RELEASE.md.
n=$(nm -gU dist/MojoMacX64/lib/libVegaRT.dylib 2>/dev/null | grep -c AsyncRT) || n=0
[ "$n" -gt 100 ] && ok libVegaRT "$n AsyncRT symbols exported" \
                 || bad libVegaRT "only $n AsyncRT symbols -- visibility regression"

# Same check for LLVM, and for the same reason: under the toolchain's default
# hidden visibility this lands near 200 instead of tens of thousands, the dylib
# links, and nothing outside it can call in.
m=$(nm -gU dist/MojoMacX64/lib/libMLIR.dylib 2>/dev/null | grep -c '4mlir') || m=0
msz=$(du -h dist/MojoMacX64/lib/libMLIR.dylib 2>/dev/null | cut -f1)
[ "$m" -gt 10000 ] && ok libMLIR "$m mlir:: symbols exported, $msz" \
                   || bad libMLIR "only $m mlir:: symbols -- visibility regression"

l=$(nm -gU dist/MojoMacX64/lib/libLLVM.dylib 2>/dev/null | grep -c '4llvm') || l=0
sz=$(du -h dist/MojoMacX64/lib/libLLVM.dylib 2>/dev/null | cut -f1)
[ "$l" -gt 10000 ] && ok libLLVM "$l llvm:: symbols exported, $sz" \
                   || bad libLLVM "only $l llvm:: symbols -- visibility regression"

# And that the compiler is actually using it rather than carrying its own copy.
otool -L dist/MojoMacX64/bin/cocoamojo-compiler 2>/dev/null | grep -q 'libLLVM.dylib' \
  && ok "compiler link" "dynamic against libLLVM.dylib" \
  || bad "compiler link" "LLVM is statically linked -- dynamic_deps not in effect"

# The language server: hand it an LSP initialize request and read back the
# capabilities. An editor's first move, so if this is broken nothing else works.
if [ -x dist/MojoMacX64/bin/mojo-lsp-server ]; then
  body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}'
  printf 'Content-Length: %d\r\n\r\n%s' "${#body}" "$body" > "$TMP/lsp_init"
  run_for 30 dist/MojoMacX64/bin/mojo-lsp-server < "$TMP/lsp_init" >"$TMP/lsp_out" 2>"$TMP/lsp_err"
  caps=$(grep -oE '"[a-zA-Z]+Provider"' "$TMP/lsp_out" 2>/dev/null | sort -u | wc -l | tr -d ' ')
  if [ "${caps:-0}" -ge 8 ]; then
    ok "mojo-lsp-server" "$caps capabilities advertised"
  elif grep -q 'registered more than once' "$TMP/lsp_err" 2>/dev/null; then
    # See RELEASE.md: two copies of LLVM's CommandLine in one process.
    bad "mojo-lsp-server" "duplicate LLVM CommandLine registry"
  else
    bad "mojo-lsp-server" "initialize returned $caps capabilities"
  fi
else
  bad "mojo-lsp-server" "not in the distribution"
fi

# COCOA: completion from cocoa.sqlite. Three positions, one per path through
# the code: a class name, an instance selector, and a class method that is only
# reachable by walking the superclass chain (alloc is on NSObject, not NSWindow).
# Positions are zero-based line/column into tools/lsp-probe/cocoa_completion.mojo.
if [ -x dist/MojoMacX64/bin/mojo-lsp-server ]; then
  probe() {  # <line> <col> <expected-label>
    # The server is launched directly here, so it never runs through the
    # `cocoamojo` wrapper that normally exports this. Without it the database
    # is unreachable and every position completes to nothing -- which looked
    # for a while like a broken feature rather than an unset variable.
    MODULAR_MOJO_MAX_COCOAKB_PATH="$PWD/dist/MojoMacX64/share/cocoa.sqlite" \
    tools/lsp-probe/complete.py dist/MojoMacX64/bin/mojo-lsp-server \
      tools/lsp-probe/cocoa_completion.mojo "$1" "$2" 2>/dev/null \
      | awk -F'\t' -v want="$3" '$1 == want { print; exit }'
    # Exact field match, not grep: a selector label ends in ':', and a regex
    # word boundary after ':' never matches, which silently reported every
    # selector as missing.
  }
  cls=$(probe 6 37 'NSWindow')
  sel=$(probe 7 52 'setTitle:')
  cm=$(probe  8 50 'alloc')
  if [ -n "$cls" ] && [ -n "$sel" ] && [ -n "$cm" ]; then
    ok "cocoa completion" "classes, selectors, inherited class methods"
    printf '         %s\n' "$cls" "$sel" "$cm" | expand -t20
  else
    # Most likely cause is an unreachable cocoa.sqlite, which is a
    # configuration problem rather than a code one.
    bad "cocoa completion" "class=${cls:-none} selector=${sel:-none} classmethod=${cm:-none}"
  fi
fi

# The out-of-tree consumer: compile and run a real LLVM program against the
# distribution's headers and dylib, nothing else. This is what the IDE will do.
if clang++ -std=c++17 -fno-rtti tools/ide-probe/ide_probe.cpp \
     -I dist/MojoMacX64/include -L dist/MojoMacX64/lib -lLLVM \
     -Wl,-rpath,"$PWD/dist/MojoMacX64/lib" -o "$TMP/ide_probe" \
     >"$TMP/ide_probe.log" 2>&1; then
  targets=$(env -i "$TMP/ide_probe" 2>&1 | grep '^registered targets:' | cut -d: -f2-)
  if [ -z "$targets" ]; then
    bad "llvm consumer" "built but produced no target list"
  elif echo "$targets" | grep -qi 'x86\|riscv'; then
    # Headers and dylib disagree about which LLVM this is.
    bad "llvm consumer" "generated Targets.def is stale:$targets"
  else
    ok "llvm consumer" "compiles and runs against dist;$targets"
  fi
else
  bad "llvm consumer" "$(grep -m1 -E 'error|fatal' "$TMP/ide_probe.log" || echo 'build failed')"
fi

# The same, for MLIR: an editor embedding compiler phases needs to build IR.
if clang++ -std=c++17 -fno-rtti tools/ide-probe/mlir_probe.cpp \
     -I dist/MojoMacX64/include -L dist/MojoMacX64/lib -lMLIR -lLLVM \
     -Wl,-rpath,"$PWD/dist/MojoMacX64/lib" -o "$TMP/mlir_probe" \
     >"$TMP/mlir_probe.log" 2>&1; then
  if env -i "$TMP/mlir_probe" 2>&1 | grep -q 'mlir context ok'; then
    ok "mlir consumer" "compiles and builds IR against dist"
  else
    bad "mlir consumer" "built but did not run"
  fi
else
  bad "mlir consumer" "$(grep -m1 -E 'error|fatal' "$TMP/mlir_probe.log" || echo 'build failed')"
fi

# The compiler front end, embedded: parse a buffer in-process and collect
# diagnostics, which is what an editor does on every keystroke.
#
# The flags are the build's own and an embedder needs all of them: -std=c++20
# because Support's headers use std::string::starts_with, and the three defines
# because KGEN's headers reference them unconditionally (bazel/config.bzl).
EMBED_FLAGS="-std=c++20 -fno-rtti -DLLVM_ON_UNIX=1
  -DMODULAR_ASYNCRT_MAX_PROFILING_LEVEL=0000000
  -DMAX_CONFIG_SECTION=max -DMOJO_CONFIG_SECTION=mojo-max"
if clang++ $EMBED_FLAGS tools/ide-probe/syntax_probe.cpp \
     -I dist/MojoMacX64/include -L dist/MojoMacX64/lib \
     -lMojoCompiler -lMLIR -lLLVM \
     -Wl,-rpath,"$PWD/dist/MojoMacX64/lib" -o "$TMP/syntax_probe" \
     >"$TMP/syntax_probe.log" 2>&1; then
  printf 'def main():\n    let x = 1\n    x = 2\n' > "$TMP/bad.mojo"
  out=$(MODULAR_CRASH_REPORTING_ENABLED=false "$TMP/syntax_probe" "$TMP/bad.mojo" \
          -I dist/MojoMacX64/lib/mojo/stdlib 2>&1)
  # Both halves matter: a diagnostic with a location, and the error actually
  # counted. A parser that returns "parsed: yes, errors: 0" here is broken.
  if echo "$out" | grep -q 'must be mutable' && echo "$out" | grep -q 'errors: 1'; then
    ok "embedded parser" "in-process parse reports diagnostics with locations"
  else
    bad "embedded parser" "$(echo "$out" | grep -v Crashpad | tail -1)"
  fi
else
  bad "embedded parser" "$(grep -m1 -E 'error|fatal|Undefined' "$TMP/syntax_probe.log" || echo 'build failed')"
fi

for src in spikes/mandelbrot/window_smoke.mojo \
           spikes/playground/playground.mojo spikes/playground/p0_window.mojo \
           spikes/life/life.mojo; do
  name=$(basename "$src" .mojo)
  [ -f "$src" ] || { bad "$name" "source missing at $src"; continue; }
  if ! "$CM" --build "$src" -o "$TMP/$name" >"$TMP/$name.log" 2>&1; then
    bad "$name" "$(grep -m1 'error' "$TMP/$name.log" || echo 'build failed')"
    continue
  fi

  case "$name" in
    window_smoke)
      # Pumps a fixed number of event cycles and exits, so it can be run here.
      out=$("$TMP/$name" 2>&1 | tail -1)
      [[ "$out" == *PASS* ]] && ok "$name" "$out" || bad "$name" "$out"
      ;;
    *)
      # Windowed apps that wait on a run loop: building them is the check.
      ok "$name" "built"
      ;;
  esac
done

# The windowed mandelbrot, now living with the examples. MANDEL_FRAMES renders
# a fixed number of frames and exits -- deterministic, and as an Accessory it
# never takes the screen -- so the check is a real run rather than a kill.
if ! "$CM" --build examples/mandelbrot/main.mojo -o "$TMP/mandel" \
     >"$TMP/mandel.log" 2>&1; then
  bad "mandelbrot" "$(grep -m1 'error' "$TMP/mandel.log" || echo 'build failed')"
else
  mrun=$(cd "$TMP" && MANDEL_FRAMES=150 run_for 120 "$TMP/mandel" 2>&1)
  gpu=$(echo "$mrun" | grep -m1 'GPU:.*ms' | sed 's/^ *//')
  fps=$(echo "$mrun" | grep -m1 'fps' | sed 's/^ *//')
  if [ -n "$gpu" ] && echo "$mrun" | grep -q 'Rendered 150 frames'; then
    ok "mandelbrot" "$gpu | $fps"
  else
    bad "mandelbrot" "${gpu:-no GPU timing -- runtime did not come up}"
  fi
fi

# The shipped examples, built out of the distribution the way someone opening
# them in Roast would. Sources only -- a distribution carrying a build/ from
# the machine that made it is not a distribution.
EX="dist/MojoMacX64/share/examples"
if [ -d "$EX" ]; then
  stray=$(find "$EX" \( -name 'build' -o -name '*.png' -o -name '.DS_Store' \) | wc -l | tr -d ' ')
  [ "$stray" -eq 0 ] && ok "examples" "$(find "$EX" -name '*.mojo' | wc -l | tr -d ' ') files, sources only" \
                     || bad "examples" "$stray stray files shipped"
  for proj in "$EX"/*/; do
    name=$(basename "$proj")
    [ -f "$proj/main.mojo" ] || { bad "example $name" "no main.mojo"; continue; }
    if "$CM" --build "$proj/main.mojo" -o "$TMP/ex_$name" >"$TMP/ex_$name.log" 2>&1; then
      ok "example $name" "builds"
    else
      bad "example $name" "$(grep -m1 'error:' "$TMP/ex_$name.log" || echo 'build failed')"
    fi
  done
else
  bad "examples" "not in the distribution -- rerun make-dist.sh"
fi

# The IDE. make-dist now refuses to assemble a dist whose IDE will not build,
# but a distribution is checked as found, not as assembled: an older dist, or
# one built with NO_IDE=1, should say so here rather than pass.
[ -x dist/MojoMacX64/bin/roast ] \
  && ok "roast" "$(stat -f%z dist/MojoMacX64/bin/roast | awk '{printf "%.0f KB", $1/1024}')" \
  || bad "roast" "not in the distribution"

# The debugger, end to end: the dist's own lldb loads the dist's own plugin,
# stops a dist-built binary at a breakpoint, and reads a local back. Every
# link is one we have watched fail silently -- the plugin not shipped, the
# launch path broken by a misplaced argdumper, locals optimized away -- and a
# dist where "frame variable" answers nothing still runs programs fine, so
# nothing else here would notice. `process launch -X 0` rather than `run`:
# the CLI's `run` shells out to lldb-argdumper, which ships in lib/ for the
# DAP's benefit, and this check must not depend on that placement.
if [ -x dist/MojoMacX64/bin/lldb ] && [ -f dist/MojoMacX64/lib/libMojoLLDB.dylib ]; then
  cat > "$TMP/dbg.mojo" <<'EOF'
fn main():
    var answer = 41 + 1
    print(answer)
EOF
  if "$CM" --build "$TMP/dbg.mojo" -o "$TMP/dbg" -g -O0 >"$TMP/dbg.log" 2>&1; then
    dout=$(run_for 60 dist/MojoMacX64/bin/lldb --batch \
      -o "plugin load dist/MojoMacX64/lib/libMojoLLDB.dylib" \
      -o "breakpoint set -f dbg.mojo -l 3" \
      -o "process launch -X 0" \
      -o "frame variable answer" \
      "$TMP/dbg" 2>&1)
    if echo "$dout" | grep -q 'answer = 42'; then
      ok "debugger" "breakpoint bound, frame variable answered 42"
    elif echo "$dout" | grep -q 'no plugin for the language'; then
      bad "debugger" "libMojoLLDB did not load"
    elif ! echo "$dout" | grep -q 'stop reason = breakpoint'; then
      bad "debugger" "breakpoint did not bind or process did not stop"
    else
      bad "debugger" "$(echo "$dout" | grep -m1 'error' || echo 'frame variable gave no answer')"
    fi
  else
    bad "debugger" "fixture did not build: $(grep -m1 'error' "$TMP/dbg.log" || echo 'see dbg.log')"
  fi
else
  bad "debugger" "lldb or libMojoLLDB.dylib not in the distribution"
fi

echo
[ "$fail" -eq 0 ] && echo "distribution OK" || echo "distribution has failures"
exit $fail
