# Debugger sprint — porting MojoLLDB to x86-64

The IDE needs the debugger in place first, so the debugger goes first. Same
discipline as `PARITY_SPRINT.md`, which governs and is not restated here:
**their chronological order, files must match, consistency over innovation.**

Base: `mojococoa/main` at `5b4f5652`. Our parity base for the cocoa arc was
`d3ce7c8a`; the debugger work sits in the 102 commits after it, interleaved
with IDE and installer work that is explicitly NOT this sprint.

## Baseline, measured before porting anything (2026-08-30)

Four facts, established on this machine, before a line was changed:

1. **`libMojoLLDB.dylib` already builds on x86-64.** No source changes, 2400
   actions. Their spike said the same of arm64 — "first time anything in this
   tree built it". The plugin was never architecture-gated; it was unbuilt.
2. **Debug builds work.** `--debug-level full --no-optimization` produces a
   binary and a `.dSYM` beside it, and the program runs.
3. **The DWARF shows THE SAME per-type cliff they documented**, on x86-64:

       p      : module dbg_min::struct Point        <- level 2, identity intact
       total  : kgen.dtype.index[[?, ? + 1)]        <- level 1, an Int, erased

   This is the single most useful thing learned today. The predicate is
   `decl.isSingleElement()` in `LowerLITTypes.cpp`, it has nothing to do with
   the target, and it reproduces here exactly. **Their debug-info contract work
   is therefore portable as-is** — it is not an arm64 fix we have to reinvent,
   which is what the cocoa arc kept turning out to be.
4. **Developer mode is DISABLED on this box, and that blocks attaching.** See
   below; it is the one thing in this sprint we cannot do ourselves.

## The three levels (their `spikes/MOJOLLDB-SPIKE.md`, ported verbatim)

1. **Storage** — locate and display the lowered bits.
2. **Semantic value** — source types, fields, scopes, and the map from a source
   type onto its scalarized storage.
3. **Semantic expression** — resolve real Mojo declarations well enough to
   compile against them.

The plugin sits between 1 and 2: a Mojo-aware DWARF reader, not a Mojo semantic
debugger. It is not a uniform middle but a per-type cliff, and the erasure is
contagious through members — `Point` survives, `p.x` does not, and `Int` is in
nearly every Mojo type. Levels 2 and 3 are decoupled and neither unblocks the
other: even a preserved `Point` has no methods, because
`CompleteStructureTypeFromDWARF` populates from `DW_TAG_member` only.

Their suggested order, which we follow: **the frame-local type filter** (the
smallest piece, and the instrument that makes the rest measurable), then the
compiler-to-debugger semantic type contract as one deliberate piece, then the
declaration surface for expressions.

## Step 1 — adopt the delta verbatim. DONE.

Every one of our files matched their pre-change parent exactly, so the whole
delta was taken whole rather than as hunks, and every file is now byte-identical
to `mojococoa/main`:

    KGEN/lib/MojoLLDB/Plugin.cpp                        idempotent target registration
    KGEN/lib/MojoLLDB/TypeSystem/MojoTypeSystem.cpp     loud target failure, safe pointer size
    KGEN/lib/MojoLLDB/TypeSystem/MojoDWARFParser.{cpp,h} keyed debug annotation
    KGEN/lib/MojoLLDB/ExpressionParser/MojoUserExpression.cpp
    KGEN/lib/MojoLLDB/ExpressionParser/MojoExpressionParser.cpp   frame-local injection
    Support/include/Support/DebugInfoDialect/IR/DebugInfoAttrs.h
    Support/lib/DebugInfoDialect/DebugInfoToLLVM/DebugInfoToLLVM.cpp  mojo_debug_schema
    bazel/public-patches/llvm-lldb-exports.patch        +42 lines of LLDB_PRIVATE_EXPORT
    spikes/MOJOLLDB-SPIKE.md, dwarf-identity-collisions.py, mojo-join-map.py

The one fix worth knowing before it bites: **target registration is now
idempotent.** liblldb and libMojoLLDB each embed a static LLVM, and on macOS the
TargetRegistry list head unifies across the images, so both initializations
append to ONE registry and the next lookup dies with `Cannot choose between
targets`. On their machine the message names "aarch64" twice; here it would name
"x86-64" twice. Asking the registry before initializing is correct in both
worlds — inside lldb it must not run, embedded standalone it must.

## BLOCKED, and it needs Alban

    $ DevToolsSecurity -status
    Developer mode is currently disabled.

Their harness records what this costs, and it matches our own note that an
unsigned debugserver cannot ptrace here: **with developer mode off lldb does not
fail, it HANGS on `run`**, waiting for an authorization dialog that never
appears. Their comment says it cost an afternoon. It needs a password, so it is
not something this session can do:

    sudo DevToolsSecurity -enable

Until then: everything compiler-side and DWARF-side is verifiable statically
(`dwarfdump`, symbol checks, the two spike scripts), and none of it is blocked.
Only *attaching* is.

## Step 2 — verify statically what developer mode does not gate. DONE.

Everything below was checked without attaching to anything.

**The export patch reaches liblldb.** The plugin imports four symbols that the
frame-local code needs and that stock LLDB hides; all four are exported by our
rebuilt `liblldb24.0.0git.dylib`. Worth checking rather than assuming, because
the failure mode is `plugin load` reporting a missing symbol, which reads as our
bug and is not:

    __ZN12lldb_private8Variable7GetTypeEv                    EXPORTED
    __ZNK12lldb_private12VariableList18GetVariableAtIndexEm  EXPORTED
    __ZNK12lldb_private12VariableList7GetSizeEv              EXPORTED
    __ZNK12lldb_private8Variable7GetNameEv                   EXPORTED

**The annotation transport works here.** `mojo_debug_schema` reaches the emitted
DWARF, 306 occurrences in a trivial program, as the keyed protocol intends:

    DW_TAG_LLVM_annotation
      DW_AT_name        ("mojo_debug_schema")
      DW_AT_const_value ("1")

**The collision test finds THEIR ambiguity, not a new one.** Run on an x86-64
dSYM: 1154 variable dies, 352 distinct tuples, 92 multiplicity, and exactly one
ambiguity —

    name="ptr" line=1497   type='!kgen.string *'   and   'index *'
    in std::builtin::variadics::VariadicPack::consume_elements[...]

which is the same case, at the same line, in the same function as theirs. Their
diagnosis holds unchanged: not two instantiations sharing a name, but one body
unrolled at compile time per pack element, every copy emitted into a single
lexical block at a single source line. Architecture-independent, as expected —
the defect is scope emission, and linkage names are not what breaks it. Our
counts are lower than their table only because their fixture was never committed
and this ran against a trivial program; **a fixture matching their description is
worth writing before the sidecar format is settled.**

**The join map validates.** 1154 of 1154 dies mapped, 353 semantic records, 211
of them described by more than one die, widest fan-out 18, validation OK. Their
central requirement — one record to many offsets — is confirmed here: a 1:1
table would drop 801 of 1154 dies (69%, against their 81% at `-O0`).

## Next

* **A fixture matching their description** (nested shadowing, sibling scopes
  reusing a name, generics at several types, a closure shadowing its capture, an
  `@always_inline` helper called twice), so our collision numbers can be compared
  with theirs rather than merely being smaller.
* The frame-local type filter, per their order — the smallest piece, and the
  instrument that makes levels 2 and 3 distinguishable at all.
* Everything that needs `run` waits on developer mode.
