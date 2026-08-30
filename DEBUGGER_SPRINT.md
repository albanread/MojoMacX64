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

## Step 3 — it debugs. Developer mode was the only gate.

`sudo DevToolsSecurity -enable`, and the whole path works on x86-64:

    Breakpoint 1: where = dbg_min2`dbg_min::main() + 34 at dbg_min.mojo:9:10
    Process stopped ... at dbg_min.mojo:9:10
    (lldb) frame variable
    (Point) p = (x = 7, y = 9)
    (__mlir_type.`!kgen.scalar<index>`) total = 16

Breakpoints bind by file:line, the program stops, source displays, and named
Mojo locals come back with values -- their spike's own success criterion. The
level split is visible in the output: `Point` keeps its identity and its fields,
`total` is an `Int` and arrives as erased storage with the right value.

**The DAP path -- which is the one the IDE uses -- also works**, verified with
`spikes/dap-probe.py`: breakpoint verified, stop lands on it, and the stopped
frame answers with `p` and `total`.

Two things needed for the CLI that DAP does not need, both of them theirs:
`lldb-argdumper` must sit beside the binaries (the CLI's `run` shells out to
it), and the layout must be `bin/` + `lib/`, because the staged `lldb` resolves
`liblldb` through `@rpath/../lib`.

### The one real defect, and why it is NOT being fixed by changing the allocator

The lldb CLI aborts on `quit` -- exit 134, `tcmalloc: Attempt to free invalid
pointer`, from CoreFoundation's autorelease pool draining on thread exit. It is
the plugin: without it the same session exits 0.

The cause is ours rather than theirs. `libMojoLLDB` pulls `//AsyncRT:RuntimeGlobals`, which statically links gperftools, and **our gperftools is a local
x86-64 build because upstream's artifact is arm64-only** (`common.MODULE.bazel`
says so). On Apple, gperftools registers a malloc zone and becomes the system
allocator; that is right for the compiler, where it loads first, and wrong for a
plugin dlopen'd into a process that has already allocated.

The tempting fix -- rebuild our gperftools with the OSX override disabled --
would change the allocator for the entire toolchain, including the compiler's
hot path, to fix a crash after all work is done. Measurement said not to: the
DAP path exits 0 and never aborts, and the plugin needs only 10 symbols from
RuntimeGlobals, three of which are `tc_new`/`tc_delete`, so it genuinely wants
tcmalloc for its own allocation. **Left alone deliberately, recorded here rather
than fixed quietly.** Revisit if the CLI is ever shipped as a product surface.

## Step 4 — the frame-local type filter. DONE, and it is AHEAD OF THEM.

**Read this before touching MojoExpressionParser.cpp.** Every other file in this
sprint is byte-identical to `mojococoa/main`. This one is not, and the
difference is not an x86-64 divergence — it is a step of the shared plan taken
here first. Their `spikes/MOJOLLDB-SPIKE.md`, which we carry verbatim, names it
as the next thing to do and specifies its purpose; it does not implement it.
**Send this upstream rather than letting the two forks solve it twice.**

The defect, reproduced here exactly as they recorded it, on an expression that
mentions no local at all:

    MOJO_LLDB_FRAME_LOCALS=0   expr 1 + 41   -> evaluates
    MOJO_LLDB_FRAME_LOCALS=1   expr 1 + 41   -> 'Pointer' parameter 'T' has
                                                'AnyType' type, but value has
                                                type 'AnyStruct[Point]'

The wrapper declares every collected variable as `Pointer[mut, Pointer[mut, T,
...], ...]` and `Pointer`'s `T` is an `AnyType`. A struct that survived lowering
with its source identity intact is not one — it arrives as a KIND, and the parse
dies on the field declaration before it ever reaches the expression. Collection
"worked" only by breaking everything else.

The filter rejects such types in `collectFrameVariables`, **before**
`AddVariable` — that ordering is deliberate. Registering a materializer entity
for a variable that is then dropped leaves the entity list and the wrapper's
fields disagreeing about position, which is the offset bug `parse()` already
warns about at length. It is commented in place; do not move it below the
registration.

Measured after, at a breakpoint with `p: Point` and `total: Int` in scope:

    expr 1 + 41       ->  evaluates (42, warns the value is unused)
    expr total + 41   ->  '!kgen.scalar<index>' does not implement '__add__'
    expr p            ->  use of unknown declaration 'p'

The middle line is **their recorded frontier, reached here**: the name binds and
a type flows, but the wrapper receives DWARF's scalar rather than Mojo's `Int`.
The third is honest rather than silent. That is the whole point of the filter —
it does not make structs work, it makes the level-1/level-2 boundary
OBSERVABLE, which is what their doc asks of it and why it is the smallest of the
three pieces.

It widens on its own when the semantic type contract lands. Nothing in it needs
revisiting to let structs through; they will simply stop being kinds.

## Step 5 — re-measuring the erasure, which turned out to be NARROWER than recorded

Before building anything toward the semantic sidecar, their two-erasures
analysis was re-measured here, because it was taken on arm64 and the sidecar's
whole priority rests on how much it actually costs. It holds — with a sharper
predicate, and the difference is worth sending upstream.

