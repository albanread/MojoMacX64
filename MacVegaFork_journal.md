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

## 2026-08-22 — Cocoa: argument-count checking closes the dispatch correctness gap

`msg_send` now catches a wrong argument count at compile time. It reads the
selector's declared arity from the database — `cocoakb_method_arg_classes`,
counted from its comma-separated SysV class string ("" = 0, "g" = 1,
"g,g" = 2) — and comptime-asserts it against the pack length. Forgetting the
index on `characterAtIndex:` is now:

```
constraint failed: std.objc: 'characterAtIndex:' on NSString takes
1 argument(s), but 0 were passed.
```

instead of a runtime read of garbage from an unset register. This is the kind
of bug that is nearly impossible to find by testing — the call *works*, it just
reads whatever was in `rdx` — so moving it to compile time is high value.

I used the SysV arg-class string rather than parsing `@encode` directly: it's
already the ABI truth the database derived, and a count has none of the
signedness or struct-layout subtlety that a full `@encode` type comparison
carries. Argument *type* checking (matching each Mojo argument's ABI category
against the expected class per position) is the natural next step on exactly
this data — the count check is the robust half done first.

Two Mojo-string gotchas worth noting for the next comptime-string code:
`len()` on a `String`/`StringSlice` is rejected outright (UTF-8 ambiguity —
use `.as_bytes()` then `len(bytes)`), and a `VariadicPack`'s comptime length is
`args.__len__()` (which returns `Ts.length`), not `args.size`.

The Cocoa dispatch path now checks: selector exists (P1), correct ABI stub
(P2), and correct argument count (this) — all at compile time, all from one
database. Remaining depth: per-argument type category, a selector cache, and
more bridged classes.

## 2026-08-22 — Cocoa: register-file type checking, and NSNumber round-trips

The argument-*type* gap is now closed, conservatively. `msg_send` compares
each Mojo argument's type against the SysV class the database recorded for that
position and rejects a **register-file mismatch** — a float where the ABI wants
an integer/pointer register, or an integer where it wants a float register.
That's the dangerous case: at runtime the call *succeeds* but reads the wrong
register file (xmm vs rdi), so it's a silent wrong answer. Now:

```
argument 0 of 'numberWithDouble:' on NSNumber is an integer, but the ABI
expects a float register here. Pass a Float32/Float64.
```

**Conservative by design.** It flags only what it's certain of — a scalar float
SIMD type (via `reflect[Ts[i]].name()` matching `SIMD[DType.floatNN, 1]`)
against a purely-SSE class, and a plain scalar `Int` against a float class.
Structs, vectors, and unclassifiable types are skipped, never mis-flagged. The
whole point is zero false positives: verified against all existing spikes,
which pass objects, C-strings, 32-byte structs, and integers without one.

