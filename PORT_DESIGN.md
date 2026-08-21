# Vega Fork — Design

**Porting Mojo to Intel x86-64 macOS and driving the Radeon Pro Vega II through Metal AIR**

| | |
|---|---|
| Fork point | `577b6b839e` — 2026-08-21, Mojo `1.1.0.dev2026082105`, MAX `26.6.0.dev2026082105` |
| Fork policy | Permanent hard fork. Never rebases on upstream. Tuned for one machine. |
| Target machine | Mac Pro (2019), Intel x86-64 host, Radeon Pro Vega II 32 GB (Vega 20, gfx906-class) |
| Status | Draft for review — grounded in repo survey of the fork point |

---

## 1. Goal and non-goals

**Goal.** A self-hosted Mojo toolchain running natively on Intel x86-64 macOS, able to compile and launch GPU kernels — including the open `max/kernels` library — on the Radeon Pro Vega II via Metal, using the compiler's existing AIR (Apple IR) emission path.

**Non-goals.**

- **MAX Engine (`libmax`, the graph compiler).** Closed-source, shipped only in the `modular` wheel, no Intel-mac build exists or ever will. The Python `max.graph` inference stack is out of scope. What we deliver is the *Mojo GPU programming stack*: compiler, stdlib `gpu` module, `DeviceContext`, and the open kernels library.
- Upstream contribution, portability, or tracking. Hardcoding for this machine is acceptable and often preferred.
- CUDA/HIP paths, Linux, other GPUs (though a second Vega II / Duo is a natural later extension — the runtime ABI already has peer-access hooks).
- GPU debugging via LLDB. Metal frame capture is the debug story (`max/mojo/max/gpu/host/_metal_capture.mojo` is already in-tree).

**License position.** The open tree is Apache 2.0 with LLVM Exceptions. `Licenses/LICENSE` at our pin is the *MAX Community License* (rev. 2026-08-18); per the sister project's analysis (`dragon/design/LICENSE-ANALYSIS.md` in WINMOJOX64Blackwell, with verbatim quotes), its terms — including the AI-derived-work clauses — attach to *using Modular's SDK binaries or hosted platform*. This fork must therefore **never pull or link the `modular` wheel** (also a build requirement, A9): everything we run is built from the Apache-licensed source plus our own code. Not legal advice; the analysis doc is the reference.

## 2. Ground truth: what the fork point actually contains

Surveyed on 2026-08-21. This is the load-bearing section — everything else follows from it.

| Component | Where | Status | Fork action |
|---|---|---|---|
| Mojo compiler (parser, elaborator, ObjectCompiler, ORC JIT, LSP, LLDB) | `KGEN/`, `tools/mojo` | **Open, builds from source** | Port host triple |
| LLVM | `llvm-raw` source dep; backends `AArch64, RISCV, X86` (`bazel/public-patches/llvm_project.bzl`) | **Open; X86 already enabled** | None (host codegen/JIT already there) |
| Metal device compile path | Hooks + building blocks open: `air64-apple-macosx` triple (`CompilationOptions.cpp:184`), versioned bitcode writers (`ObjectCompiler/LLVM/Bitcode/{17,19,21}`, `LLVMIRDowngradePass`, `PointerRewriter`). **The AIR backend itself (traits/lowering/backend trio) is NOT in-tree** — only the `Host` trio is (`KGEN/lib/Target/Host`, `KGENToLLVM/Target/Host`, `ObjectCompiler/Target/Host`) | Hooks **open**, backend **closed** | **Write the AIR trio** (§5.2) on the open registries |
| Mojo stdlib incl. `gpu` module + Metal stdlib plugin | `mojo/stdlib/std/`, `mojo/stdlib/std/_plugin/metal/` | **Open** | Add Vega II target entry |
| GPU target table + how-to guide | `mojo/stdlib/std/gpu/host/info.mojo` (MetalM1…M5 at :438–537), `mojo/stdlib/docs/adding-gpu-targets.md` | **Open** | Follow the guide for `MetalVega2` |
| MAX kernels library | `max/kernels/` (Mojo source) | **Open** | Triage for wave64 / feature gaps |
| GPU host API (Mojo side) | `max/mojo/max/gpu/host/` (`_metal.mojo`, `_device_context_metal.mojo`, `_metal_capture.mojo`) | **Open** | Audit unified-memory assumptions |
| AsyncRT runtime *framework* (CPU device, work queues, allocators) | `AsyncRT/` (`lib/Runtime/CPUDevice.cpp`, docs in `AsyncRT/docs/AsyncRTRuntime.md`) | **Open** | Foundation for our runtime |
| **Device runtime C ABI implementation** (`AsyncRT_*`, 137 distinct symbols called from Mojo) | `AsyncRTMojoBindings` + `MGPRT` + `AsyncRTRuntimeGlobals` + `MSupportGlobals` from `@modular_wheel` — macOS build unconditionally selects **arm64** (`bazel/modular_wheel_repository.bzl:213-217`) | **Closed, arm64-only** | **Reimplement** (§5.1) |
| KGEN CompilerRT | Source in `KGEN/lib/CompilerRT` **and** prebuilt `KGENCompilerRTShared` in wheel | Open source exists | Build from source, drop wheel |
| MAX Engine | `libmax` in wheel | **Closed** | Out of scope (§1) |

