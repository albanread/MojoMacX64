# MojoMacX64

**Mojo for Intel Macs with AMD GPUs, via Metal.**

A permanent fork of [modular/modular](https://github.com/modular/modular),
frozen at commit `577b6b839e` (2026-08-21 — Mojo `1.1.0.dev2026082105`).
It exists to bring the Mojo language and its GPU programming stack to
hardware upstream never targeted:

- **Host:** Intel x86-64 macOS (built on/for the Mac Pro 2019)
- **GPU:** AMD Radeon Pro Vega II 32 GB, programmed through Metal's
  low-level IR (AIR) — the same path the upstream compiler uses for
  Apple Silicon GPUs

![Mojo Mandelbrot on the Radeon Pro Vega II](spikes/mandelbrot/mandelbrot.png)

*A native macOS app in Mojo: a live-zooming Mandelbrot at 60fps where both the
escape iteration and the colour are Mojo kernels on the Vega II — no shader
anywhere — presented through an NSWindow whose every AppKit and Metal call is
type-checked against the SDK at compile time. See
[`spikes/mandelbrot/`](spikes/mandelbrot/).*

**Mojo only.** This fork covers the Mojo compiler, standard library,
`DeviceContext` GPU runtime, and the open `max/kernels` library.
The MAX Engine (graph compiler, `libmax`, Python inference stack) is
closed-source, has no Intel-mac build, and is **out of scope**.

## ⚠️ No support — and don't bother Modular

This fork is **unsupported by Modular Inc.** and unaffiliated with them.

- Do **not** file issues, discussions, or support requests with Modular
  or on the upstream repo for anything you build or break here.
- No support is offered here either. Everything is provided **as-is**,
  for one machine, with no compatibility promises.

If you want supported Mojo on supported platforms, use the real thing:
[modular/modular](https://github.com/modular/modular) and
[docs.modular.com](https://docs.modular.com).

## Fixed at this release, forever

This fork never rebases on, merges, or tracks upstream. The fork point
is the whole point: a known-good snapshot of the open-sourced compiler,
tuned for this hardware until the machine stops working. Hardcoding for
x86-64 Darwin and gfx906 is a feature, not a bug.

## Thank you, Mojo developers

This fork exists only because Modular open-sourced the entire Mojo
compiler — parser, elaborator, code generator, JIT, LSP — along with the
standard library, the GPU kernel library, and the AIR bitcode
machinery, all under Apache 2.0 with LLVM Exceptions. That is a rare and
generous act. Thank you to everyone who built Mojo and then gave it
away. 🔥

## Notes for others: AIR on AMD GPUs

Targeting Apple's AIR for an **AMD GPU through Metal** is close to
undocumented territory. [AIR_on_AMD.md](AIR_on_AMD.md) collects what we
learned doing it — the public reverse-engineering record digested and
credited, plus everything we measured on real hardware: why AMD's Metal
plugin crashes on generic pointers (and where the crash log is), the
address-space trap that CUDA-shaped frontends walk into, AIR's real
type-mangled runtime symbols, the LLVM-vintage constructs that break the
bitcode writer, bugs in the vendored downgrade writer itself, and which
tools lie to you. Written to be useful even if you never touch Mojo.

## High-level plan

Full design with file-level detail: [PORT_DESIGN.md](PORT_DESIGN.md).

**Front A — host port (x86-64 macOS).** The compiler builds from source
and LLVM's X86 backend is already enabled; the port is a bounded list of
arm64 assumptions: target-triple hardcodes in the bazel toolchain,
aarch64-only hermetic tool downloads (Python, uv, linters), a gRPC
patch, and severing the arm64-only binary wheel.

**Front B — Vega II via Metal AIR.** The macOS Metal driver compiles
AIR → GCN at pipeline creation, so no GPU instruction selector is
needed. The compiler's AIR hooks and bitcode machinery are open, but the
AIR backend itself is not published — we write a small "AIR trio"
(traits/lowering/backend) into the open target registries, the same
bounded shape our Windows sibling proved with its SPIR-V trio. Then:

1. **MetalRT** — reimplement the closed device-runtime C ABI
   (`AsyncRT_*`) over the open in-tree AsyncRT framework: CPU device
   first to validate semantics, then a Metal device (command queues,
   blit copies, pipeline cache) for the Vega II.
2. **Target entry** — a `MetalVega2` GPU definition: wave64
   (`warp_size=64` vs Apple's 32), 64 CUs, 64 KB LDS, discrete-memory
   semantics (private storage + explicit DMA, no unified-memory
   zero-copy).
3. **Feature gating** — no `simdgroup_matrix`, no bfloat16, Metal 3
   tier; fp16 fast paths stay on.
4. **Kernel triage** — sweep `max/kernels`, fix wave64 assumptions,
   fall back where Apple-only features are used; benchmark against MPS.

**Also intended — Cocoa + Unix, automated.** Make Mojo great at Cocoa:
comptime metadata queries (`cocoakb_query`) evaluated by the compiler
against [CocoaBaseMCP](https://github.com/albanread/CocoaBaseMCP)'s
SQLite mirror of the Objective-C surface — checked struct layouts,
constants, selectors, and per-signature x86-64 `objc_msgSend` variant
selection, with no hand-maintained bindings. Includes a no-leak memory
design: RAII retain/release, autorelease-pool scoping, zeroing weak
references for cycles, and leak-checked golden tests. See
[PORT_DESIGN.md](PORT_DESIGN.md) §10.

**Phases.** 0: de-risk spikes (Metal smoke test on the Vega II, native
build attempt) → 1: native x86-64 toolchain, CPU tests green → 2:
runtime ABI over CPU device → 3: first kernel end-to-end on the Vega II
(Mojo → AIR → metallib → dispatch) → 4: kernel library triage →
5: tune for gfx906 and freeze.

## License

Inherited unchanged from upstream: Apache License v2.0 with LLVM
Exceptions ([LICENSE](LICENSE)); third-party licenses in
[Licenses/](Licenses/).