Building it surfaced the useful primitives: `reflect[T].name()` yields a
comptime type-name string (`Int` reflects as `SIMD[DType.int, 1]`, which is a
quirk worth knowing), a `comptime for i in range(args.__len__())` walks the
pack, and the ABI-class field is classified in place rather than by building a
comptime substring (which the StaticString constructors don't make easy).

`typecheck_test` also proves NSNumber works: a double (3.14159) and an integer
(42) round-trip through `numberWithDouble:`/`doubleValue` and
`numberWithInteger:`/`integerValue`. Another class bound in a few lines.

**The Cocoa dispatch path now verifies four things at compile time**, all from
one database: the selector exists, the correct objc_msgSend variant, the
correct argument count, and the correct register file per argument. That is a
meaningfully safer FFI than hand-written bindings, which check none of them.

## 2026-08-22 — Cocoa dispatch materialized to C speed (3660ns → 3ns)

The user's push — "materialize these into C speed calls, we are on LLVM, use
code generation" — was exactly right, and it turned into two small KGEN fixes
that make a fully-checked, database-driven message send cost about as much as a
hand-written `objc_msgSend`. The progression, on a 50M-iteration `length` loop:

| stage | ns/send | what changed |
|---|---|---|
| original | 3660 | `dlsym(RTLD_DEFAULT)` **per call** — scans every dylib |
| hashed cache | 38 | dlsym + selector cached in the runtime global registry (one hash each) |
| direct stub | 26.7 | stub is a link-time symbol reference (relocation), selector still hashed |
| **global slot** | **3.0** | selector in a per-selector persistent global slot (one load) |

**Two compiler bugs, same shape.** Both `pop.extern_ptr_symbol` and
`pop.global_alloc` lower through `symtab.insert()`, which **renames on
collision** (`objc_msgSend` → `objc_msgSend_0`, `_1`; `slot` → `slot_0`). That
uniquing is correct for genuinely distinct symbols but wrong for two cases I
needed:

- Referencing **one shared external symbol** (`objc_msgSend`, from every send)
  from many call sites — the renamed `objc_msgSend_0` is undefined at link.
- A **named host global** used as a cache — each call site silently got its own
  renamed slot, so nothing ever persisted (this is why my first `global_alloc`
  persistence test read 0 every time).

The fix in both lowerings is the lookup-or-reuse the same file already used for
`AlignedAlloc`/`AlignedFree`: look up an existing declaration for the name and
reuse it. For `global_alloc` it's guarded to the non-GPU-shared, no-initializer
path (a fixed-name global is a C-file-scope-`static`-like named global);
`GPU_SHARED` keeps its per-kernel uniquing. Only three `global_alloc` users
exist, all GPU-path, so the host change is safe — confirmed by rebuilding std
and max plus the full GPU regression.

**Why this matters beyond a microbenchmark.** The whole thesis of the
database-backed design is that the compiler does the work the programmer would
otherwise do by hand and get wrong. Dispatch was the last place that thesis
leaked into runtime cost: a checked call was 1000× slower than an unchecked
one, which would have pushed anyone writing a hot loop back to raw
`external_call` and its hand-rolled ABI. Now the checked path *is* the fast
path — selector existence, ABI stub, argument count, and register file all
verified at compile time, and the emitted code is a relocation, a load, a
predicted branch, and the call. There is no longer a reason to write an
unchecked Cocoa call.

The two KGEN dedup fixes are general — any Mojo code referencing a shared
external symbol, or using a fixed-name host global as a cache, benefits.

## 2026-08-22 — The same disease in another codebase: llama.cpp on the Vega II

A detour, but a load-bearing one. `llama.cpp`'s Metal backend now runs
Qwen3-8B-Q4_K_M entirely on the Vega II, correctly, at **50 t/s prefill and
32.4 t/s generation** — 2.3× the 24-thread Xeon for generation. Fork at
[albanread/IntelMacLlamaCpp](https://github.com/albanread/IntelMacLlamaCpp).

The reason it belongs in this journal: **it is an independent confirmation of
the diagnosis in the Phase 4 entry above, arrived at from the opposite
direction.** That entry named the disease as the tree encoding *lane count as
vendor identity*. ggml has the identical bug, in the identical shape:

```objc
dev->props.has_simdgroup_reduction  = [dev supportsFamily:MTLGPUFamilyApple7];
```

which is `_resolve_warp_size()`'s `is_apple_gpu() → 32` wearing a different
hat — a capability inferred from vendor family rather than measured. Two
codebases, written by different people for different purposes, made the same
substitution. The Vega II is simply the first machine where the substitution
is false, so it is the first machine where both break. Our fix is the same
shape too: probe the width (compile a trivial kernel, read the pipeline's
`threadExecutionWidth`), then inject it as `N_SIMDWIDTH` rather than trusting
a family check.

Four bug classes, of which the third is the one worth remembering:

1. **Device selection.** `MTLCreateSystemDefaultDevice()` returns the GPU
   driving the display — on this Mac Pro the 8 GB 580X, which reports Metal 2,
   so `has_simdgroup_reduction` is false and the whole backend silently
   degrades to nothing. The 32 GB Vega II is invisible until asked for by name.
2. **Wave64 arithmetic**, ~14 kernel families. Two distinct shapes: lane→block
   mapping (`nypsg = 32/nxpsg`), and — subtler — *pointer advances left at a
   literal stride* after the loop stride became width-dependent. `q3_K` and
   `q5_K` both stride `ib += N_SIMDWIDTH/8` (8 lanes' worth on wave64) while
   still advancing `y1 += 4 * QK_K`. `q6_K` was immune only because it
   recomputes `yy + i*QK_K` fresh each iteration.
3. **A race, not arithmetic.** With every kernel numerically correct, output
   was *still* garbage — and a **different** garbage each run. The AMD driver
   does not enforce `memoryBarrierWithScope:` between concurrently dispatched
   kernels; Apple's TBDR does. Restricting concurrent dispatch to Apple GPUs
   costs 4.6% and fixes it. **Nondeterminism across runs is the tell that
   separates a scheduling bug from a maths bug** — worth reaching for early,
   because it partitions the search space in one experiment.
4. `set_tensor` asserting on non-page-aligned host pointers, which is simply
   an unexercised discrete-GPU path.

**The testing lesson generalizes to us directly.** Upstream's op suite
exercises k-quant matmul at `k = 256` only — `nb = 1`, one block per row, one
loop iteration, so every tiling and stride variant is trivially correct.
Qwen3-8B uses `k = 4096` and `12288` (`nb = 16`, `48`). The result:

```
q5_K, q3_K: pass all 1161 MUL_MAT tests; relative error ~1.0 at real sizes
```

A green suite proved nothing until the tested shapes matched the shapes the
workload uses. Our own `basics` sweep has the same hazard — it verifies that
warp primitives work, not that they work at the tile counts a real kernel
drives. Worth an audit pass.

For proving numerical correctness end-to-end, perplexity against the CPU
backend on identical text turned out to be the only honest instrument:

```
Vega II (Metal) : PPL = 23.2535 +/- 1.52
CPU reference   : PPL = 23.2960 +/- 1.53      delta 0.18%, inside the bars
```

That gap is floating-point reduction-order noise. The failure mode it exists
to catch is the one nothing else catches: subtly-wrong results that still read
as fluent text.

**And a number that sharpens our own priorities.** llama.cpp's prefill on this
card sustains roughly **0.8 TFLOP/s** effective (2·N·tokens/s) — **about 6% of
the card's ~14.1 TFLOPS peak** — while the naive tiled Mojo matmul from the
entry above already does **2.37 TFLOP/s** on the same silicon. Worse: the Xeon
beats it at prompt processing (94 vs 48 t/s at 512 tokens), and does so at
**1.54 TFLOP/s**, roughly 60% of its own AVX-512 peak via Accelerate. A CPU
running near its ceiling is outrunning a GPU running at a sixteenth of its
own, for one reason: `has_simdgroup_mm` is gated on
Apple7, so every prompt matmul falls back to mat-*vec* kernels computing one
output column at a time. It is not a hardware limit — our own backend beats it
threefold with a kernel written in an afternoon. **A wave64 `mul_mm` built on
`simd_shuffle` rather than `simdgroup_matrix` is the single highest-value
piece of unclaimed performance on this card**, in either project.

One operational hazard, learned the hard way: **do not run the full
`test-backend-ops` suite on this machine.** Both GPUs share
`IOAcceleratorFamily2`, so a compute hang on the headless Vega II stalls the
580X that is driving the display, and the userspace watchdog kills WindowServer
after 40 seconds. It presents as a crash but is not a panic — the spin dump
shows WindowServer wedged in `AMDRadeonX4000` (the *other* card's driver)
while we were computing on the Vega. Per-op with a timeout, always.

Still open: `iq2_xxs` is measurably wrong at large k and `iq2_xs` hangs the
GPU, so the whole IQ quant family is off-limits here pending triage; the
K-quants and `mxfp4` are verified at real shapes. Next up is
Qwen3-30B-A3B (MoE, 3B active), where the interesting risk is that top-k
expert routing runs through `argsort`/`top_k`/`get_rows` — the wave64-suspect
families — and wrong routing produces fluent, subtly worse output rather than
an obvious failure. The perplexity harness above is what will catch it.

### Capstone note

The C-speed dispatch result is the moment the Cocoa design fully arrived: a
message send that is checked four ways at compile time (selector exists,
correct objc_msgSend variant, correct argument count, correct register file)
and costs 3ns at runtime. The compiler does the work a hand-binding does by
hand and gets wrong, and pays nothing for it. Two general KGEN fixes
(extern-symbol and named-global dedup) fell out, useful to any Mojo FFI code.
Next: prove it drives a real app — a native NSWindow Mandelbrot that times CPU
vs GPU and renders into a Metal texture at 60fps, the Mac answer to the Windows
D3D example.

## 2026-08-22 — Cocoa Mandelbrot: the two halves meet at 60fps

The capstone runs. A native macOS app, written entirely in Mojo, that computes
a mandelbrot on the Vega II each frame and presents it through a CAMetalLayer:

```
Mandelbrot 1024 x 768 , 256 iterations
  CPU: 149.8 ms
  GPU: AMD Radeon Pro Vega II (Apple Metal)
  GPU: 0.40 ms  ( 374.5 x faster )
Rendering. Close the window to quit.
  frame 120 — 60.3 fps
  frame 240 — 60.2 fps
```

Locked to 60fps by the drawable's vsync, exactly like the Windows D3D example
it answers. It is the first thing that exercises **both** halves of the fork at
once — the AIR GPU backend computing the fractal, and the Cocoa dispatch layer
driving AppKit and Metal — and neither strains.

**It came together fast because the foundations were right.** Each risky piece
was proven as its own spike first: `window_smoke` (an AppKit event loop pumped
from Mojo — the frame height reading back 508 = 480 content + 28 title bar was
the tell that the NSRect struct arg had landed correctly), then `compute_smoke`
(CPU vs GPU, 99.86% exact agreement — the 0.14% that differ are the chaotic
boundary band where Float32 FMA-vs-mul/add rounding shifts the escape count,
inherent to the algorithm, not a bug). With those green the full app was
assembly.

**One gap surfaced and closed cleanly: protocol-typed objects.** Metal traffics
in `id<MTLDevice>`, `id<MTLTexture>`, `id<MTLCommandBuffer>` — the concrete
class is unknown at compile time, so the class-keyed `msg_send` cannot look
them up. But a selector carries the same ABI wherever it is implemented, so two
selector-keyed queries (majority ABI across implementing classes) plus a
`std.objc.send` gave a protocol path that still checks dispatch, arg count and
register file — only the receiver class is unchecked. `CAMetalLayer` and
`CAMetalDrawable` are concrete classes already in the database, so the display
objects stayed fully class-checked; only the true protocol calls
(`newCommandQueue`, `replaceRegion:…`, `presentDrawable:`, `commit`) use the
selector path.

**Why the C-speed dispatch mattered here, concretely.** The render loop makes a
couple of dozen sends per frame — event pump, drawable, texture upload, present,
commit — 60 times a second. At the original 3660ns/send that is ~5ms/frame of
pure binding overhead, enough to miss the frame. At 3ns it is unmeasurable, and
the 60fps is entirely the GPU and the compositor. The optimisation the user
pushed for is the reason the checked binding is usable in a real-time loop at
all.

The struct-argument ABI got a real workout too: the window's `NSRect` (32 bytes,
stack), `CAMetalLayer setDrawableSize:` taking a `CGSize` (16 bytes, xmm pair),
and `replaceRegion:` taking a 48-byte `MTLRegion` on the stack — three
different SysV struct-argument classes, all correct through the same
function-pointer-cast path, none written by hand.

What a hand binding would have gotten wrong and this did not: the msgSend
variant per call, the register file for each scalar, the exact argument counts,
the struct-vs-scalar classification of three different geometry types, and the
retain/release balance of every autoreleased NSString built for a title or a
run-loop mode. The compiler checked all of it, and the app is ~450 lines with
no binding boilerplate.

### Colour: a Mojo kernel, not a shader

First cut coloured with a flat CPU ramp and looked muted beside the Windows
demo. The fix is the point of the whole exercise: the Windows version coloured
in an **HLSL pixel shader**; ours colours in a **Mojo kernel**. The escape
count and the Inigo-Quilez cosine palette (`0.5 + 0.5·cos(2π·(t + phase +
{0, ⅓, ⅔}))` per channel — three cosines a third of a cycle apart give a smooth
rainbow) are computed together in one kernel on the Vega II, packed to BGRA8,
and the loop just uploads the bytes. The phase drifts per frame so it shimmers.
Colouring on the GPU keeps the 2.4M cosines/frame off the CPU and the loop
stays at 60fps. So the entire pipeline — compute and colour — is Mojo compiled
to AIR; there is no shader anywhere, which is a step past the example it
answers.

## 2026-08-22 — MoE on the Vega II: a 30B that outruns an 8B, and a statistic that nearly lied

Qwen3-30B-A3B (Q4_K_M, 17.28 GiB, 128 experts / 8 active) runs on the Vega II,
and the result is better than the dense case on every axis:

```
                       prefill (pp512)   generation (tg64)
MoE 30B-A3B, Vega II        88.5              46.6
MoE 30B-A3B, Xeon          119.8              30.2
dense 8B,    Vega II        48.4              32.9
```

**A 30B model generating 1.4× faster than an 8B**, because only ~3B parameters
and 8 of 128 experts are active per token. It also nearly closes the prefill
embarrassment from the previous entry: the CPU's lead shrinks from 1.94× to
1.35×, since MoE prefill computes a sixteenth of the expert FLOPs and so
suffers far less from the mat-vec fallback.

The open question from the last entry was whether top-k routing — which runs
through `argsort`/`top_k`/`get_rows`, the wave64-suspect families — was
silently selecting wrong experts. Wrong routing does not crash or babble; it
produces fluent, subtly worse text. Perplexity against the CPU backend said:

```
Vega II : PPL = 23.4508      CPU : PPL = 23.2909      delta +0.69%
```

versus **+0.18% on the dense 8B control** — nearly four times larger, and in
the wrong direction. That looked like a hit.

**It was not, and how it wasn't is the lesson.** `llama-perplexity` prints
*cumulative* perplexity, not per-chunk. Read as per-chunk, the series shows a
+2.5% first chunk decaying monotonically to +0.69% — a tidy "error that
starts big and dilutes" story that is entirely an artifact of averaging.
Recovering the actual per-chunk NLL (`n·log(cumₙ) − (n−1)·log(cumₙ₋₁)`)
inverts the conclusion:

- the signs are **mixed** — the GPU is *better* on 3 of 12 chunks (−0.75%,
  −0.23%, −0.02%), where broken routing would be worse nearly everywhere;
- the mean per-chunk delta is +0.0068 NLL against a stdev of 0.0115, i.e.
  **t = 2.06, p ≈ 0.064**; the 9/12 sign split is binomial p ≈ 0.15;
- the largest single chunk is 0.85% NLL, where a wrong expert costs percent­s.

Two supporting checks: `TOP_K` and `ARGSORT` both pass at **`ne = 128`**,
exactly this model's expert count (445/445 and 97/97), and re-running the GPU
perplexity at a different `ubatch` returns a **bit-identical** number, so the
GPU path is deterministic and the delta is systematic rather than run noise.

Best explanation is expert flips on near-ties: when two of 128 experts score
within floating-point rounding, the two backends choose differently. Both
choices are legitimate. At ≤0.7% the residual sits below Q4_K_M's own ~1–3%
quantization cost, so it is immaterial — though p = 0.064 is not "proven
identical", and a 4× corpus would settle it if it ever matters.

**The transferable lesson is about instruments, not MoE.** A summary statistic
that aggregates — cumulative anything — will manufacture a monotone trend out
of a single early outlier, and a monotone trend reads as a mechanism. The
check that saved it was cheap: differentiate the cumulative series before
believing its shape, and look at the *signs* of the residuals, because noise
straddles zero and a bug does not. Worth applying to our own kernel timings,
which are reported the same way.

Practical outcome: Qwen3-30B-A3B Q4_K_M is now the default model on this box —
faster and more capable than the 8B, with ~14 GB of headroom left for context.

## 2026-08-22 — Correction: the MoE routing verdict, measured properly

The previous entry called the MoE perplexity gap "expert flips on near-ties" on the
strength of n = 12 chunks of an ad-hoc corpus, and said p = 0.064 was "no evidence
of a bug". Re-run on **wikitext-2, 80 paired chunks** for both models, the picture is
sharper and the earlier framing was too loose in both directions:

```
                        GPU        CPU      delta     paired t
Qwen3-30B-A3B (MoE)    9.6700     9.6356   +0.357%     +2.69
Qwen3-8B      (dense) 10.5178    10.5342   -0.156%     -2.59
```

**The deltas are systematic, not noise.** Both exceed |t| = 2, and the GPU number
reproduces bit-for-bit across a `ubatch` change, so the backend is deterministic and
genuinely differs from CPU. Saying "identical to CPU" on one perplexity number, as the
previous entry effectively did, is an over-claim.

**But it is still not a routing fault**, and the control is what settles it: the *dense*
model deviates just as significantly and in the **opposite** direction — the GPU is
slightly better there. A real routing fault would make MoE worse while leaving dense at
t ≈ 0. A sign that depends on the model is accumulated floating-point divergence, not a
broken argmax. The MoE magnitude being ~2× dense fits expert selection amplifying that
divergence through a discrete top-k over 128 near-tied scores.

Practically it is immaterial — 0.36% against Q4_K_M's own 1–3% quantization cost.

**Two lessons, both about measurement rather than GPUs.** First, `p = 0.064` at n = 12
was not "no effect", it was *no power*; at n = 80 the same effect is p ≈ 0.009. Reporting
an underpowered null as reassurance is how you set someone up for a fall. Second, and
worse: a *single-arm* measurement could not have distinguished "MoE routing is broken"
from "the two backends simply differ slightly". Only the dense control, run at equal
power on the same corpus, separates them — and it inverted the conclusion. The control
was the whole experiment; the treatment arm on its own was uninterpretable.

Fork README now carries the full table and the caveat rather than the earlier
"floating-point noise" line.

## 2026-08-22 — Tuning llama.cpp on the Vega II: three results, one cause

Chased the obvious speedups for Qwen on the card. The interesting part is that two of
them made things *worse*, and all three point at the same missing piece.

**Prompt prefix caching is already on, and dwarfs everything else.** llama-server keeps
per-slot KV and evaluates only the tokens you appended:

```
first turn, ~1460-token prompt   21.19 s
follow-up, same prefix            1.56 s
fully warm                        1.30 s      -> 13.6x
```

The server log confirms the mechanism rather than the timing: the follow-up evaluated 18
tokens, the warm repeat 1 (`n_past = 1479`). This immediately caught a bug in the chat
app's context trimming, written an hour earlier: it trimmed to *just* under the budget,
so once a conversation hit the limit it would trim on **every** turn, change the prefix
every turn, and invalidate the cache every turn — converting 1.3 s replies into 20 s ones
permanently. Now hysteresis: nothing until 70% full, then cut to 40%. **Any cache keyed on
a prefix turns "trim a little, often" into a pathology; trim rarely and in large steps.**

**KV cache quantization is harmful here** — the opposite of the usual advice:

```
KV f16    pp 48.1   tg 33.1
KV q8_0   pp 45.4   tg 14.1     -> generation -57%
```

Dequantising K/V inside attention costs more than the bandwidth it saves, because the
flash-attention kernels that normally absorb that cost are disabled on non-Apple7 GPUs.

**Speculative decoding is also a loss**, 25.1 → 15.3 t/s with a Qwen3-0.6B draft. The
diagnostic that matters is the acceptance rate: **0.65, mean accepted length 2.95**. That
is a *good* draft. So the draft is not at fault — verification is. Speculation's premise
is that checking K drafted tokens costs about one forward pass, which is only true with a
batched **mat-mul**. We have the mat-**vec** fallback, so verifying ~4 tokens costs ~4x,
and the draft model is pure overhead on top. n-gram speculation (no draft model at all)
landed within noise, consistent with the same explanation.

**All three trace to `has_simdgroup_mm` being gated on `MTLGPUFamilyApple7`.** It is not
just a prefill tax — it makes an entire class of optimisation unprofitable. That sharpens
the case from the earlier entry considerably: a wave64 `mul_mm` built on `simd_shuffle`
would unlock prompt processing *and* speculative decoding in one change, on top of the
2.37 TFLOP/s our own AIR matmul already demonstrates the silicon can do.

The methodological note, since it nearly cost a wrong conclusion again: the first pass at
these numbers grepped `eval time` out of the server log, which also matches `prompt eval
time`, silently interleaving prefill and generation figures in the same column. The values
looked plausible — that is precisely the danger. Anchor the pattern (`\|\s+eval time`)
rather than trusting a substring to be unambiguous.

## 2026-08-22 — Designing the Mojo Mac Playground (editor + REPL, no terminal)

The user's next ask: the lldb REPL is "remarkably un-Mac-like" — build a native
Cocoa editor+REPL in Mojo. Design written to `MOJO_MAC_PLAYGROUND_DESIGN.md`.
The research that shaped it:

**The engines already exist, open, in this tree.** `mojo-lsp-server` builds
(130 MB) and answers `initialize` with completion, hover, definition,
references, rename, document symbols, semantic tokens, signature help, inlay
hints and code actions — editor intelligence is free. `mojo-jupyter-executor`
builds: a persistent-state cell kernel (`MojoKernel::startExecution(cell,
expr, storeHistory)`) — the REPL engine behind Mojo notebooks. `lldb-dap` is
buildable from the vendored LLVM, and the in-tree `MojoLLDB` plugin's own docs
name lldb-dap as their primary integration target.

**The question "can a user work inside a running program?" conflates two
things**, and the design gives them separate engines behind one UI: a REPL
(persistent evaluation — the jupyter executor) and a debugger (stop, inspect,
evaluate in-frame — lldb-dap). Both are lldb's expression engine underneath,
which is *why* upstream's REPL is lldb; the un-Mac-like part was the terminal,
not the engine. Xcode is the precedent — lldb behind a Cocoa face.

**Cocoa → Mojo callbacks work** (`spikes/s5-cocoakb/callback_probe.mojo`): a
class allocated at runtime, `class_addMethod` with a Mojo `abi("C")` IMP, and
the database supplying the `v@:@` encoding. The first attempt failed for the
*right* reason — `send` refused my made-up `doAction:` because the database
doesn't know it — so the probe uses a real delegate selector. Every AppKit
selector the design needs resolves: the "missing" ones are on superclasses
(inheritance walk) or a private subclass (selector-keyed `send`).

**One honest open item.** The executor launches but never prints its prompt,
with or without the MojoLLDB plugin path wired — the signature of macOS's
debugserver/entitlement requirement for a non-Apple-signed lldb. Filed as P2
wiring with a fallback REPL (accumulate cells, re-run) that needs nothing.
The design is not blocked on it; P0+P1 (editor + run) use only `mojo run`.

## 2026-08-22 — Playground P0: Cocoa calls Mojo, and the real run loop

`spikes/playground/p0_window.mojo` passes unattended: a window, a button, a
label and a timer, with the app delegate's lifecycle, the timer tick and the
button action all **Mojo functions reached by Cocoa** — through
`std.objc.ObjCClassBuilder`, which allocates a class at runtime and adds
methods whose IMPs are Mojo `abi("C")` functions. For any selector the SDK
knows, the `@encode` type string is pulled from the database and its frame
offsets stripped (`v24@0:8@16` → `v@:@`), so a delegate method's signature is
never hand-typed; custom selectors pass `encoding=`. The app runs on
`[NSApp run]` — the genuine AppKit loop — and exits through
`applicationShouldTerminateAfterLastWindowClosed:` answering `True` from Mojo.

Two small primitives fell out that every Cocoa app in Mojo will want:
`named_global[name, T]()` — a zero-initialised process global callbacks can
reach (they get no closure), built on the KGEN named-global dedup from the
dispatch work — and `nsstring()` promoted into `std.objc`. Also a
`selector_encoding` query (majority `@encode` across implementing classes).

Verification is the `P0_AUTOCLOSE_TICKS` knob: the timer closes the window
after N ticks so launch → ticks → close → terminate runs headless. Next: P1,
the editor.

## 2026-08-22 — Playground P1: a Mojo editor, in Mojo

`spikes/playground/playground.mojo` is a working native editor: code pane over
output pane, Menlo on a dark ground, live syntax highlighting, ⌘R / ⇧⌘R (Vega
II) / ⌘. to stop, ⌘O / ⌘S, and a real menu bar. Running is an `NSTask` whose
pipes a 50 ms `NSTimer` drains on the main thread, so a program that hangs or
crashes cannot take the editor with it. `PG_SELFTEST=1` exercises the whole
thing headlessly.

**Three KGEN fixes fell out, all general.** `pop.extern_ptr_symbol` — the
link-time symbol reference that made dispatch 3 ns — needed two more repairs to
be usable beyond `objc_msgSend`: it emitted `dso_local=true`, which promises the
definition is in *this* image, so referencing a **dylib data symbol**
(`NSForegroundColorAttributeName`) produced direct rip-relative addressing the
linker rejects outright; and it only looked for an existing *global* of the
name, so a symbol already declared as a **function** (`read`, from an
`external_call` elsewhere) got a second declaration and the uniquer renamed one
of them into oblivion. Both now resolve to the single existing definition.
`extern_object[name]()` in `std.objc` reads Cocoa's extern constants on top of
that.

**And a fourth lesson that is not a compiler bug:** file I/O in the app goes
through Cocoa (`writeToFile:atomically:encoding:error:`,
`stringWithContentsOfFile:encoding:error:`) rather than stdlib `open`. That
sidesteps a `read` symbol collision *and* is the idiomatic call in a Cocoa app —
the same "use the platform's own API" instinct that made the Mandelbrot colour
in a Mojo kernel instead of a shader.

### Two bugs the user found, both about being *seen*

- **UTF-8 vs UTF-16.** The tokenizer emits byte offsets; `NSTextStorage` ranges
  are UTF-16 code units. They agree for ASCII, which is why it looked perfect
  for a moment — and the starter text has `⌘R` in a comment, so every range
  after that glyph pointed past the end: `NSRangeException`, instant abort.
  Fixed with a byte→UTF-16 offset map (astral characters counting 2 for the
  surrogate pair) and taking the length from `NSString length`, not the byte
  count.
- **Invisible output.** `setTextColor:` on the text view does nothing for text
  appended through the storage's `mutableString` — appended text carries *no*
  attributes and renders default black, invisible on the dark ground. The
  program had been running correctly all along; the user simply could not see
  `sum of the first million integers: 499999500000`. Each appended range is now
  coloured explicitly, which gave colour-coding for free: blue command echo,
  light output, grey/red exit status.
- Also filtered: the SDK's benign `Failed to initialize Crashpad` notice. I have
  been `grep -v`-ing it out of every terminal command all session; in an output
  pane it is the most prominent thing on screen and reads exactly like a crash.
  Noise you have learned to ignore is not noise to a user.

## 2026-08-22 — Python interop: the system Python was too old

A stock example (`mojo/examples/life/lifev2.mojo`, Conway's Game of Life drawn
with pygame) aborted with `symbol not found: Py_NewRef`. Nothing to do with the
fork: **`Py_NewRef` arrived in CPython 3.10 and macOS ships 3.9**, so
`std.python` cannot resolve it against the system interpreter. Worth noting
because the error names a symbol, not a version, and reads like a port gap.

Fixed by pointing Mojo at a newer interpreter, wired into `vega-sdk/bin/mojo`:
Homebrew `python@3.12` (3.12.14 — `Py_NewRef` confirmed present with `nm`),
`MOJO_PYTHON_LIBRARY` → its framework `libpython3.12.dylib`, `PYTHONHOME` →
that framework, and a venv at `vega-sdk/pyenv` on `PYTHONPATH`. Every one of
those defers to an existing value, so pointing at a different interpreter needs
no edit.

The venv is not fussiness: Homebrew's Python is PEP 668 externally-managed and
refuses `pip install`, so it is either a venv or `--break-system-packages`.
Gitignored, with `vega-sdk/python-requirements.txt` (pygame, numpy) to rebuild
it; the README carries the recipe.

Verified before the demo — `sys.version` 3.12.14, numpy arrays round-tripping,
pygame importing — then the Game of Life ran: green cells evolving in a pygame
window, driven from Mojo on the Intel Mac.

## 2026-08-22 — A Cocoa Game of Life, and two lifetime traps

The pygame example runs now, but it is a poor demo: no pause, no drawing, one
colour regardless of a cell's history. `spikes/life/life.mojo` is the Cocoa
answer — pause/resume and single-step, draw with the mouse (erase with shift or
the right button), clear, randomise, speed control, live stats in the title —
and cells **coloured by age**: newborns burn white, survivors cool through cyan
and green to deep blue, and dead cells leave a fading ember. A glider reads as
a bright head with a warm tail; a still life sits quiet and blue. The view is
an `NSView` subclass defined at runtime whose mouse and key handlers are Mojo
functions; rendering is a BGRA blit into a `CAMetalLayer` drawable.

**Two crashes, both about lifetime, both instructive.**

`autorelease pool page corrupted` came from an early `return` *inside* a
`with autoreleasepool():` block — the pop never ran, so the pool stack
desynchronised. Restructured to one pool per tick with no early exit, and
`__exit__` is now idempotent so a double pop cannot corrupt the page.

The second was subtler and is a genuine Mojo trap. The stack showed
`String::_add` → `tc_memalign` → SIGSEGV: heap corruption surfacing in the
allocator, far from its cause. The real bug:

```mojo
var alive = List[UInt8](length=CELLS, fill=0)
g_alive()[] = Int(alive.unsafe_ptr())   # last use of `alive`
```

**Mojo destroys a value at its LAST USE, not at end of scope.** The `List` was
freed the instant its pointer was stashed, so every buffer dangled; the app ran
for seconds looking healthy and then died allocating a string. Fixed by owning
the buffers outside Mojo (`calloc` through the extern-symbol cast), which makes
the lifetime explicit. Worth remembering for any long-lived buffer whose raw
pointer outlives the expression that produced it — exactly what a callback-based
UI needs.

`ObjCClassBuilder` gained a `superclass` struct parameter (so
`ObjCClassBuilder["NSView"]("LifeView")` works) and an `IMP0Bool` shape for
zero-argument predicates like `acceptsFirstResponder`.

## 2026-08-23 — The wave64 mat-mul lands: prefill 3.4x, and a compiler bug underneath

The gap named in the two previous entries is closed. `llama.cpp` on the Vega II now has a
mat-mul, and prompt processing is transformed:

```
                        before        after
Qwen3-8B    pp512      48.4 t/s    162.9 t/s   (3.4x)
            pp2048     45.3        156.7       (3.5x)
Qwen3-30B   pp512      88.4        179.2       (2.0x)
  -A3B      pp2048     76.4        172.2       (2.3x)
generation  (both)     unchanged
```

**The GPU now beats the 24-thread Xeon at prompt processing** (93.9 t/s), reversing the
embarrassment recorded earlier, and the partial-offload advice that existed only because the
CPU was faster is retired — `-ngl 99` now wins on both axes.

`kernel_mul_mm_w64` is deliberately unremarkable: a register-tiled GEMM with **no matrix
intrinsics**, so the 64-wide wavefront is used as 64 independent lanes. 64x32 output tile,
K stepped in 32s, 4x2 accumulators per thread in registers, A and B staged k-major so the
inner loop reads four rows as one `half4` and two columns as one `half2`. Shared memory is
byte-identical to the kernel it replaces, so the host allocation never changed. It reaches
**~2.67 TFLOP/s, ~19% of the card's fp32 peak** — slightly ahead of the 2.37 TFLOP/s our own
naive tiled Mojo kernel hit, which is a satisfying cross-check between the two projects.

**The interesting part is the MoE variant, which was wrong for a long time.** The failure
signature was maddening: output correct up to token 127 and garbage from token 128 onward,
identical whether the model had 2, 4, 8 or 16 experts, independent of matrix size, and
independent of which tile or which expert owned that token. Every hypothesis it suggested —
partial tiles, tiles-per-expert, an undercounted `tokens-per-expert`, a grid that stopped
early — was tested and killed.

The cause was not in the kernel logic at all. **AMD's Metal compiler miscompiles
`uint64_t * short`**, placing the short operand in the high word:

```
args.nb12 * i12        // i12 is a short holding 128
  -> 4398046511104     // nb12 << 32, not nb12*128 == 131072
args.nb12 * (int)i12   // correct
```

The B pointer therefore pointed far outside the buffer and the tile multiplied uninitialised
memory. 128 is simply where a `short` index first pushes the miscompiled product beyond
anything the allocation covers — which is why the boundary looked like a tiling artefact and
was nothing of the sort. The dense kernel was immune only because it happened to use `int`
throughout. Fixing it is a two-word change; finding it was not.

**What actually found it was refusing to keep theorising.** A standalone reproducer that runs
the same graph on CPU and Metal and diffs per column, with hand-built id patterns, converted
a vague "one column in n is wrong" into a precise question. Then, in order: a constant-write
probe showed the column *was* being written, with zero; an end-of-kernel probe showed the
suspect threadgroups ran to completion with correct bounds; an in-kernel dump showed the ids,
strides, column and offset were all correct. That left one contradiction — `src1[32768]`
read 0.5 while `y[0]` read NaN *at the same address* — and comparing four addressing forms
in-kernel isolated the miscompile in a single run.

Two lessons, both about method rather than GPUs. First: **when every input to a computation
is verifiably correct and the output is still wrong, stop trusting the language and start
testing the code generator.** Second, less comfortable: two of my confident intermediate
conclusions ("`neh1` is undercounted", "tiles beyond four never launch") were artefacts of my
own instrumentation — debug writes clobbered by the kernel's real output, and a `grep` that
counted verdict lines mangled by interleaved pipeline-compile messages. Bad instruments
manufacture facts, and they do it most convincingly when you are already deep in a hunt.

Correctness, since none of this counts otherwise: `MUL_MAT` passes 2129/2163 (all 34 failures
being pre-existing `iq2_xxs` breakage on the mat-vec path), `MUL_MAT_ID` passes 1087/1087,
and wikitext-2 perplexity over 80 chunks is 9.6627 against 9.6356 on CPU — marginally closer
to the reference than the mat-vec path it replaced.

Still open, and now precisely characterised: **speculative decoding remains a ~40% loss even
with mat-mul available.** Not draft quality (acceptance 0.60-0.65, mean accepted length ~2.8),
and not the missing mat-mul. Throughput simply does not improve at the batch sizes speculation
produces — 1.13x at batch 4, against 2.99x at 32 and 4.88x at 128 — so verifying a 3-token
draft costs nearly three full passes and the draft model is pure overhead. The mat-*vec*
kernels still run at roughly 16% of the card's memory bandwidth; making that region efficient
would speed up generation directly *and* make speculation profitable. That is the next piece
of unclaimed performance, and it is a bigger one than the mat-mul was.

## 2026-08-23 — Generation +27%, from a constant that was tuned for the wrong wave

Prefill was the loud problem, so it got the mat-mul. Generation turned out to have a much
cheaper win sitting in a `#define`.

The diagnosis came from measuring each mat-vec kernel against the card's ~830 GB/s copy
ceiling rather than against itself:

```
f32   675 GB/s   81%          q4_K   219 GB/s   26%
f16   654 GB/s   79%          q6_K   191 GB/s   23%
q4_0  428 GB/s   52%          q5_K    90 GB/s   11%
```

**That table is the whole diagnosis.** The float kernels nearly saturate the card, so the
memory path, the dispatch and the wave64 work distribution were all fine — only the
*quantised* kernels were starved. A single measurement against an absolute ceiling separated
"the GPU is slow" from "these particular kernels are slow", which no amount of comparing our
numbers to our own earlier numbers would have done.

The cause is `N_R0_*`: how many src0 rows one simdgroup accumulates, which sets how far the
activation-vector load is amortised. The stock values are tuned for 32-wide Apple waves, and
the correlation was already sitting in the numbers above — q4_0 has `nr0=4` and reaches 52%,
q4_K has `2` and reaches 26%, q5_K has `1` and reaches 11%. Raising it to 8:

```
q4_K  219 -> 369    q2_K  123 -> 216    q5_0  344 -> 395
q5_K   90 -> 139    q3_K   92 -> 129    q4_0  428 -> 460
q6_K  191 -> 208
```

End to end: **dense 8B generation 33.2 -> 42.0 t/s, MoE 46.4 -> 49.9.** Perplexity is
bit-identical at 10.5168, which is what you want from a change that only redistributes work.
The constants are keyed on the probed wave width rather than replaced, so Apple GPUs keep
their tuning — `N_SIMDWIDTH` is already injected at shader-compile time and the host picks the
matching variant.

Two results worth carrying forward. **`nsg` does nothing** — 1, 2 and 4 simdgroups give
369/368/368 GB/s — so the entire effect is `nr0`, and an hour spent tuning `nsg` would have
been an hour wasted. And **`nr0` is non-monotonic**: 8 is optimal, 16 and 32 are both worse as
register pressure starts to cost more than the amortisation buys. A hill-climb from the stock
value would have found it; an assumption that "more is better" would have overshot badly.

**A methodological note, because this bit me twice in one session.** My first parameter sweep
returned four identical results for four different configurations. The cause was zsh: `set --
$cfg` does *not* word-split an unquoted parameter the way bash does, so every configuration
built the same binary and I was reading one number four times. It looked like a clean "this
parameter has no effect" result. The only reason I caught it is that the numbers were
*suspiciously* identical rather than merely close. Sweeps need a check that the thing under
test actually changed — I now dump the patched constants alongside each result.

Also re-measured everything the tuning invalidated rather than leaving stale figures in the
docs: KV quantisation is still harmful and now costs 61% of generation, and speculative
decoding got **worse** — throughput at batch 4 is now 0.92x of batch 1, because single-token
decode sped up 27% while small batches did not. Faster scalar decode makes speculation less
attractive, not more.

And the concurrency question was re-opened honestly: it was plausible that the
nondeterministic garbage which forced serial dispatch had really been the broken wave64
kernels, all of which are now fixed. It was not. With concurrency forced on, three identical
greedy runs still produce three *different* wrong answers. `memoryBarrierWithScope:` is simply
not enforced between concurrent dispatches on this driver; serialisation stays, at ~6%.

Where the card now stands, against where it started:

```
                   prefill            generation
dense 8B       48 -> 163 t/s        33 -> 42 t/s
MoE 30B-A3B    88 -> 175 t/s        46 -> 50 t/s
```

The remaining gap in generation is **~2x and is a memory access pattern, not a constant**.
q4_K now reaches 44% of the card's bandwidth against ~80% for f16. A K-quant super-block
scatters quants, high bits and packed scales across 144 bytes and eight threads read different
fields of it, where f16 reads contiguous `half4x4`. Closing it means loading blocks
cooperatively before dequantising — a kernel rewrite, and the next real piece of work here.

## 2026-08-23 — Eight models, a load-width defect, and being wrong about quantisation

Broadened the testing beyond Qwen to see what the Metal work actually holds up against.
Eight model/quant combinations, four architectures, dense and MoE, each checked against the
**CPU backend on identical text** rather than eyeballed:

```
Gemma-4-26B-A4B (MoE) QAT Q4_K_XL  13 GB   241 / 49 t/s    vs CPU -1.56%
Qwen3-30B-A3B   (MoE) Q4_K_M       17 GB   179 / 52        vs CPU +0.28%
gpt-oss-20b     (MoE) MXFP4        12 GB   231 / 62        vs CPU -0.02%
Qwen3-8B              Q4_K_M      4.7 GB   162 / 47        bit-identical
Gemma-3-12B           Q6_K        9.7 GB   127 / 21        vs CPU +0.01%
Llama-3.1-8B          Q8_0        8.5 GB   176 / 32        vs CPU -0.00%
Llama-3.2-3B          Q5_K_M      2.3 GB   317 / 54        vs CPU -0.00%
Llama-3.2-3B          f16         6.4 GB   426 / 59        vs CPU -0.00%
```

Everything works, including Gemma 3's interleaved sliding-window attention and Gemma 4's
dual head dimensions. **Generation tracks active parameters, not model size** — the three
MoE models take the top of that column despite being the largest.

**A load-width defect, found by a diagnostic worth reusing.** Gemma-3-12B Q6_K generated at
only 15 t/s, and profiling each kernel against the card's ~830 GB/s ceiling showed why: f32
and f16 reach ~80% of it, q4_K 44%, q5_K 11%. The question was whether the K-quants were
ALU-bound or memory-bound, and the way to settle it was to **delete the arithmetic**:
stripping almost everything out of the q5_K inner loop while leaving every load in place made
it **2.5% faster**. A kernel that does not care whether you remove its maths is not
ALU-bound. Comparing with q4_K then showed the difference plainly — q4_K reads quants as
`uint16_t`, q5_K and q6_K read them as `uint8_t`: twice the transactions at half the width.
Converting both gave 139 → 206 and 208 → 328 GB/s, and Gemma-3-12B went 15.0 → 20.6 t/s with
bit-identical perplexity.

**And then I was wrong about something, in a way worth recording.** Gemma 4 scored a
perplexity of ~17000 where Gemma 3 scored 8.9, on the same corpus. Alban suggested the
quantisation-aware build; I argued against it, reasoning that quantisation moves perplexity
by fractions of a percent and could not possibly account for a 1900x gap, and went looking
for a backend or architecture fault instead. I ruled out — carefully and correctly — the
tokenizer (byte-identical to Gemma 3, same vocabulary), BOS handling, missing architecture
support, context length (broken at 128 through 2048 alike), and our own Metal code (the CPU
path shows it too). All true, all beside the point.

The QAT build scores **777 instead of 16097**, and is *smaller and faster* as well: 13 GB
against 16, and 49 t/s against 39. The alarming +11% GPU-vs-CPU gap I had been chasing as a
possible backend bug collapsed to −1.56% with better weights.

The mechanism is one this journal already contains, and I failed to connect it. **An MoE
router is a small tensor making a discrete decision about which experts fire.** Quantisation
error there does not perturb an output slightly; it changes which weights are used at all.
That is the same near-tie sensitivity recorded a few entries ago when explaining why MoE
greedy decoding diverges faster than dense — I had the mechanism, applied it to numerical
noise, and did not think to apply it to quantisation. Dense models have no equivalent
pressure point, which is exactly why the intuition I was reasoning from did not transfer.

**Rule: for MoE, prefer a QAT build or go up a quantisation level. And when an MoE model
scores far worse than expected, suspect the weights before the backend.**

Two smaller notes. `-no-cnv` no longer suppresses the chat template — it was removed as a
CLI flag upstream — which is why Gemma 4 generated coherently throughout while scoring raw
text catastrophically; the two go through different paths, and it hid the problem for a
while. And a round of kernel measurements was silently corrupted by a colleague using the
same GPU: the untouched q4_K control appeared to lose 64% of its bandwidth. Without a
control in the same run it would have read as a catastrophic regression in code I had not
touched. Every performance table since carries one.

## 2026-08-24 — Cross-pollination: the sibling port found bugs in our AIR layer

[MojoCocoa](https://github.com/albanread/MojoCocoa) took this fork's AIR backend
to Apple Silicon. Different hardware, **same intermediate representation** — so
the encoding and legalisation findings transfer wholesale even though the
hardware-specific work correctly diverges. Ported here, each re-verified on the
Vega II.

**Symbol names we had wrong**, read off Apple's own compiler rather than
guessed:

- **`air.simd_prefix_sum` does not exist.** AIR spells them
  `air.simd_prefix_exclusive_sum` / `..._inclusive_sum`. Wrong in *both* our
  stem lists.
- **There are no 64-bit simd-group ops at all** — MSL rejects them, so `.u.i64`
  named a symbol AIR does not define. Ballot is the exception and is
  unaffected: the stdlib emits `air.simd_ballot.i64` fully suffixed, so it
  never reaches the mangler, and its width correctly follows the SIMD width.
- **Integer min/max cannot be mangled at all.** AIR carries separate `.s.` and
  `.u.` symbols; an LLVM integer is signless. `.u.` is sound for
  sum/product/shuffles (two's complement makes both compute identical bits) and
  wrong for min/max — `min(-1, 5)` is `-1` signed, `5` unsigned. Now a
  diagnostic rather than a silent wrong reduction.

The reason those are so expensive: **a symbol AIR does not define is diagnosed
nowhere.** It survives `metal -x ir -c` *and* `metallib`, then kills the
driver's compiler service at pipeline creation with
`XPC_ERROR_CONNECTION_INTERRUPTED` — the same symptom as a dozen unrelated
defects, and one we burned hours on. A stem that needs a suffix and cannot get
one is now a compile error.

**Invalid IR the AIR reader was tolerating:**

- `dso_local` was cleared on *every* function, but LLVM requires local linkage
  to imply it. Every internal helper carried invalid IR.
- Overloaded memory intrinsics encode address spaces **in the name**
  (`llvm.memcpy.p0.p0.i64`); retyping an argument to `addrspace(1)` left the
  call disagreeing with its own callee. Now re-resolved after retyping.
- Same-address-space `addrspacecast` is invalid outright and metallib rejects
  the *whole module* for one — exactly the bug that cost us a round during
  capture hoisting. Now dropped as a safety net.

**An ordering mistake that had caused three separate defects over there:**
inlining ran *after* legalisation, so every legalisation pass reasoned about a
module that was about to change shape — deviceization never saw the callee
bodies the inliner brought in. AIR has no call stack and Metal kernels are
fully inlined regardless, so inlining first costs nothing and the question
stops arising. Moved to the top of `legalizeModule`.

**And hoisting only ever caught the first pointer.** It matched an
`extractvalue` whose aggregate was *directly* an `Argument`, but a descriptor
blob holding several tensors is a struct of structs — the frontend pulls the
per-tensor struct out first and the pointer out second. Whichever pointer
happened to be unpacked in one step got hoisted; the rest stayed generic. The
walk now follows the chain back to the root parameter.

**A gate so the class cannot recur silently:** the LLVM verifier now runs
before emission (`VEGA_AIR_NO_VERIFY=1` downgrades it). It passed everything
first time, which is the good outcome — it says our IR was already valid, not
that the gate is useless. Over there, adding the same gate immediately cost two
passing tests and then named exactly what was wrong with them.

### Where the two ports genuinely diverge

Worth stating, because it is the interesting part of "same IR, different
silicon":

| | Vega II (here) | Apple Silicon (there) |
|---|---|---|
| captured device pointers | **hoisted** to real buffer params — AMD needs a bound resource descriptor | hoisting **removed**; it burned one of 31 buffer slots per pointer |
| reaching a raw address | `addrspacecast`, to keep the provenance `getPtrRsrcId` needs | `inttoptr` — AIR has no generic space and Apple's own compiler uses it; our cast "silently wrote zeroes" there |
| SIMD width | 64 | 32 |
| memory | discrete, staging blits | unified, plain `memcpy` |
| generic pointer | crashes the compiler service — loud | reads zero — silent |

That last row is the one to remember. The same defect is a hard crash on AMD
and an invisible wrong answer on Apple silicon, which is why their tree needed
a legality firewall to find what ours finds by falling over.

Still on the table from their tree: the data-driven legality firewall
(`AirLegality.cpp`, rules tiered by evidence — measured / air-poc / unproven,
with per-rule permit/log/fail), routing int↔float casts through `air.convert`,
and binding from the kernel's argument contract via pipeline reflection rather
than classifying argument values — which is the durable fix for the heuristic
already flagged as a wart in `VegaRTMetal`.

## 2026-08-24 — The largest model that fits, and a quant that got faster by getting bigger

Alban asked what the largest model this 32 GB card can hold actually is. Worth answering
with arithmetic rather than folklore, so: Metal reports `recommendedMaxWorkingSetSize =
34343 MB` — exactly 32 GiB — and `hasUnifiedMemory = false`. Because the 580X drives the
display, the Vega II pays no framebuffer tax and all of it is available to compute.

Weights, KV cache and ~1.5 GiB of compute buffer share it. At the bits-per-weight our own
files imply (Qwen3-30B-A3B is 17.3 GiB for 30.5B = 4.54 bpw) that leaves ~29.5 GiB of
weights: about **52B at Q4_K_M**, 37B at Q6_K, 30B at Q8_0. Two things bound it further —
`Q2_K` destroys an MoE router, and the IQ family, which is how everyone else crams 70B into
32 GB, is broken on this card. That escape hatch is closed to us.

One measurement I did not expect: **KV cache varies 9x between architectures we already
run** — 48 KiB/token for gpt-oss-20b, 96 for Qwen3-30B, 384 for Gemma-3-12B, 420 for
Gemma-4-26B. Both Gemmas use sliding-window attention so the real allocation is a fraction
of the naive figure, but the shape of the model, not just its size, decides how much context
you can afford.

**Then the result that inverted the intuition.** We pulled Qwen3-30B-A3B at Q6_K to see what
the extra headroom buys. I predicted, in writing, that prefill would be roughly flat and
generation would drop to 38-42 t/s. Both wrong:

| Qwen3-30B-A3B | Q4_K_M | Q6_K |
|---|---:|---:|
| size | 17.3 GiB | 23.4 GiB |
| prefill | 176.8 | **207.5** (+17%) |
| generation | 50.9 | 46.7 (−8%) |
| perplexity (24 chunks) | 8.659 | **8.284** (−4.3%) |

The larger quant is *faster at prefill* and better in quality, for 8% of generation. The
likely mechanism: q4_K packs its scales as 6-bit fields needing per-sub-block unpacking,
while q6_K uses plain 8-bit scales. Since we already established these kernels are not
ALU-bound, reading more bytes while doing less work per byte is the better trade. It also
explains why q6_K gained more from the 16-bit load change than q4_K did. **Rule: on this
card, if the VRAM is free, take the higher quant.**

**A near-miss worth recording.** Before benchmarking I noticed the binaries were timestamped
84 minutes *earlier* than the last `ggml-metal` commit. This build has
`GGML_METAL_EMBED_LIBRARY=ON`, which compiles the shader source into the executable — so a
stale binary silently runs stale kernels with no warning at load time. I rebuilt (43 s) and
re-measured Gemma-3-12B: 20.44 t/s against the published 20.6, and far above the pre-fix
15.0, which proved the published figure was sound. But the check was worth doing, and the
general point stands: **when shaders are embedded at build time, staleness is invisible at
runtime.** Timestamps are the only warning you get.

The same discipline applied to the comparison itself. The Q4 baseline in the README was
measured on the older binary, and its perplexity used 80 chunks against Q6_K's 24 — so the
two absolute figures were never comparable. Re-ran Q4 on the current build at 24 chunks
before believing anything. The README's perplexity column now carries an explicit **n**,
because it had been quietly mixing both.

## 2026-08-24 — A retraction, and finding out we were not alone

Two things today, one of which is me taking something back.

**Q6_K is genuinely the better model, and now it is measured.** Alban's instinct that the
higher quant might be a quality improvement was right, and my first attempt to check it was
too weak to say so: a single 24-chunk run gave a 4.3% perplexity gain against a ±0.34 error
bar, which is nearly the size of the difference. But that bar is the *unpaired* one, and
both models scored identical text. Differentiating the cumulative series back into per-chunk
NLL and running a paired test over 80 chunks:

```
Q4_K_M 9.6627   Q6_K 9.1957   (-4.83%)
mean paired diff +0.0495 +/- 0.0050 nats/chunk
paired t = +9.84 on 79 df,  Q6_K ahead on 68/80 chunks
```

About ten standard errors. Worth remembering how much power was hiding in the pairing —
the unpaired bar said "maybe", the paired test says "certainly". Same data.

**The retraction.** I explained the Gemma 4 mystery with a mechanism I did not verify: that
an MoE router is a small tensor making a discrete choice, so quantisation error there flips
which experts fire. It reads well, it connects to the earlier expert-flip analysis, and it
is wrong for these files. Reading the tensor tables out of the GGUFs directly:

- the router (`ffn_gate_inp`) is **F32 in every build we have** — these quantisers never
  touch it;
- the Gemma 4 build that scores **21x worse** carries **higher** precision nearly everywhere
  (`Q8_0` attention/output/embeddings against the good build's `Q4_0`).

Precision is not the variable. I had a plausible story and reached for it instead of opening
the files, which took about ninety seconds once I finally did. The empirical advice — prefer
QAT, measure perplexity before trusting a build — was arrived at by measurement and stands;
the explanation is withdrawn from the README, the journal and the memory. Also worth saying
plainly: 777 is itself a terrible score next to Gemma-3-12B's 8.94, so *both* Gemma 4 builds
are anomalous and the real question may be about Gemma 4 support upstream, on every backend.

**And we were not alone.** Alban asked me to look up "tosh", who turns out to be Engelbert
Delgado and whose ToshLLM has been doing this same port for months — a native Intel-Mac AMD
app over a patched llama.cpp, 143 stars, actively developed. His patch series independently
contains: wave64 reductions and mat-vec, a register-tiled GEMM without `simdgroup_matrix`,
the MoE `_id` variant of it, q6_K word loads, rows-per-thread tuning for wave64 including
the `_id` case, device identity selection, and a buffer allocation guard. That is our commit
log with different filenames. Two people, no contact, same hardware, same defects, in nearly
the same order — which is the strongest confirmation yet that these are properties of the
platform and not quirks of this machine.

He is ahead on four things worth naming: flash attention on AMD (we pinned FA to 32 lanes
and moved on), multi-GPU dispatch (which for a Vega II *Duo* means 64 GB and rewrites the
"largest model" answer entirely), a quantised KV cache, and proper mmap residency where we
merely worked around it with `-lm none`.

His licence is **GPL-3.0**, ours is MIT. So we cannot take his code — but equally, nobody
else can: not a commercial product, and not upstream llama.cpp, which is MIT and cannot
accept GPL-3.0 patches. Ours is the only one of the two that can ever go upstream. That is a
real difference in what the two projects can become, not a consolation.

The thing I most want from him is not code but an **instrument**. He extracts GCN ISA from
the compiled metallib and tabulates per kernel `instr narrow loads ds mac vgpr th_max smem`
— one of those columns is literally `narrow`. He built a measuring device for exactly the
defect class we found by hand in q5_K and q6_K. Our "delete the arithmetic and see if it
gets faster" trick was a clever substitute for not having this; with ISA dumps we would have
*seen* the `uint64 x short` miscompile as instructions rather than inferring it from wrong
output. Techniques are facts, not expression. That one is worth building ourselves.

## 2026-08-24 — Second pull from the sibling: two silent wrong-answer bugs

Twelve new commits over there; four mattered here. The two headline ones were
**silent wrong answers**, not crashes — the class this fork is worst at finding,
because nothing falls over.

**Barriers were being CLONED.** Our `air.wg.barrier` declaration carried no
attributes; Apple's carries `convergent mustprogress nounwind willreturn`.
Without `convergent` the optimiser believes the call has no cross-thread
meaning and may sink, hoist or duplicate it across divergent control flow.
Loop unswitching specialises a loop body per predicate, and a tiled kernel's
guards (`row < M`, `col < N`) are per-lane — so on a **ragged tile edge** each
specialised copy got its own barrier, lanes taking different branches reached
*different barrier instances*, and the threadgroup never synchronised.

Reproduced here before fixing, on a 100×100×64 tiled matmul:

| | barrier calls | `.us` unswitch blocks | wrong values |
|---|---:|---:|---:|
| before | 9 | 5 | 24 |
| after | 2 | 0 | 0 |

The attribute must be set **where the declaration is created**, in
`AirLowering` — not in the object backend, where we set nothing at all. It only
does anything if it is present when the optimiser runs; afterwards you get an
emitted module that looks correct and is useless.

Our own exact-dimension matmul was correct *by luck*: 1024 divides by 16, so
there is no ragged edge, no divergent predicate, and nothing for the unswitcher
to specialise. It would have broken the first time anyone used a ragged size.
`spikes/matmul/ragged_matmul.mojo` is now the regression test.

**`llvm.vector.interleave2` is an unresolved external.** It comes from our own
stdlib (`SIMD.interleave`), but the LLVM-17-era AIR reader knows the construct
only as `llvm.experimental.vector.interleave2`. Measured here: *"SC compilation
failure: There is a call to an undefined label"* at pipeline creation. Expanded
to `shufflevector` in the downgrade pass, alongside freeze/fneg/GEP-flags —
same family, a construct newer than the reader.

**A caveat on my own previous commit.** The reflection discriminator I ported
(`bufferDataType == MTLDataTypeNone` ⇒ device pointer) only means that for *our*
compiled AIR, which declares device parameters with an opaque pointee. An **MSL**
kernel declares `device float *`, so Metal reports `Float/4` for a parameter
that is very much a buffer — same API, opposite meaning. Our `loadFunction`
accepts MSL source, so the contract is now recorded only for MTLB containers.
Their tree hit this as a broken saxpy smoke test; we caught it by reading their
follow-up rather than by breaking.

Not applicable to us, checked rather than assumed: their `$<hash>` signature-tag
bug (we mangle by type suffix, and our modules carry no `$` at all), and the
Apple capability/core-count work.

### The pattern worth naming

Every fix this round followed the same shape, and it is the one to keep using:
**reproduce on our own hardware first, then fix, then show the before/after
numbers.** The barrier bug was a paragraph in someone else's commit message
until it was 24 wrong values in our own matmul; after that it was obvious. A
port that trusts the other tree's diagnosis skips exactly the step that tells
you whether the bug is yours.

### Postscript, same day: the head-to-head

Downloaded his release (checksummed against his published SHA-256; note that `curl` sets no
quarantine flag where a browser would, so nothing needed bypassing) and found he ships
`llama-bench`, `llama-perplexity` and `test-backend-ops` inside the app bundle. So a clean
comparison was possible: same model file, same flags, same idle card.

| Qwen3-30B-A3B Q4_K_M | prefill | generation |
|---|---:|---:|
| ours | 176.8 ± 3.9 | 50.9 ± 0.04 |
| ToshLLM v0.85.7 | **615.5 ± 12.6** | 53.3 ± 0.7 |

**His prefill is 3.5x ours.** In FLOP terms his GEMM reaches ~29% of the card's fp32 peak on
this model against our ~8.5%. Generation is level within 5%, which says the mat-vec work —
rows-per-simdgroup, the 16-bit loads — landed properly, and that the whole remaining gap is
in `mul_mm`. Earlier I wrote in the field guide that "~19% of peak is reachable from an
ordinary tiled kernel with no vendor intrinsics"; that stands as a floor, but 29% is now the
demonstrated number to chase, and our MoE path is well below even our own dense figure.

Two smaller things from his binary, both facts rather than code. His build defaults to
device 0 — the 580X — exactly the trap we hit, and needs `GGML_METAL_DEVICE_LIST=all` before
the Vega II appears at all. And his startup prints `wave64 mode: GPU prefill matmul, CPU
decode/reductions for correct output`, with a per-type allowlist for what may run mat-vec on
the GPU. That is a more conservative posture than ours: where he allowlists what is proven
and falls back to the CPU otherwise, we repaired the kernels so every K-quant runs on the
card. Different risk appetite, and his is arguably the wiser one for shipping software.

Alban's call on what to do about it was to be generous: point users at ToshLLM for the
better and more complete application, link him prominently, and state our independence
plainly rather than defensively. That is now the top section of the README. It is the right
thing on the merits — his is better, and saying so costs nothing true — and it is also the
strongest possible answer to anyone who later notices how similar the two patch sets are.
The dates are public and checkable; being the ones who raised it is worth more than any
argument made afterwards.

### Two more, from finishing the accounting properly

I nearly stopped after the barrier and interleave fixes. Going back through
their remaining commits one at a time turned up two more that were ours as well.

**The dead-declaration divergence.** They measured a dead `llvm.*` declaration
— declared, never called — as fatal on its own. I reproduced it here before
porting the fix, and got the opposite: after the interleave expansion our module
still declares `llvm.vector.interleave2.v8f32` with no call anywhere, and it
compiles, links and runs. So the two machines are strict about *different*
things: AMD gives a real sentence for the unresolved call and forgives the dead
declare; Apple gives nothing for either and forgives neither. We erase the
declaration anyway — it is unused by definition, and leniency measured on one
driver build is not a property to depend on.

**A truncated ABI symbol, which we did share.** The runtime defined
`AsyncRT_cuda_tensorMapEncodeIm`; Mojo calls `AsyncRT_cuda_tensorMapEncodeIm2col`.
A link failure waiting for the first build that reaches the im2col TMA path,
invisible only because nothing we build gets there yet.

`tools/check-abi-symbols.py` now checks parity both ways — 121 called, 125
defined, 4 unused — and regenerates the capability table in ABI-NOTES.md, which
until now was a flat list of 137 names that said nothing about what any of them
*does*. 69 of 125 implemented; the rest are honest stubs.

Three things that only showed up by building it:

- The **call** scan must be multi-line — their trap, and real here too: a
  same-line grep finds **14 of 121** and reports success.
- The **definition** scan must be multi-line as well, which they did not hit.
  clang-format wraps the return type onto its own line, so `extern "C"` and the
  symbol are never on the same line. My first regex reported **34 false missing
  symbols**, including ones that plainly link today. A checker that cries wolf
  34 times is worse than no checker, and I would have shipped it if I had not
  looked at the list and thought "that cannot be right".
- The generator ate its own marker and could only run once. Caught by running
  it twice.

The pattern from the last entry held for all of it: **reproduce here first.**
Two of the four findings this round changed shape on contact with our hardware
— one was not our bug at all, one was worse than advertised.