Two facts make the project feasible:

1. **The compiler is fully open and self-contained.** `tools/mojo` and `KGEN` have no `@modular_wheel` build dependency; wheel prebuilts attach only to runtime-linked Mojo targets via `bazel/api.bzl:128`.
2. **The Metal compile path is designed-for, and its heavy machinery is open.** The `air64` triple, the versioned AIR-capable bitcode writers, and the offload flow (`ObjectCompiler::emitOffloadKernels` → per-kernel bytes in `CompiledFunctionInfo.asm` → `AsyncRT_DeviceContext_loadFunction`) are all in-tree. The backend *implementation* that drives them is not — we write a small "AIR trio" (§5.2) into the open per-triple registries, each of which ships a complete `Host` template. Precedent: our sister Windows port wrote exactly such a trio for SPIR-V/Adreno in bounded time (see below). AIR itself is GPU-agnostic — the macOS Metal driver compiles AIR → GCN for the Vega II at pipeline-creation time, so no LLVM AMDGPU backend is involved.

The two hardest items are therefore **reimplementing the closed device-runtime layer** behind the documented `AsyncRT_*` C ABI (§5.1) and **the AIR trio** (§5.2).

**Sister-project intelligence.** [WINMOJOX64Blackwell](https://github.com/albanread/WINMOJOX64Blackwell) (cloned at `/Volumes/S/WINMOJOX64Blackwell`) is the same play on Windows x64 + NVIDIA, one day ahead of us, with journals (`PORT-JOURNAL.md`, `DRAGONMAX-JOURNAL.md`) that already traced the paths we care about: the verbatim `--target-accelerator` flow, the open registries, the offload flow, the runtime-ABI bring-up (33-symbol subset to first kernel), and a compiler-side comptime metadata mechanism (`winkb`) we adopt for Cocoa (§10). Findings from it are cited inline below.

## 3. Architecture

### 3.1 Compile pipeline (per kernel)

```
mojo source ──► KGEN elaboration ─┬─► [host] LLVM X86 ──► x86_64 Mach-O ──► ORC JIT / mojo build
                                  │
                                  └─► [device, air64-apple-macosx]
                                        AIR trio (ours, §5.2)
                                        └─► versioned BitcodeWriter ──► AIR bitcode ──► metallib
                                              └─► Metal driver (OS) ──► GCN ISA on Vega II
```

The AIR → GCN step is Apple's driver, invoked at `MTLComputePipelineState` creation. No LLVM AMDGPU backend is involved, and none is needed.

### 3.2 Runtime stack (the seam we rebuild)

```
Mojo program
  └─ stdlib gpu.host / max.gpu.host DeviceContext          [open, in-tree]
       └─ external_call["AsyncRT_*"] — 137-symbol C ABI    [the seam; signatures
          documented as comments in the .mojo files]        are the contract]
            └─ TODAY: AsyncRTMojoBindings + MGPRT (closed, arm64 wheel)   ← REPLACED
            └─ FORK:  MetalRT (new, ours) over in-tree AsyncRT framework
                 ├─ CPUDevice (in-tree, open)               [bring-up vehicle]
                 └─ MetalDevice (new) ──► Metal.framework ──► Vega II
```

### 3.3 Why AIR is the only route (alternatives dismissed)

- **ROCm/HIP:** does not exist on macOS.
- **Direct GCN ISA via LLVM AMDGPU backend:** Metal has no public interface to load native ISA; only AIR inside metallib containers.
- **OpenCL:** deprecated since macOS 10.14, no path to modern IR, no integration with the existing backend.
- **Vulkan/MoltenVK:** MoltenVK layers Vulkan *on top of* Metal — strictly more moving parts for less integration.

Metal + AIR is both the only viable route and the one the compiler already implements.

## 4. Front A — Host port to x86-64 macOS

Mechanical but real. Every known arm64 assumption, with file:line:

| # | Item | Where | Change |
|---|---|---|---|
| A1 | Mojo target triple hardcode | `bazel/internal/mojo_toolchain.bzl:29` | `arm64-apple-macosx{os}` → `x86_64-apple-macosx{os}` (frozen fork: hardcode is fine) |
| A2 | C++ toolchain target | `bazel/internal/cc-toolchain/args/BUILD.bazel:37` | `--target=arm64-apple-macosx11.0` → `x86_64-apple-macosx11.0` |
| A3 | lit test triple | `bazel/internal/llvm-lit/BUILD.bazel:50` | `arm64-apple-macosx` → `x86_64-apple-macosx` |
| A4 | Hermetic Python toolchains | `bazel/common.MODULE.bazel:175-180` (aarch64-apple-darwin only) | Add `x86_64-apple-darwin` python-build-standalone (upstream ships it) |
| A5 | `uv` download | `bazel/common.MODULE.bazel:492-496` | Add `uv-x86_64-apple-darwin` |
| A6 | Lint tools pinned aarch64 | `bazel/lint/BUILD.bazel:32,48`, `bazel/lint/ruff_wrapper.py:29`, `rumdl_wrapper.py:28` | Add x86_64 variants or stub lint (fork doesn't need linters to build) |
| A7 | Unidentified aarch64-darwin artifact | `bazel/common.MODULE.bazel:313-315` | Identify; add x86_64 hash or build locally |
| A8 | gRPC x86-mac patch | `bazel/public-patches/grpc-no-macos-x86.patch` (referenced at `common.MODULE.bazel:130`) | Inspect; revert/adjust (gRPC upstream supports x86 mac). Only matters for `tools/compilation-server` — can be deferred/stubbed |
| A9 | Wheel severing | `bazel/modular_wheel_repository.bzl:213-217`, `bazel/api.bzl:128` | Point runtime deps at: in-tree-built `KGENCompilerRTShared` + our MetalRT (§5.1); delete `libmax`-dependent targets |
| A10 | pixi platforms | `mojo/pixi.toml:5` | Add `osx-64` (secondary; bazel is the primary flow) |
| A11 | Stdlib/`Support` host-arch audit | `mojo/stdlib/std/sys/info.mojo`, `Support/lib/MArchTarget` | x86-64 paths exist for Linux; audit darwin+x86 combinations (`MarchTest.cpp` already mentions them — good sign) |
| A12 | Crash/bug-report messaging points users at Modular | KGEN crash + OOM paths (sister port: "Stop sending fork users upstream to report bugs") | Rebrand to the fork's own issue destination; Modular must not receive our bug reports |

**Acceptance for Front A:** `./bazelw build //tools/mojo` natively on the Mac Pro; stdlib builds; CPU-only test suite green; `mojo run` (JIT) and `mojo build` produce working x86-64 Mach-O; REPL works. ORC JIT on x86_64-darwin is a mature LLVM path — low risk.

## 5. Front B — Vega II device support

### 5.1 MetalRT: reimplementing the runtime ABI (the big item)

**Contract.** The stdlib calls 137 distinct `AsyncRT_*` symbols; every call site documents the C signature in a comment (e.g. `AsyncRT_DeviceContext_metal_device(MTL::Device **result, const DeviceContext *ctx)` in `_metal.mojo:37`). The contract is fully recoverable from the open code.

**Scope control.** Only the CPU + Metal subset is implemented. CUDA/HIP-specific symbols (`cuda_context`, etc.) get stubs that return errors. Realistic core: device/context lifecycle, buffer create/retain/release/sub-buffer, HtoD/DtoH/DtoD async copies, streams, kernel load + launch, timing/completion, device attributes, host buffers. Estimate ~60–80 real implementations.

**Structure.** New C++ library in-tree (e.g. `AsyncRT/lib/Runtime/Metal` + `AsyncRT/lib/MojoBindings`), built on the open AsyncRT framework (work queues, allocators, `CPUDevice`):

- One thin C-ABI layer over an abstract `Device` interface.
- **CPU first:** wire the C ABI to the in-tree `CPUDevice` and pass the existing `DeviceContext` CPU tests. This validates ABI-layer semantics (async model, ownership, scopes) before any Metal code exists — it isolates R1 (below).
- **Bring-up practices (adopted from the sister port's runtime, which reached a verified first kernel with a 33-symbol subset):**
  - A **headerless C smoke test** drives the built dylib through `dlsym` only — exercising the ABI exactly as Mojo will find it, before any Mojo exists.
  - `loadFunction` **sniffs the blob**: `metallib` container magic → `newLibraryWithData`; otherwise treat as **MSL source** → `newLibraryWithSource`. The source path makes the whole runtime testable on the Vega II *before* the AIR trio exists — a codegen bug and a runtime bug can never be the same investigation.
  - Launch dims are `uint32` because the bindings say so; Mojo speaks a CUDA-shaped grid-of-blocks and Metal wants threadgroups × threads-per-threadgroup — the launch multiplies through.
  - The runtime **retains every buffer referenced by an in-flight command buffer** (release in the completion handler). Mojo destroys values at last use (ASAP), so the sister port had to patch tests with `__ownership_keepalive` — bake the retention into the runtime instead.
- **Then MetalDevice** (metal-cpp or raw objc_msgSend):
  - Device: `MTLCopyAllDevices()` → pick Vega II; `archName` reports `"amd-vega2"` (must match §5.2).
  - Streams: one `MTLCommandQueue` per stream; async model via command buffers + completion handlers.
  - Kernel load: metallib bytes (produced by the compiler's AIR writer) → `newLibraryWithData` → `MTLComputePipelineState` cache.
  - Launch: `dispatchThreadgroups` with dynamic threadgroup memory via `setThreadgroupMemoryLength` (`shared_mem_bytes` already plumbed in `_device_context_metal.mojo:118`).
  - Copies: `MTLBlitCommandEncoder` (§5.3).

### 5.2 Compiler-side: the AIR trio

The three per-triple registries (`TargetTraitsRegistry`, `TargetLoweringRegistry`, `TargetBackendRegistry`) are open and each ships a complete `Host` implementation as a template. We add an `air64` trio:

- **`AirTraits`** — claims `triple.starts_with("air64-")` (helper `isMetalTriple` already exists); modeled on `KGEN/lib/Target/Host/HostTraits` (~40 lines).
- **`AirLowering`** — KGEN→LLVM lowering config for the AIR data layout / address spaces.
- **`AirBackend`** — `emitObject` produces AIR bitcode using the in-tree versioned BitcodeWriters + `LLVMIRDowngradePass` + `PointerRewriter`, then wraps it in a `metallib` container (own writer, or shell out to `xcrun metallib` — precedent: `mojo build` already shells to `xcrun dsymutil`). Raw bytes land in `CompiledFunctionInfo.asm` via the existing offload flow — **no packaging or linker step exists to build** (sister project traced this end-to-end: `emitOffloadKernels` splits per exported kernel and dispatches by triple; the runtime's `loadFunction` receives the bytes verbatim).

Sister-project findings that de-risk this (verified against their tree, same lineage as ours):

- `--target-accelerator` is stored **verbatim** (`Compilation.cpp`) and surfaces in the stdlib via `POC::AcceleratorArch` — validation happens in the *stdlib's* `_all_targets` comptime constraint, not in closed tables. The closed per-vendor tables feed only `--print-supported-accelerators` help text.
- `isMaxInstalled()` (`Support/lib/Configuration.cpp:663`) gates accelerator use but **defaults to true when no config value exists** ("probably in bazel, pretend we have MAX").
- Their SPIR-V trio + stdlib plugin took a bounded effort with the `Host` templates as the shape; first-compile bounce-backs were named and small (calling-convention spelling, buffer idioms, alwayslink pickup).

### 5.3 Target definition

Follow `mojo/stdlib/docs/adding-gpu-targets.md` exactly; model on the M1 entry (`info.mojo:268`):

```mojo
def _get_metal_vega2_target() -> _TargetType:
    return __mlir_attr[
        `#kgen.target<triple = "air64-apple-macosx", `,
        `stdlib_plugin = "metal", `,
        `arch = "amd-vega2", `,
        `features = "+metal3_2,+air2_7_0", `,   # validate in spike S4; lower if needed
        `data_layout = "<same AIR layout string as Apple entries — AIR is arch-neutral>", `,
        `simd_bit_width = 128`,
        `> : !kgen.target`,
    ]
```

Plus a new architecture family and `GPUInfo` entry (fields per `info.mojo:1732`):

- `AMDMetalFamily`: **`warp_size = 64`** (GCN wave64 — the deepest difference from Apple's 32)
- `MetalVega2 = GPUInfo.from_family(...)`: `name="Radeon Pro Vega II"`, `api="metal"`, `arch_name="amd-vega2"`, `sm_count=64` (CUs), `threads_per_multiprocessor=2560` (40 waves × 64), `shared_memory_per_multiprocessor=65536` (64 KB LDS), `max_thread_block_size=1024`
- Use the **non-Metal4** tier (the `MetalM*` vs `MetalM*Metal4` split at `info.mojo:493-537` already encodes API tiers; Metal 4 API is Apple-Silicon-only)
- The full set of edit sites, per the sister port's count ("six sites, not the five the guide documents" — ours is five because the `metal` stdlib plugin already exists): family struct, target function, `GPUInfo` alias, the `_all_targets` canonical list (**this is the actual gate** — see §5.2), `GPUInfo.target()` dispatch + the arch-string mapping in `_get_info_from_target`. Then audit `arch.starts_with("apple")`-style gates in stdlib + `max/mojo`

### 5.4 Memory model: discrete, not unified

Every existing Metal target is Apple Silicon: unified memory, zero-copy, `storageModeShared` everywhere. The Vega II is discrete — 32 GB HBM2 behind PCIe. This inverts the defaults:

| Concern | Apple Silicon (today) | Vega II (fork) |
|---|---|---|
| Device buffers | shared, zero-copy | `storageModePrivate` in HBM2 |
| HtoD/DtoH | often no-op | real DMA via `MTLBlitCommandEncoder`; shared-storage staging buffers for pinned-host semantics |
| `DeviceBuffer.hostPtr` | valid pointer | null for device buffers (forces the copy path — ABI supports it) |
| Bandwidth | one pool | **Measured (S1):** 830 GB/s on-device (copy kernel r+w) vs 12.0 GB/s HtoD blit — overlap copies with compute; keep data resident |
| Max single buffer | large | **3.5 GiB cap — measured (S1)** despite the 32 GiB working set; MetalRT must chunk or reject larger allocations |

Work item: audit `_device_context_metal.mojo` + stdlib for zero-copy fast paths keyed on unified memory, and route them through the copy path.

### 5.5 Codegen feature gating (Mac2 family vs Apple family)

| Feature | Vega II under Metal | Action |
|---|---|---|
| SIMD-group width | **64 — verified (S1)**, by API and empirically (sum/ballot/shuffle agree) | `warp_size=64` in target; audit warp-level algorithms |
| `simd_shuffle` / ballot / reductions | Supported (Mac2 family) | Keep; ballot masks are 64-bit — check mask-type assumptions |
| `simdgroup_matrix` | **Not available — verified (S1)**: compiles, then fails at *pipeline* creation | Gate at compile time (never surface the pipeline error); matmul falls back to tiled SIMD-group kernels |
| bfloat16 | **Surprise (S1): compiles + builds pipelines at MSL 3.1** on both GCN cards; execution/precision unverified, presumably conversion-based | Verify numerics + measure rate before enabling bf16 kernel paths; keep gated until then |
| fp64 | In hardware (1:2 on Vega 20!) but **Metal has no `double`** | Unavailable — same constraint as Apple GPUs, existing backend already handles it |
| fp16 | Native, 2× rate (Rapid Packed Math) | Keep fp16 paths on |
| Metal 4 API | Apple-Silicon-only | Use Metal 3 tier |

### 5.6 Kernel triage (`max/kernels`)

1. Compile-all sweep against the `MetalVega2` target; classify failures.
2. Expected buckets: hardcoded warp-32 assumptions (most kernels parameterize on `warp_size` from `GPUInfo` — verify); `simdgroup_matrix` matmuls (need the fallback path); bf16 kernels (skip); tensor-core-style APIs (N/A).
3. Curated v1 kernel set: elementwise, reductions, softmax, fp32/fp16 tiled matmul, attention (fp16), basic conv.
4. Benchmark bar: **MPS** (`MPSMatrixMultiplication`) on the same GPU for matmul; ≥80% of peak HBM2 bandwidth for bandwidth-bound kernels. MPS is what "good" looks like on this hardware via Metal — set targets against it, not against theoretical TFLOPS.

## 6. Phases and acceptance gates

| Phase | Deliverable | Gate | Size |
|---|---|---|---|
| **0. Spikes** | De-risk findings (§8) | S1–S4 answered | days |
| **1. Host port** | Native x86-64 toolchain (Front A) | `bazelw build //tools/mojo`; CPU tests green; JIT/REPL works | weeks |
| **2. Runtime — CPU** | C ABI layer over in-tree CPUDevice | Existing CPU `DeviceContext` tests pass against our lib | weeks |
| **3. Runtime — Metal + target** | MetalDevice + AIR trio (§5.2) + `MetalVega2` entry | **Vector-add end-to-end**: Mojo → AIR → metallib → dispatch on Vega II → verified result; then wave64 shuffle/reduction tests | weeks |
| **4. Kernels** | Triaged `max/kernels` on Vega II | Curated set green; matmul within 2× of MPS, then tune | weeks–months |
| **5. Tune + freeze** | gfx906 occupancy/LDS tuning, quirk workarounds, docs | Benchmarks recorded; toolchain + macOS version pinned | ongoing |

## 7. Risks

| # | Risk | Likelihood / Impact | Mitigation |
|---|---|---|---|
| R1 | Closed C++ runtime has behavioral contracts (async ordering, ownership, scopes) not fully recoverable from signatures | Med / **High** | CPU-first ABI bring-up against existing tests; headerless `dlsym` smoke test; MSL-source path decouples runtime from codegen (§5.1); the .mojo call sites + doc comments are the spec; sister port's `nvptxrt.cpp` (109 symbols, 2.9k lines) is a working reference implementation |
| R2 | The AIR trio (§5.2) is new compiler work: AIR emitted by our backend may not load on Intel-mac Metal (version, layout, metallib container) | Med / High | Offload flow already traced end-to-end by sister port; in-tree BitcodeWriters were built for AIR levels; spike S4 validates loadability before porting work; MSL-source path keeps Phase 3 unblocked meanwhile |
| R3 | Wave64 latent assumptions in Metal plugin/kernels (only ever run on 32-wide Apple GPUs) | **High** / Med | Targeted shuffle/ballot/scan tests early in Phase 3; `warp_size` is already a first-class `GPUInfo` field |
| R4 | Metal-on-AMD driver quirks, frozen forever (Apple ships no more Intel driver fixes) | Med / Med | Pin macOS after S1 (provisionally Tahoe 26.3.1, where S1 ran clean); keep a quirks layer in MetalRT; the in-box 580X (Polaris, Mac2-tier, wave64) is a second GCN device for generality checks — S1 found no peer group |
| R5 | Build-system long tail (hermetic downloads, remote-exec assumptions) | Med / Low | Frozen fork tolerates non-hermetic local fallbacks; delete what we don't need |
| R6 | 137-symbol ABI scope creep | Low / Med | Stub aggressively; implement on demand, driven by test failures |
| R7 | Perf ceiling without `simdgroup_matrix` | Certain / Low | MPS is the honest bar (§5.6); Vega II's HBM2 favors bandwidth-bound workloads anyway |

## 8. Week-1 spikes (do first, in order)

- **S1 — Metal smoke on Vega II. ✅ Done 2026-08-21** (`spikes/s1-metal-smoke/`, results in `RESULTS.md`): width **64 confirmed** (API + empirical), MSL 3.2 accepted, Metal3 family yes, `simdgroup_matrix` no (fails at pipeline stage), `double` no, **bfloat compiles (surprise — numerics unverified)**, vadd verified, **830 GB/s** VRAM / **12 GB/s** HtoD, **3.5 GiB single-buffer cap**, no peer group. Offline-metallib leg pending full Xcode. Provisional macOS pin: **26 (Tahoe)** — it ran clean there; confirm at S4.
- **S2 — Native LLVM+KGEN build attempt.** `./bazelw build //tools/mojo` on the Mac Pro with A1–A3 patched. Surfaces the real build-system long tail immediately.
- **S3 — Wheel-severed dependency graph.** Map exactly which targets break without `@modular_wheel` (expected: runtime-linked Mojo targets and MAX python only).
- **S4 — AIR compatibility.** Compare AIR emitted by KGEN's bitcode writers (via `xcrun air-objdump`, already referenced in `bazel/internal/llvm-lit/lit.common.cfg.py:92`) against what the pinned macOS accepts for the AMD device; validate `+metal3_2,+air2_7_0` or pick the right level.
- **S5 — CocoaBase on x86-64.** Run CocoaBaseMCP's `build.py` on the Mac Pro: the ingest walks the *live* runtime, so a database built there carries x86-64 struct offsets and encodings by construction. Verify BridgeSupport availability on the pinned macOS, spot-check `NSRect` layout, and scope the SysV-x86-64 ABI derivation (`objc_msgSend` vs `_stret`/`_fpret` classification — the existing derivation covers AAPCS64).

## 9. Machine prep

- Full Xcode (Metal toolchain incl. `metal`, `air-objdump`, `dsymutil` — `mojo build` already shells out to `xcrun dsymutil`, `KGEN/tools/mojo/Build/mojo-build.cpp:617`).
- macOS pin: **provisionally 26.x (Tahoe)** — S1 ran clean on 26.3.1; final confirmation at S4.
- bazelisk; ~100 GB free for LLVM/KGEN build trees (`/Volumes/S` has ~1.1 TB — fine).
- Regenerate `cocoa.sqlite` on this machine after the macOS pin (`python3 /Volumes/S/CocoaBaseMCP/build.py`) so offsets/encodings are x86-64 truth (spike S5).

## 10. Cocoa + Unix integration — comptime metadata, automated

Make Mojo *great* at Cocoa on this machine: Foundation, AppKit, Core*, WebKit, and the POSIX/BSD layer, callable from Mojo with compiler-checked layouts and no hand-maintained bindings. This is now designed around two existing assets:

### 10.1 The database: CocoaBaseMCP

[`CocoaBaseMCP`](https://github.com/albanread/CocoaBaseMCP) (sister repo, local at `/Volumes/S/CocoaBaseMCP`, MIT) already maintains `cocoa.sqlite` (~100 MB, regenerated from the live SDK in ~2 s): a faithful raw ingest of the libobjc runtime (`rt_classes`, `rt_methods` — every selector and type encoding), BridgeSupport (`bs_structs`, `bs_methods`, `bs_enums`, full attrs as JSON), POSIX/BSD libc signatures, plus derived tables (`structs`, `struct_fields` with names, offsets, ABI tier). Philosophy — *ingest the source faithfully once; derive by query; new needs become `SELECT`s, not new generators* — is exactly the lesson of the sister port's `winkb`.

Crucially, the ingest walks the **live runtime**, so a database regenerated on the Mac Pro carries **x86-64 truth by construction** (offsets, encodings). One addition needed: SysV x86-64 ABI classification alongside the existing AAPCS64 derivation, to answer "which dispatch stub" per signature (spike S5).

### 10.2 The compiler hook: `cocoakb_query`

Adopt the sister port's `winkb` mechanism wholesale (their `IREvaluatorContext.cpp` + `Support/Configuration` carry the pattern): one **generic comptime query param-expr** — `#kgen.param.expr<cocoakb_query, "<kind>", "<name>">` — evaluated during elaboration against `cocoa.sqlite`, whose path comes from compiler configuration. Adding a query kind is one row in the query table plus SQL, not a new opcode. Mojo-side wrappers in `std/sys/_cocoakb.mojo`:

- `cocoakb_struct_size/align/field_offset` — **declarations become checkable**: a Mojo struct asserts its layout against the database and fails to build if wrong. (Sister port's origin story: 34 of 35 hand-transcribed constants right; the 35th failed silently for hours. A name the database doesn't know is a compile error, not a wrong answer.)
- `cocoakb_constant` / enums — with the signed-first `COALESCE` reading (survives narrowing in both directions).
- `cocoakb_selector`, `cocoakb_type_encoding`, `cocoakb_msgsend_variant` — selector registration data plus the per-signature x86-64 dispatch choice (`objc_msgSend` / `_stret` / `_fpret`), computed from the ABI tier, never by the user.
- `cocoakb_posix_sig` — the Unix layer, same database, same discipline.

The MCP side (`cocoa-mcp`, `ccq`, the Claude agent card) is the **development-time** face of the same database — agents and humans query the identical source of truth the compiler reads at comptime.

### 10.3 Memory: refcounts, pools, and cycles — designed not to leak

Cocoa is retain/release with autorelease pools; Mojo has ASAP ownership and no GC. The boundary design:

- **`Strong[T]` RAII handle** — retain on acquisition per the Cocoa ownership conventions (`alloc`/`new`/`copy`/`mutableCopy` return +1; everything else autoreleased → retain to own), `release` in the destructor. Mojo's ASAP destruction makes lifetimes *prompt* — but see the keepalive lesson (§5.1): anything handed to an async Cocoa API must be retained by the callee-side wrapper, not borrowed.
- **Autorelease pool scoping** — a `with autoreleasepool():` context (`objc_autoreleasePoolPush/Pop`); required around loops that touch Cocoa, and drained periodically in long-lived contexts (REPL, servers).
- **Cycles are the leak class refcounting cannot catch.** Three defenses:
  1. **`Weak[T]`** over `objc_storeWeak`/`objc_loadWeak` — runtime-managed zeroing weak references for back-edges.
  2. **Weak-by-convention defaults**: delegate/target/observer/parent-style references bind weak by default — and the database knows the patterns (`bs` attrs + naming), so the binding layer applies the convention mechanically instead of trusting each caller to remember.
  3. **Verification, not hope**: golden tests run under `leaks --atExit` and retain-count soak tests (the sister port's `ComPtr` suite — "refcounting as ownership, and the count agrees" — is the template). A binding change that introduces a cycle fails CI, not ships.
- **Borrowed fast paths** — where Mojo's origin tracking proves a reference outlives a call, pass unretained and skip refcount traffic entirely; refcounts only at ownership boundaries.

### 10.4 Sequencing

Off the GPU critical path. Needs the native toolchain (Phase 1) plus the `cocoakb_query` hook (small, mirrors a proven implementation). First slice: Foundation structs/constants + `NSString` round-trip; then msgSend dispatch; then an on-screen `NSWindow`/Metal-view demo (the sister port's `d3dwindow`/`d3djulia` examples are the shape). SDK and database regenerated together with the macOS pin from S1.

---

## Appendix A — Vega II datasheet (for tuning)

Radeon Pro Vega II: Vega 20, gfx906-class, 64 CUs / 4096 lanes, wave64, 32 GB HBM2 @ ~1 TB/s, ~14.1 TFLOPS fp32 / ~28.3 TFLOPS fp16 (RPM), 64 KB LDS per CU, max threadgroup 1024, PCIe 3.0 ×16 (MPX).

**Measured on this machine (S1, 2026-08-21, macOS 26.3.1):** SIMD width 64; Metal3 + Mac2 families; MSL 3.2 accepted; 830 GB/s VRAM copy (r+w); 12.0 GB/s HtoD blit (`maxTransferRate` 15.75 GB/s); 64 KiB threadgroup memory; 1024 threads/TG; working set 32.0 GiB; **single-buffer cap 3.5 GiB**; no `double`; no `simdgroup_matrix` (pipeline-stage failure); bfloat pipelines build (unverified numerics). Second GPU: Radeon Pro 580X (Mac2-tier, wave64) passes all but Metal3. Duo variant pairs two GPUs with Infinity Fabric Link — exposed by Metal as peer transfers; the `AsyncRT_*` ABI already has `canAccess`/`allPeerAccessEnabled` hooks for a later multi-GPU phase.

## Appendix B — Verified repo facts (survey of `577b6b839e`)

- `isMetalTriple` / `air64-` prefix: `KGEN/lib/ToolCommon/CompilationOptions/CompilationOptions.cpp:184-189` ("Metal GPU targets use ARM64 during compilation, then get converted to AIR").
- Backend-owned bitcode ("Metal emits AIR"): `KGEN/include/KGEN/Compiler/Target/TargetBackend.h:219,227`; `ObjectCompiler.cpp:1303`.
- Apple targets: `mojo/stdlib/std/gpu/host/info.mojo:268-343` (`_get_metal_m1..m5_target`, features `+metal3_2,+air2_7_0`); GPUInfo aliases `:438-537`.
- LLVM backends `AArch64, RISCV, X86`: `bazel/public-patches/llvm_project.bzl:5-9`.
- 137 distinct `AsyncRT_*` symbols: `grep -rho 'AsyncRT_[A-Za-z_]*' --include='*.mojo' . | sort -u | wc -l`.
- Wheel prebuilts (`AsyncRTMojoBindings`, `AsyncRTRuntimeGlobals`, `KGENCompilerRTShared`, `MGPRT`, `MSupportGlobals`; macOS→arm64 unconditional): `bazel/modular_wheel_repository.bzl:97-110,213-217`; attach point `bazel/api.bzl:128`.
- In-tree CPU runtime: `AsyncRT/lib/Runtime/CPUDevice.cpp`; design doc `AsyncRT/docs/AsyncRTRuntime.md`.
- arm64 hardcodes: listed with file:line in §4.
- Metal API tiers ("Metal 2/3/4" ↔ hardware/OS): `bazel/common.MODULE.bazel:428-430`.
