# Mojo Mac Playground — design

A native macOS app, written in Mojo, for writing and running Mojo: an editor
with real editor conveniences and a REPL, in a window instead of a terminal.
The Mac precedent is Swift Playgrounds; the ambition is the same — the
language feels *native* on the platform — and it doubles as the proof that
Mojo is useful on the Mac, because the app is itself a real Mojo Cocoa program.

## 1. The question to answer first: can a user work inside a running program?

Yes — but it conflates two different things, and they get two different
engines behind one UI:

| what the user wants | what it is | engine |
|---|---|---|
| type Mojo, see results, definitions persist | a **REPL** (persistent-state evaluation) | `mojo-jupyter-executor` — the cell kernel behind Mojo notebooks (`MojoKernel::startExecution(cell, expr, storeHistory=true)`) |
| stop a program mid-run, inspect variables, evaluate in that frame | a **debugger** | `lldb-dap` + the in-tree `MojoLLDB` plugin — the Debug Adapter Protocol, which the MojoLLDB docs name as their primary target |

Both of those are already lldb's expression engine underneath; that *is* why
upstream's REPL is lldb. The "un-Mac-like" part was never the engine, it was
the terminal. Xcode is the proof: its console, variable view and breakpoints
are lldb behind a Cocoa front end. This app is the same move for Mojo.

All three backends exist **in this tree, open-source, and build on this
machine**: `mojo-lsp-server` (130 MB, answers `initialize`),
`mojo-jupyter-executor` (14 MB), and `@llvm-project//lldb:lldb-dap`.

## 2. Architecture

```
┌─────────────────────────── Mojo Mac Playground.app (all Mojo, via std.objc) ──────────────────────────┐
│  NSWindow / NSToolbar [Run ⌘R] [Run on Vega II] [Stop] [Debug]                                         │
│  NSSplitView                                                                                           │
│   ├─ Editor   NSTextView  ← highlighting (semantic tokens), diagnostics squiggles, completion popover   │
│   └─ Right column                                                                                      │
│       ├─ Output  NSTextView (read-only)  ← streamed stdout/stderr; file:line:col → click to jump        │
│       └─ REPL    transcript NSTextView + NSTextField  ← cells (idle) / frame evaluate (stopped)          │
│       └─ Variables NSOutlineView (debug only)                                                           │
└─────────────┬──────────────────────┬───────────────────────────┬───────────────────────────────────────┘
              │ JSON-RPC (stdio)     │ line protocol (stdio)      │ DAP JSON (stdio)
        mojo-lsp-server      mojo-jupyter-executor          lldb-dap + MojoLLDB      mojo run / mojo build
        (editor brains)      (REPL, persistent state)       (debug, in-frame eval)   (whole-file execution)
```

**Process model.** Every backend is a child process over pipes (`NSTask` +
`NSPipe`). The app never links a compiler, so a user program that crashes,
hangs, or leaks cannot take the editor with it; *Stop* is `-[NSTask terminate]`.
This is also what makes the GPU path trivial: "Run on Vega II" is the same
launch with `--target-accelerator=metal-vega2`.

**Threading.** Everything on the main thread. Child output is read from
non-blocking pipe fds by an `NSTimer` (16 ms) with a Mojo target/action — no
blocks, no GCD, no Mojo threads touching AppKit. LSP/DAP replies are parsed
from the same timer.

## 3. What the app needs that std.objc does not yet have

Everything below was de-risked before this document was written.

**Cocoa calling back into Mojo** (target/action, delegates, notifications,
timers). Proven by `spikes/s5-cocoakb/callback_probe.mojo`: a class allocated
at runtime with `objc_allocateClassPair`, a method added with
`class_addMethod` whose IMP is a Mojo `def … abi("C")` function, and — the
nice part — the **database supplying the `@encode` string** for the method, so
even a callback's type signature isn't hand-typed. This becomes
`std.objc.define_class[...]` with `@method` registration. Instances are held
in app globals (Cocoa delegates are unretained), and IMPs reach app state
through one global `App` struct.

**The real run loop.** With an app delegate and target/action in place, the
app uses `[NSApp run]` and `NSTimer` like any Cocoa program, instead of the
hand-pumped loop the Mandelbrot used.

**API coverage.** Every AppKit/Foundation selector the design uses resolves
through the database — the "missing" ones (`addAttribute:value:range:`,
`setTarget:`, `setAction:`) live on superclasses and are found by `msg_send`'s
inheritance walk; `waitUntilExit` lives on a private subclass and is reached
by selector-keyed `send`. Nothing here needs a hand binding.

**No blocks.** ObjC blocks are not supported; the design only uses
selector/notification/timer APIs, which covers every need listed.

## 4. Components

### 4.1 Editor
- `NSTextView` in `NSScrollView`, Menlo/SF Mono, line numbers in a ruler view,
  soft tabs, auto-indent after `:`.
