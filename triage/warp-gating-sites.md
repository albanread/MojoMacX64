# Warp-gating triage: the 92 `is_amd_gpu()` sites

Full manual pass (2026-08-22): every site opened and its enclosing function
read. Context: this fork's GPU is AMD GCN silicon (Radeon Pro Vega II,
wave64) driven through Metal, so the target classifies as Apple
(`is_apple_gpu()` true, `is_amd_gpu()` false) while `WARP_SIZE == 64`.
Vendor gates that select AMD instructions must stay closed to us (we emit
AIR, never GCN ISA); only genuine lane-count gates would need re-gating on
`is_wave64()` / `WARP_SIZE` (`std.gpu.globals`).

Grep note: `grep -rn 'is_amd_gpu()'` returns 93 hits — 92 code sites plus
one docstring mention (`globals.mojo:81`, kept below under *neither*).

## Summary

| classification | count |
|---|---|
| ISA-dispatch (stays vendor-gated) | 73 |
| wave-width (re-gate on is_wave64/WARP_SIZE) | 1 |
| mixed | 0 |
| neither | 19 |
| **total** | **93** (92 code + 1 docstring) |

**Headline finding:** the heuristic pre-classification's "wave-width — 14"
bucket was almost entirely wrong. This tree has already been through a pass
that added `is_apple_gpu()` / AIR branches next to every AMD branch in the
warp/id/shuffle stdlib code, and the actual lane-count dependence is already
carried by width-parametric constants — `WARP_SIZE` (resolved via `GPUInfo`
for the Apple-classified target), `_FULL_MASK = 2**WARP_SIZE - 1`,
`_WIDTH_MASK = WARP_SIZE - 1`, and `mask_type = uint32 if WARP_SIZE <= 32
else uint64` in `match_any`/`match_all`. The `is_amd_gpu()` branches beside
them select *instructions* (`ds_bpermute`, `readfirstlane`,
`llvm.amdgcn.ballot`, DPP, MFMA, buffer loads), not widths. Exactly one code
site is intrinsically about lane count — the `WARP_SIZE` resolver itself —
and it is already handled for our target.

**Least-confident 5** (see rationale inline): `max/kernels/src/comm/sync.mojo:469`,
`max/kernels/src/linalg/gemv.mojo:484`, `max/kernels/src/nn/softmax.mojo:1865`,
`mojo/stdlib/std/math/math.mojo:2185`, `max/kernels/src/comm/broadcast.mojo:47`
(and its twin `reducescatter.mojo:59`).

## ISA-dispatch (stays vendor-gated) — 73

### stdlib — 39

