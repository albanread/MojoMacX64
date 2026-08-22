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

### Verified scoreboard

Final sweep after the day's fixes: **23 passing** (from 13), and every
remaining failure is accounted for — foreign-ISA features, upstream's own
`_APPLE_GPU_INCOMPATIBLE` set, SDK package gaps, or the three open items
below. Notably `test_init_vector_gpu` — skip-listed as upstream's
KERN-2360 MetalAIRPass address-space bug — **passes here**, so our
address-space work fixed that class outright.

Passing: accelerator_arch (+cli, +cli_kernels), add_constant, barrier,
cast_roundtrip, constant_memory, dim, gpu_mem_alloc_validation, grid_dim,
has_sm100_or_newer, id, info, init_vector_gpu, laneid, launch_binary,
prefix_sum, shuffle, simd_reduction, strided_load, sum, targetinfo,
verify_buffers_gpu.

### Skip list, with upstream's blessing

Cross-checking `max/kernels/test/gpu/basics/BUILD.bazel` showed upstream
already marks the whole print family `_APPLE_GPU_INCOMPATIBLE` (FIXMEs
MOCO-2405/2366) — their own Metal backend cannot run them either, and
KERN-2360 is *their* MetalAIRPass address-space propagation bug, a class we
fixed in ours. Two upstream-skipped tests now pass here: `test_launch_binary`
(apple-incompatible upstream) and `test_constant_memory` (nvidia-only).

## 2026-08-22 — "Interrupted compilation" decoded: AMD wants resource descriptors

The opaque failure blocking `test_fast_div`, `test_random` and
`test_function_mts` finally has a name, and it came from a source I should
have checked hours earlier: **`~/Library/Logs/DiagnosticReports/`**. The
Metal shader compiler runs as an XPC service, and it was not *rejecting* our
AIR — it was **crashing on it**, dozens of times, leaving fully symbolicated
reports each time:

```
EXC_BAD_ACCESS (SIGSEGV) KERN_INVALID_ADDRESS at 0x20
libAMDIL902.dylib  llvm::ILTargetLowering::getPtrRsrcId(...)
libAMDIL902.dylib  llvm::ILTargetLowering::getRsrcDescNode(...)
libAMDIL902.dylib  llvm::ILTargetLowering::LowerSTORE(...)
AMDRadeonX5000Shared  AMDGFX9MTLCompilerPlugin::compileShaders(...)
```

**AMD's Metal plugin must resolve every memory access to a buffer *resource
descriptor*.** A generic (AS0) pointer has none, so `getPtrRsrcId` null-
derefs. Apple silicon accepts the identical IR because it has flat
addressing — which is why upstream never had to care, and why this is a
fork-specific class rather than a bug anyone else would hit.

Where the generics came from: Mojo packs kernel captures into an argument
buffer, loads the whole thing as **one aggregate**, and `extractvalue`s the
device pointers out — so they materialize as AS0. (My first fix hooked only
loads *returning* pointers and did nothing; the pointers were never loaded
individually.) `deviceizeCapturedPointers` now retypes pointers sourced from
AS2/AS1 loads *and* from capture-struct extractvalues to device AS1 and
propagates. Generic stores in the fast_div kernel: **6 → 0**, and
`test_function_mts` went from "cannot compile" to executing its kernel.

Two lessons worth keeping:

- **When a vendor toolchain reports a transport error, look for a crash
  report.** "XPC_ERROR_CONNECTION_INTERRUPTED after multiple retries" is what
  a segfaulting compiler service looks like from the client side; the actual
  stack was on disk the whole time. This replaces `amdgpu-nt`, which is no
  longer usable (air-as stamps its own AIR version, so the standalone tool
  always sees 2.6 against its 2.5 plugin).
- **Apple-silicon tolerance hides address-space bugs.** Flat addressing means
  upstream's Metal path never needs correct address spaces; ours does, for
  every pointer, everywhere. Expect more of this class.

Also fixed: the SDK was missing kernels-library packages — `linalg` and
`graph_compiler/extensibility` are now built and linked into `vega-sdk/pkg`.
`test_wmma` needs `_rocblas` (an AMD library binding, genuinely N/A here).

Still open: `test_fast_div`/`test_random` still crash the plugin (generic
stores are gone, so a remaining generic access or another unresolvable
pointer shape); `test_function_mts` and
`test_static_layout_capture_argcount` now execute but compute wrong values —
argument-index correspondence between Mojo's packed captures, our
`air.buffer location_index`, and VegaRT's bind loop is the prime suspect.

