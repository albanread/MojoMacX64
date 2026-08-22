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

### Atomics may miscompile without explicit aliasing metadata

The LLVM RFC author found Apple's on-device compiler reordering memory across
atomic compare-and-swap — **wrong results, not errors**, the nastiest class in
the record. The fix was Apple-style aliasing annotation (`noalias` attributes
plus `!alias.scope` / `!noalias`) and marking affected loads `volatile`.

**Open question:** that work was almost certainly done on Apple silicon.
Whether it reproduces on GCN is unverified here. Budget for it before any
lock-free kernel work.

---

## Hardware facts: Radeon Pro Vega II under Metal

> **`MEASURED`** — probe source: [`spikes/s1-metal-smoke/`](spikes/s1-metal-smoke/).

| Property | Vega II | 580X (control) |
|---|---|---|
| SIMD (wave) width | **64** | **64** |
| GPU family | Metal 3 + Mac2 | Mac2 only |
| Max MSL accepted by runtime | 3.2 | 3.2 |
| `simdgroup_matrix` | **no** — compiles, then fails at *pipeline creation* ("SC compilation failure") | no |
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
   rather than errors.
2. **Does Apple's AMD backend ever select `v_dot4_i32_i8`?** Only
   answerable by benchmarking an integer-dot idiom against a scalar loop.
3. **Is the LLVM-18 downgrade target better than 17** for current macOS? Ours
   works at 17; nobody has measured the difference.
4. **What is in Blender's pre-removal Cycles commits?** Almost certainly the
   largest untapped catalogue of AMD-Metal workarounds.
5. **Does `bfloat` compute correctly on GCN under Metal?** It compiles and
   builds pipelines here (a surprise), but numerics are unverified.

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
