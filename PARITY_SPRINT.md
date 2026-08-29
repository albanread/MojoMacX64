# The Parity Sprint — instructions, order, and rules

**The prize is consistency, not innovation.** This fork's job for the rest of
the class arc is to behave exactly like the Apple Silicon fork (MojoCocoa), so
that the same user code runs unmodified on both machines. Every clever idea
that is not in their tree is drift, and drift is the failure mode — even when
the idea is good. If something in their design seems wrong, the move is to
verify it on this hardware, report it upstream, and follow their tree until it
changes there. We do not fix it locally first.

## The two rules that were learned the hard way

**Rule 1 — port in THEIR chronological order, never by sprint label.**
Their history contains mid-arc corrections in commits whose titles name no
sprint (`693f426c`, `e289fa28`). Both defects found during our sprint 3 were
in commits skipped by label-ordering. The order below is their `git log
--reverse` order. Do not reorder it, even when a later commit looks more
interesting.

**Rule 2 — a port is done when the FILES match, not when the hunks apply.**
The two forks' std.objc were never byte-identical, so a hunk can apply cleanly
and still leave the files different. After every ported commit, diff each
touched file against their tree at that commit. At the end of the arc, adopt
the stdlib files whole and diff against their HEAD.

## Allowed divergences — the complete list

Nothing diverges without landing on this list, and nothing lands on this list
without evidence (clang's own output, the cocoa.sqlite tables, or a
measurement on the Vega II). Today the list is:

Enforced by `tools/check-parity.sh`, which is now the authority — this table is
the human-readable copy of `tools/parity-allowlist.txt`.

| where | ours | theirs | evidence |
|---|---|---|---|
| CocoaKB queries | `method_abi_x64`, `posix_function_abi_x64` | `method_abi`, `posix_function_abi` | the tables disagree by design; NSRect return is registers there, sret here |
| ~~`encodeObjCType`~~ | ~~Bool → `c`~~ | ~~Bool → `B`~~ | **RETIRED at step 3** — their `canon()` treats `B` and `c` as one ABI class, which is the proper fix; our adaptation was a workaround for a check they had already corrected |
| ~~IMP spelling~~ | ~~`def ... abi("C")`~~ | ~~`fn`~~ | **RETIRED at step 1** — `fn` is revived and `std/objc/classes.mojo` now matches their tree byte for byte |
| `runtime.mojo` `_nth_class_kind` | every eightbyte `f` is SSE | scalar float **or HFA** (`h`) | System V classifies per eightbyte; AAPCS64 has Homogeneous Floating-point Aggregates in v0-v3 and we have no such concept |

Anything else that differs is a bug in the port. The parity checker (step 3)
turns this table into an enforced allowlist.

## The order of work

Do these in sequence. Each step ends with: regression suite green, files
diffed against their tree at that commit, one commit pushed.

1. ~~**Revive `fn`**~~ — their `a694adc9`. **DONE.** The foreign-callable function: thin,
   non-raising, C ABI. Unblocks the `fern` acceptance example and retires the
   IMP-spelling divergence (adopt their IMP comptime aliases and the full
   overload set at the same time).
2. ~~**Revive `let`**~~ — their `b9ca66e1`. **DONE**, together with the
   predecessor `784e8f50` (weak refs, NSError) that their chronology puts
   first and step order had missed.
3. ~~**Close the skipped-commit residue**~~ **DONE.** — `693f426c` and `e289fa28`: verify
   the Signatures.cpp state matches theirs exactly; adopt
   `std/objc/geometry.mojo`; port `struct_arg_test.mojo` and
   `struct_ret_test.mojo` and run them (delete our local NSRange stand-in in
   class_field_test in favour of the real geometry module).
4. ~~**Build `tools/check-parity.sh`**~~ **DONE.** — diffs the shared surface (std/objc,
   the objc regions of MojoParser, CocoaKB) against `mojococoa/main`, fails on
   any divergence not in `tools/parity-allowlist.txt`. From here it runs as
   part of every step's exit criteria.
5. **Port `spikes/run-cocoa-checks.sh`** — the whole cocoa suite (spikes,
   parser tests, ABI oracle, parity check) behind one command. No more
   hand-typed test lists.
6. **`@objc`** — their `8723fbd9`.
7. **Fields constructed into the box** — their `fd49242c`.
8. **Field initializers** — their `2db74630`.
9. **`class B(A)` inheritance** — their `ac1b2de2`.
10. **`@staticmethod`** — their `cb5c155d`.
11. **`box_ref`** — their `05604113` then `a63f1bec`.
12. **Returned-class trio** — their `feb4d5d6`, `3358ba19`, `6faa3a82`.
13. **`std.objc.typed`** — their `ea19518e`.
14. **Stdlib convergence** — adopt `std/objc/*` whole from their HEAD; every
    surviving diff is either on the allowlist or eliminated.
15. **Acceptance** — the six examples in `acceptance/_class-pending/`
    (window, life, mandelbrot, fluid, ferns, fernwind) build and run here
    **unmodified**. This, and only this, is the definition of done.

## What NOT to do

- Do not improve their code while porting it. Not naming, not structure, not
  diagnostics wording. Identical is the feature.
- Do not skip ahead to an interesting commit. Rule 1 exists because that
  already caused two defects.
- Do not adapt for x86-64 on suspicion. Adapt on evidence, then put it on the
  allowlist in the same commit.
- Do not write new tests in place of porting theirs. Port theirs first; add
  ours only for things theirs cannot see (x86-64-specific behaviour).
- Do not touch the GPU/AIR side, the benchmarks, or the census while this
  sprint runs. They are separate tracks; interleaving them is how a sprint
  loses its thread.

## Standing verification

- After every step: the regression list (spikes + basics + class suite), the
  ABI oracle, and — once step 4 lands — the parity checker.
- Rebuild all 16 `.mojoc` packages after any dialect or stdlib change; a
  stale package presents as a false regression ("precompiled file is
  incompatible", or `mojo run` import failures).
- The trace hatch `VEGA_TRACE_OBJC_REGISTER` shows what registration emits
  when a binary strips the evidence.
