# Targeting AIR on AMD GPUs under Metal

A field guide to emitting Apple Intermediate Representation for **AMD (GCN)
GPUs driven through Metal** — the configuration of a 2019 Intel Mac Pro, and
the one corner of the Metal ecosystem with almost no public documentation.

Two things are collected here:

1. **The public record**, digested from ~14 sources (LLVM RFC, Julia's
   `llvm-downgrade`, `metal-air-docs`, naga's container notes, MoltenVK,
   Blender, wgpu, SDL, Apple developer forums) — credited in
   [Sources](#sources).
2. **Measurements and diagnoses from this fork**, made on real hardware while
   building a Mojo → AIR backend for a Radeon Pro Vega II. Everything in a
   **`MEASURED`** block was observed on that machine, not inferred.

Machine of record: Mac Pro (2019), Xeon W-3235, macOS 26.3.1, Xcode 15.2,
Radeon Pro Vega II 32 GB (Vega 20 / gfx906) plus a Radeon Pro 580X (Polaris)
as a control device.

If you are doing this work, the short version is: **AIR is an LLVM-vintage
bitcode format with a strict reader, and the AMD backend behind it needs
things the Apple-silicon backend does not.** Most of your bugs will be one of
those two facts.

---

## The four layers

Failures sort into four layers that fail differently and are debugged
differently. Conflating them is the main reason people go in circles.

| Layer | What it is | How it fails |
|---|---|---|
| **Container** | `MTLB` archive wrapping one bitcode blob per function | Loader rejects the file, or finds no functions |
| **Bitcode encoding** | The bitstream: record encodings, type table, pointer typing | *"Invalid bitcode"*, *"Unexpected bitcode file"* — rejected before anything compiles |
| **IR content & metadata** | Address spaces, `air.*` named metadata, entry points | Loads, then fails to build a pipeline state — or miscompiles |
| **Device behaviour** | Apple's backend compiling your AIR to GCN | Compiler *crashes*, silent wrong answers, performance cliffs |

Layers 1–3 are deterministic and testable on any Mac. **Layer 4 is where AMD
diverges from every Apple-silicon machine**, and it has the least
documentation and the most breakage.

---

## Layer 4 first: what AMD needs that Apple silicon does not

This section is the reason this document exists. Everything here is ours.

### Generic pointers are fatal — AMD needs resource descriptors

> **`MEASURED`** — the single most valuable finding in this document.

Symptom, as the runtime reports it:

```
newComputePipelineStateWithFunction: Compilation failed due to an
interrupted connection: XPC_ERROR_CONNECTION_INTERRUPTED.
This error occurred after multiple retries.
```

That is not a rejection. Metal's shader compiler runs as an **XPC service**,
and it is **crashing** — the message is what a segfaulting service looks like
from the client side. It takes ~200 s of retries to surface.

**The stack is on disk the whole time**, in
`~/Library/Logs/DiagnosticReports/MTLCompilerService-*.ips`, fully
symbolicated:

```
EXC_BAD_ACCESS (SIGSEGV) KERN_INVALID_ADDRESS at 0x20
libAMDIL902.dylib      llvm::ILTargetLowering::getPtrRsrcId(...)
libAMDIL902.dylib      llvm::ILTargetLowering::getRsrcDescNode(...)
libAMDIL902.dylib      llvm::ILTargetLowering::LowerSTORE(...)
libAMDIL902.dylib      llvm::SelectionDAGISel::CodeGenAndEmitDAG()
AMDRadeonX5000Shared   AMDGFX9MTLCompilerPlugin::compileShaders(...)
```

**Root cause: AMD's Metal plugin must resolve every memory access to a buffer
*resource descriptor*.** A generic (`addrspace(0)`) pointer has none, so
`getPtrRsrcId` dereferences null. **Apple silicon accepts the identical IR**
because it has flat addressing — which is exactly why an Apple-silicon-only
backend never has to get address spaces right, and yours does, for every
pointer, everywhere.

Where generics come from in practice: a compiler that packs kernel captures
into an argument buffer will load the whole buffer as **one aggregate** and
`extractvalue` the device pointers out of it. Those pointers materialize in
AS0. (A fix that hooks only *loads returning pointers* will do nothing —
the pointers are never loaded individually.) Retype pointers sourced from
loads out of AS2/AS1 **and from capture-struct `extractvalue`s** to device
AS1, then propagate through GEPs, phis, selects, bitcasts and into called
functions' parameters.

**If you take one thing from this document: when a vendor toolchain reports a
transport error, go read the crash reports.**

### Device pointers must arrive as bound resources, not addresses

> **`MEASURED`** — the architectural consequence of the above, and the
> largest single constraint we found.

Fixing address spaces is necessary but **not sufficient**. A kernel that
takes device pointers as **direct buffer arguments** works. A kernel that
receives them **inside a captured struct** — a raw 64-bit `gpuAddress`
written into a constant buffer with `setBytes` — crashes the AMD plugin no
matter how the pointer is typed, because there is no descriptor behind a raw
address.

This is easy to misread, because the equivalent MSL works:

```metal
struct Handle { device float *p; uint n; };
kernel void k(constant Handle &h [[buffer(0)]], uint id [[thread_position_in_grid]]) {
  if (id < h.n) h.p[id] = 1.0f;      // compiles and runs on Vega II
}
```

That succeeds because Metal treats it as a real **argument buffer** and
encodes a resource reference into it. Hand-writing an address into bytes is
not the same thing, even though it is indistinguishable in the IR.

**Implication:** if your frontend packs kernel captures into a flat argument
blob (most do), you need `MTLArgumentEncoder`-built argument buffers, or you
must hoist captured pointers into real kernel buffer parameters.

#### A hoisting protocol that works

> **`MEASURED`** — this fixed kernels that had been crashing the shader
> compiler outright.

The obstacle is that the *host* usually cannot know which capture bytes hold
device addresses (a frontend that treats captures as opaque values has no
such record), while the *compiler* can see it plainly in the IR. So let the
compiler tell the runtime, through a channel that survives compilation:

1. **Compiler.** For each device pointer extracted from the capture struct,
   append a real kernel buffer parameter, and name it to encode where the
   address lives — e.g. `__vega_cap_<srcArg>_<byteOffset>`. Give it normal
   `air.buffer` argument metadata with `air.location_index` = its parameter
   index.
2. **Runtime.** Create the pipeline with `MTLPipelineOptionArgumentInfo` and
   read `reflection.bindings`. **Parameter names survive into reflection** —
   verified on Vega II, including synthetic ones. Parse them back into a
   table of *(bufferIndex, srcArg, byteOffset)*.
3. **At launch.** For each entry, read 8 bytes from the packed argument at
   that offset, resolve the address to its owning `MTLBuffer` (keep an
   interval map of allocations keyed by `gpuAddress`), and `setBuffer` it at
   `bufferIndex`.

The pointer is then a bound resource with a descriptor behind it, and
`getPtrRsrcId` resolves. **Probe step 2 before building steps 1 and 3** —
the whole design rests on reflection preserving names.

Three traps worth naming, all hit while implementing this:

- Rewiring uses to a new device-space parameter leaves the old
  AS0-derived users behind; **propagate the address space through the use
  graph**, because a `bitcast` cannot cross address spaces.
- If an earlier pass already inserted an `addrspacecast` on the pointers
  you are about to hoist, you are left with an **invalid same-address-space
  cast**. Hoisting supersedes such casts — do not do both.
- Once a module is malformed enough that `llvm-dis` refuses it, you have no
  way to see what you emitted. **Dump textual IR from inside the backend**,
  before and after the pass pipeline.

Two provenance notes that cost us time:

- **`inttoptr` destroys provenance.** If any pass reconstructs a pointer
  through an integer, `getPtrRsrcId` cannot trace it, even when the address
  space is right. Use `addrspacecast`.
- **Mutating an `extractvalue`'s type does not survive serialization** — the
  type is recomputed from its aggregate, and the mismatch tends to reappear
  downstream as exactly that `ptrtoint`/`inttoptr` round trip.

### Catch a generic dereference at compile time — it is worth building

> **`MEASURED`** — this rule alone would have saved more debugging time than
> everything else in this document.

The generic-pointer defect above is the most expensive thing in this stack to
diagnose, because the only symptom is an XPC transport error ~200 s later with
no file and no line. It is also **statically detectable**: a load or store
through `addrspace(0)` whose pointer is not alloca-derived (private stack
memory is legitimately generic) has no resource descriptor behind it and will
kill the compiler service.

Walk the pointer back through GEPs, phis, selects and casts looking for an
`alloca`. Two subtleties, both of which produce false positives if missed:

- **A pointer loaded out of stack memory is usually fine.** `alloca [2 x ptr]`
  holding pointers to other allocas is ordinary private indirection. But a
  device pointer *spilled* to the stack and reloaded is exactly what you are
  hunting, so "came off the stack" is not enough on its own — follow the load
  back to what was **stored** into that slot and accept only if every store put
  something itself alloca-derived there.
- **That case may only establish privacy or decline.** If it returns "not
  private" it abandons the rest of the worklist and reports pointers another
  path proves private.

Validate in both directions or the checker means nothing: run it over a corpus
of kernels known to work (expect zero findings), and over one with the fix
deliberately disabled (expect it to name the exact instructions).

### Apple silicon and AMD disagree about AIR, and it matters

> **`MEASURED`** — from porting this backend to both.

Two GPUs behind the same IR do not accept the same IR. Findings that transfer
are about the *encoding*; findings that do not are about the *hardware*:

| | AMD (this document) | Apple Silicon |
|---|---|---|
| generic pointer | **crashes** the compiler service | **reads zero**, silently |
| captured device pointer | must be **hoisted** to a real buffer parameter — AMD needs a bound resource | hoisting is harmful; it burns one of 31 buffer slots each |
| reaching a raw address | `addrspacecast`, preserving the provenance `getPtrRsrcId` needs | `inttoptr` — AIR has no generic space and Apple's own compiler uses it |
| `sitofp`/`uitofp`/`fptoui` | **accepted** — verified correct output | rejected; must be `air.convert.*` |
| vector `llvm.fma` | **accepted** | kills pipeline creation; must be `air.fma` |
| SIMD width | 64 | 32 |
| memory | discrete; staging blits | unified; plain `memcpy` |

The first row is the one to internalise: **the same defect is loud on AMD and
invisible on Apple silicon.** If you are targeting both, build the static
checker — on Apple it is the only thing that will tell you, and on AMD it turns
your worst diagnostic into an ordinary compile error.

### Apple's front-end compiler crashes on Radeon, and that is normal

The public record has three independent reports of Metal shader-compiler
crashes on Intel/AMD Macs (wgpu #5827; two Apple forum threads) with no
diagnosis attached. Expect to **bisect kernels** to find shapes the AMD
backend cannot digest, and keep minimal reproducers. Build the bisection
harness early.

### Blender withdrew rather than keep fighting this

Cycles removed Metal support for AMD and Intel GPUs in Blender 4.3, citing
*"significant performance regressions and bugs, all stemming from bugs in the
Metal GPU driver/compiler."* Before removal, features were already being
conditionally disabled per-platform.

Calibrate accordingly — but also **mine it**: the commits *preceding* that
removal are the closest thing that exists to a catalogue of AMD-Metal
workarounds, each conditional disable marking a specific thing the AMD
backend gets wrong.

### You do not control instruction selection

Your AIR is compiled to GCN by Apple's backend. Whether gfx906's dot-product
instructions (`v_dot2_f32_f16`, `v_dot4_i32_i8`, `v_dot8_i32_i4`) are ever
selected is Apple's decision; there is no ROCm-style escape hatch. Shape the
IR to make patterns findable, then **measure** — you cannot inspect the
result. Port ROCm-tuned kernels for correctness first and treat their
performance as unknown.

### Threadgroup sizes can fail silently

Metal can silently no-op a dispatch whose threadgroup exceeds the pipeline's
limit (SDL #15241). Validate against the **pipeline's own**
`maxTotalThreadsPerThreadgroup` before dispatch and treat a silent no-op as a
real failure mode.

> **`MEASURED`** — a related trap that is not about exceeding the limit.
> llama.cpp dispatches most kernels as `(simd_width, n_simdgroups, 1)` but one
> path hard-codes `(128, 1, 1)`, which is four simdgroups *only at width 32*.
> At width 64 that threadgroup is half the size the kernel was written for, so
> the threads responsible for staging one operand simply did not exist and the
> kernel multiplied uninitialised memory — NaNs, no error.
>
> **Derive threadgroup size from the probed wave width**, never from a constant
> that assumes it. A too-small threadgroup is as silent as a too-large one, and
> reads as a data bug rather than a dispatch bug.

### Atomics may miscompile without explicit aliasing metadata

The LLVM RFC author found Apple's on-device compiler reordering memory across
atomic compare-and-swap — **wrong results, not errors**, the nastiest class in
the record. The fix was Apple-style aliasing annotation (`noalias` attributes
plus `!alias.scope` / `!noalias`) and marking affected loads `volatile`.

**Open question:** that work was almost certainly done on Apple silicon.
Whether it reproduces on GCN is unverified here. Budget for it before any
lock-free kernel work.

### `uint64 x short` is miscompiled — the short lands in the high word

> **`MEASURED`** — found in llama.cpp's Metal backend on the Vega II; probe is
> four addressing forms written from inside one kernel.

Multiplying a 64-bit stride by a **`short`** index produces a wrong product on
Apple's AMD backend. The short's value ends up scaled by 2^32:

```metal
// nb12 is uint64_t (a byte stride), i12 is a short holding 128
args.nb12 * i12        // -> 4398046511104   == nb12 << 32
args.nb12 * (int)i12   // -> 131072          == nb12 * 128   (correct)
```

Same address, two spellings, two answers:

```
((device const float *) src1)[32768]                   -> 0.5   (correct)
*(device const T1 *)(src1 + nb11*i11 + nb12*i12)       -> NaN
```

This is the atomics class of bug — **wrong results, not errors** — and it is
brutal to localise because the symptom looks structural. Ours presented as
"output is correct up to token 127 and garbage from 128 onward", identical for
2, 4, 8 and 16 experts, independent of matrix size and of which tile or expert
owned the token. Every geometric explanation it suggests is wrong: 128 is
simply where a `short` index first pushes the miscompiled product past
anything the allocation covers.

**Rule: any index that multiplies a stride must be `int` or wider.** Do not use
`short` for loop or tile indices that reach pointer arithmetic, however small
their range. The sibling kernel in the same file was immune purely because it
happened to use `int`.

### `memoryBarrierWithScope:` is not enforced between concurrent dispatches

> **`MEASURED`** — llama.cpp's Metal backend, Vega II.

Encoding with `MTLDispatchTypeConcurrent` and separating dependent kernels
with `memoryBarrierWithScope:MTLBarrierScopeBuffers` is honoured on Apple's
TBDR parts and **is not** here. The result was nondeterministic garbage —
*different* garbage on each run of an identical, deterministic workload.

That non-determinism is itself the useful signal: **a result that changes
between runs of a deterministic kernel is a scheduling bug, not an arithmetic
one**, and that single observation partitions the search space before any code
is read. Falling back to serial dispatch cost ~4.6% throughput and fixed it.
Ending and restarting the encoder at each barrier point is *not* a substitute —
it discards encoder state that multi-dispatch operations rely on.

---

## Hardware facts: Radeon Pro Vega II under Metal

> **`MEASURED`** — probe source: [`spikes/s1-metal-smoke/`](spikes/s1-metal-smoke/).

| Property | Vega II | 580X (control) |
|---|---|---|
| SIMD (wave) width | **64** | **64** |
| GPU family | Metal 3 + Mac2 | Mac2 only |
| Max MSL accepted by runtime | 3.2 | 3.2 |
| `simdgroup_matrix` | **no** — compiles, then fails at *pipeline creation* ("SC compilation failure" / "call to an undefined label") | no |
| `double` | **no** — rejected at source compile | no |
| `bfloat` | **compiles and builds pipelines** (numerics unverified) | same |
| Threadgroup memory | 64 KiB | 64 KiB |
| Max threads / threadgroup | 1024 | 1024 |
| Working set | 32.0 GiB | 8.0 GiB |
| **Max single buffer** | **3.5 GiB** — despite the 32 GiB working set | 3.5 GiB |
| VRAM bandwidth (copy kernel, r+w) | **830 GB/s** | 169 GB/s |
| HtoD blit (PCIe) | **12.0 GB/s** (`maxTransferRate` reports 15.75) | 9.2 GB/s |
| Unified memory | no — discrete, private storage + explicit DMA | no |
| Peer group | none | none |

### On the wave-width question

The public record contains a genuine warning here: **MoltenVK 1.4.2** shipped
a fix described as *"Metal expects a subgroup size of 32, but MoltenVK was
reporting 64 on affected AMD Mac GPUs"*, and an Apple forum thread documents
`threadExecutionWidth` reporting **16** on Intel UHD 630 for complex kernels
whose real simdgroup was 32. The prescribed test is to dispatch a kernel that
writes `[[threads_per_simdgroup]]` and read it back.

> **`MEASURED`** — we ran that test. On both GPUs, **three independent
> in-kernel measurements agree: 64.** `threads_per_simdgroup` = 64,
> `simd_sum(1u)` = 64, and a 64-bit `simd_ballot` popcount = 64. Subsequently
> confirmed positively: an alternating-lane ballot returns
> `0x5555555555555555` — a full 64-lane mask — and a wave-wide sum returns 64.
>
> **Metal exposes 64-wide simdgroups on Vega II.** The MoltenVK issue concerns
> what MoltenVK reports to Vulkan clients, a different layer. Their
> methodological advice — never trust `threadExecutionWidth`, query from a
> kernel — is right regardless, and is what we did.

Consequence for portable code: **lane count is not vendor identity.** A
codebase that reaches wave64 paths via `is_amd_gpu()` will take the wrong
branch here, because this GPU is AMD silicon behind an Apple-classified
target. Gate on the width, not the vendor.

> **`MEASURED`** — independently confirmed in a second, unrelated codebase.
> llama.cpp's Metal backend makes the same substitution in a different
> spelling: `has_simdgroup_reduction` and `has_simdgroup_mm` are derived from
> `supportsFamily:MTLGPUFamilyApple7`, and its shaders hard-code
> `#define N_SIMDWIDTH 32`. Two projects, written independently for different
> purposes, both encoded lane count as vendor identity — which suggests the
> mistake is the natural one to make, not a local lapse. The repair is the
> same in both: probe the width (compile a trivial kernel, read the
> pipeline's `threadExecutionWidth`) and thread it through as a value.

### Matrix maths without `simdgroup_matrix`

`simdgroup_matrix` being unavailable does not cost you matrix throughput; it
costs you the *intrinsic*. A plain register-tiled GEMM — threadgroup-staged
tiles, accumulators in registers, no matrix intrinsics, the 64-wide wavefront
used as 64 independent lanes — recovers most of it.

> **`MEASURED`** — a 64x32 tile with 4x2 accumulators per thread, K stepped in
> 32s, 4 simdgroups of 64 lanes, operands staged k-major so the inner loop
> reads four rows as one `half4` and two columns as one `half2`.
>
> | | achieved |
> |---|---|
> | This kernel, in llama.cpp | **~2.67 TFLOP/s** (~19% of fp32 peak) |
> | Our naive tiled Mojo matmul (`spikes/matmul/`) | 2.37 TFLOP/s (~17%) |
> | The mat-vec fallback it replaced | ~0.8 TFLOP/s (~6%) |
>
> Prompt processing went from 48 to 163 tokens/s on an 8B model and 88 to 179
> on a 30B MoE — and from *losing* to the host Xeon to beating it by ~1.7x.

The wider lesson for anyone shaping IR here: **~19% of peak is reachable from
an ordinary tiled kernel with no vendor intrinsics at all.** Reach for the
exotic path only after measuring the plain one.

### Narrow loads leave most of your bandwidth on the floor

Byte-at-a-time reads of packed data cost far more on this card than the
instruction count suggests. Two kernels reading the same bytes, differing only
in access width, differ by ~50% in achieved bandwidth.

> **`MEASURED`** — llama.cpp's K-quant mat-vec kernels, against the card's
> ~830 GB/s ceiling. `q4_K` read its quants as `uint16_t`; `q5_K` and `q6_K`
> read the same data as `uint8_t`.
>
> | kernel | before | after | of ceiling |
> |---|---:|---:|---:|
> | `q5_K` | 139 GB/s | **206 GB/s** | 11% → 25% |
> | `q6_K` | 208 GB/s | **328 GB/s** | 25% → 40% |
>
> The change is only the load width — same bytes, same arithmetic, same
> results bit-for-bit. Halving the number of transactions bought ~50%.

Packed 4-bit data makes this easy to get wrong, because the natural way to
write the unpack is per-byte. Read the widest aligned unit the layout permits
and shift the fields out of registers. Check alignment first: a 210-byte block
whose sub-arrays start at 0 and 128 is safe for 16-bit loads; one starting at
an odd offset is not.

### Diagnostic: delete the arithmetic

Before optimising a kernel, settle whether it is ALU-bound or memory-bound —
and the fastest way is destructive. **Strip the arithmetic out of the inner
loop while leaving every load in place**, and time the wreckage. It computes
nonsense; that does not matter.

> **`MEASURED`** — gutting the `q5_K` inner loop this way made it **2.5%
> faster**. A kernel indifferent to the removal of its own maths is not
> ALU-bound, and no amount of instruction-level cleverness will help it. That
> one measurement redirected the work to the loads, where the 50% was.

The result is unambiguous in a way profiler counters are not, and it takes
about two minutes. Note also what it rules *out*: had the kernel sped up
sharply, the arithmetic would have been worth attacking.

> **Corollary for measurement generally:** keep an untouched kernel in the
> same run as a control. One of our sweeps showed `q4_K` — code we had not
> modified — apparently losing 64% of its bandwidth. A colleague had started
> using the same GPU. Without the control it would have read as a
> catastrophic regression in code that had not changed.

---

## Layer 3: IR content and metadata

### Address spaces

Non-negotiable, and the first thing to get right — a wrong address space is a
silently wrong program, not a load failure.

| `addrspace` | Metal memory type |
|---|---|
| `1` | device |
| `2` | constant |
| `3` | threadgroup |
| `4` | threadgroup_imageblock |
| `5` | ray_data |
| `6` | object_data |
| *(none / 0)* | thread |

> **`MEASURED`** — **the NVIDIA trap.** Frontends built around CUDA emit
> NVPTX numbering, where `4 = constant` and `5 = local`. Under AIR those
> numbers mean **imageblock** and **ray_data**. `1`/`3` coincide between the
> two schemes, which is why device buffers and threadgroup memory appear to
> work from day one and constants/locals mysteriously do not. Remap `4 → 2`
> and `5 → 0`, and propagate the pointer retyping through use graphs.

Also note the interaction with layer 4: **by-value scalar kernel arguments**
are modelled in AIR as `constant`-AS(2) pointer parameters (MSL's
`constant T&`), loaded at entry, with the host binding them via `setBytes` at
the same argument index.

### Required named metadata

| Node | Contents |
|---|---|
| `air.version` | 3 elements: major, minor, patch |
| `air.language_version` | 4 elements: language name, major, minor, patch |
| `air.compile_options` | e.g. `air.compile.fast_math_enable`, denorm handling |
| `air.source_file_name` | source name |
| `llvm.ident` | compiler identification |
| `llvm.module.flags` | includes `air.max_device_buffers`, `air.max_constant_buffers`, `air.max_threadgroup_buffers`, `air.max_textures`, `air.max_read_write_textures`, `air.max_samplers` |

Entry points live in per-stage arrays (`air.kernel`, `air.vertex`, …), each
element `{function, outputs, arg_metadata}`. Per-argument records take a
positional index first, then named entries — `air.buffer`,
`air.location_index`, `air.address_space`, `air.arg_type_size`,
`air.arg_type_align_size`, `air.arg_type_name`, `air.arg_name`. Builtin
parameters carry their own tag instead (`air.thread_position_in_grid`,
`air.threadgroup_position_in_grid`, …). Pure compute needs far less of this
than the graphics-oriented docs imply.

> **`MEASURED`** — `air.location_index` **is** the buffer binding index the
> host must use. Keep the compiler's argument order and the runtime's
> `setBuffer`/`setBytes` indices in one place; they are the same numbering.

### AIR runtime functions are type-mangled

> **`MEASURED`** — harvested by compiling equivalent MSL with Apple's own
> `metal -c` and disassembling.

The stdlib-style bare stems do not exist. The real symbols carry type
suffixes, and signedness is spelled out for integers:

```
i64 @air.max.s.i64(i64, i64)      i64 @air.min.s.i64(i64, i64)
i64 @air.max.u.i64(i64, i64)      i64 @air.abs.s.i64(i64)
i32 @air.simd_shuffle_xor.u.i32(i32, i16)   ← note: the mask is i16
i32 @air.simd_sum.u.i32(i32)      float @air.simd_sum.f32(float)
i64 @air.simd_ballot.i64(i1)      ← the wave64 form; i32 drops lanes 32–63
float @air.fast_fmax.f32(float, float)      float @air.fma.f32(float, float, float)
float @air.fast_sqrt.f32(float)   float @air.fast_rint.f32(float)
```

Declare them `nounwind willreturn memory(none) local_unnamed_addr`.

> **`MEASURED`** — **but do not remap standard LLVM intrinsics to these.**
> We mapped `llvm.umax`/`smax`/`abs`/`fabs`/`sqrt`/`fma` onto their `air.*`
> equivalents using correct names and attributes, and it **regressed working
> kernels**. The driver handles `llvm.*` intrinsics natively. Only the
> genuinely AIR-specific operations (the `simd_*` family) need the mangling.

---

## Layer 2: bitcode encoding

The largest single source of work in every independent implementation. Three
separate projects — Modular, the LLVM RFC author, and Julia — all concluded
you **cannot use the stock `BitcodeWriter`**.

### Apple's reader wants typed pointers

Modern LLVM discards pointee types; Apple's reader still demands them. The
RFC author called a typed-pointer writer *"the single largest piece of the
target"* (~3,500 lines). You need a `PointeeTypeMap`-equivalent and a rewrite
pass that re-types pointers before emission.

**Do not write this from scratch.** [Julia's
`llvm-downgrade`](https://github.com/JuliaLLVM/llvm-downgrade) maintains
forked `BitcodeWriter` + `ValueEnumerator` for LLVM **5.0 / 7.0 / 14.0 / 15.0
/ 18.0**, building against modern LLVM. Modular's Metal writer is derived from
it and says so in its file header.

### Which LLVM version is the reader?

The record disagrees: `metal-air-docs` says *"just LLVM 4.0 bytecode"*;
Modular's 2026 source says *"metal's reader is based on LLVM 18"*. Treat the
community docs as **version-dated, not wrong** — the baseline moves across
macOS releases. Determine it empirically on your own machine.

> **`MEASURED`** — golden metallib produced by Xcode 15.2 here:
> `air.version 2.6.0`, `air.language_version {"Metal", 3, 1, 0}`, target
> triple `air64-apple-macosx14.2.0`. The runtime accepts 2.6. Our writer is
> the LLVM-17 fork and works; per Julia's target list, **18.0 is arguably the
> better base** given the LLVM-18 claim.

### Vintage landmines: constructs newer than the reader

> **`MEASURED`** — each of these cost real debugging time.

| Construct | Introduced | Symptom |
|---|---|---|
| `freeze` | LLVM 10 | Writer hard-crashes: `llvm_unreachable("can not encode freeze instruction for LLVM 5.0")` |
| unary `fneg` | LLVM 8 | Same hard crash |
| GEP no-wrap flags (`nusw`/`nuw`) | LLVM 19 | Apple's `air-as` rejects the text form; encoded flags break the **GCN compiler** |
| Attribute kinds with bitcode codes ≳ 77 | various | `air-opt`: *"Unknown attribute kind (82)"* — `allockind`, `allocptr`, `nofpclass`, `fn_ret_thunk_extern`, `hybrid_patchable`, `disable_sanitizer_instrumentation` |
| `memory(none)` | LLVM 16 | Documented in the community record as breaking reassembly |

The optimizer introduces `freeze` and `fneg` freely, so a downgrade pass must
run **after** optimization and before emission. Fold `freeze` to its operand;
lower `fneg` to `fsub(-0.0, x)` preserving fast-math flags; reduce GEP flags
to plain `inbounds`; encode too-new attributes as "unsupported".

### Fast-math flags and kernel argument widths

Two fixups recorded in Modular's writer, both worth replicating:

- **FP-math flags on non-FP types.** Main LLVM permits `FPMathOperator` flags
  on a broader set of types than Metal's reader accepts. Unwrap array types
  to the element type and confirm it is genuinely FP before emitting flags.
- **Kernel argument `i64 → i32` correction**, threaded through *every*
  constant-emission path (`CST_CODE_SETTYPE`, `CE_CAST`, `CE_BINOP`,
  `CE_EXTRACTELT`, `CE_INSERTELT`). Miss one and you get a type-table mismatch
  far from the cause.

### Use Metal's math functions; don't ship a polynomial

> **`MEASURED`** — and the crash location lied about this one for a day.

Symptom: a kernel using `log` crashes the AMD backend in `LowerSTORE` — on a
store hundreds of instructions downstream that merely consumes the result.

Cause: a portable math library that implements `log` as an **inline
polynomial** expands into vector compare/select shapes the AMD Metal backend
cannot lower. Apple's own `log` is a single `air.log.v4f32` call. Metal
provides the whole math family natively; call it. (Our stdlib had a fast path
for NVIDIA and fell through to the polynomial for everyone else — worth
checking whether yours does the same.)

**The diagnostic that finds this class in one command** — diff the bitstream
record-type inventory against an Apple compilation of the equivalent kernel,
and investigate every record type that is yours alone:

```sh
llvm-bcanalyzer --dump ours.air  | grep -oE '<[A-Za-z_0-9]+' | sort -u > ours.txt
llvm-bcanalyzer --dump apple.air | grep -oE '<[A-Za-z_0-9]+' | sort -u > apple.txt
comm -23 ours.txt apple.txt        # -> INST_VSELECT, INST_CMP2, ...
```

Two things this exercise also settled, worth recording so nobody repeats
them: **vector constant elements are encoded as `DATA` records, not
individual `FLOAT` records**, so counting `FLOAT` records against float
literals in the text IR compares two different things and will fake a
dropped-constant bug. And **`poison` (LLVM 12) is newer than the AMD plugin's
LLVM fork** — Apple emits none of it — so downgrade `poison` → `undef`
(recursing into constant aggregates) alongside `freeze` and `fneg`.

### Bugs we found in the vendored writer itself

> **`MEASURED`** — if you vendor a downgrade writer, these are waiting for you.

- **Switch case values are not enumerated.** The forked `ValueEnumerator` was
  copied from an LLVM where `SwitchInst` kept case values as *operands*.
  Current LLVM stores them **out-of-line**, so the operand walk misses them
  while the writer still emits them: `"Value not in slotcalculator!"` for any
  kernel the optimizer turned into a `switch`. Mirror upstream's
  `ValueEnumerator.cpp` — enumerate `SI->cases()` explicitly. (Latent in
  *every* vendored version, not just one.)
- **The writer emits its own bitcode-wrapper header.** Do not add a second
  one. A double wrapper produces `"Unexpected bitcode file!"` and can
  masquerade as an encoding incompatibility for an entire debugging session.
- **The wrapper's size field legitimately excludes trailing alignment
  padding.** "Fixing" it to `file_size - 20` makes the reader parse padding as
  records — `"Malformed block"`, breaking every kernel that has padding.

---

## Layer 1: the metallib container

The best-documented layer, thanks to naga and MetalShaderTools.

A `.metallib` opens with magic `MTLB`, a 4-byte unknown field, and a format
version (commonly 3; 2 still in the wild), then a total size and offset/length
pairs for four regions: headers, types, empties, bitcode. Little-endian
throughout.

Per-function headers are FourCC-tagged runs: `NAME` (null-terminated),
`TYPE`, `HASH` (SHA-256 of the function's bitcode), `MDSZ` (bitcode size, 8
bytes), `OFFT` (`[u64; 3]`), `VERS` (typically `[2,2,2,2]`), `ENDT`.
Version 3 places an `ENDT` after the headers section; version 2 omits it. The
bitcode region is sequential blobs, each starting with `0x0B17C0DE`.

**Emit `.air` and link the metallib separately.** The RFC reviewers preferred
this, mirroring Apple's own compile-then-link model, and it keeps the layer
most likely to change between macOS releases out of your codegen. In practice
`xcrun -sdk macosx metallib in.air -o out.metallib` is the whole step, and it
doubles as a structural validator.

---

## Tooling: what works, what lies

Apple ships a full AIR binutils suite most people never notice, in
`$(dirname $(xcrun -sdk macosx -f metal))`:

```
air-as  air-opt  air-objdump  air-readobj  air-nm  air-lld  air-ar
amdgpu-nt  applegpu-nt        ← the AIR → native translators
```

> **`MEASURED`** — the caveats matter more than the list:
>
> - **`llvm-dis` lies about old bitcode.** It silently modernizes what it
>   reads, so a module whose bitstream carries *typed* pointer records
>   disassembles as opaque-pointer IR. Diffing disassembly will send you
>   hunting a non-existent bug. **`llvm-bcanalyzer --dump` is the truth** —
>   it shows the actual records.
> - **A round-trip through `llvm-dis`/`llvm-as` is not a validity test.** A
>   modern `llvm-dis` adds attributes Apple's reader rejects.
> - **`amdgpu-nt` gives real AIR → GCN diagnostics** instead of the driver's
>   opaque messages — genuinely valuable — **but its bundled plugin caps at
>   AIR 2.5** and rejects the 2.6 modules the runtime happily accepts.
> - **`air-as` stamps its own `air.version`**, so you cannot work around that
>   cap by editing the version metadata in text and reassembling.
> - Which leaves **crash reports** as the primary layer-4 diagnostic. See the
>   first section.

### The validation loop

Apple ships a working AIR producer on your machine; use it as an oracle.

1. Write the equivalent kernel in `.metal`, compile with `xcrun metal -c`.
2. Disassemble both Apple's output and yours.
3. Diff **metadata blocks first**, type table second, function bodies last.
4. For anything the driver rejects, check `~/Library/Logs/DiagnosticReports/`.

> **`MEASURED`** — a cheap trick worth knowing: to learn the real AIR symbol
> for an operation, write two lines of MSL that use it, compile, and read the
> `declare` lines. That is how every mangled name in this document was found.

---

## Open questions

Ordered by how much they would change a plan.

1. **Do the atomics/aliasing miscompiles reproduce on GCN**, or are they
   Apple-silicon-specific? Unverified here; the class produces wrong answers
   rather than errors. Note that a *different* silent miscompile on this
   backend is now confirmed (see `uint64 x short` above), so the class is
   demonstrably live on GCN even if that specific instance is not.
2. **Does Apple's AMD backend ever select `v_dot4_i32_i8`?** Only
   answerable by benchmarking an integer-dot idiom against a scalar loop.
3. **Is the LLVM-18 downgrade target better than 17** for current macOS? Ours
   works at 17; nobody has measured the difference.
4. **What is in Blender's pre-removal Cycles commits?** Almost certainly the
   largest untapped catalogue of AMD-Metal workarounds.
5. **Does `bfloat` compute correctly on GCN under Metal?** It compiles and
   builds pipelines here (a surprise), but numerics are unverified.
6. **How wide is the `uint64 x short` miscompile?** We hit it in a stride
   multiply. Whether other narrow-integer operands (`ushort`, `char`) or other
   64-bit operations are affected is unknown, and the failure mode is silent.
   Until someone maps it, treat narrow integers as unsafe anywhere near
   64-bit arithmetic.

---

## Sources

Public record, as digested:

- **LLVM RFC** — *[RFC] Add an Apple Metal/AIR backend target*,
  discourse.llvm.org (May 2026)
- **Julia** — [JuliaLLVM/llvm-downgrade](https://github.com/JuliaLLVM/llvm-downgrade)
- **AIR docs** — [SamoZ256/metal-air-docs](https://github.com/SamoZ256/metal-air-docs);
  *Breaking down Metal's intermediate representation format*
- **naga** — gfx-rs/naga wiki, *Metallib file format*
- **Blender** — *Cycles: Remove support of Metal with AMD/Intel GPUs for 4.3
  and onwards*
- **MoltenVK** — v1.4.2 release notes, *AMD Subgroup Fixes and Legacy GPU
  Patches*
- **Apple forums** — *Inconsistent threadExecutionWidth vs SIMD group size*;
  *Shader compiler crash on macOS Sequoia + Radeon*; *Metal fails to create
  PSO on AMD based GPUs*
- **wgpu** — issue #5827, *Internal error in Metal Shading Language compiler
  on Intel macs*
- **SDL** — issue #15241, *SDL 3 GPU silently fails if threadgroup size is too
  large (Metal)*
- **Tooling** — YuAo/MetalLibraryArchive, MetalLibraryExplorer,
  zhuowei/MetalShaderTools, steelbrain/metal2vulkan, a2flo/floor_llvm,
  a2flo/applecl-encoder
- **Modular** — `modular/modular`:
  `KGEN/lib/Compiler/ObjectCompiler/LLVM/Bitcode/17/`,
  `LLVMIRDowngradePass.cpp` (registered as `kgen-metal-air`),
  `KGEN/include/KGEN/Compiler/Target/TargetBackend.h`. Apache-2.0 with LLVM
  exceptions.

Everything marked **`MEASURED`** is original to this fork — see
[`MacVegaFork_journal.md`](MacVegaFork_journal.md) for the working record
each finding came from, and [`PORT_DESIGN.md`](PORT_DESIGN.md) for the
overall design.

Corrections welcome. Where sources conflict — notably on AIR's bitcode
baseline — both positions are recorded rather than resolved.