- [ ] `mojo/stdlib/std/gpu/globals.mojo:135` — `elif is_amd_gpu() or has_amd_gpu_accelerator():` — Selects the `rocdl.flat_work_group_size` metadata tag; the following `is_apple_gpu()` branch already emits `pop.air.max_work_group_size` for us.
- [ ] `mojo/stdlib/std/gpu/intrinsics.mojo:376` — `elif is_amd_gpu():` — `_byte_permute_inst` returns the `llvm.amdgcn.perm` intrinsic name.
- [ ] `mojo/stdlib/std/gpu/intrinsics.mojo:646` — `if is_amd_gpu():` — `get_ib_sts` uses AMD inline asm `s_getreg_b32 ... HW_REG_IB_STS` (else returns 0).
- [ ] `mojo/stdlib/std/gpu/intrinsics.mojo:857` — `is_amd_gpu()` — assert guarding `AMDBufferResource.__init__`, a 128-bit GCN buffer descriptor (incl. gfx-arch word-3 constants).
- [ ] `mojo/stdlib/std/gpu/intrinsics.mojo:887` — `is_amd_gpu()` — assert guarding the zeroed `AMDBufferResource` constructor (same descriptor type).
- [ ] `mojo/stdlib/std/gpu/intrinsics.mojo:933` — `is_amd_gpu()` — assert guarding `AMDBufferResource.load`, which emits `llvm.amdgcn.raw.buffer.load`.
- [ ] `mojo/stdlib/std/gpu/intrinsics.mojo:1010` — `is_amd_gpu()` — assert guarding `load_to_lds` (`llvm.amdgcn.raw.ptr.buffer.load.lds` / `rocdl.raw.ptr.buffer.load.lds`).
- [ ] `mojo/stdlib/std/gpu/intrinsics.mojo:1107` — `is_amd_gpu()` — assert guarding `AMDBufferResource.store` (`llvm.amdgcn.raw.buffer.store`).
- [ ] `mojo/stdlib/std/gpu/intrinsics.mojo:1244` — `is_amd_gpu()` — assert guarding `ds_read_tr16_b64` (`llvm.amdgcn.ds.read.tr16.b64`, CDNA4+).
- [ ] `mojo/stdlib/std/gpu/intrinsics.mojo:1288` — `is_amd_gpu()` — assert guarding `ds_read_tr8_b64` (`llvm.amdgcn.ds.read.tr8.b64`, CDNA4+).
- [ ] `mojo/stdlib/std/gpu/intrinsics.mojo:1342` — `is_amd_gpu()` — assert guarding `cvt_pk_fp8_f32_raw` (`llvm.amdgcn.cvt.pk.fp8.f32`, CDNA4+).
- [ ] `mojo/stdlib/std/gpu/intrinsics.mojo:1388` — `is_amd_gpu()` — assert guarding `permlane_swap` (`llvm.amdgcn.permlane{16,32}.swap`, CDNA4+).
- [ ] `mojo/stdlib/std/gpu/primitives/id.mojo:104` — `elif is_amd_gpu():` — `_lane_id` AMD path uses `llvm.amdgcn.mbcnt.{lo,hi}`; the `is_apple_gpu()` branch below uses `llvm.air.thread_index_in_simdgroup` for us.
- [ ] `mojo/stdlib/std/gpu/primitives/id.mojo:160` — `comptime if is_amd_gpu():` — `_warp_id[broadcast=True]` picks the `readfirstlane` intrinsic (amdgcn-only) over `warp.broadcast`; our target correctly takes the shuffle-based else path. (Pre-classified wave-width; it is instruction selection.)
- [ ] `mojo/stdlib/std/gpu/primitives/id.mojo:226` — `elif is_amd_gpu():` — `thread_idx` intrinsic-name selection: `llvm.amdgcn.workitem.id.*` (AIR branch exists).
- [ ] `mojo/stdlib/std/gpu/primitives/id.mojo:274` — `elif is_amd_gpu():` — `block_idx` intrinsic-name selection: `llvm.amdgcn.workgroup.id.*` (AIR branch exists).
- [ ] `mojo/stdlib/std/gpu/primitives/id.mojo:334` — `elif is_amd_gpu():` — `block_dim` AMD path reads GCN dispatch-packet/implicit-arg words via `_get_gcn_idx` (HSA ABI); AIR branch exists.
- [ ] `mojo/stdlib/std/gpu/primitives/id.mojo:389` — `elif is_amd_gpu():` — `grid_dim` AMD path reads GCN implicit-arg words (HSA ABI); AIR branch exists.
- [ ] `mojo/stdlib/std/gpu/primitives/warp.mojo:562` — `elif is_amd_gpu():` — `shuffle_idx` dispatch to `_shuffle_idx_amd` → `llvm.amdgcn.ds.bpermute`; `is_apple_gpu()` branch uses `llvm.air.simd_shuffle`. (Pre-classified wave-width; the width lives in `WARP_SIZE`-derived masks, not this gate.)
- [ ] `mojo/stdlib/std/gpu/primitives/warp.mojo:659` — `elif is_amd_gpu():` — `shuffle_up` dispatch to `ds_bpermute` helper; AIR branch (`llvm.air.simd_shuffle_up`) exists.
- [ ] `mojo/stdlib/std/gpu/primitives/warp.mojo:757` — `elif is_amd_gpu():` — `shuffle_down` dispatch to `ds_bpermute` helper; AIR branch exists.
- [ ] `mojo/stdlib/std/gpu/primitives/warp.mojo:858` — `elif is_amd_gpu():` — `shuffle_xor` dispatch to `ds_bpermute` helper; AIR branch exists.
- [ ] `mojo/stdlib/std/gpu/primitives/warp.mojo:1010` — `and is_amd_gpu()` — `_lane_group_broadcast_reduce` routes to `_dpp_reduce_and_broadcast` (`llvm.amdgcn.update.dpp.i32`, permlane); our target correctly falls through to the width-parametric `shuffle_xor` ladder (`log2_floor(num_lanes)` steps).
- [ ] `mojo/stdlib/std/gpu/primitives/warp.mojo:1425` — `elif is_amd_gpu():` — `vote` dispatch to `llvm.amdgcn.ballot.i{32,64}`; AIR branch uses `llvm.air.simd_ballot.i32`. **See notes: the Apple helper's 32-bit ballot truncates on wave64.**
- [ ] `mojo/stdlib/std/gpu/primitives/warp.mojo:1519` — `elif is_amd_gpu():` — `match_any` AMD path is the ROCm `readfirstlane` + ballot idiom; the Apple path is a `WARP_SIZE`-unrolled shuffle sweep (already width-correct).
- [ ] `mojo/stdlib/std/gpu/primitives/warp.mojo:1640` — `elif is_amd_gpu():` — `match_all` AMD path uses `readfirstlane` + ballot; Apple path is a `WARP_SIZE`-unrolled shuffle sweep.
- [ ] `mojo/stdlib/std/math/math.mojo:303` — `elif is_amd_gpu():` — `rsqrt` selects `llvm.amdgcn.rsq.*`; `is_apple_gpu()` branch uses `llvm.air.rsqrt`.
- [ ] `mojo/stdlib/std/math/math.mojo:360` — `elif is_amd_gpu():` — `recip` selects `llvm.amdgcn.rcp.*` (no Apple branch; we fall to exact `1.0 / x`).
- [ ] `mojo/stdlib/std/math/math.mojo:420` — `comptime if is_amd_gpu() and dtype in (DType.float16, DType.float32):` — `exp2` selects `llvm.amdgcn.exp2.*`; `llvm.air.exp2` branch follows for us.
- [ ] `mojo/stdlib/std/math/math.mojo:1004` — `elif is_amd_gpu() and dtype in (DType.float32, DType.float16):` — `log2` selects `llvm.amdgcn.log.*`.
- [ ] `mojo/stdlib/std/math/math.mojo:2185` — `elif is_amd_gpu():` — `log10` picks the generic `llvm.log10` lowering for the AMDGPU backend; the `is_apple_gpu()` branch (`llvm.air.log10`) covers us. **Low confidence** — the intrinsic is generic LLVM, not amdgcn.*, so this is arguably a backend-lowering preference ("neither") rather than ISA proper; either way it stays vendor-gated and our target is already served.
- [ ] `mojo/stdlib/std/sys/intrinsics.mojo:874` — `comptime assert is_amd_gpu(), "This intrinsic is only defined for AMD GPUs"` — `implicitarg_ptr` = `llvm.amdgcn.implicitarg.ptr` (HSA kernarg ABI).
- [ ] `mojo/stdlib/std/sys/intrinsics.mojo:900` — `comptime assert is_amd_gpu(), ...` — `readfirstlane(Pointer)` = `llvm.amdgcn.readfirstlane`.
- [ ] `mojo/stdlib/std/sys/intrinsics.mojo:917` — `comptime assert is_amd_gpu(), ...` — `readfirstlane(Int)` = `llvm.amdgcn.readfirstlane`.
- [ ] `mojo/stdlib/std/sys/intrinsics.mojo:939` — `comptime assert is_amd_gpu(), ...` — `readfirstlane[dtype](Scalar)` = `llvm.amdgcn.readfirstlane`. (Pre-classified wave-width; it is an intrinsic guard like its two siblings.)
- [ ] `mojo/stdlib/std/sys/intrinsics.mojo:963` — `comptime assert is_amd_gpu(), ...` — `sendmsg` = `llvm.amdgcn.s.sendmsg`.
- [ ] `mojo/stdlib/std/sys/intrinsics.mojo:990` — `comptime assert is_amd_gpu(), ...` — `ballot` = `llvm.amdgcn.ballot` (EXEC-mask read).
- [ ] `mojo/stdlib/std/time/time.mojo:215` — `elif is_amd_gpu():` — `global_perf_counter_ns` AMD path reads `s_memrealtime` ticks (`_amd_gpu_realtime`).
- [ ] `mojo/stdlib/std/time/time.mojo:318` — `elif is_amd_gpu():` — `sleep` AMD path loops `s_sleep` against the `s_memrealtime` counter (ROCm ockl rtcwait idiom).

