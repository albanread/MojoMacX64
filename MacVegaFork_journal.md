# MacVegaFork — port journal

Mojo on an Intel Mac Pro, driving a Radeon Pro Vega II through Metal AIR.
Running record of what was done, what was learned, and what it cost. Newest
entries at the bottom. The design lives in [PORT_DESIGN.md](PORT_DESIGN.md);
this file is what actually happened.

Machine: Mac Pro (2019), 24-core Xeon, 192 GB, macOS 26.3.1 (Tahoe).
GPUs: Radeon Pro Vega II 32 GB (slot 1, the target), Radeon Pro 580X 8 GB
(slot 3, the control group). Fork: `modular/modular @ 577b6b839e`, frozen
forever, fresh git history, never rebases.

Sister projects, one day ahead of us and heavily plundered:
[WINMOJOX64Blackwell](https://github.com/albanread/WINMOJOX64Blackwell)
(Windows x64 + NVIDIA, journals `PORT-JOURNAL.md` / `DRAGONMAX-JOURNAL.md`)
and [CocoaBaseMCP](https://github.com/albanread/CocoaBaseMCP) (SQLite mirror
of the Objective-C surface). Both cloned as siblings under `/Volumes/S/`.

---

## 2026-08-21 — Recon: what the fork point actually contains

Cloned upstream (1.1 GB, 720k objects), surveyed, then cut fresh history
(`eb55c88`, 20:33; `.git` shrank 830 MB → 96 MB).

**The two facts everything else follows from:**

1. **The compiler is fully open and self-contained.** `KGEN/` carries the
   parser, elaborator, ObjectCompiler, ORC JIT, LSP, LLDB; `tools/mojo` the
   driver. LLVM builds from source, and its backend list
   (`bazel/public-patches/llvm_project.bzl`) already includes **X86**.
   `tools/mojo` and `KGEN` have **no dependency on the binary wheel** —
   prebuilts attach only to runtime-linked targets via `bazel/api.bzl:128`.

2. **The device runtime is not open.** The Mojo stdlib calls a 137-symbol C
   ABI (`AsyncRT_*`, every signature documented in comments at the call
   sites) implemented by wheel-only libraries — `AsyncRTMojoBindings`,
   `MGPRT` and friends — and on macOS the build selects the **arm64** wheel
   unconditionally (`bazel/modular_wheel_repository.bzl:213-217`). No
   x86-64-darwin wheel exists or ever will.

Also found on day one: an in-tree how-to (`mojo/stdlib/docs/adding-gpu-targets.md`),
Apple Metal targets M1–M5 in `mojo/stdlib/std/gpu/host/info.mojo` (triple
`air64-apple-macosx`, features `+metal3_2,+air2_7_0`), Metal frame capture
support, and `isMetalTriple()` hooks throughout the compiler.

**Wrong belief, held for several hours:** "the Metal backend already exists
in-tree." See the next entry.

## 2026-08-21 — Sister-port review: four corrections and a blueprint

Reviewed WINMOJOX64Blackwell's 21 commits and both journals. It is the same
play (frozen fork of the same monorepo, unsupported platform, closed runtime
reimplemented) one platform over, and it changed our design in four places:

1. **The AIR backend is not in open source.** Their DragonMax journal traced
   the per-triple registries; re-checking *our* tree confirmed only the
   `Host` trio exists (`KGEN/lib/Target/Host`, `KGENToLLVM/Target/Host`,
   `ObjectCompiler/Target/Host`). The AIR *building blocks* are in-tree —
   versioned bitcode writers (LLVM 17/19/21), `LLVMIRDowngradePass`,
   `PointerRewriter` — but the backend that drives them is closed. So we
   write an **AIR trio** (traits/lowering/backend), the same bounded shape
   as their SPIR-V trio. Their traced offload flow
   (`emitOffloadKernels` → per-kernel bytes in `CompiledFunctionInfo.asm` →
   `AsyncRT_DeviceContext_loadFunction`) means **no packaging step exists to
   build** — the kernel blob goes straight from backend to runtime.

2. **The accelerator gate is open.** `--target-accelerator` is stored
   verbatim and validated in the *stdlib's* `_all_targets` comptime list.
   The closed vendor tables feed only `--print-supported-accelerators` help
   text. And `isMaxInstalled()` defaults to **true** when no config exists
   ("probably in bazel, pretend we have MAX").

3. **Runtime bring-up practices, proven twice** (their `dragonrt` over
   OpenCL, `nvptxrt` over the CUDA driver — 109 symbols, 2.9k lines, and a
   **33-symbol subset reached a verified first kernel**): a headerless C
   smoke test through `dlsym` only; `loadFunction` sniffing the blob so an
   **MSL-source path** exists before the AIR trio does (a codegen bug and a
   runtime bug can never be the same investigation); `uint32` launch dims;
   and the runtime retaining buffers referenced by in-flight work — their
   `__ownership_keepalive` test patch is the scar Mojo's ASAP destruction
   leaves when the runtime borrows instead of retains.

4. **Cocoa gets the `winkb` architecture, not a bindings generator.** Their
   origin story: 35 hand-transcribed constants, 34 right, the 35th
   (`STARTF_USESTDHANDLES` = 1, actually 0x100) failed *silently* for hours.
   The fix was a generic comptime query param-expr in the elaborator over a
   SQLite metadata DB — "a binding states a name and the compiler supplies
   the rest"; an unknown name is a compile error, not a wrong answer. Our
   §10 now adopts this as `cocoakb_query`, backed by **CocoaBaseMCP's**
   `cocoa.sqlite` (libobjc runtime walk + BridgeSupport + POSIX signatures;
   regenerated on this machine it carries **x86-64 truth by construction**).
   One gap: its ABI-tier derivation covers AAPCS64; we add SysV x86-64 for
   `objc_msgSend` / `_stret` / `_fpret` selection. Memory design (Strong/
   Weak RAII, autoreleasepool scoping, weak-by-convention delegates,
   `leaks --atExit` golden tests) is §10.3.

Also adopted: their "Stop sending fork users upstream to report bugs" commit
(our A12), their capability-diagnostics pattern (assert the architecture at
the intrinsic; never let LLVM's "Cannot select" invite a bug report), and
their license read — the MAX Community License attaches to *using Modular's
SDK binaries or hosted platform*, so the fork's standing rule is **never
pull or link the wheel**.

## 2026-08-21 — S1: the hardware says yes (`f831f58`, 20:59)

~300 lines of Objective-C (`spikes/s1-metal-smoke/`), run on both GPUs.
Everything the design predicted, plus three surprises:

| Predicted | Measured |
|---|---|
| wave64 | **64** — API `threadExecutionWidth` *and* empirical (`threads_per_simdgroup`, `simd_sum(1)`, 64-bit ballot popcount, `simd_shuffle_xor` all agree, both GPUs) |
| discrete memory | `hasUnifiedMemory=NO`, managed storage works |
| no `simdgroup_matrix` | correct — but it **compiles and fails at pipeline creation** with an opaque "SC compilation failure"; gate at compile time |
| no `double` | correct — rejected at source compile |
| MSL / features | runtime accepts **3.2** (validates `+metal3_2`); Vega II reports **Metal3 family** |
| ~1 TB/s HBM2 | **830 GB/s** from a naive copy kernel (81% of peak — the ≥80% bandwidth target is real, day one) |
| PCIe transfers | **12.0 GB/s** HtoD blit |

Surprises: **bfloat compiles and builds pipelines** on both GCN cards
(numerics unverified, stays gated — but cheaper than feared); a **3.5 GiB
single-buffer cap** despite the 32 GiB working set (MetalRT must chunk); and
no peer group — but the box has a second GCN GPU (the 580X, Mac2-tier,
wave64) which passes everything except Metal3 family: a free control device.

After Xcode 15.2 arrived, the offline leg passed too: a metallib built by
Xcode's `metal` loads via `newLibraryWithURL` and builds pipelines on both
GPUs. `air-objdump` on it gives the AIR trio its reference target:
container `MetalLib`, arch `air64`, embedded triple
**`air64-apple-macosx14.2.0`**, and the `air.*` metadata schema
(`air.buffer`, `air.thread_position_in_grid`, `air.arg_type_name`,
`air.max_device_buffers`, `air.compile.*`). macOS pin: provisionally Tahoe
26 — S1 ran clean on it.

## 2026-08-21 — S2: seven blockers between us and a compiler

The build attempt, in the order the wall was hit. Each fix is one commit
theme in `7361a23` (analysis passes, 21:15) and `e8d488b` (build completes,
22:28).

1. **`bazelw` itself is arm64-hardcoded** (`platform=darwin-arm64`). Patched
   to arch-detect; buildbuddy's bazel 5.0.382 ships darwin-x86_64 and just
   works.
2. **A mode gate**: `--config=prebuilt-mojo` or `--config=build-mojo`.
   Prebuilt can never exist here; `build-mojo` is now the fork default.
3. **`tools/bazel` requires full Xcode** (rejects CommandLineTools, uses
   `xcodebuild` metadata). Legitimate machine prep, not patched around.
   Xcode 15.2 installed and selected.
4. **`@clang-macos` is arm64-only** — a single Mach-O, no fat binary, and
   there is no reverse Rosetta. Worse: official LLVM 22.1.4 releases ship
   **macOS-ARM64 only**; the ecosystem has dropped Intel-mac binaries. So we
   built our own: LLVM 22.1.4 clang+lld+compiler-rt, X86 target only,
   ~35 minutes on 24 cores (recipe in `spikes/toolchain-build-run.sh`),
   packaged in the layout `clang.BUILD` expects and pinned by sha256 via a
   `file://` URL. 476 MB, ours forever.
5. **SDK version skew, disguised as a protobuf bug.** `port.cc:120: variable
   does not have a constant initializer` — constinit `std::string` at C++20
   fails against Xcode 15.2's SDK 14.2 libc++ under clang 22, compiles clean
   against the CommandLineTools SDK 26. Repro'd both ways in isolation
   before touching the build. `macos_sysroot_repository.bzl` now pins the
   CLT `MacOSX26.sdk` (falls back to xcrun).
6. **Two more arm64 prebuilts, found at link time**: `@llvm-ifs`'s mac
   `llvm-readtapi.stripped` ("Bad CPU type in executable" — plus a hardcoded
   `-arch arm64` in `linker-driver.sh`), and `@gperftools-macos`'s
   `libtcmalloc_minimal.a` (ld64.lld warned, then 38 undefined `tc_*`
   symbols). Both replaced with local x86-64 builds, same `file://` + sha
   pattern as the toolchain.
7. Result: **~9,000 actions, exit 0.** `bazel-bin/KGEN/tools/mojo/mojo` is a
   165 MB x86-64 Mach-O reporting `Mojo 1.1.0.dev0`.

**The subtle one, worth its own paragraph.** With the compiler built, the
stdlib wouldn't: `No matching toolchains found for @@rules_mojo+//:toolchain_type`
— despite the source-built mojo toolchain being registered first and
carrying no platform constraints at all. The catch: it is gated on
`target_settings = ["//:use_prebuilt_mojo_toolchain_disabled"]`, and
**exec-configuration transitions reset build settings to their defaults**.
The flag's default was `True`, so in every `[for tool]` configuration the
gate failed and the toolchain vanished — invisibly, because the normal
target configuration (where `--config=build-mojo` applies) resolved fine.
The fix is one word: `build_setting_default = False`, which on this platform
is also simply the truth. File under: *config_setting-gated toolchains and
exec transitions do not mix unless the default is the mode you mean.*

## 2026-08-21/22 — Phase 1 core: hello, Mojo (`a2a7041`, 22:35)

The stdlib (3,681 Mojo files) compiled to `std.mojoc` by our own compiler on
the first try — zero Mojo-language-level failures in the port so far; every
single blocker has been build-system or binary-artifact plumbing.

Driver wiring, learned from `KGEN/lib/Support/Configuration.cpp`: config
keys map to `MODULAR_MOJO_MAX_*` environment variables (`.compilerrt_path` ↔
`MODULAR_MOJO_MAX_COMPILERRT_PATH`, `.import_path` ↔
`MODULAR_MOJO_MAX_IMPORT_PATH`, defaults resolved against a package root as
`lib/libKGENCompilerRTShared.dylib` etc.). `vega-sdk/bin/mojo` wraps the
bazel artifacts with exactly those variables. Verified:

```
$ vega-sdk/bin/mojo run hello.mojo      # ORC JIT, x86-64: works
$ vega-sdk/bin/mojo build hello.mojo    # native Mach-O: runs
```

Formerly-wheel-only libraries — `MSupportGlobals`, `AsyncRTRuntimeGlobals`,
`KGENCompilerRTShared` — all built and linked **from in-tree source**. The
closed-wheel problem is now confined to exactly where the design said it
lived: the GPU device runtime (`AsyncRTMojoBindings`/`MGPRT`), which is
Phase 2's job to replace.

Still open in Phase 1: the CPU test suite needs the real A4 fix (pycross has
no `x86_64-apple-darwin` environments — python-interop tests only), a REPL
check, and two cosmetics (crashpad-handler warning → A12 rebrand; an ld
warning from linking SDK-26 objects at min-os 14.2).

### Traps collected so far, for whoever reads this next

- **"macos" without an arch suffix means arm64.** Every Modular macOS
  artifact (`clang-macos`, `llvm-ifs` `tools/mac`, `gperftools-macos`,
  `uv_darwin_aarch64`) is single-arch, and the failure surfaces at *use*
  time ("Bad CPU type", undefined symbols), never at fetch time.
- **Exec transitions reset build settings to defaults.** Gated toolchains
  disappear only in `[for tool]` configurations. Make the default the truth.
- **New clang + old SDK libc++ is a real compatibility axis.** It presents
  as a third-party code bug (protobuf's constinit string), not as a
  toolchain error. Repro in isolation before patching the dependency.
- **Wrap builds you background in an exit-code sentinel.** `cmd | tail`
  reports tail's exit status; every long build here writes
  `SOMETHING-EXIT:$?` and the watcher greps for it.
- **zsh eats backticks in double-quoted `git commit -m` strings.** One
  commit message lost half a sentence to command substitution before this
  was noticed. Single-quote commit messages.
- The pipeline of fixes ran: patch → relaunch → next wall, seven times, with
  ~2–6 minutes per round thanks to bazel's action cache. Background the
  build, watch for the sentinel, and fix while it's still warm.

### Where this leaves the plan

Phase 0 spikes: S1 done (hardware verified beyond the design's hopes), S4's
reference artifact captured, S2 done a phase early. Phase 1: core met in one
evening against a "weeks" estimate — the sister port's journals deserve a
share of the credit for pre-clearing the traps. Next: **Phase 2**, the
MetalRT C ABI over the in-tree `CPUDevice` (existing DeviceContext tests as
the spec), then `MetalDevice`, then the AIR trio against the captured
reference.

## 2026-08-22 — Phase 2a: VegaRT passes upstream's own tests

The closed `AsyncRTMojoBindings`/`MGPRT` layer is now replaced by
`AsyncRT/lib/MojoBindings/VegaRT.cpp` (~900 lines): real implementations of
the context/buffer/copy/stream/event/timer surface with synchronous
semantics under the async names, plus a linkable, self-naming error stub for
every other census symbol. `bazel/api.bzl` maps the virtual
`//MLRT:Driver/DeviceContext` dep to it; the wheel is out of the graph.

Verdict: **5/5 of upstream's `asyncrt` CPU-lane tests pass** (smoke, memset,
timing, host_mapped, device_pointer). `test_copies.cpu` is excluded by
*upstream* on macOS — a pre-existing note in their BUILD file, not ours.

What the recon established before writing code:

- The true census is **120 symbols** (a first grep said 137 — it was
  matching the substring inside `KGEN_CompilerRT_AsyncRT_*`, a *different*
  family provided by the open CompilerRT we already build; the task-chain
  and spin-waiter "gaps" evaporated on word-boundary matching).
- Conventions, recovered from the Mojo side and now load-bearing: fallible
  calls return `const char*` (null = success) and **every returned string,
  errors included, is heap-owned and freed via `strfree`**; handles are
  opaque and refcounted; **getters hand back +1 references** (the wrappers
  release in destructors); `deviceApi`/`archName` write StringRef-shaped
  {ptr,len} out-params that must point at context-lifetime storage.

Then one more arm64 assumption — `mojo_copts_toolchain` passes
`--target-cpu=apple-m1` on all of macOS; ours is now `cascadelake` (Xeon
W-3235, and the fork finally *tunes* for the machine) — and three semantic
bugs the tests caught in an afternoon, which is the CPU-first strategy
doing exactly what it was designed to do:

1. `test_smoke` requires a lowercase `"cpu"` substring in the device name
   (and, noted for phase 2b: `"Apple"` for api=metal — our Vega device name
   will need care or a test patch).
2. `get_attribute` is CUDA-numbered; CLOCK_RATE(13) and WARP_SIZE(10)
   needed real answers.
3. **Zero-length buffers must still return a non-null device pointer** —
   the Mojo wrapper unwraps it unconditionally
   (`device_context.mojo:1517`). `malloc(bytes ? bytes : 1)`.

Next: phase 2b — `MetalDevice` behind the same ABI, `MTLCommandQueue`
streams, blit copies, and the MSL-source `loadFunction` path so the runtime
runs kernels on the Vega II before the AIR trio exists.

## 2026-08-22 — Phase 2b: the runtime runs kernels on the Vega II

`VegaRTMetal.cpp` (~600 lines) — the Metal backend, written in plain C++
over raw `objc_msgSend` casts (the metal-cpp technique) so no Objective-C++
toolchain support had to exist. The hermetic sysroot already ships
Metal/CoreFoundation/Foundation — upstream included them deliberately.

The acceptance gate, a headerless C smoke driving the ABI exactly as Mojo's
`external_call` will find it:

```
metal devices: 2
device: AMD Radeon Pro Vega II (Apple Metal)
memory: 32.0 GiB total, maxAlloc 3.5 GiB, warp 64
buffers: x@0x400400000 y@0x400800000 (private, HBM2)
pipeline: built from MSL source
saxpy: 0/1048576 wrong
memset: verified zero
VEGART METAL SMOKE: ALL PASS
```

Decisions that made it work:

- **Device pointers are `MTLBuffer.gpuAddress` values**, and a global
  interval map resolves any address back to (buffer, offset). Kernel
  launches use it to bind pointer args with `setBuffer` — which also makes
  the resource resident — without trusting any struct layout we don't own
  (specifically the Mojo `Optional` inside `MetalEnqueueFunctionArgs`, whose
  buffers list we therefore never need to read).
- **The Metal launch protocol** (decoded from `_device_context_metal.mojo`):
  on Metal, `enqueueFunctionDirect`'s `args` carries one pointer to a
  `MetalEnqueueFunctionArgs{addrs, sizes, is_device_ptr, …}` — distinguished
  at runtime by `argSizes == null`. Scalars bind with `setBytes`, pointers
  with resolved `setBuffer`; argument index is the buffer slot.
- **Discrete semantics as designed** (§5.4): device buffers
  `storageModePrivate` in HBM2, host buffers `storageModeShared`, every
  HtoD/DtoH a staging blit, `fillBuffer` for uniform-byte memsets and a
  pattern-staging fallback otherwise. Still synchronous under the async
  names — the same completion model the CPU lane validated.
- `loadFunction` sniffs the blob: `MTLB` magic → `newLibraryWithData`,
  else MSL source → `newLibraryWithSource`. The runtime is fully testable
  before the AIR trio exists, exactly as the sister port prescribed.
- Device ordering ranks Metal3-family then working-set size: the Vega II is
  device 0, the 580X device 1, deterministically.

Two -Werror lessons from the repo's warning set: no global constructors
(function-local statics via leaked `new`), and no const-dropping casts even
through `id`. And one self-inflicted: adding a "late additions" stub block
without deleting the stub the real implementation replaces.

CPU lane regression: still 5/5. Runtime status: buffers/copies/kernels
proven on both backends; still stubbed with legible errors — graphs,
multicast, streams-as-parallelism, occupancy, function attributes.

Next (phase 3): the target entry (`MetalVega2`, `_all_targets`, warp 64) so
`--target-accelerator` accepts this GPU, then the AIR trio against the S1
reference metallib — at which point ordinary Mojo GPU code compiles and
launches through everything built today.

## 2026-08-22 — Phase 3: MOJO-ON-VEGA: PASS

```
device: AMD Radeon Pro Vega II (Apple Metal)
vecadd: 0 / 1024 wrong
MOJO-ON-VEGA: PASS
```

Ordinary Mojo GPU code — `DeviceContext`, `enqueue_function`, `global_idx`,
unchanged from what anyone writes for NVIDIA — compiled through the fork's
own AIR trio and executed on the Vega II. The chain, every link from source:

Mojo → KGEN elaboration → LowerPOP (`llvm.air.*` → extern-call branch) →
**AirBackend legalization** (builtin calls → trailing kernel params with AIR
metadata; kernel pointer params AS0→AS1 with use-graph retyping; `air.kernel`
metadata with location_index == parameter order, exactly what VegaRT binds;
host target-attrs scrubbed) → **PointerRewriter** → **BitcodeWriter17** →
`xcrun metallib` → embedded per-kernel in the x86-64 host binary → VegaRT
`loadFunction` (MTLB sniff) → `MetalEnqueueFunctionArgs` protocol →
interval-map buffer binding → `dispatchThreadgroups` → GCN.

What the day's debugging established, for the record:

- **The stdlib target entry took six edit sites** and one naming trap:
  `_vendor_from_arch` substring-matches `"amd"` *before* `"metal"`, so the
  design's `amd-vega2` would have misrouted device codegen down HIP paths.
  The arch token is **`metal-vega2`**.
- `--target-accelerator` flows exactly as the sister port documented; the
  TargetMachine for air64 is built for arm64 (the upstream comment's
  convention) — but only via `adjustOptionsForTargetMachine`, never
  globally: adjusting the global options wipes GPU address spaces at
  MLIR-lowering time. And AIR kernels need AS1 pointer params, which Mojo's
  generic-AS0 elaboration never provides — that rewrite is half of what the
  closed MetalAIRPass must have done.
- **`llvm-dis` lies about old bitcode.** The golden .air *looked* like
  opaque-pointer IR; its bitstream actually carries typed POINTER records,
  and the driver's "Failed to upgrade function bitcode" is what rejecting
  opaque record code 25 looks like. `llvm-bcanalyzer` tells the truth.
- **`metal -x ir` / `air-as` are not the AIR writer** — they emit modern
  opaque bitcode the runtime rejects. The in-tree
  **PointerRewriter + BitcodeWriter17 are a cooperating pair** (the file
  comments even say so); together they emit the typed-record encoding.
  `WriteBitcode17ToFile` writes the bitcode-wrapper header itself — the
  double-wrap this caused contaminated an entire bisection round and briefly
  convicted the innocent writer.
- The Metal toolchain hides a full AIR binutils (`air-as`, `air-opt`,
  `air-objdump`, and **`amdgpu-nt`** — the AIR→GCN translator as a
  standalone tool). `amdgpu-nt` turns the driver's opaque pipeline errors
  into real diagnostics; it also revealed the runtime accepts AIR 2.6 on
  this GPU while the standalone tool's fallback plugin caps at 2.5.
- The comptime kernel cache will happily serve a stale kernel while you
  debug the backend: `MODULAR_CACHE_DIR` per iteration.
- One more VegaRT correction en route: **host (shared-storage) buffers hand
  Mojo their `contents` pointer** (host-dereferenceable), not their
  gpuAddress token; the registry keys each buffer by whichever address it
  exposed.

The design's highest-risk item — R2, the AIR trio — is retired. What remains
in phase 3/4: warp-level tests on wave64, `--emit=asm` cosmetics for the
device lane, the gpu-lane test-suite wiring, and then the kernel-library
triage.

### Addendum, same day — the writers' own testimony (review credit: Alban)

A closer read of the vendored writers — prompted by review, and verified —
corrects and enriches the record above:

- `BitcodeWriter17.cpp:15` says it plainly: *"for writing Metal bitcode."*
  It IS the AIR writer, by its own declaration; no bitstream forensics were
  ever needed, and the bisection that briefly convicted it was contaminated
  by the double-wrap. It is also, like PointerRewriter, taken from Julia's
  LLVM downgrader — one lineage for the whole emission apparatus.
- `BitcodeWriter17.cpp:~1765`: **Apple's AIR reader is LLVM-18-based**, and
  the LLVM-17-fork writer carries targeted fixups for it (metal-allowed
  FPMathOperator checks). The version skew is deliberate. Sibling
  `Bitcode/19|21` directories are the same treatment for other consumers,
  selected by `TargetTraits::forcedBitcodeVersion()`.
- `BitcodeWriter17.cpp:3611`: the writer knows PointerRewriter's `emask`
  callee typing and matches explicit call types to it — the cooperation is
  literal, not inferred.
- `BitcodeWriter17.cpp:2820`: `VE.getMetalKernelArgType` applies
  **i64→i32 kernel-argument conversions** inside the writer. Phase-4
  watchpoint: our legalizer's argument typing interacts with this
  machinery (and it rhymes with the sister port's i64-vs-i32 launch-path
  legalization note).
- `LLVMIRDowngradePass.cpp:184`: the downgrade pass is internally
  **`MetalAIRPass`** (pipeline name `kgen-metal-air`) — upstream published
  the pass *skeleton* (lifetime-intrinsic downgrading today) and kept its
  body closed. Our `AirBackend::legalizeModule` is that missing body; it
  arguably belongs inside this pass eventually. The pass was also innocent
  of the address-space stripping it was blamed for mid-debug (the AS0 came
  from Mojo's generic-pointer elaboration all along) and is now back in the
  emission pipeline where upstream intended it. vecadd still passes.

## 2026-08-22 — Phase 4 opens: wave64 passes, and a review names the disease

`WAVE64-PRIMITIVES: PASS` — `shuffle_xor` round-trips and `warp.sum(1)`
returns 64 on the Vega II. Getting there surfaced, in order: warp ops
reaching AIR as calls to undefined labels (the stdlib emits bare stems like
`air.simd_shuffle_xor`; AIR's real functions are type-mangled —
`air.simd_shuffle_xor.u.i32(i32, i16)`, mask is **i16**, harvested from a
golden MSL probe; the backend now carries `mangleAirOps`), then
`warp.sum` returning **32**: `_resolve_warp_size()` hardcodes
`is_apple_gpu() → 32` ahead of its own GPUInfo fallback. One-line re-gate.

Then a review (Alban) reframed the whole pass, with numbers that verify
exactly: **92 `is_amd_gpu()` sites, zero `WARP_SIZE ==` comparisons**
across stdlib + kernels. The tree encodes lane count as vendor identity;
this fork's GPU is the first target where vendor (Apple path) and lane
count (64) disagree, and the codebase had no vocabulary for it. The wave64
logic largely already exists (`_reduce` handles `num_lanes >= 64`, CDNA
permlane paths) — gated behind the wrong predicate. Triage is therefore
substantially **re-gating, not authoring**:

- `std.gpu.globals` now carries the missing vocabulary: `is_wave64()` /
  `is_wave32()`.
- `triage/warp-gating-sites.md` pre-classifies all 92 sites (heuristics:
  24 ISA-dispatch, 14 wave-width, 55 for human eyes — review offered to
  sort the remainder).
- Map #3 (the `AppleMetalFamily(warp_size=32)` constant) was already
  covered by `AMDMetalFamily`; the `_FULL_MASK = UInt(2**WARP_SIZE - 1)`
  tripwire did not fire at WARP_SIZE=64 (module scope evaluated in the
  warp smoke). Both now verified rather than assumed.
- Also adopted: land the AIR legalization inside `LLVMIRDowngradePass`
  (`kgen-metal-air`) eventually — the documented pipeline home.

The basics sweep (55 tests) is running; first finds include an expected
NVIDIA-only reject and a genuine compiler abort on `test_grid_dim`.

## 2026-08-22 — Phase 4 day one: 8-agent triage, and a .gitignore that ate the compiler

The basics sweep went from **13 → 22 passing** on the Vega II. An 8-agent
triage workflow root-caused the failure clusters in parallel; findings were
applied centrally and verified on hardware. What it produced, in order of
consequence:

**The AIR trio was never committed.** Upstream's `.gitignore` carries a bare
`target/` rule (Rust build dir). On this case-insensitive filesystem it
matched every `KGEN/.../Target/` *source* directory, so `git add -A`
silently skipped `AirTraits`, `AirLowering`, `AirBackend` — and upstream's
own `HostBackend`/`TargetBackend`/`HostLowering`, carried in the working
tree since the import. Every Phase-3 commit that claimed to add the trio
recorded only its tracked collaborators. Found because `git stash push`
refused a file git had never heard of, mid-bisect. Rule anchored to
`/target/`; 21 files recovered (`b8380ce`). **Check `git ls-files` after
adding a directory whose name collides with a build convention.**

**A compile-time data race in our own lowering.** Two agents independently
converged on it: the `llvm.air.*` branch inserted module-level declarations
from inside `LowerPOPToLLVM` — a pass MLIR runs *concurrently across
functions* — racing the symbol table whenever two kernels shared a builtin.
Fixed via upstream's own extension hooks (`isLoweredInGlobalPOPPass` +
`populateLowerGlobalPOPToLLVMPatterns`), which also required expanding
KGEN's struct-packed operands and mangling AIR type suffixes at
*declaration* time (one `air.simd_shuffle` symbol shared across `i32` and
`f16` payloads trips LLVM's signature assert).

**A launch-protocol ambiguity of our own making.** `DeviceExternalFunction`
passed `argSizes=null` with plain args — exactly VegaRT's discriminator for
the `MetalEnqueueFunctionArgs` wrapper, so it read a `DeviceBuffer` struct
as a wrapper and faulted. External launches now pass real per-arg sizes;
the plain path classifies device pointers through the allocation registry;
the wrapper branch validates instead of crashing. `test_launch_binary`
passes — fork-produced metallibs load and launch as external binaries,
which upstream's own Metal backend cannot do (`_APPLE_GPU_INCOMPATIBLE`).

**Address-space numbering is NVIDIA's.** `AddressSpace.CONSTANT=4,
LOCAL=5` are NVPTX's enum, hardcoded in vendor-neutral stdlib code; AIR
wants constant=2, private=0. `GLOBAL=1`/`SHARED=3` coincide by luck, which
is why device buffers and barriers worked from day one. The legalizer now
remaps and propagates. Static constant memory verified on hardware.

**A latent bug in vendored upstream code.** `ValueEnumerator{17,19,21}`
were copied from an LLVM that kept `SwitchInst` case values as operands;
they are now stored out-of-line, so the operand walk missed them while the
writer still emitted them — `"Value not in slotcalculator!"` for any kernel
SimplifyCFG turned into a `switch`. Present in all three vendored copies.

**More LLVM-vintage landmines**, all in the published `MetalAIRPass`:
`freeze` (LLVM 10) and unary `fneg` (LLVM 8) hard-crash BitcodeWriter17 —
its own message says *"for LLVM 5.0"*; GEP no-wrap flags (LLVM 19) survive
into AIR and break the GCN compiler; seven attribute kinds whose bitcode
codes postdate Apple's reader now route to the unsupported encoding.

### Two of my own fixes were wrong, and the tests caught both

- A wrapper-header "size self-heal" declared trailing alignment padding as
  payload; Apple's reader parsed padding as records and every kernel with
  padding broke. The delta-8 observation that motivated it was a red
  herring — the writer's size field legitimately excludes padding.
- Mapping LLVM min/max/abs/float intrinsics to `air.*` runtime names
  (harvested from golden `metal -c` probes, correct names, correct
  attributes) **regressed `test_shuffle`**. The driver handles `llvm.*`
  intrinsics natively; the remapping was unnecessary and harmful. Reverted.
  *Do not retry this.*

### Still open

`test_fast_div`, `test_random`: compile clean, driver reports "Compilation
failed due to an interrupted compilation" at pipeline creation. Disproved:
LLVM-intrinsic availability, i128 (comptime-folded host-side), GEP flags.
`test_static_layout_capture_argcount`: wrong values (-1.0 vs 1.0).
Also noted: **`amdgpu-nt` is no longer usable as a diagnostic** — `air-as`
stamps its own AIR version, so the standalone tool always sees 2.6 against
its 2.5 plugin.

### Skip list, with upstream's blessing

Cross-checking `max/kernels/test/gpu/basics/BUILD.bazel` showed upstream
already marks the whole print family `_APPLE_GPU_INCOMPATIBLE` (FIXMEs
MOCO-2405/2366) — their own Metal backend cannot run them either, and
KERN-2360 is *their* MetalAIRPass address-space propagation bug, a class we
fixed in ours. Two upstream-skipped tests now pass here: `test_launch_binary`
(apple-incompatible upstream) and `test_constant_memory` (nvidia-only).
