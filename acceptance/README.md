# Acceptance corpus — the sister fork's examples, run here

Imported from MojoCocoa at `284c834c` as the acceptance criteria for the parity
plan. Not maintained here; send changes there.

## Plain Mojo — buildable today

Baseline on first import (2026-08-29): **5 of 7**.

| example | status |
|---|---|
| grayscale, hello, operators, process, vector-add | PASS |
| fern | needs the revived `fn` — a **phase 1 dependency**, not a defect |
| tiled-matmul | `metallib`: *"LLVM ERROR: Unexpected bitcode file!"* — see below |

## `_class-pending/` — the phase 1 acceptance set

window, life, mandelbrot, fluid, ferns, fernwind. These are written in the
`class` keyword and cannot build until phase 1 lands. That is their purpose:
when they run here, phase 1 is done.

`fluid` is additionally the launch-overhead stress test — its frame is many
dispatches rather than one, and at our measured 0.235 ms per synchronous
dispatch it will crawl until phase 3a defers the wait.

## The tiled-matmul reproducer

A compact case for the census's largest actionable backend bucket
(`metallib_fail`, 63 tests). Groundwork done, so nobody repeats it:

- **Procedure validated.** A known-good module (`spikes/matmul`) passes
  `xcrun metallib` by hand, so the harness is sound.
- **The 16-byte trailer is NOT the cause**, tested both directions.
  `BitcodeWriter17.cpp:5157` pads the file to a 16-byte multiple *after*
  `BCSize` is computed, so a file can carry up to 12 bytes the header does not
  declare — and the rejected module carries 4 while both known-good ones
  happen to carry 0. It looked conclusive and is not: trimming the pad off the
  rejected module still fails, and adding 4 trailing bytes to a known-good
  module is still **accepted**. The correlation was luck.
- **Size is not the cause.** `matmul_reg_unrolled` is 81,693 bytes of IR —
  nearly double the rejected module's 45,917 — and builds fine.
- **Not metadata kinds or exotic types.** Both modules use the same named
  metadata kinds and neither carries i128/fp128/x86_fp80/bfloat.

So the cause is inside the bitcode stream, and the next step is a bisection of
the module body rather than another look at the container.