### max/kernels — 34

- [ ] `max/kernels/src/linalg/bmm.mojo:651` — `elif is_amd_gpu() and not _is_amd_rdna():` — dispatches batched matmul to `AMDMatmul` (MFMA-based CDNA kernel).
- [ ] `max/kernels/src/linalg/gemv.mojo:453` — `is_amd_gpu()` (in compound condition) — `_dot_accum` bf16 path emits `llvm.amdgcn.fdot2.f32.bf16`.
- [ ] `max/kernels/src/layout/layout_tensor.mojo:6405` — `comptime assert is_amd_gpu(), "This function is only supported on AMD GPUs."` — `copy_dram_to_sram` built on `make_amd_buffer_resource` + `buffer_load`.
- [ ] `max/kernels/src/layout/layout_tensor.mojo:7340` — `comptime assert is_amd_gpu(), ...` — `_copy_local_to_dram` writes through `AMDBufferResource.store`.
- [ ] `max/kernels/src/layout/layout_tensor.mojo:7454` — `comptime assert is_amd_gpu(), ...` — `copy_local_to_dram` wrapper constructing the AMD buffer descriptor.
- [ ] `max/kernels/src/layout/layout_tensor.mojo:7475` — `comptime assert is_amd_gpu(), ...` — `_copy_dram_to_local` reads through `AMDBufferResource` buffer loads. (Pre-classified wave-width; it is buffer-descriptor I/O.)
- [ ] `max/kernels/src/layout/layout_tensor.mojo:7584` — `comptime assert is_amd_gpu(), ...` — `copy_dram_to_local` wrapper (`make_amd_buffer_resource(src_base)`).
- [ ] `max/kernels/src/layout/layout_tensor.mojo:7608` — `comptime assert is_amd_gpu(), ...` — `_copy_dram_to_local` iterator overload, same buffer-load machinery.
- [ ] `max/kernels/src/layout/layout_tensor.mojo:7898` — `is_amd_gpu()` (multiline assert) — `copy_local_to_shared` row-major branch whose store order exists to mirror AMD `copy_dram_to_local` buffer-load ordering.
- [ ] `max/kernels/src/nn/softmax.mojo:1865` — `fragment_transpose and is_amd_gpu()` — assert restricting `fragment_transpose` (AMD MFMA output-fragment ordering, `col_major(16, 4)` warp tile) to AMD in a validation-only kernel. **Low confidence** — the 16x4 = 64-lane tile also encodes wave64, so this has a wave-width flavor, but the fragment order comes from MFMA, which our AIR target never emits.
- [ ] `max/kernels/src/nn/attention/mha_utils.mojo:682` — `elif is_amd_gpu():` — `_copy_frag_to_smem` dispatch to `_copy_frag_to_smem_amd` (MFMA fragment layout). (Pre-classified wave-width; the fragment geometry is tensor-core ISA.)
- [ ] `max/kernels/src/nn/attention/gpu/mla.mojo:1895` — `elif is_amd_gpu():` — MLA decode dispatch to the AMD `Attention` kernel (MFMA + AMD tile-IO).
- [ ] `max/kernels/src/nn/attention/gpu/mla.mojo:3700` — `elif is_amd_gpu():` — MLA prefill dispatch to the AMD `Attention` kernel.
- [ ] `max/kernels/src/nn/attention/gpu/mha.mojo:2879` — `elif is_amd_gpu():` — MHA prefill dispatch to `Attention`/`AttentionRDNA` (comment: "different fragment geometry / wave size / WMMA intrinsics" — all tensor-core ISA concerns handled inside the AMD subtree).
- [ ] `max/kernels/src/nn/attention/gpu/mha.mojo:4684` — `elif is_amd_gpu():` — MHA decode dispatch to `Attention`/`AttentionRDNA`.
- [ ] `max/kernels/src/shmem/_rocshmem.mojo:441` — `comptime if is_amd_gpu():` — `rocshmem_my_pe`: device-side `external_call` into the ROCSHMEM device library (vs host dlopen).
- [ ] `max/kernels/src/shmem/_rocshmem.mojo:453` — `elif is_amd_gpu():` — `rocshmem_n_pes`: same ROCSHMEM device/host linkage split.
- [ ] `max/kernels/src/shmem/_rocshmem.mojo:578` — `comptime if is_amd_gpu():` — `rocshmem_p`: ROCSHMEM device-library call.
- [ ] `max/kernels/src/shmem/_rocshmem.mojo:684` — `comptime if is_amd_gpu():` — `rocshmem_barrier_all`: ROCSHMEM device-library call.
- [ ] `max/kernels/src/shmem/shmem_api.mojo:388` — `elif is_amd_gpu() or has_amd_gpu_accelerator():` — `shmem_my_pe` → `rocshmem_my_pe` (NVSHMEM/ROCSHMEM runtime dispatch).
- [ ] `max/kernels/src/shmem/shmem_api.mojo:405` — `elif is_amd_gpu() or has_amd_gpu_accelerator():` — `shmem_n_pes` → `rocshmem_n_pes`.
- [ ] `max/kernels/src/shmem/shmem_api.mojo:636` — `elif is_amd_gpu():` — `shmem_get_nbi` → `rocshmem_get_nbi`.
- [ ] `max/kernels/src/shmem/shmem_api.mojo:662` — `elif is_amd_gpu():` — `shmem_g` → `rocshmem_g`.
- [ ] `max/kernels/src/shmem/shmem_api.mojo:699` — `elif is_amd_gpu():` — `shmem_put` → `rocshmem_put`.
- [ ] `max/kernels/src/shmem/shmem_api.mojo:738` — `elif is_amd_gpu():` — `shmem_put_nbi` → `rocshmem_put_nbi`.
- [ ] `max/kernels/src/shmem/shmem_api.mojo:769` — `elif is_amd_gpu() or has_amd_gpu_accelerator():` — `shmem_p` → `rocshmem_p`.
- [ ] `max/kernels/src/shmem/shmem_api.mojo:847` — `elif is_amd_gpu():` — `shmem_put_signal_nbi` → `rocshmem_put_signal_nbi`.
- [ ] `max/kernels/src/shmem/shmem_api.mojo:880` — `elif is_amd_gpu() or has_amd_gpu_accelerator():` — `shmem_barrier_all` → `rocshmem_barrier_all`.
- [ ] `max/kernels/src/shmem/shmem_api.mojo:921` — `elif is_amd_gpu():` — `shmem_signal_wait_until` → `rocshmem_signal_wait_until`.
- [ ] `max/kernels/src/shmem/shmem_api.mojo:947` — `elif is_amd_gpu():` — `shmem_fence` → `rocshmem_fence`.
- [ ] `max/kernels/src/shmem/shmem_api.mojo:985` — `elif is_amd_gpu():` — `shmemx_signal_op` → `rocshmemx_signal_op`.
- [ ] `max/kernels/src/shmem/ep_comm.mojo:132` — `elif is_amd_gpu():` — `_BLOCK_SCOPE` returns the AMDGPU LLVM syncscope string `"workgroup"` (backend memory-model naming).
- [ ] `max/kernels/src/shmem/ep_comm.mojo:144` — `elif is_amd_gpu():` — `_DEVICE_SCOPE` returns the AMDGPU syncscope string `"agent"`.
- [ ] `max/kernels/src/structured_kernels/amd_tile_io.mojo:162` — `comptime assert is_amd_gpu(), "_load_to_lds is AMD-only"` — direct `buffer_load_lds` DMA with `amdgpu.AsyncCopies` alias scoping.

