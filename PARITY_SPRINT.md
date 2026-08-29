# The Parity Sprint — instructions, order, and rules

**The prize is consistency, not innovation.** This fork's job for the rest of
the class arc is to behave exactly like the Apple Silicon fork (MojoCocoa), so
that the same user code runs unmodified on both machines. Every clever idea
that is not in their tree is drift, and drift is the failure mode — even when
the idea is good. If something in their design seems wrong, the move is to
verify it on this hardware, report it upstream, and follow their tree until it
changes there. We do not fix it locally first.

## The two rules that were learned the hard way

**Rule 0 — their history gets rewritten; track content, not SHAs.**
On 2026-08-30 MojoCocoa force-pushed a rebased history: every commit we had
ported got a new SHA, and the old ones became orphans that still resolve
locally (because we fetched them) but are no longer on their `main`. The
CONTENT was identical -- five shared files compared byte for byte across the
old base and its new twin. So a rewrite is not a re-port; it is a
`parity-base.txt` update. Verify content before assuming either way, and if
`check-parity.sh` starts reporting mass drift, suspect this first.

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
5. ~~**Port `spikes/run-cocoa-checks.sh`**~~ **DONE.** — the whole cocoa suite (spikes,
   parser tests, ABI oracle, parity check) behind one command. No more
   hand-typed test lists.
6. ~~**`@objc`**~~ — their `8723fbd9`. **DONE** (a back-fill: it sits before
   the dealloc commit already ported, so it was a skipped predecessor rather
   than forward progress).
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

- After every step, run **`./spikes/run-cocoa-checks.sh`**. It is the whole
  cocoa suite, the must-fail set, the clang ABI oracle and the parity checker
  behind one command, and it reports `NOT PORTED` for anything in their test
  list this fork has not reached — so the gap is visible without being a
  failure. Do not hand-type a test list; that is how coverage drifts.
- The GPU regression (spikes + basics) after any dialect or stdlib change.
- Rebuild all 16 `.mojoc` packages after any dialect or stdlib change; a
  stale package presents as a false regression ("precompiled file is
  incompatible", or `mojo run` import failures).
- The trace hatch `VEGA_TRACE_OBJC_REGISTER` shows what registration emits
  when a binary strips the evidence.

---

## STOP POINT — 2026-08-30, mid step 12/13

**The working tree has UNCOMMITTED, UNVERIFIED changes.** Steps 11-13 were in
progress when work stopped. Read this before touching anything.

### Committed and pushed (all green when committed)

Steps 1-10 plus the zlib fix, through `74b396b7`. At that point:
`./spikes/run-cocoa-checks.sh` was 29 passed / 0 failed, GPU regression clean,
and **all six class-based acceptance examples built unmodified** — which was
the arc's definition of done.

### Uncommitted, and NOT verified

box_ref (step 11), the returned-class trio and `std.objc.typed` (steps 12-13),
adopted from their tree. Last known suite state was **29 passed, 3 failed** —
`struct_ret_test`, `typed_test`, `abi_oracle_test`. Do not assume these are
fixed; the last build+test cycle never ran.

### The live issue, and it is the important one

Upstream **hard-codes the send variant** as `'objc_msgSend'`, with the comment
"arm64 has exactly one send". On x86-64 there are three, and the SDK needs them:

    objc_msgSend        418681
    objc_msgSend_stret    3670
    objc_msgSend_fpret       2

Answering the constant fetches a struct return from a register that was never
written. It appears in **two** queries and both must read `m.msgsend`:

  * `kMsgSendVariantSQL`   — FIXED in the tree, compiler rebuilt, verified:
    `NSView.frame -> objc_msgSend_stret` again.
  * `kSelectorVariantSQL`  — FIXED in the tree but **NOT rebuilt or tested**.
    This is the selector-keyed path, which is what `send[...]` and the ABI
    oracle use, and is the likely cause of the three failures above.

### Next steps, in order

1. `./bazelw build //KGEN/tools/mojo:mojo` and rebuild the 16 `.mojoc`
   packages, then `./spikes/run-cocoa-checks.sh`. Expect the three failures to
   clear; if they do not, the selector-keyed path is the place to look.
2. Add the allowlist row for `kSelectorVariantSQL` (the kMsgSendVariantSQL row
   is already there) — these are now **three** allowed divergences: the SysV
   eightbyte classifier and the two send-variant queries.
3. Add a property check to `check-parity.sh`: **no `'objc_msgSend'` string
   literal may survive in CocoaKBDatabase.cpp.** A diff cannot express this,
   the file is whole-file allowlisted, and it has now bitten twice in one
   sitting. This is the highest-value item here.
4. Bump `parity-base.txt` to `d3ce7c8a` only once the suite is green, and
   commit steps 11-13 together.
5. Then re-run the acceptance six, and the cocoa arc is finished.

### Also true, and easy to trip over

**They force-pushed a rewritten history** (see Rule 0). Every SHA in earlier
commit messages is orphaned — resolvable locally because we fetched it, absent
from their `main`. Content was verified identical across the rewrite. The
current base is `d3ce7c8a`.

Remaining upstream work after this arc is **IDE, debugger and installer** —
116 new commits — which is explicitly the next project, not this one.