Their record (`spikes/MOJOLLDB-SPIKE.md`) shows a one-field `Meters` with no DIE
of its own, sharing `Int`'s:

    total  0x230  '!kgen.scalar<index>'
    dist   0x230  '!kgen.scalar<index>'   <- Meters

Measured here, by `DW_AT_type` reference rather than by name, as their doc
rightly insists:

    struct A(Copyable, Movable)        one Int field    -> own DIE, named A
    struct C(Copyable, Movable)        one Int field    -> own DIE, named C
    struct One(TrivialRegisterPassable) one Int field   -> shares Int's DIE
    struct OneF(TrivialRegisterPassable) one F64 field  -> shares Float64's DIE
    struct Two(TrivialRegisterPassable) two fields      -> own DIE, named Two

**The trigger is single-element AND register-passable, not single-element
alone.** An ordinary user struct — `Copyable, Movable`, memory-only — keeps its
source identity even with exactly one field. Only a register-passable
single-field wrapper collapses into the storage type it lowers to, and it does
so for floats as well as integers, which rules out anything integer-specific.

This narrows a claim the design leans on. Their doc says "`Int` occurs in very
nearly every Mojo type, so there is almost nothing that is wholly level 2
today". The half about MEMBERS stands unchanged — `p.x` is an `Int` and is
erased, and that is still most of the reach. But the half about user types does
not: the structs a person writes and wants to inspect are, today, mostly level 2
already. What is erased is `Int` and `Float64` themselves, and newtype wrappers
over them.

For the IDE that is the difference between "almost nothing is inspectable" and
"your own types are inspectable, the scalars inside them are not", which is a
much better position than the doc implies — and it argues for the sidecar being
scoped at scalars and newtypes first rather than at the whole type graph.

**Not acted on beyond measuring.** The next step in their order is the semantic
sidecar, which is a large piece they have specified in detail and not built. It
is deliberately NOT started here: two independent implementations of a
serialisation contract is precisely the divergence this fork exists to avoid.
Their spec already names the shortcut (`MojoPrecompiledFile.cpp`, the `.mojoc`
serialiser, which already does the staleness discipline) and the trap to avoid
(a `DIBasicType` carrying the source name, which `MojoDWARFParser.cpp:397` reads
as a builtin scalar and yields no type at all).

## Step 6 — read ahead, because they are in our past

Working forward through the spike doc was re-deriving questions they had already
closed. Surveying every non-IDE file they had touched since our base found six we
had never looked at, and two more arrived while doing it. Parity base is now
`284c834c`.

**The debugger produced two stdlib bugs, both in `String._realloc_mutable`, and
both are ours as much as theirs.** Neither is architecture-specific:

* asking the allocator for zero — an empty inline String grown by nothing
  computes `(0 + 7) >> 3 == 0`, and `alloc` refuses, naming itself rather than
  the String that asked it for nothing.
* doubling on COPY, not just on growth — the same function makes a shared
  string unique, called with the capacity the string already has. Applying an
  append heuristic there walks a 5 KB string through 9 MB, 18 MB, 37 MB … 600 MB
  and dies on a null pointer, with process memory flat the whole way because
  each step frees the one before it. Their debugger hit it because **every
  locals fetch shares strings out of a list and mutates them** — inspecting a
  variable should not mean copying it.

That second one is worth remembering as a shape: a debugger stresses the stdlib
in a way ordinary programs do not, so the debugger arc will keep producing
stdlib fixes, and they belong upstream in `docs/stdlib_patches.md` rather than
here.

**Their IDE-side debugger fixes (284c834c) are lessons for our IDE arc**, and
one applies already. The code is in `ide/` and is not ported, but:

* `target.max-children-count 64` and `target.max-string-summary-length 512` in
  initCommands are **not tuning**. Without them lldb formats every element of
  every container at every stop — a `List` of 691,200 `UInt32` rendered in full
  to fill one line — and memory across a stepping run climbs from 132 MB to
  12.8 GB. `spikes/dap-probe.py` now sets both.
* A local that is declared but not yet live reads as
  `<error: variable not available>`. That is lldb's ordinary phrase for an
  ordinary state at a breakpoint; treating it as an error sends people hunting
  a fault that is not there.
* An uninitialised local renders as whatever bytes were at that address, and
  arbitrary bytes are not text — invalid UTF-8 reaching a grapheme iterator
  aborts. Display paths must repair to U+FFFD rather than hold back, which is
  the opposite of the streaming case.

**The acceptance corpus was stale and is re-synced.** It is a mirror of their
`examples/` — its own README says so — and it had sat at `ce53b96e` while they
fixed four of the six. Now at `284c834c`, and all six still build.

## Next

* **Coordinate the sidecar with them before either fork writes it.** Everything
  up to here was adoption or measurement; that one is a shared format.
* **A fixture matching their description** (nested shadowing, sibling scopes
  reusing a name, generics at several types, a closure shadowing its capture, an
  `@always_inline` helper called twice), so our collision numbers can be compared
  with theirs rather than merely being smaller.
* The frame-local type filter, per their order — the smallest piece, and the
  instrument that makes levels 2 and 3 distinguishable at all.
* Everything that needs `run` waits on developer mode.