## wave-width (re-gate on is_wave64/WARP_SIZE) — 1

- [ ] `mojo/stdlib/std/gpu/globals.mojo:65` — `elif is_amd_gpu():` — `_resolve_warp_size` returns 64 here because AMD CDNA waves are 64 lanes: the one code site whose *content* is lane count — **re-gate: NO CHANGE NEEDED** — the fork's `is_apple_gpu()` arm (lines 67–70, VEGA-FORK) already resolves our width via `GPUInfo.from_name[_accelerator_arch()]().warp_size` instead of assuming 32, so `WARP_SIZE`/`is_wave64()` are already correct on this target; keep the AMD arm as-is for real amdhsa targets.

## mixed — 0

No site both selects AMD instructions *and* separately encodes lane count in
a way our target must inherit; in every instruction-selecting branch the
width dependence has already been factored into `WARP_SIZE`-derived
parameters shared by all vendors.

## neither (vendor check for something unrelated) — 19

- [ ] `mojo/stdlib/std/builtin/debug_assert.mojo:593` — `elif is_amd_gpu():` — device-printf plumbing: AMD's hostcall `printf_begin`/`printf_append_string_n` service workaround for `%s` (MSTDL-1783); printing, not compute.
- [ ] `mojo/stdlib/std/builtin/simd.mojo:303` — `return _is_sm_9x_or_newer() or is_nvidia_gpu["sm_89"]() or is_amd_gpu()` — `_has_native_f8_support` feature availability; correctly false for us (Vega has no FP8).
- [ ] `mojo/stdlib/std/builtin/simd.mojo:2294` — `comptime if Self.dtype == DType.bfloat16 and is_amd_gpu():` — software `_bfloat16_to_f32` cast workaround for the AMDGPU LLVM backend's bf16 handling; our AIR path uses the generic `pop.cast`.
- [ ] `mojo/stdlib/std/gpu/globals.mojo:81` — `` reachable only via `is_amd_gpu()` ``. — docstring text inside `is_wave64()`, not code.
- [ ] `mojo/stdlib/std/io/io.mojo:226` — `elif is_amd_gpu():` — `_printf` AMD path: hostcall printf ABI (Triton-derived lowering); printing.
- [ ] `mojo/stdlib/std/io/io.mojo:440` — `elif is_amd_gpu():` — `print` GPU path: AMD hostcall printf; the `is_apple_gpu()` branch (`_metal_print_write`) already serves us.
- [ ] `mojo/stdlib/std/memory/unsafe.mojo:81` — `comptime if not is_nvidia_gpu() and not is_amd_gpu():` — guards comptime asserts forbidding f16↔2xi8 bitcasts on Arm-ish targets (MOCO-2179); dtype-cast capability, nothing to do with waves (note: our Apple-classified GPU falls in the restricted set — harmless unless a kernel does exactly those casts).
- [ ] `mojo/stdlib/std/sys/info.mojo:1167` — `def is_amd_gpu() -> Bool:` — the predicate's own definition (`amdgcn-amd-amdhsa` triple test); not a gating site.
- [ ] `mojo/stdlib/std/sys/info.mojo:1188` — `return is_amd_gpu() and CompilationTarget._is_arch[subarch]()` — definition of the subarch-parameterized `is_amd_gpu[subarch]` predicate.
- [ ] `mojo/stdlib/std/sys/info.mojo:1198` — `return is_nvidia_gpu() or is_amd_gpu() or is_apple_gpu()` — `is_gpu()` definition; our target already counted via `is_apple_gpu()`.
- [ ] `mojo/stdlib/std/sys/info.mojo:1637` — `is_amd_gpu()` — inside `has_amd_gpu_accelerator()`: host-side accelerator-vendor detection (`_vendor_from_arch`), not a device gate.
- [ ] `max/kernels/src/comm/broadcast.mojo:47` — `comptime _target_address_space = AddressSpace.GLOBAL if is_amd_gpu() else AddressSpace.GENERIC` — multi-GPU P2P perf tuning ("loads from GLOBAL give better performance on AMD systems"); unreachable on a single Metal-driven GPU. **Low confidence** — as AMD silicon we might share the perf characteristic, but the comm path itself needs HIP P2P we don't have.
- [ ] `max/kernels/src/comm/sync.mojo:469` — `comptime if need_fence or is_amd_gpu():` — full acquire/release fence instead of volatile spin in the multi-GPU barrier (KERN-3443, cause unknown). **Low confidence** — if this reflects an AMD-silicon memory-model property our Vega shares it would matter, but the multi-GPU P2P barrier is unreachable via Metal, and the vendor gate is not about lane width either way.
- [ ] `max/kernels/src/comm/allreduce.mojo:1044` — `return is_nvidia_gpu() or is_amd_gpu()` — `_lamport_supported`: feature availability (guaranteed single-transaction 128-bit volatile load/store for the Lamport allreduce); correctly excludes our unproven Metal path.
- [ ] `max/kernels/src/comm/reducescatter.mojo:59` — `comptime _target_address_space = AddressSpace.GLOBAL if is_amd_gpu() else AddressSpace.GENERIC` — same address-space perf tuning as broadcast.mojo:47.
- [ ] `max/kernels/src/linalg/gemv.mojo:484` — `elif is_amd_gpu():` — `_dot_accum` non-bf16 fallback: vector `reduce_add()` on AMD vs scalar FMA chain elsewhere, a register-pressure codegen heuristic. **Low confidence** — purely perf, both branches numerically fine, but which is faster for AIR-on-GCN is untested; worth benchmarking `is_amd_gpu() → is_amd_gpu() or is_apple_gpu()` here later.
- [ ] `max/kernels/src/linalg/gemv.mojo:632` — `comptime if is_amd_gpu():` — weight-tile load with `non_temporal` streaming hint on AMD vs plain vectorized load; cache-policy perf tuning, not lane count. (Pre-classified wave-width; it is a cache hint.)
- [ ] `max/kernels/src/shmem/ep_comm.mojo:2176` — `comptime if is_amd_gpu():` — volatile-poll-then-acquire-fence instead of ACQUIRE atomic load (KERN-3184 perf workaround) in EP dispatch; memory-ordering tuning in RDMA code unreachable on our target.
- [ ] `max/kernels/src/shmem/ep_comm.mojo:3620` — `comptime if is_amd_gpu():` — same KERN-3184 volatile-poll workaround in EP combine.