- **Highlighting**: P1 uses a ~100-line Mojo tokenizer (keywords, strings,
  comments, numbers, decorators) applied as `NSTextStorage` attributes to the
  edited paragraph only; P3 switches to LSP `semanticTokens`.
- **Diagnostics**: LSP `publishDiagnostics` → red/yellow underlines + gutter
  marks; the Output pane's `file:line:col: error:` lines are also parsed so
  compile errors from a Run are clickable even without LSP.
- **Completion**: `NSTextView`'s own popover via the
  `completionsForPartialWordRange:…` delegate, fed by LSP `completion`.
  Hover → LSP `hover` in a tooltip; ⌘-click → `definition`.
- Open/Save with `NSOpenPanel`/`NSSavePanel` (`runModal` is synchronous —
  easy); Untitled buffers autosave to a temp file for runs.

### 4.2 Run
- ⌘R writes the buffer to disk and launches `vega-sdk/bin/mojo run <file>`
  (or `build` + exec for the GPU target) via `NSTask`; stdout/stderr stream
  into the Output pane with a timestamp and the exit status; compile errors
  become clickable.
- The run target menu exposes the machine: *CPU* / *Radeon Pro Vega II* /
  *Radeon Pro 580X*.

### 4.3 REPL
- A transcript view and an input field; ↩ evaluates, ⇧↩ inserts a newline,
  ↑/↓ walk history. Each entry is a cell sent to one long-lived
  `mojo-jupyter-executor` with `storeHistory=true`, so `var x = 41` in one
  cell and `print(x + 1)` in the next just works. `:reset` restarts the
  process; completion comes from the executor's completion callback.
- When the debugger is **stopped at a breakpoint**, the same input field
  evaluates in the selected frame via DAP `evaluate` — that is "working inside
  the running program", and the UI makes the switch visible (a frame label in
  the prompt).
- **Fallback if the executor ever misbehaves**: accumulate cells into a hidden
  session file and re-run it with `mojo run`, showing only the new output.
  Slower, side effects repeat, but needs nothing beyond *Run*.

### 4.4 Debug
- Gutter click toggles a breakpoint. *Debug* launches the built binary under
  `lldb-dap`, sends `setBreakpoints`, `launch`, then on `stopped` shows the
  stack and a variables `NSOutlineView` (DAP `scopes`/`variables`), with
  Continue / Step Over / Step In / Step Out. The REPL field evaluates in-frame.
- MojoLLDB's data formatters are what make `String`, `List`, `SIMD` readable
  in that view — they ship in the plugin.

### 4.5 The bundle
- `mojo build` produces the binary; a script wraps it in
  `Mojo Mac Playground.app/Contents/{MacOS,Resources,Info.plist}` with an
  icon, so it is a double-clickable Mac app that shows up in the Dock with a
  name. The three backend binaries and the `vega-sdk` ride inside `Resources`.

## 5. Phases

| phase | deliverable | proves |
|---|---|---|
| **P0** | `std.objc.define_class`, target/action, app delegate, `[NSApp run]`, `NSTimer`; spike: a window whose button prints from Mojo and quits via delegate | Cocoa ⇄ Mojo both ways, real run loop |
| **P1** | Editor + Run: highlighting, ⌘R, streamed output, clickable errors, open/save, run-target menu | "a nice development environment" — usable on its own |
| **P2** | REPL pane on the executor, history, `:reset`, completion | interactive Mojo with persistent state, no terminal |
| **P3** | LSP: diagnostics-as-you-type, completion, hover, ⌘-click, outline, semantic highlighting | editor conveniences |
| **P4** | Debug: breakpoints, lldb-dap, variables view, stepping, in-frame REPL | working *inside* a running program |
| **P5** | `.app` bundle, icon, Dock name, timing readouts, Vega II default | feels like a Mac app |

P0+P1 is a weekend's work on the foundation that exists today and is already
the thing the user asked for; P2 makes it a REPL; P4 is where it outgrows
`mojo repl`.

## 6. Open items and honest risks

- **Executor init on this host**: the binary builds and runs, but it must load
  the MojoLLDB plugin through the same configuration mechanism as the other
  toolchain paths (`.lldb_plugin_path` / `MODULAR_MOJO_MAX_LLDB_PLUGIN_PATH`);
  wiring that into `vega-sdk` is a P2 task, and the §4.3 fallback needs
  nothing. (lldb-dap has the same dependency.)
- **Large files**: full re-highlighting on every keystroke is O(n); the design
  re-highlights the edited paragraph and debounces LSP `didChange` (the LSP
  server already ships a `DocumentDebouncer`).
- **Retain discipline**: delegates/targets are unretained by Cocoa, so every
  Mojo-defined instance is owned by the `App` struct for the app's lifetime.
- **Not in scope**: multiple windows/documents, tabs, a project model. One
  window, one buffer, one REPL — a playground, not an IDE. That scope is what
  makes it finishable.