## 2026-08-22 — Cross-check against the AIR Backend Field Notes digest

Read a research digest of the public AIR reverse-engineering record
("AIR Backend Field Notes", 14 sources, compiled 22 Aug 2026). Cross-checking
it against what this fork has measured:

**Its top-priority open question (Q1) is already settled here — and the
answer is 64.** The digest opens with a warning that Metal may expose 32-wide
simdgroups on AMD Macs (MoltenVK 1.4.2 fixed crashes from reporting 64 where
"Metal expects 32"), cautions that `threadExecutionWidth` is unreliable, and
prescribes a ten-minute experiment: dispatch a kernel that writes
`[[threads_per_simdgroup]]` and read it back. Spike S1 ran exactly that
experiment on day one. On both the Vega II and the 580X:
`threads_per_simdgroup` = 64, `simd_sum(1u)` = 64, and a 64-bit ballot
popcount = 64 — three independent in-kernel measurements agreeing, not an API
query. Since then the wave64 work has produced positive on-device proof:
`warp.sum` returns 64, and the ballot fix yields `0x5555555555555555` across
all 64 lanes. **Metal exposes 64-wide simdgroups on this hardware.** The
MoltenVK issue concerns what MoltenVK reports to Vulkan clients, a different
layer. (Their advice to prefer an in-kernel query over `threadExecutionWidth`
is sound regardless, and is what S1 did.)

**Q2 is likewise answered locally:** the Xcode-produced golden metallib on
this machine carries `air.version 2.6.0`, `air.language_version Metal 3.1.0`,
triple `air64-apple-macosx14.2.0`, and the runtime accepts 2.6. We can add a
data point the digest lacks: `amdgpu-nt`'s bundled plugin caps at **2.5**, so
the standalone tool rejects modules the driver accepts.

**Its address-space table confirms our remap is correct** — AIR 1=device,
2=constant, 3=threadgroup, and notably **4=threadgroup_imageblock,
5=ray_data**. Mojo emits NVPTX numbering (4=constant, 5=local), so leaving
those unmapped meant our constants were landing in *imageblock* space and
locals in *ray_data*. `remapAddressSpaces` (4→2, 5→0) is right per spec, not
just empirically.