## Notes / derived findings (not `is_amd_gpu()` sites, found during the pass)

1. **`_vote_apple_helper` truncates ballots on wave64**
   (`mojo/stdlib/std/gpu/primitives/warp.mojo:~1388`): the Apple path our
   target takes uses `llvm.air.simd_ballot.i32` and zero-extends to 64 bits,
   so lanes 32–63 can never be reported. On a 64-lane simdgroup `vote`
   returns a wrong mask. This is the real wave-width bug in the warp module —
   in the Apple branch, not the AMD one.
2. `match_any` / `match_all` default `mask_type` on `WARP_SIZE <= 32` and the
   Apple emulation sweeps `range(WARP_SIZE)` — already correct for wave64,
   but both funnel through `vote`/ballot-free shuffles, so they dodge finding
   (1); anything else built on `warp.vote` does not.
3. `_FULL_MASK = UInt(2**WARP_SIZE - 1)` and `_WIDTH_MASK = WARP_SIZE - 1`
   (warp.mojo:~55) are already width-parametric; no vendor gate involved.
4. The tensor-core kernel subtrees (mha/mla/bmm `Attention`, `AMDMatmul`,
   `amd_tile_io`, `mha_utils` fragment copies) have **no** Apple branch —
   they hit `unsupported_target_error` on us. Bringing attention/matmul up
   on this fork is a porting project (AIR simdgroup ops), not a re-gating
   exercise.
5. The zero-`WARP_SIZE ==`-comparisons claim in the old header is now moot:
   width already flows through `WARP_SIZE`/`GPUInfo`; the single genuine
   lane-count site (globals.mojo:65) is handled.
