#!/usr/bin/env bash
# Verify the Roast shell: build it, run the whole lifecycle unattended, and
# check that AppKit reports the pieces it should have.
#
#   ./tools/check-ide.sh
#
# The app reports its own state rather than being screenshotted, for the same
# reason window_smoke does: a screenshot needs an unlocked screen and a human,
# and this has to run in CI. ROAST_AUTOCLOSE_TICKS drives launch -> ticks ->
# close -> terminate with nobody at the keyboard.
set -uo pipefail
cd "$(dirname "$0")/.."
# Overridable, so compiler work can check the IDE against a private
# distribution instead of rewriting the one a running Roast is sitting on.
CM="${COCOAMOJO:-dist/CocoaMojo/bin/cocoamojo}"
[ -x "$CM" ] || { echo "no distribution -- run ./tools/release.sh first"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
ok()  { printf '  OK   %-18s %s\n' "$1" "${2:-}"; }
bad() { printf '  FAIL %-18s %s\n' "$1" "${2:-}"; fail=1; }
skip(){ printf '  SKIP %-18s %s\n' "$1" "${2:-}"; }

# Debugger checks are OFF by default. Attaching a debugger and reading a
# removable volume are both gated by macOS behind dialogs that wait for a
# person, and an unattended run sits behind them until it times out -- which
# reads as a broken debugger and is not one. Set ROAST_CHECK_DEBUGGER=1 to
# run them with a human at the keyboard.
DEBUGGER_CHECKS="${ROAST_CHECK_DEBUGGER:-0}"

if ! "$CM" --build ide/roast.mojo -o "$TMP/roast" >"$TMP/build.log" 2>&1; then
  bad "build" "$(grep -m1 'error' "$TMP/build.log" || echo 'build failed')"
  echo; echo "IDE shell has failures"; exit 1
fi
ok "build" "$(stat -f%z "$TMP/roast" | awk '{printf "%.0f KB", $1/1024}')"

# The rope, first: it is the thing the latency claim rests on, it is pure Mojo,
# and it needs no window. Its own suite asserts values and prints timings.
if "$CM" --build ide/rope_test.mojo -o "$TMP/rope_test" >"$TMP/rope_build.log" 2>&1; then
  rope_out=$(timeout 300 "$TMP/rope_test" 2>&1)
  if echo "$rope_out" | grep -q '^rope OK'; then
    ok "rope" "$(echo "$rope_out" | grep -c '  OK ') checks"
    echo "$rope_out" | grep -E 'bytes:|build:|line lookup:|edit:|snapshot:' \
      | sed 's/^ */         /'
  else
    bad "rope" "$(echo "$rope_out" | grep -m1 FAIL || echo 'tests failed')"
  fi
else
  bad "rope" "$(grep -m1 'error' "$TMP/rope_build.log" || echo 'build failed')"
fi

# JSON, which the language server conversation rests on.
if "$CM" --build ide/json_test.mojo -o "$TMP/json_test" >"$TMP/json_build.log" 2>&1; then
  json_out=$(timeout 120 "$TMP/json_test" 2>&1)
  if echo "$json_out" | grep -q '^json OK'; then
    ok "json" "$(echo "$json_out" | grep -c '  OK ') checks — escapes, surrogate pairs, round trip"
  else
    bad "json" "$(echo "$json_out" | grep -m1 FAIL || echo 'tests failed')"
  fi
else
  bad "json" "$(grep -m1 'error' "$TMP/json_build.log" || echo 'build failed')"
fi

# The session file, without a window. ROAST_SESSION keeps every one of these
# off whatever the person at this machine had open.
if "$CM" --build ide/session_test.mojo -o "$TMP/session_test" >"$TMP/sess_build.log" 2>&1; then
  sess_out=$(ROAST_SESSION="$TMP/session.json" timeout 120 "$TMP/session_test" 2>&1)
  if echo "$sess_out" | grep -q '^session OK'; then
    ok "session" "$(echo "$sess_out" | grep -c '  OK ') checks — round trip, damaged files, settings"
  else
    bad "session" "$(echo "$sess_out" | grep -m1 FAIL || echo 'tests failed')"
  fi
else
  bad "session" "$(grep -m1 'error' "$TMP/sess_build.log" || echo 'build failed')"
fi

# Project Python paths and pip argv are deterministic policy, separate from
# the expensive integration check below. The override proves no test touches
# the user's real Application Support environment.
if "$CM" --build ide/python_env_test.mojo -o "$TMP/python_env_test" \
     >"$TMP/python_env_build.log" 2>&1; then
  pyenv_out=$(ROAST_PYTHON_ENV_ROOT="$TMP/python-envs" \
              ROAST_PYTHON_VERSION="3.14" \
              timeout 120 "$TMP/python_env_test" 2>&1)
  if echo "$pyenv_out" | grep -q '^python environment OK'; then
    ok "python env policy" "$(echo "$pyenv_out" | grep -c '  OK ') checks — Application Support keying, pip argv"
  else
    bad "python env policy" "$(echo "$pyenv_out" | grep -m1 FAIL || echo 'tests failed')"
  fi
else
  bad "python env policy" "$(grep -m1 'error' "$TMP/python_env_build.log" || echo 'build failed')"
fi

# The debug adapter, against a real lldb-dap and a real program: compile a
# tiny thing WITH debug info, set a breakpoint on it, and require the stop to
# land where the adapter said it bound. Skipped rather than failed when Xcode
# is not installed -- lldb-dap comes from Xcode, and its absence is a fact
# about this machine and not about the code.
# The toolchain's own adapter first: it ships with the MojoLLDB plugin
# beside it, and with it this section requires VARIABLES, not just stops.
# Xcode's is the fallback and inspects nothing (dap_test skips that part).
DISTROOT="$(dirname "$CM")/.."
if [ -x "$DISTROOT/bin/lldb-dap" ]; then
  DAPBIN="$DISTROOT/bin/lldb-dap"
else
  DAPBIN="$(xcrun -f lldb-dap 2>/dev/null || true)"
fi
# Developer mode gates every debugger attach behind an authorization prompt.
# With it off, lldb does not fail -- it HANGS on `run`, waiting for a dialog
# no headless check can answer, and the timeout that follows looks exactly
# like a broken debugger. It cost an afternoon to find, so the state is read
# here and named.
DEVMODE="$(DevToolsSecurity -status 2>/dev/null || true)"
if [ -z "$DAPBIN" ]; then
  echo "  --   dap                lldb-dap not found (no Xcode); skipped"
  DAPBIN=""
elif [[ "$DEVMODE" != *enabled* ]]; then
  echo "  --   dap                developer mode is off; skipped"
  echo "                          run: sudo DevToolsSecurity -enable"
  DAPBIN=""
elif ! "$CM" --build ide/dap_test.mojo -o "$TMP/dap_test" >"$TMP/dap_build.log" 2>&1; then
  bad "dap" "$(grep -m1 'error' "$TMP/dap_build.log" || echo 'build failed')"
else
  mkdir -p "$TMP/dbg"
  cat > "$TMP/dbg/main.mojo" <<'DBGEOF'
def add(a: Int, b: Int) -> Int:
    var sum = a + b
    return sum


def main():
    var total = 0
    for i in range(5):
        total = add(total, i)
    print("total:", total)
DBGEOF
  # --debug-level full, and the dSYM it emits beside the binary is where the
  # line table actually lives -- looking for DWARF inside the executable
  # finds nothing and is how this looked broken at first.
  if ! "$CM" --build "$TMP/dbg/main.mojo" -o "$TMP/dbg/prog" \
       --debug-level full --no-optimization \
       >"$TMP/dbg/build.log" 2>&1; then
    bad "dap" "could not build a program with debug info"
  else
    dap_out=$(cd "$TMP/dbg" && ROAST_DAP="$DAPBIN" ROAST_DAP_PROGRAM="./prog" \
              ROAST_DAP_SOURCE="main.mojo" timeout 400 "$TMP/dap_test" 2>&1)
    # With our own adapter the plugin is beside it, so a skip here is a
    # packaging regression, not an environment fact.
    if [ -x "$DISTROOT/lib/libMojoLLDB.dylib" ] || [ -f "$DISTROOT/lib/libMojoLLDB.dylib" ]; then
      if echo "$dap_out" | grep -q "is among them = 1"; then
        ok "dap variables" "the stopped frame answers with named locals"
      else
        bad "dap variables" "plugin shipped but no variables came back"
      fi
    fi
    if echo "$dap_out" | grep -q '^dap OK'; then
      ok "dap" "$(echo "$dap_out" | grep -c '  OK ') checks — a breakpoint binds and the stop lands on it"
    else
      bad "dap" "$(echo "$dap_out" | grep -m1 FAIL || echo 'tests failed')"
    fi
  fi
fi

# Editing behaviour, also without a window: the text input client's risk is
# the arithmetic, not the Objective-C plumbing.
if "$CM" --build ide/edit_test.mojo -o "$TMP/edit_test" >"$TMP/edit_build.log" 2>&1; then
  edit_out=$(timeout 120 "$TMP/edit_test" 2>&1)
  if echo "$edit_out" | grep -q '^edit OK'; then
    ok "editing" "$(echo "$edit_out" | grep -c '  OK ') checks — UTF-8 backspace, column keeping, UTF-16 offsets"
  else
    bad "editing" "$(echo "$edit_out" | grep -m1 FAIL || echo 'tests failed')"
  fi
else
  bad "editing" "$(grep -m1 'error' "$TMP/edit_build.log" || echo 'build failed')"
fi

# The view's own state, in its box. edit_test drives the editor without ever
# making a view, so every accessor there takes the pre-view fallback -- it
# proves the migration changed no behaviour and nothing at all about the box.
# This makes the view, which is the path the running app takes, and then
# checks the thing the migration was for: two views, two carets.
if "$CM" --build ide/view_state_test.mojo -o "$TMP/view_state" \
     >"$TMP/vs_build.log" 2>&1; then
  vs_out=$(timeout 120 "$TMP/view_state" 2>&1)
  if echo "$vs_out" | grep -q '^view state OK'; then
    ok "view state" "$(echo "$vs_out" | grep -c '  OK ') checks — per-view caret, selection, width"
  else
    bad "view state" "$(echo "$vs_out" | grep -m1 FAIL || echo 'tests failed')"
  fi
else
  bad "view state" "$(grep -m1 'error' "$TMP/vs_build.log" || echo 'build failed')"
fi

# The build driver: which file gets compiled, where the binary goes, and
# taking the compiler's diagnostics apart. All string arithmetic, no window.
if "$CM" --build ide/build_test.mojo -o "$TMP/build_test" >"$TMP/bt_build.log" 2>&1; then
  bt_out=$(ROAST_REPO="$PWD" timeout 120 "$TMP/build_test" 2>&1)
  if echo "$bt_out" | grep -q '^build OK'; then
    ok "build driver" "$(echo "$bt_out" | grep -c '  OK ') checks — entry point, output path, diagnostics"
  else
    bad "build driver" "$(echo "$bt_out" | grep -m1 FAIL || echo 'tests failed')"
  fi
else
  bad "build driver" "$(grep -m1 'error' "$TMP/bt_build.log" || echo 'build failed')"
fi

# The language server, for real: spawn it, initialize, open a file with a
# deliberate error, read the diagnostic back. Needs an import path or every
# parse fails on `std` and the diagnostics are about configuration.
if "$CM" --build ide/lsp_test.mojo -o "$TMP/lsp_test" >"$TMP/lsp_build.log" 2>&1; then
  lsp_out=$(ROAST_LSP="$PWD/dist/CocoaMojo/bin/mojo-lsp-server" \
            ROAST_IMPORTS="$PWD/dist/CocoaMojo/lib/mojo/stdlib" \
            MODULAR_MOJO_MAX_COCOAKB_PATH="$PWD/dist/CocoaMojo/share/cocoa.sqlite" \
            timeout 180 "$TMP/lsp_test" 2>&1)
  if echo "$lsp_out" | grep -q '^lsp OK'; then
    ok "lsp client" "handshake, diagnostics and Cocoa completion"
    echo "$lsp_out" | grep -E '^ +line [0-9]+ col' | head -1 | sed 's/^ */         /'
    echo "$lsp_out" | grep -E '^ +set[A-Za-z]+:' | head -3 | sed 's/^ */         /'
  else
    bad "lsp client" "$(echo "$lsp_out" | grep -m1 FAIL || echo 'tests failed')"
  fi
else
  bad "lsp client" "$(grep -m1 'error' "$TMP/lsp_build.log" || echo 'build failed')"
fi

# Build and run for real, driven by the app's own timer. The examples are
# copied somewhere writable first: a test editor never works on live data, and
# building writes a build/ folder next to whatever it compiles.
cp -R examples "$TMP/examples"
brun=$(COCOAMOJO_ROOT="$PWD/dist/CocoaMojo" \
       ROAST_PROJECT="$TMP/examples/hello" \
       ROAST_AUTOBUILD=run ROAST_AUTOCLOSE_TICKS=400 \
       timeout 240 "$TMP/roast" 2>&1)
if echo "$brun" | grep -q 'building finished, status 0'; then
  if echo "$brun" | grep -q 'running finished, status 0'; then
    ok "build + run" "⌘R compiled the project and ran the binary"
  else
    bad "build + run" "built, but the binary did not run clean"
  fi
else
  bad "build + run" "$(echo "$brun" | grep -m1 'error:' || echo 'build did not succeed')"
fi

# The console is read back out of AppKit, so this asserts what someone would
# be looking at rather than what went into the pipe.
if echo "$brun" | grep -q 'Hello from cocoa-mojo'; then
  ok "console" "the program's output reached the pane"
else
  bad "console" "nothing from the program in the console"
fi
if echo "$brun" | grep -q 'console open'; then
  ok "console pane" "$(echo "$brun" | grep -m1 'console open' | sed 's/roast: //')"
else
  bad "console pane" "the build did not open it"
fi

# A failure has to land on the error -- including when the error is in a file
# that is not the entry point and is not even open yet.
sed -i '' 's/var maps = List\[Affine\]()/var maps = List[Affine](sherbet)/' \
  "$TMP/examples/fern/ifs.mojo"
bfail=$(COCOAMOJO_ROOT="$PWD/dist/CocoaMojo" \
        ROAST_PROJECT="$TMP/examples/fern" \
        ROAST_AUTOBUILD=run ROAST_AUTOCLOSE_TICKS=400 \
        timeout 240 "$TMP/roast" 2>&1)
if echo "$bfail" | grep -q 'jump to ifs.mojo line 18'; then
  ok "jump to error" "opened the imported file and put the caret on it"
else
  bad "jump to error" "$(echo "$bfail" | grep -m1 'jump to' || echo 'did not jump')"
fi
if echo "$bfail" | grep -q 'running finished'; then
  bad "failed build stops" "it ran the binary anyway"
else
  ok "failed build stops" "run did not happen after a failed compile"
fi

out=$(ROAST_AUTOCLOSE_TICKS=12 timeout 90 "$TMP/roast" 2>&1)

check() {  # <label> <pattern> <description>
  if echo "$out" | grep -q "$2"; then ok "$1" "$3"; else
    bad "$1" "expected $2 — got: $(echo "$out" | grep -m1 "$1" || echo 'nothing')"
  fi
}

check "window"      "window visible: True"  "on screen"
check "toolbar"     "toolbar: True"         "attached"
# Items are made by a factory method the toolbar calls back into; zero means
# the identifiers registered and the factory never ran.
ti=$(echo "$out" | grep -m1 'toolbar items:' | sed 's/.*items: //')
if [ -n "$ti" ] && [ "$ti" -ge 4 ]; then
  ok "toolbar items" "$ti built by the factory"
else
  bad "toolbar items" "${ti:-none} — the item factory did not produce"
fi
check "split view"  "split panes: 2"        "sidebar + editor area"
check "editor panes" "editor panes: 2"      "editor above the console"
check "menu bar"    "menu bar items: 10"    "app, File, Edit, Navigate, Debug, View, Build, Python, Examples, Window"
# Installing a toolbar changes the content view's height, so a layout computed
# from the height read before it existed leaves a band above the tab strip.
# Zero here means flush.
check "tab strip"   "tab gap: 0.0"          "flush under the toolbar"
check "lifecycle"   "applicationWillTerminate" "launch → close → terminate clean"

# An example is a PROJECT: fern is three files, and opening one of them is the
# bug this check exists to catch. Driven through the menu ITEM, not around it
# -- ROAST_EXAMPLE reproduces the action's logic, which means it would go on
# passing if the menu stopped reaching it. Both halves are asserted: the files
# opened as tabs, and the rows the sidebar is showing, because the file list on
# the left is the half someone actually looks at.
# ROAST_EXAMPLES points the menu at the working tree rather than the
# distribution: building and running an example writes its output back into the
# folder it shipped in, so the row count over there moves the moment anyone
# presses cmd-R. That the distribution HAS examples is check-dist's business.
exout=$(COCOAMOJO_ROOT="$PWD/dist/CocoaMojo" ROAST_EXAMPLES="$PWD/examples" \
        ROAST_EXAMPLE_MENU="fern" \
        ROAST_AUTOCLOSE_TICKS=12 timeout 90 "$TMP/roast" 2>&1)
if ! echo "$exout" | grep -q 'roast: window visible'; then
  # Distinguished from an empty menu on purpose: this reported "no fern item"
  # for a run that never got far enough to build a menu, and sent someone
  # looking for a wiring bug that was not there.
  bad "example menu" "the run did not complete — timeout or crash, not the menu"
elif ! echo "$exout" | grep -q 'roast: example menu: fern True'; then
  bad "example menu" "the Examples menu has no fern item to click"
elif echo "$exout" | grep -q 'roast: project rows: 3'; then
  ok "example menu" "clicking fern lists its three files in the sidebar"
else
  bad "example menu" "$(echo "$exout" | grep -m1 'project rows:' || echo 'no rows reported')"
fi
# The tab bar half, and the working tree rather than the distribution, so a
# stale share/examples cannot make this pass. Sixty ticks, not twelve: the
# same run also has to live long enough for the language server handshake,
# so the announce check below is a check and not a race.
exout=$(COCOAMOJO_ROOT="$PWD/dist/CocoaMojo" ROAST_EXAMPLE="$PWD/examples/fern" \
        ROAST_AUTOCLOSE_TICKS=60 timeout 120 "$TMP/roast" 2>&1)
if echo "$exout" | grep -q 'roast: example files: 3'; then
  ok "example project" "fern opens its three files, not just main.mojo"
else
  bad "example project" "$(echo "$exout" | grep -m1 'example files:' || echo 'no count reported')"
fi
# Opening a project in a fresh window must START the server -- it used to
# only re-root a running one, so an app launched onto its scratch buffer had
# no server for the whole session -- and a server that just finished its
# handshake knows nothing, so every open tab is announced to it then.
if ! echo "$exout" | grep -q 'roast: language server started'; then
  bad "server starts" "opening a project did not start the language server"
elif echo "$exout" | grep -q 'roast: announced 3 documents to the server'; then
  ok "server told" "all three open files announced after the handshake"
else
  bad "server told" "$(echo "$exout" | grep -m1 'announced' || echo 'no announce before autoclose')"
fi
# Restoring what was open, which needs two launches: the first opens fern and
# saves on the way out, the second is told nothing at all and has to come back
# with the same three files and the same one showing.
SESS="$TMP/live-session.json"
rm -f "$SESS"
_=$(COCOAMOJO_ROOT="$PWD/dist/CocoaMojo" ROAST_SESSION="$SESS" \
    ROAST_EXAMPLE="$PWD/examples/fern" ROAST_AUTOCLOSE_TICKS=40 \
    timeout 120 "$TMP/roast" 2>&1)
sout=$(COCOAMOJO_ROOT="$PWD/dist/CocoaMojo" ROAST_SESSION="$SESS" \
       ROAST_AUTOCLOSE_TICKS=40 timeout 120 "$TMP/roast" 2>&1)
if ! [ -s "$SESS" ]; then
  bad "session restore" "nothing was written on the way out"
elif echo "$sout" | grep -q 'roast: restored 3 tabs from the last session, showing main.mojo'; then
  ok "session restore" "three tabs and the project come back, main.mojo showing"
else
  bad "session restore" "$(echo "$sout" | grep -m1 'restored' || echo 'nothing restored')"
fi

# Debugging, driven the way someone does it: put a breakpoint on a line and
# press Debug. The whole path runs -- build with debug info, launch the
# adapter, bind, stop, follow the program to where it stopped -- and the line
# asserted is the BOUND one, 10, not the clicked one, 9. Skipped without
# Xcode, like the dap suite.
if [ -n "$DAPBIN" ]; then
  mkdir -p "$TMP/dbgproj"
  cat > "$TMP/dbgproj/main.mojo" <<'DBGPROJ'
def add(a: Int, b: Int) -> Int:
    var sum = a + b
    return sum


def main():
    var total = 0
    for i in range(5):
        total = add(total, i)
    print("total:", total)
DBGPROJ
  # 1200 ticks is two minutes, which is generous on purpose: this check is
  # the only one that compiles a program AND launches a debugger on it, and
  # under the load of the rest of the suite the unoptimised build alone can
  # eat what used to be the whole budget. It passed alone and failed here,
  # twice, before the number was the number.
  # A debugger check that launches and NEVER STOPS, with no error anywhere,
  # is almost never the code: macOS gates debugging behind a dialog, and the
  # grant is keyed to the EXACT BINARY -- measured: the dist roast stops at
  # its breakpoint, a freshly built copy of the same source does not, and
  # embedding a bundle identity in the fresh copy changes nothing. So the
  # debugger checks drive dist/CocoaMojo/bin/roast, the binary a human has
  # approved once, while every other check keeps exercising the fresh
  # build. If these three fail with empty walks anyway, a human dismissed
  # nothing on a machine where the dist binary changed: run one debug
  # session by hand and answer the dialogs -- there are TWO: debugger
  # access, and removable-volume access (this repo lives on one), and
  # either can be the entire mystery.
  DBGROAST="$PWD/dist/CocoaMojo/bin/roast"
  [ -x "$DBGROAST" ] || DBGROAST="$TMP/roast"
  dbgout=""
  [ "$DEBUGGER_CHECKS" = 1 ] && dbgout=$(COCOAMOJO_ROOT="$PWD/dist/CocoaMojo" ROAST_DAP="$DAPBIN" \
           ROAST_PROJECT="$TMP/dbgproj" ROAST_DEBUG_LINE=9 \
           ROAST_AUTOCLOSE_TICKS=1200 timeout 400 "$DBGROAST" 2>&1)
  # Line 9, the line that was clicked -- not 10. The debug build is
  # unoptimised, so nothing slides; if this ever reports 10 again, the
  # --no-optimization has been lost and locals have gone with it.
  if [ "$DEBUGGER_CHECKS" != 1 ]; then
    skip "debugger" "needs a human for the macOS attach dialog (ROAST_CHECK_DEBUGGER=1)"
  elif echo "$dbgout" | grep -q 'roast: debug stopped at main.mojo:9 reason breakpoint'; then
    ok "debugger" "a breakpoint on line 9 binds to line 9, and the program stops there"
  else
    bad "debugger" "$(echo "$dbgout" | grep -m1 -E 'debug stopped|debugging|debug:' || echo 'never stopped')"
  fi

# The agent surface: Apple Events in, text out. The self-test posts a
# Rost/cmnd event to the running app's OWN process and checks the reply came
# back through the reply descriptor -- registration, unpack, dispatch and
# reply, with no second process and no TCC grant, because a process may always
# send to itself. (screencapture and System Events are both refused here, by
# design, and cannot be granted headlessly; this is why the app is scriptable
# rather than screen-scraped.)
mkdir -p "$TMP/agentproj"
agentout=$(COCOAMOJO_ROOT="$PWD/dist/CocoaMojo" ROAST_SESSION="$TMP/agent.json" \
           ROAST_AGENT_SELFTEST=1 ROAST_AGENT="status" \
           ROAST_AUTOCLOSE_TICKS=60 timeout 240 "$TMP/roast" 2>&1)
if echo "$agentout" | grep -q 'roast: agent self-test OK'; then
  reply=$(echo "$agentout" | grep -m1 'roast: agent >' | sed 's/^roast: agent > //')
  ok "agent events" "Rost/cmnd round trip; status replied \"${reply:-?}\""
elif echo "$agentout" | grep -q 'agent events FAILED to register'; then
  bad "agent events" "handler did not register"
else
  bad "agent events" "$(echo "$agentout" | grep -m1 'agent self-test' || echo 'no round trip')"
fi

# The screenshot: the app drawing ITSELF into a PNG. This is view drawing --
# cacheDisplayInRect:toBitmapImageRep: -- not screen capture, so it needs no
# Screen Recording grant and works headlessly, which is the whole reason it
# exists. The view photographed is contentView's superview, the frame view,
# so the picture includes the titlebar and toolbar; a check that only proved
# a file appeared would pass on a picture of the editor with no buttons in
# it, so the pixel size is asserted against the window's own reported frame.
shotout=$(COCOAMOJO_ROOT="$PWD/dist/CocoaMojo" ROAST_SESSION="$TMP/shot.json" \
          ROAST_AGENT="screenshot $TMP/shot.png" \
          ROAST_AUTOCLOSE_TICKS=60 timeout 240 "$TMP/roast" 2>&1)
if [ -f "$TMP/shot.png" ]; then
  magic=$(head -c8 "$TMP/shot.png" | xxd -p)
  bytes=$(stat -f%z "$TMP/shot.png")
  dims=$(echo "$shotout" | grep -m1 'agent >' | grep -oE '[0-9]+x[0-9]+ px')
  if [ "$magic" = "89504e470d0a1a0a" ] && [ "$bytes" -gt 2000 ]; then
    ok "screenshot" "${dims:-?}, $bytes bytes, PNG magic"
  else
    bad "screenshot" "wrote $bytes bytes, magic $magic"
  fi
else
  bad "screenshot" "$(echo "$shotout" | grep -m1 'agent >' || echo 'no file written')"
fi

  # The same walk, driven over APPLE EVENTS rather than by a direct call:
  # each verb is posted to the app's own process, unpacked by the handler,
  # and dispatched to the live toolbar item. That is the whole agent path
  # against a real debug session -- what an external agent does, minus only
  # the cross-process hop TCC gates. Asserted on the line walk, so a
  # transport that replied without moving the debugger would fail.
  agentwalk=$(COCOAMOJO_ROOT="$PWD/dist/CocoaMojo" ROAST_DAP="$DAPBIN" \
              ROAST_PROJECT="$TMP/stepproj" ROAST_SESSION="$TMP/awalk.json" \
              ROAST_DEBUG_LINE=11 \
              ROAST_AGENT_STEPS="step-in,step-over,step-out,continue" \
              ROAST_AUTOCLOSE_TICKS=1200 timeout 400 "$DBGROAST" 2>&1)
  awalk=$(echo "$agentwalk" | grep -oE 'debug (stopped at main\.mojo:[0-9]+|pressed [a-z]+)|agent step [a-z-]+' \
          | sed -E 's/debug stopped at main\.mojo:/@/; s/agent step /!/' | tr '\n' ' ')
  if [ "$DEBUGGER_CHECKS" != 1 ]; then
    skip "agent debugger" "needs a human for the macOS attach dialog"
  elif [ "$awalk" = "@11 !step-in @6 !step-over @7 !step-out @11 !continue " ]; then
    ok "agent debugger" "in -> 6, over -> 7, out -> 11, continue; over Apple Events"
  else
    bad "agent debugger" "walk was: ${awalk:-empty}"
  fi

  # The editor over Apple Events: menus walked and INVOKED by their visible
  # names, files opened, the caret driven, text typed and saved, find run,
  # both dividers moved. Assertions read state BACK (views, the saved file,
  # the setting) rather than trusting the mutating reply -- and the menu
  # invocation is checked by its visible effect: Zoom In moves the status
  # line to a new point size.
  mkdir -p "$TMP/edproj"
  printf 'fn helper(x: Int) -> Int:\n    return x + 1\n\nfn main():\n    var r = helper(41)\n    print(r)\n' \
    > "$TMP/edproj/main.mojo"
  edout=$(COCOAMOJO_ROOT="$PWD/dist/CocoaMojo" ROAST_PROJECT="$TMP/edproj" \
          ROAST_SESSION="$TMP/ed.json" \
          ROAST_AGENT="menus;open $TMP/edproj/main.mojo;goto 6:1;type X;save;find helper;sidebar 300;console-size 35;views;setting agent.gate ok;setting agent.gate;menu View > Zoom In;status" \
          ROAST_AUTOCLOSE_TICKS=80 timeout 240 "$TMP/roast" 2>&1)
  edfail=""
  echo "$edout" | grep -q 'agent > .*Debug.*View.*Examples' || edfail="menus missing"
  grep -q '^X    print(r)$' "$TMP/edproj/main.mojo" 2>/dev/null || edfail="${edfail:-typed text not in saved file}"
  echo "$edout" | grep -q 'agent > 2 match(es)' || edfail="${edfail:-find count wrong}"
  echo "$edout" | grep -q 'sidebar|editor 300' || edfail="${edfail:-sidebar readback wrong}"
  echo "$edout" | grep -q 'agent > ok' || edfail="${edfail:-setting round trip failed}"
  echo "$edout" | grep -q 'agent > invoked View > Zoom In' || edfail="${edfail:-menu invoke failed}"
  if [ -z "$edfail" ]; then
    ok "agent editor" "menus, open, goto, type->file, find, dividers, setting, menu invoke"
  else
    bad "agent editor" "$edfail"
  fi

  # Run Script: a file of agent commands replayed against the session, and
  # an AppleScript run in-process by NSAppleScript -- one function behind
  # both the File menu item and the run-script verb. Asserted on effects: the
  # scripted edit must be IN the saved file, the setting must round-trip, and
  # the AppleScript's result must reach the console.
  mkdir -p "$TMP/scproj"
  printf 'fn main():\n    print(42)\n' > "$TMP/scproj/main.mojo"
  printf 'goto 2:1\ntype X\nsave\nsetting script.gate ok\nsetting script.gate\n' \
    > "$TMP/session.roast"
  printf 'return "osa-alive"\n' > "$TMP/hello.applescript"
  scout=$(COCOAMOJO_ROOT="$PWD/dist/CocoaMojo" ROAST_PROJECT="$TMP/scproj" \
          ROAST_SESSION="$TMP/sc.json" \
          ROAST_AGENT="open $TMP/scproj/main.mojo;run-script $TMP/session.roast;run-script $TMP/hello.applescript" \
          ROAST_AUTOCLOSE_TICKS=80 timeout 240 "$TMP/roast" 2>&1)
  scfail=""
  grep -q '^Xprint(42)$\|^X    print(42)$' "$TMP/scproj/main.mojo" 2>/dev/null \
    || scfail="scripted edit not in saved file"
  echo "$scout" | grep -q 'script ok: 5 command(s), 0 error(s)' \
    || scfail="${scfail:-agent script did not run clean}"
  echo "$scout" | grep -q 'applescript ok: osa-alive' \
    || scfail="${scfail:-NSAppleScript path failed}"
  if [ -z "$scfail" ]; then
    ok "run-script" "agent lines edit the file; AppleScript answers in-process"
  else
    bad "run-script" "$scfail"
  fi

  # The debugger's BUTTONS. ROAST_DEBUG_STEPS presses one toolbar item per
  # stop -- looked up in the live bar by identifier, its action sent to its
  # own target through NSApp, the dispatch a click takes -- so a button
  # missing from the bar, wired to the wrong selector, or aimed at a dead
  # target fails here, not under the pointer. The fixture's shape makes the
  # three steps distinguishable: INTO lands inside middle(), OVER crosses a
  # helper() call without entering, OUT climbs back to main. The line
  # numbers are exact because the debug build is unoptimised; if this walk
  # ever drifts, stepping has changed underneath the buttons.
  mkdir -p "$TMP/stepproj"
  cat > "$TMP/stepproj/main.mojo" <<'EOF'
fn helper(x: Int) -> Int:
    var h = x + 1
    return h

fn middle(x: Int) -> Int:
    var a = helper(x)
    var b = helper(a)
    return b

fn main():
    var r = middle(4)
    print(r)
EOF
  stepout=$(COCOAMOJO_ROOT="$PWD/dist/CocoaMojo" ROAST_DAP="$DAPBIN" \
            ROAST_PROJECT="$TMP/stepproj" ROAST_SESSION="$TMP/stepsession.json" \
            ROAST_DEBUG_LINE=11 ROAST_DEBUG_STEPS="in,over,out,continue" \
            ROAST_AUTOCLOSE_TICKS=1200 timeout 400 "$DBGROAST" 2>&1)
  walk=$(echo "$stepout" | grep -oE 'debug (stopped at main\.mojo:[0-9]+|pressed [a-z]+)'          | sed -E 's/debug stopped at main\.mojo:/@/; s/debug pressed /!/' | tr '\n' ' ')
  want="@11 !in @6 !over @7 !out @11 !continue "
  if [ "$DEBUGGER_CHECKS" != 1 ]; then
    skip "debug buttons" "needs a human for the macOS attach dialog"
  elif [ "$walk" = "$want" ]; then
    ok "debug buttons" "in -> 6, over -> 7, out -> 11, continue -> exit; all via the toolbar"
  else
    bad "debug buttons" "walk was: ${walk:-empty}$(echo "$stepout" | grep -m1 'press FAILED' || true)"
  fi
fi

# Go to definition, against the real server. The caret goes onto the CALL of
# `helper` on line 6 and the answer has to be line 1, where it is defined --
# the server advertised definitionProvider from the first handshake and
# nothing had ever asked it anything.
mkdir -p "$TMP/navproj"
cat > "$TMP/navproj/main.mojo" <<'NAVEOF'
def helper(x: Int) -> Int:
    return x * 2


def main():
    var v = helper(21)
    print(v)
NAVEOF
navout=$(COCOAMOJO_ROOT="$PWD/dist/CocoaMojo" ROAST_PROJECT="$TMP/navproj" \
         ROAST_OPEN="$TMP/navproj/main.mojo" ROAST_DEFINE="6:13" \
         ROAST_AUTOCLOSE_TICKS=120 timeout 180 "$TMP/roast" 2>&1)
if echo "$navout" | grep -q 'roast: definition -> main.mojo:1'; then
  ok "go to definition" "the caret on a call lands on the def"
else
  bad "go to definition" "$(echo "$navout" | grep -m1 'definition' || echo 'no answer')"
fi

# Find all references, against the real server. `helper` is declared once and
# called twice, so the answer is three -- includeDeclaration is true because
# the question someone asks is "where does this appear".
mkdir -p "$TMP/refproj"
cat > "$TMP/refproj/main.mojo" <<'REFEOF'
def helper(x: Int) -> Int:
    return x * 2


def main():
    var a = helper(1)
    var b = helper(2)
    print(a + b)
REFEOF
refout=$(COCOAMOJO_ROOT="$PWD/dist/CocoaMojo" ROAST_PROJECT="$TMP/refproj" \
         ROAST_OPEN="$TMP/refproj/main.mojo" ROAST_REFS="1:5" \
         ROAST_AUTOCLOSE_TICKS=120 timeout 200 "$TMP/roast" 2>&1)
if echo "$refout" | grep -q 'roast: references 3'; then
  ok "find references" "one declaration and two calls"
else
  bad "find references" "$(echo "$refout" | grep -m1 'references' || echo 'no answer')"
fi

# Rename, against the real server. `a` is a local used twice, and the check
# is the TEXT rather than a count: a rename that reports two edits over a
# buffer saying something else is the exact failure this feature has.
mkdir -p "$TMP/renproj"
cat > "$TMP/renproj/main.mojo" <<'RENEOF'
def helper(x: Int) -> Int:
    return x * 2


def main():
    var a = helper(1)
    var b = helper(2)
    print(a + b)
RENEOF
renout=$(COCOAMOJO_ROOT="$PWD/dist/CocoaMojo" ROAST_PROJECT="$TMP/renproj" \
         ROAST_OPEN="$TMP/renproj/main.mojo" ROAST_RENAME="6:9:total" \
         ROAST_AUTOCLOSE_TICKS=140 timeout 240 "$TMP/roast" 2>&1)
if ! echo "$renout" | grep -q 'roast: renamed 2 in 1 file'; then
  bad "rename" "$(echo "$renout" | grep -m1 'renamed\|failed:' || echo 'no answer')"
elif echo "$renout" | grep -q "var total = helper(1)" \
  && echo "$renout" | grep -q "print(total + b)" \
  && echo "$renout" | grep -q "var b = helper(2)"; then
  ok "rename" "both uses renamed, the neighbouring name untouched"
else
  bad "rename" "the count was right and the text was not"
fi

# Documents from the Finder. Two halves, because they fail apart: whether
# AppKit can FIND the handler is selector derivation, and whether it works is
# open_path. A file becomes a tab, a folder becomes the project.
fout=$(COCOAMOJO_ROOT="$PWD/dist/CocoaMojo" ROAST_OPEN_FILE="$PWD/examples/fern/ifs.mojo" \
       ROAST_AUTOCLOSE_TICKS=50 timeout 120 "$TMP/roast" 2>&1)
if ! echo "$fout" | grep -q 'roast: openFile responds: True True'; then
  bad "open file" "the delegate does not answer application:openFile(s):"
elif echo "$fout" | grep -q 'roast: openFile: True'; then
  ok "open file" "a .mojo handed over by the Finder opens as a tab"
else
  bad "open file" "$(echo "$fout" | grep -m1 'openFile:' || echo 'no result reported')"
fi

# The first named_globals migrated onto class fields: the tab bar builds its
# label attributes lazily in its own box, and says so exactly once.
check "box fields"  "tab attributes built in the box" "per-instance state, built on first draw"

# Implementing the selectors is not conformance, and AppKit asks. The app says
# so on startup when the protocol is missing.
if echo "$out" | grep -q 'NSTextInputClient protocol not registered'; then
  bad "input client" "class does not conform — IME will not work"
else
  ok "input client" "NSTextInputClient conformance registered"
fi

# The editor surface: a document sized from the rope, which only happens if the
# buffer loaded, the font was measured and the view was installed.
doc=$(echo "$out" | grep -m1 'document:' | sed 's/roast: document: //')
if [ -n "$doc" ] && echo "$doc" | grep -qv 'x 0.0'; then
  ok "grid view" "$doc"
else
  bad "grid view" "${doc:-no document reported}"
fi

# The frame is derived from the screen now, not written into the source, so
# assert that it is usable rather than that it is one particular number: wide
# and tall enough for the layout to mean anything, and not off the top.
frame=$(echo "$out" | grep -m1 'frame:' | sed 's/roast: frame: //')
fw=${frame%% *}; fw=${fw%.*}
fh=$(echo "$frame" | awk '{print $3}'); fh=${fh%.*}
if [ -n "$fw" ] && [ "$fw" -ge 640 ] && [ -n "$fh" ] && [ "$fh" -ge 400 ]; then
  ok "frame" "$frame"
else
  bad "frame" "${frame:-none} — below the minimum usable size"
fi

echo
[ "$fail" -eq 0 ] && echo "IDE shell OK" || echo "IDE shell has failures"
exit $fail