**Where we can contribute back to that record:** finding A3 ("front-end
compiler crashes on Radeon") lists three independent reports with no
diagnosis — "no fix, only strategy." We have the diagnosis: symbolicated
`MTLCompilerService` crash stacks showing
`ILTargetLowering::getPtrRsrcId ← getRsrcDescNode ← LowerSTORE` in
`libAMDIL902.dylib`, root-caused to generic (AS0) pointers having no buffer
resource descriptor. The crash-report directory is the missing diagnostic
the digest's section 07 never mentions.

Acted on immediately: **A5** — Metal can silently no-op a dispatch whose
threadgroup exceeds the pipeline limit (SDL #15241). `VegaRTMetal_launch` now
validates against the pipeline's own `maxTotalThreadsPerThreadgroup` and
fails loudly.

Filed as backlog from the digest:

- **I1 / Q5 — atomics miscompile without explicit aliasing metadata.** The
  RFC author found Apple's compiler reordering memory across atomic CAS,
  producing *wrong answers, not errors*, and fixed it with Apple-style
  `!alias.scope`/`!noalias` annotation plus marking affected loads volatile.
  Unknown whether it reproduces on GCN (the RFC author was almost certainly
  on Apple Silicon). **Budget this before any lock-free kernel work.**
- **A1 — Blender's Cycles removed Metal-on-AMD in 4.3** citing driver/compiler
  bugs; the commits *preceding* removal are the closest thing to a catalogue
  of AMD-Metal workarounds. Worth mining before writing our own.
- **B2 — Julia's `llvm-downgrade` maintains an 18.0 target**, and Modular's
  writer derives from it. Since Metal's reader is LLVM-18-based, 18.0 may be a
  better base than the 17 we force. Ours works; this is robustness, not a fix.
- **A4 — instruction selection is Apple's**: gfx906 dot-product instructions
  (`v_dot4_i32_i8` et al.) cannot be hand-placed. Port AMD kernels for
  correctness first; treat their performance as unknown.
- **B5** — the `getMetalKernelArgType` i64→i32 kernel-argument correction,
  already on our watchpoint list, is confirmed as load-bearing across *every*
  constant-emission path.

## 2026-08-22 — fast_div/random: the limit is architectural, and now named

Chased the last crash class to the bottom. Three layers came off:

1. **`deviceizeCapturedPointers` was not sticking.** Mutating an
   `extractvalue`'s type does not survive serialization — the type is
   recomputed from the aggregate — and the mismatch got reconciled downstream
   as a `ptrtoint` → `inttoptr` round trip. **`inttoptr` destroys pointer
   provenance**, which is exactly what `getPtrRsrcId` needs to find the
   buffer resource. Replaced type mutation with an explicit
   **`addrspacecast`** (and direct `Use::set` rewriting, since
   `replaceUsesWithIf` demands identical types). `inttoptr` in the emitted
   kernel: **2 → 0**, provenance chain intact, `air-opt -verify` clean.

2. **It still crashes.** With every store now `addrspace(1)`, provenance
   preserved, and the module verifying, AMD's plugin still null-derefs in
   `getPtrRsrcId`.

3. **Because address space was never the real question.** The evidence was
   already on the bench: `vecadd`, which takes device pointers as **direct
   kernel buffer arguments**, has worked since day one. Every kernel that
   fails takes its device pointers **inside a captured struct**, delivered as
   raw `gpuAddress` bytes via `setBytes`.

**On AMD under Metal, a device pointer must arrive as a bound resource.** A
raw 64-bit address sitting in a constant buffer is just data; there is no
descriptor behind it, and no amount of address-space labelling creates one.
Apple silicon accepts raw addresses because it has flat addressing — the same
divergence as before, one level up.

Note the golden-MSL probe that appeared to contradict this: `device float *p`
inside a `constant Handle&` compiles and runs fine on the Vega II. That works
because it is a real **argument buffer** — Metal encoded a resource reference
into it. Our path bypasses that machinery entirely.

**So the fix is argument buffers**, not codegen: capture structs carrying
device pointers must be built with an `MTLArgumentEncoder` (or the pointers
hoisted into real kernel buffer parameters, which needs host/device agreement
on binding indices). That is a runtime + protocol change of real size, not a
legalizer tweak, and it is now the single largest known gap.

Affected: `test_fast_div`, `test_random`, `test_function_mts`,
`test_static_layout_capture_argcount` — i.e. **the `elementwise` /
captured-closure kernel family**, which is a large share of `max/kernels`.
Kernels taking buffers directly are unaffected and continue to pass.

The `addrspacecast` work is kept regardless: `inttoptr` in device code is a
provenance bug on any target, and the AS1 typing is correct per the AIR
address-space spec. No regressions (warp64, ballot64, shuffle, prefix_sum,
vecadd, add_constant, sum, laneid, constant_memory, launch_binary all pass).

## 2026-08-22 — Hoisting lands: captured pointers become bound resources

**25 passing (+2), no regressions.** `test_fast_div` and `test_function_mts`
both pass — two kernels that crashed Apple's shader compiler all session.

The protocol, end to end:

- **Compiler.** Every device pointer `extractvalue`d out of a by-value
  capture struct becomes a real kernel buffer parameter, named
  `__vega_cap_<srcParam>_<byteOffset>` and carrying its own `air.buffer`
  metadata. Offsets come from walking the aggregate layout by hand
  (`getIndexedOffsetInType` wants `Value` indices; `extractvalue` carries
  constant `unsigned`s).
- **Runtime.** Pipelines build with `MTLPipelineOptionArgumentInfo`;
  reflection parameter names are parsed back into a hoist table; at launch
  each entry reads the address out of the recorded packed argument at the
  recorded offset, resolves it in the allocation registry, and binds the
  owning buffer with `setBuffer`.

The design is self-describing — the compiler tells the runtime, through
parameter names, which capture bytes hold which binding — which matters
because **Mojo itself does not know**: its own comment says *"captures are
raw values, never device buffers"*, and the `_buffers` handle list only
covers *passed* `DevicePassable` args. For an elementwise kernel everything
is captured, so `_buffers` is empty and the host has nothing to offer. The
compiler knows, and VegaRT already had the address→buffer registry, so the
information exists on both ends — it just needed a channel.

**Verify the linchpin before building on it.** The whole design collapses if
reflection drops parameter names, so that was probed first: a hand-written
MSL kernel with a literal `__vega_cap_16` argument, compiled and reflected on
the Vega II. Names survive. Only then was any of the above written.

Three bugs found on the way in, all mine:

1. `scalarOrigTypes` indexed past its end once hoisted params joined the
   parameter list (the original-param metadata loop must stop at
   `firstHoistIdx`).
2. Rewiring uses to an AS1 parameter leaves AS0-derived users behind, and a
   `bitcast` cannot cross address spaces — the address space has to be
   propagated through the use graph after rewiring.
3. `deviceizeCapturedPointers` ran *before* hoisting and addrspacecast the
   very `extractvalue`s hoisting then replaced, leaving an **invalid
   same-address-space `addrspacecast`**. Hoisting supersedes that path
   entirely, so the extractvalue branch is gone.

Tooling note: added a post-pass IR dump (`VEGA_KEEP_AIR` now writes
`vega-kernel.pre.ll` *and* `vega-kernel.post.ll`). Once a module is bad
enough that `llvm-dis` refuses it, the textual dump from inside the backend
is the only way to see what was actually emitted — which is precisely when
you most need to.

### `test_random`: narrower than it looks

Same `getPtrRsrcId` ← `LowerSTORE` crash, but the easy explanations are all
excluded: exactly one device pointer, cleanly hoisted, provenance intact
(`__vega_cap_0_0` → bitcast → GEP → bitcast → store), zero generic accesses,
zero `addrspacecast`s. The kernel stores `half`, and a plain MSL `half` store
compiles and builds a pipeline on this GPU, so f16 is not the trigger by
itself. Something narrower — the `[2 x i8]` byte-array GEP arithmetic feeding
a 16-bit store, or the 4-wide (`r1_w4`) vectorized variant — still defeats
AMD's resource inference. Next.

## 2026-08-22 — test_random: narrowed hard, not yet cracked

Bisected the test down to a single trigger and fixed two real bugs on the
way, but the crash survives all of them.

**The trigger is `NormalRandom`/`step_normal`, not `Random`.** Running each
variant alone: `float16` uniform and `float32` uniform both **pass**; both
`"normal"` variants fail. So it is the Box-Muller path, in both dtypes.

Two genuine bugs found and fixed while narrowing:

1. **AIR math functions were emitted as bare stems.** The kernel called
   `air.cos`, `air.sin`, `air.sqrt` — undefined symbols. Golden probes show
   AIR spells them `air.cos.f32` (and `air.fast_cos.f32` under fast-math,
   which we do not enable), with genuine **vector** forms too:
   `air.cos.v4f32`. `mangleAirOps` now covers the whole math family, keyed on
   the first argument type, and emits exactly the golden names.
2. **Internal helpers were not being inlined.** The module carried a
   non-inlined `std_random_philox_NormalRandom...` taking and returning
   structs by value. Metal kernels are conventionally fully inlined, and
   AMD's backend cannot trace a buffer resource across a call boundary, so
   an always-inliner now runs over internal functions before emission. The
   module is now a single function.

After both: **one function, all stores `addrspace(1)`, one cleanly hoisted
buffer parameter, correct AIR symbol names, no generic pointers, no
`addrspacecast`s** — and `getPtrRsrcId` ← `LowerSTORE` still segfaults.

Excluded by direct probe on this GPU, so none of these is the cause:

- `half` stores (plain MSL, and our own direct-buffer f16 kernel: both fine)
- f16/f32 elementwise at width 1 and 4 through a hoisted pointer (passes)
- `Random`/`step_uniform` (passes)
- vector transcendentals — Apple's own `float4` `cos`+`sqrt` kernel builds a
  pipeline on the Vega II
- non-inlined helpers (now inlined; crash persists)
- undefined AIR symbols (now correctly mangled; crash persists)

Both fixes are kept: they are correct independently, and the regression set
(warp64, ballot64, shuffle, prefix_sum, vecadd, fast_div, function_mts, sum,
barrier, constant_memory, launch_binary, laneid) is green.

Next angle when this resumes: bisect the *kernel body* rather than the test —
take the emitted `.ll`, delete statements until the pipeline builds, and read
what survives. The harness for that is the `VEGA_KEEP_AIR` pre/post dumps
plus `xcrun metallib` + the S1 probe, which together give a
sub-minute edit→verdict loop without going through Mojo at all.

## 2026-08-22 — test_random bisected to a constant-encoding bug

Bisected from a failing test down to a four-line kernel and then into the
bitstream. The chain:

1. **`test_random` → `NormalRandom`.** Running variants alone: both uniform
   variants pass, both `"normal"` variants fail. Box-Muller, not the RNG.
2. **`step_normal` → `log`.** A minimal kernel (direct buffer argument, no
   elementwise, no captures, no hoisting) reproduces it, and stripping
   `step_normal` down to `sqrt(-2.0 * log(v))` on a `SIMD[float32, 4]` still
   crashes. `cos`, `sin`, `sqrt`, vector transcendentals, scalar NaN — all
   pass in isolation.
3. **`log` → NaN/Inf vector constants.** Mojo's `log` expands inline with
   special-case handling whose tail is
   `select ..., <4 x float> splat (float +qnan)` and
   `splat (float +inf)`.
4. **Not a driver bug.** Apple's own MSL kernel doing `select` over `float4`
   NaN and Inf constants compiles, links and builds a pipeline on the Vega II.
5. **Our encoding is dropping them.** `llvm-bcanalyzer` on the emitted AIR:
   the kernel's text IR contains `+inf`, `+qnan`, `-2.0`, `-0.0`, `-1.0` and
   more, but the bitstream carries **only 4 `FLOAT` records** — the three
   scalars I wrote explicitly in the probe, and nothing else. **The float
   constants inside vector/splat constants are never emitted.** The reader
   therefore reconstructs garbage, and the AMD backend dies lowering the
   instruction that consumes it — which is why the crash always surfaced in
   `LowerSTORE`, on the store that consumes the value, and why fixing address
   spaces, provenance, symbol names, attributes and inlining never helped.

**Next step is a specific hypothesis, and it rhymes with a bug already fixed
here:** the vendored `ValueEnumerator17` failed to enumerate `SwitchInst`
case values because newer LLVM stores them out-of-line. Splat vector
constants got a new representation in recent LLVM too (hence the `splat (…)`
textual form the LLVM-18-era `air-as` cannot even parse). The enumerator very
likely walks `ConstantVector` operands in a way that misses splat elements,
so they are never assigned value IDs and never written. Check
`ValueEnumerator17::EnumerateValue` against upstream's handling of
`ConstantDataVector`/splat constants, exactly as was done for switch cases.

Tooling note: an IR-level bisection harness (`.ll` → `air-as` → `metallib` →
S1 probe) was attempted and abandoned. `air-as` is LLVM-18-era and rejects
essentially every modern textual construct — `splat (…)`, `f0x…` float
literals, `disjoint`, `captures(none)`, `memory(…)`, `+qnan`. A normalizer
can be written for each in turn, but it is a losing race; **bisecting the
Mojo source with our own compiler was far cheaper** and is what actually
found this. Worth remembering: prefer bisecting at the level where your
own toolchain still works.

## 2026-08-22 — test_random solved: it was Mojo's `log`, not the encoder

**26 passing (+1), no regressions.** The constant-encoding hypothesis from
the previous entry was **wrong**, and checking it properly is what found the
real answer.

Correction first: NaN/Inf vector constants *are* encoded correctly, as `DATA`
records, byte-identical in form to Apple's. The earlier "only 4 FLOAT
records" reading was a misreading — **vector constant elements are encoded as
`DATA`, not as individual `FLOAT` records**, so counting `FLOAT` records
against float literals in the text IR compares two different things. A
genuine dropped-constant bug would look different.

What actually found it: comparing **bitstream record-type inventories**
between our module and an Apple-compiled equivalent MSL kernel.

```
record types only in ours: INST_CMP2, INST_VSELECT, STRUCT_ANON, UNDEF
```

Apple's `log` is a single `air.log.v4f32` call. **Mojo's is an inline
polynomial**, and its special-case handling expands into vector
compare/select shapes the AMD Metal backend cannot lower. `std.math.log` had
a fast path for NVIDIA (`ln2 * log2(x)`) and fell through to the generic
polynomial for everyone else — including Metal, which provides `log`
natively. Added the Apple-GPU path; `test_random` passes.

Also fixed along the way, and kept because it is correct regardless:
**`poison` (LLVM 12) is newer than the AMD plugin's LLVM fork** and Apple
emits none of it. `MetalAIRPass` now downgrades `poison` → `undef`,
recursing into constant aggregates. It was not this bug's trigger, but it is
the same class as `freeze`/`fneg`/GEP-flags and would have bitten later.

### The lesson worth keeping

Three times today the crash location was a lie. `getPtrRsrcId ← LowerSTORE`
pointed at stores, and the causes were, in order: a capture struct's pointers
having no resource descriptor, then nothing at all (already fixed), then a
`log` polynomial hundreds of instructions upstream of the store that merely
*consumed* its result. **On this backend, treat the crashing instruction as
"where the DAG died", not "what is wrong".** The reliable technique is not
reading the stack — it is:

1. bisect at the level where your own toolchain still works (Mojo source
   here, never the `air-as` text round-trip), then
2. diff the **record-type inventory** of your bitstream against an Apple
   compilation of the equivalent kernel, and investigate every record type
   that is yours alone.

That comparison takes one command and would have found this in minutes:

```
llvm-bcanalyzer --dump ours.air  | grep -oE '<[A-Za-z_0-9]+' | sort -u > ours.txt
llvm-bcanalyzer --dump apple.air | grep -oE '<[A-Za-z_0-9]+' | sort -u > apple.txt
comm -23 ours.txt apple.txt
```

## 2026-08-22 — basics suite complete: 26 pass, 0 unexplained

Every remaining failure in `max/kernels/test/gpu/basics` is accounted for on
the skip list — NVIDIA/AMD-ISA-only features, upstream's own
`_APPLE_GPU_INCOMPATIBLE` set, or SDK package gaps. **Nothing is failing for
a reason we do not understand.** Moving past basics to real kernels.

## 2026-08-22 — It runs real work: 1024³ matmul at 2.37 TFLOP/s

```
device: AMD Radeon Pro Vega II (Apple Metal)
matmul 1024 x 1024 x 1024 : 0.907 ms   2367.68 GFLOP/s
verify: 0 wrong
MATMUL-ON-VEGA: PASS
```

A tiled 16×16 matmul written in ordinary Mojo — `stack_allocation` in
`AddressSpace.SHARED`, `barrier()`, `thread_idx`/`block_idx`, buffer
arguments — compiled through the fork's AIR backend and run on the Vega II.
Results verified against a CPU reference. **~17% of the card's ~14.1 TFLOPS
fp32 peak from a naive tiled kernel**, which is the normal range for one
before any register-tiling or vectorization work. Source kept at
[`spikes/matmul/matmul.mojo`](spikes/matmul/matmul.mojo).

To get there, two more mangling bugs — both in code added earlier today:

1. **Declaration-time mangling was needed for *all* suffixed families, not
   just shuffles.** `AirLowering` reused one bare `air.log` declaration for
   both a scalar and a vector call, and LLVM asserts "Calling a function with
   a bad signature" when the second call's operands do not match. Extending
   the suffix to every family that carries one fixed it.
2. **…but not for the families that do *not* carry one.** Generalizing to
   every `air.*` name promptly broke the matmul: builtin shims became
   `air.thread_position_in_threadgroup.x.u.i32`, which the backend's
   `parseBuiltinShim` no longer recognized (so they were never turned into
   kernel parameters), and `air.wg.barrier` gained a suffix it does not have.
   Both now consult the same whitelist the backend uses.

The pairing is the lesson: **"mangle nothing" and "mangle everything" are
both wrong; AIR's symbol families differ and the whitelist has to be shared
between the lowering and the backend.** They are now explicitly kept in sync,
with a comment saying so on both copies.

Also on the way: the full kernel-library package set is now built and linked
into `vega-sdk/pkg` — `layout`, `linalg`, `nn`, `algorithm`, `pipeline`,
`comm`, `structured_kernels`, `internal_utils`, `extensibility`, and the
vendor-binding stubs (`_rocblas`, `_cublas`, `_cudnn`, `_miopen`, `_cufft`).
Every `unable to locate module` error in the kernels tree is gone.

## 2026-08-22 — Cocoa P1: the compiler now reads the SDK during elaboration

Pivoted to making this fork the best Cocoa compiler. The foundation is in and
proven end to end: `spikes/s5-cocoakb/check.mojo` resolves struct layouts,
enum values, inheritance-resolved `@encode` signatures, three `objc_msgSend`
variants, a POSIX signature, and the database hash — **all at comptime** —
and `must_fail.mojo` proves an unknown name is a compile error at the asking
source location, never a wrong answer.

**Mechanism.** One generic param-operator, `#kgen.param.expr<cocoakb_query,
"<query>", "<arg>"...>`, evaluated in `IREvaluatorContext` against a
read-only, mutex-guarded, lazily-opened handle on `cocoa.sqlite`. The
compiler owns a fixed query table (name → SQL); Mojo passes query names,
never SQL, so a new capability is one row plus a wrapper. Adopted wholesale
from the sister port's `winkb` (Windows x64), re-aimed at CocoaBaseMCP's
now-x86-64-correct database.

**The thing that bit, and is worth remembering for the next opcode.** Adding
a `POC` case is not one edit — the sister port touches **eight** sites, and
missing any one is not a compile error in KGEN but an `llvm_unreachable`
("unhandled opcode") at *Mojo precompile* time, which reads like a stdlib
bug. The full set: the enum (`KGENEnums.td`), *both* evaluator dispatches
(`ParametricIREvaluator.cpp` and `IREvaluator.cpp` — there are two), verify +
fold + type-agreement exemption (three separate switches in `KGENAttrs.cpp`),
the textual parser (`KGENUtils.cpp`), and the operand-type exemption list.
Grepping the sister repo for every `WinKBQuery` occurrence was what found
them; doing it from the four sites I remembered would have failed.

**And the version bump.** A new opcode changes the compiler's bytecode
version, so **every** `.mojoc` (std, max, layout, linalg, nn, …) is
"incompatible with the current version" until rebuilt — not just the ones
that use the feature. Rebuilt all sixteen SDK packages; GPU stack reverified
(matmul 2.39 TFLOP/s, test_random, shuffle, prefix_sum green).

**Why the x86-64 database matters most here.** The crown-jewel query is
`msgsend_variant`. On arm64 every send is plain `objc_msgSend`; on x86-64 a
MEMORY-class return (any aggregate > 16 bytes — `NSRect` is 32) *must* go
through `objc_msgSend_stret` with a hidden buffer pointer in `rdi` and `self`
shifted to `rsi`, and a `long double` through `_fpret`. Get it wrong and the
stack corrupts silently. `NSValue rectValue` resolving to `objc_msgSend_stret`
in the spike is the proof this is right, and it is a distinction upstream
Mojo (arm64-only Apple GPUs) has no concept of.

Next (P2): `std.objc` — an `msg_send` that selects the stub with `comptime
if` over `cocoakb_msgsend_variant`, so no human ever picks it; smoke test an
NSString round-trip on the host.

## 2026-08-22 — Cocoa P2+P3: callable Cocoa, and no-leak by default

std.objc now calls Cocoa. `objc_smoke` does a full NSString round-trip
(class-method send with a C-string arg, `length` = 26, `UTF8String` back to
the original text) and `ownership_test` cycles **1,000,000 NSMutableArrays at
a flat ~10 MB RSS** — proven leak-free — plus explicit shared ownership and
autorelease-from-a-function. Every selector and ABI stub came from the
database; none is hand-written.

**The dispatch problem, and the fix.** `objc_msgSend` is one C symbol called
with a different signature at every call site, but `external_call` declares
one LLVM type per symbol name — a second signature is a hard error ("existing
function with conflicting signature", confirmed with a two-line repro). Every
serious ObjC bridge solves this the same way and so do we: take the *address*
of the stub and call it through a per-signature function-pointer cast. Mojo
spells the cast `def(id, SEL, /, *args) thin abi("C") -> R` — the `/` making
the two fixed params positional-only so the argument pack can follow — and
std.ffi's own `DLHandle` callable uses exactly this shape, which is where the
idiom came from. The stub address comes from `dlsym(RTLD_DEFAULT, variant)`,
with `variant` chosen at comptime from the database; a struct-return
(`objc_msgSend_stret`) is a compile error until P2.1, never a silent stack
smash.

**No-leak ownership.** `ObjCRef` owns a +1 and releases in `__deinit__`, so an
object's lifetime follows the Mojo value — the default is *no leak*, and you
opt out with `.autorelease()`, not into ownership. It's move-only with an
explicit `.copy()`, so a share (a retain) is always visible in the code. The
primitives are `objc_retain/release/autorelease` — the ARC entry points Clang
emits — so it interoperates with ARC.

**Two things that bit:**

- **Foundation must be linked.** `objc_getClass("NSString")` returns *nil*
  with only `-lobjc`, because the class isn't registered until Foundation
  loads. The wrapper now links `-framework Foundation`. This is a real gotcha:
  the symbol resolves, the call succeeds, and you get a null class — no error,
  just nil everywhere downstream.
- **Retain-count probing lies.** My first ownership test read
  `CFGetRetainCount(a.object())` between operations and crashed intermittently
  — because `a.object()` materializes temporaries that perturb Mojo's ASAP
  destruction ordering, so the probe *changes* what it measures. The sound
  test is behavioral: cycle a million objects and watch RSS stay flat. Lesson
  for a value-semantics language: don't measure destruction timing with
  something that itself creates values.

**Trait/idiom drift from the sister port's era**, all mechanical once found:
`@register_passable("trivial")` → `@fieldwise_init struct X(TrivialRegister
Passable)`; `owned self` → `deinit self`; custom copy is `__init__(out self,
*, copy: Self)`; `Pointer` is non-null by design so nullable C handles are
stored as `Int` and reconstructed with `unsafe_from_address`; `constrained[…]`
→ `comptime assert`.

P4 (deferred): comptime `@encode` parser + Mojo-type encoder for
argument-level type checking, and the `objc_msgSend_stret` sret path for
struct returns (NSRect/NSRange-returning selectors).

## 2026-08-22 — Cocoa P4: struct returns, and the C ABI does the work

The struct-return path I'd deferred as "P2.1, not yet implemented" turned out
to need **no new machinery** — just the removal of the restriction that
rejected it. This is the nicest kind of finding.

`objc_msgSend`, `objc_msgSend_fpret`, and `objc_msgSend_stret` are all reached
through the *same* per-signature function-pointer cast. The C ABI lowering
does whatever the declared **return type** requires: register allocation for
a scalar, x87 for a `long double`, or the hidden sret pointer (plus the
self→rsi / _cmd→rdx shift that the `_stret` entry point itself performs) for a
struct larger than 16 bytes. The database's only job is to name *which* entry
point; everything else follows from `R`.

I proved it with raw `external_call` first (a 32-byte CGRect round-tripping
through `+valueWithRect:` and `-rectValue`), then two edits made the library
path work: `_stub_addr` stops rejecting `objc_msgSend_stret` (only unmodelable
`?` stays a compile error), and `msg_send`'s `R` relaxes from
`RegisterPassable` to `AnyType`. `stret_test` now round-trips a CGRect through
`msg_send` with the stub chosen entirely by the database.

**An ABI subtlety worth keeping**, straight from the classifier: `NSRange`
(16 bytes, classified `gg`) returns in the **rax:rdx register pair through
plain `objc_msgSend`** — *not* stret. Only aggregates **strictly larger than
16 bytes** (`NSRect` = 32 = `s`) go through `objc_msgSend_stret`. The 16-byte
boundary is the SysV MEMORY threshold, and getting it wrong (routing a 16-byte
return to stret, or a 24-byte one to the register path) corrupts the stack
silently — which is exactly why reading it from a per-method classifier rather
than guessing from the type name is the whole point of this design.

Cocoa now has: checked layouts/enums/selectors (P1), calling with
database-selected dispatch (P2), no-leak RAII ownership (P3), and struct
returns/arguments (P4). What remains is depth, not new mechanism: a comptime
`@encode` parser to check argument *types* against the selector (today the
count and the return are checked, the arg types are trusted), a
`sel_registerName` cache, and higher-level sugar (NSString<->String bridging,
typed wrappers for common AppKit/Foundation classes) — all queries and
convenience over the four working layers.

## 2026-08-22 — Cocoa: the payoff — idiomatic, leak-safe Cocoa in Mojo

`std.objc.foundation` binds `NSString` as a leak-safe Mojo type, and
`foundation_demo.mojo` reads like ordinary Mojo:

```mojo
var hello = NSString("Hello, ")
var greeting = hello.appending(NSString("Cocoa from Mojo"))
print(greeting.to_string())          # Hello, Cocoa from Mojo
print(greeting.equals(other))        # a real -isEqualToString:
```

Creation from a Mojo `String`, `.length()`, `.to_string()`, `.equals()`,
`.appending()` — each is one `msg_send` with a database-selected stub, and the
object is owned by an `ObjCRef`, so nothing leaks and no stub is ever named by
hand. 200,000 bridged NSStrings cycle at a flat 10 MB RSS.

The point of this layer is what it *isn't*: it's not a generator, and it's not
1,000 lines. Binding a Cocoa class is a handful of typed methods over the four
working layers underneath. That's the whole thesis of the database-backed
design — new surface is queries and convenience, never new machinery. The
Windows sister port learned the same lesson with `winkb`; here it holds for a
runtime with 422,683 methods.

The Cocoa stack as it stands: **P1** comptime SDK queries (checked layouts,
enums, selectors, encodings), **P2** calling with database-selected dispatch,
**P3** no-leak RAII ownership, **P4** struct returns/arguments, and a
**Foundation** convenience layer proving it composes. Remaining is depth, not
mechanism: a comptime `@encode` parser to check argument *types* (the count
and return are checked today, arg types trusted), a selector cache, and more
bridged classes as they're needed.
