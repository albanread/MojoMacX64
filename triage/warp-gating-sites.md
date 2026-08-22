# Warp-gating triage: the 92 `is_amd_gpu()` sites

Per review (2026-08-22): the tree encodes lane count as vendor identity —
92 `is_amd_gpu()` sites, zero `WARP_SIZE ==` comparisons. This fork's GPU
is AMD silicon behind an Apple target, so every site must be sorted into:
**ISA-dispatch** (which instructions exist — stays vendor-gated) versus
**wave-width** (how wide the wave is — re-gate on `is_wave64()` /
`WARP_SIZE`, new in `std.gpu.globals`). Heuristic pre-classification
below; every row needs a human eye, especially the last bucket.

## ISA-dispatch (stays vendor-gated) — 24

- [ ] `mojo/stdlib/std/gpu/globals.mojo:65` — `elif is_amd_gpu():`
- [ ] `mojo/stdlib/std/gpu/globals.mojo:135` — `elif is_amd_gpu() or has_amd_gpu_accelerator():`
- [ ] `mojo/stdlib/std/gpu/intrinsics.mojo:376` — `elif is_amd_gpu():`
- [ ] `mojo/stdlib/std/gpu/intrinsics.mojo:933` — `is_amd_gpu()`
- [ ] `mojo/stdlib/std/gpu/intrinsics.mojo:1010` — `is_amd_gpu()`
- [ ] `mojo/stdlib/std/gpu/intrinsics.mojo:1342` — `is_amd_gpu()`
- [ ] `mojo/stdlib/std/gpu/intrinsics.mojo:1388` — `is_amd_gpu()`
- [ ] `mojo/stdlib/std/gpu/primitives/id.mojo:226` — `elif is_amd_gpu():`
- [ ] `mojo/stdlib/std/gpu/primitives/id.mojo:274` — `elif is_amd_gpu():`
- [ ] `mojo/stdlib/std/gpu/primitives/warp.mojo:1519` — `elif is_amd_gpu():`
- [ ] `mojo/stdlib/std/math/math.mojo:303` — `elif is_amd_gpu():`
- [ ] `mojo/stdlib/std/math/math.mojo:360` — `elif is_amd_gpu():`
- [ ] `mojo/stdlib/std/math/math.mojo:420` — `comptime if is_amd_gpu() and dtype in (DType.float16, DType.float32):`
- [ ] `mojo/stdlib/std/math/math.mojo:1004` — `elif is_amd_gpu() and dtype in (DType.float32, DType.float16):`
- [ ] `mojo/stdlib/std/sys/info.mojo:1167` — `def is_amd_gpu() -> Bool:`
- [ ] `mojo/stdlib/std/sys/info.mojo:1637` — `is_amd_gpu()`
- [ ] `mojo/stdlib/std/sys/intrinsics.mojo:874` — `comptime assert is_amd_gpu(), "This intrinsic is only defined for AMD GPUs"`
- [ ] `mojo/stdlib/std/sys/intrinsics.mojo:900` — `comptime assert is_amd_gpu(), "This intrinsic is only defined for AMD GPUs"`
- [ ] `mojo/stdlib/std/sys/intrinsics.mojo:917` — `comptime assert is_amd_gpu(), "This intrinsic is only defined for AMD GPUs"`
- [ ] `mojo/stdlib/std/sys/intrinsics.mojo:963` — `comptime assert is_amd_gpu(), "This intrinsic is only defined for AMD GPUs"`
- [ ] `mojo/stdlib/std/time/time.mojo:318` — `elif is_amd_gpu():`
- [ ] `max/kernels/src/linalg/bmm.mojo:651` — `elif is_amd_gpu() and not _is_amd_rdna():`
- [ ] `max/kernels/src/nn/attention/gpu/mha.mojo:2879` — `elif is_amd_gpu():`
- [ ] `max/kernels/src/structured_kernels/amd_tile_io.mojo:162` — `comptime assert is_amd_gpu(), "_load_to_lds is AMD-only"`

## wave-width (re-gate on is_wave64/WARP_SIZE) — 14

- [ ] `mojo/stdlib/std/gpu/globals.mojo:81` — `reachable only via `is_amd_gpu()`). This fork's primary GPU is AMD`
- [ ] `mojo/stdlib/std/gpu/primitives/id.mojo:160` — `comptime if is_amd_gpu():`
- [ ] `mojo/stdlib/std/gpu/primitives/warp.mojo:562` — `elif is_amd_gpu():`
- [ ] `mojo/stdlib/std/gpu/primitives/warp.mojo:659` — `elif is_amd_gpu():`
- [ ] `mojo/stdlib/std/gpu/primitives/warp.mojo:757` — `elif is_amd_gpu():`
- [ ] `mojo/stdlib/std/gpu/primitives/warp.mojo:858` — `elif is_amd_gpu():`
- [ ] `mojo/stdlib/std/gpu/primitives/warp.mojo:1425` — `elif is_amd_gpu():`
- [ ] `mojo/stdlib/std/gpu/primitives/warp.mojo:1640` — `elif is_amd_gpu():`
- [ ] `mojo/stdlib/std/sys/intrinsics.mojo:939` — `comptime assert is_amd_gpu(), "This intrinsic is only defined for AMD GPUs"`
- [ ] `max/kernels/src/layout/layout_tensor.mojo:7475` — `comptime assert is_amd_gpu(), "This function is only supported on AMD GPUs."`
- [ ] `max/kernels/src/linalg/gemv.mojo:632` — `comptime if is_amd_gpu():`
- [ ] `max/kernels/src/nn/attention/gpu/mla.mojo:1895` — `elif is_amd_gpu():`
- [ ] `max/kernels/src/nn/attention/gpu/mla.mojo:3700` — `elif is_amd_gpu():`
- [ ] `max/kernels/src/nn/attention/mha_utils.mojo:682` — `elif is_amd_gpu():`

## unclassified (needs eyes) — 55

- [ ] `mojo/stdlib/std/builtin/debug_assert.mojo:593` — `elif is_amd_gpu():`
- [ ] `mojo/stdlib/std/builtin/simd.mojo:303` — `return _is_sm_9x_or_newer() or is_nvidia_gpu["sm_89"]() or is_amd_gpu()`
- [ ] `mojo/stdlib/std/builtin/simd.mojo:2294` — `comptime if Self.dtype == DType.bfloat16 and is_amd_gpu():`
- [ ] `mojo/stdlib/std/gpu/intrinsics.mojo:646` — `if is_amd_gpu():`
- [ ] `mojo/stdlib/std/gpu/intrinsics.mojo:857` — `is_amd_gpu()`
- [ ] `mojo/stdlib/std/gpu/intrinsics.mojo:887` — `is_amd_gpu()`
- [ ] `mojo/stdlib/std/gpu/intrinsics.mojo:1107` — `is_amd_gpu()`
- [ ] `mojo/stdlib/std/gpu/intrinsics.mojo:1244` — `is_amd_gpu()`
- [ ] `mojo/stdlib/std/gpu/intrinsics.mojo:1288` — `is_amd_gpu()`
- [ ] `mojo/stdlib/std/gpu/primitives/id.mojo:104` — `elif is_amd_gpu():`
- [ ] `mojo/stdlib/std/gpu/primitives/id.mojo:334` — `elif is_amd_gpu():`
- [ ] `mojo/stdlib/std/gpu/primitives/id.mojo:389` — `elif is_amd_gpu():`
- [ ] `mojo/stdlib/std/gpu/primitives/warp.mojo:1010` — `and is_amd_gpu()`
- [ ] `mojo/stdlib/std/io/io.mojo:226` — `elif is_amd_gpu():`
- [ ] `mojo/stdlib/std/io/io.mojo:440` — `elif is_amd_gpu():`
- [ ] `mojo/stdlib/std/math/math.mojo:2185` — `elif is_amd_gpu():`
- [ ] `mojo/stdlib/std/memory/unsafe.mojo:81` — `comptime if not is_nvidia_gpu() and not is_amd_gpu():`
- [ ] `mojo/stdlib/std/sys/info.mojo:1188` — `return is_amd_gpu() and CompilationTarget._is_arch[subarch]()`
- [ ] `mojo/stdlib/std/sys/info.mojo:1198` — `return is_nvidia_gpu() or is_amd_gpu() or is_apple_gpu()`
- [ ] `mojo/stdlib/std/sys/intrinsics.mojo:990` — `comptime assert is_amd_gpu(), "This intrinsic is only defined for AMD GPUs"`
- [ ] `mojo/stdlib/std/time/time.mojo:215` — `elif is_amd_gpu():`
- [ ] `max/kernels/src/comm/allreduce.mojo:1044` — `return is_nvidia_gpu() or is_amd_gpu()`
- [ ] `max/kernels/src/comm/broadcast.mojo:47` — `comptime _target_address_space = AddressSpace.GLOBAL if is_amd_gpu() else AddressSpace.GENERIC`
- [ ] `max/kernels/src/comm/reducescatter.mojo:59` — `comptime _target_address_space = AddressSpace.GLOBAL if is_amd_gpu() else AddressSpace.GENERIC`
- [ ] `max/kernels/src/comm/sync.mojo:469` — `comptime if need_fence or is_amd_gpu():`
- [ ] `max/kernels/src/layout/layout_tensor.mojo:6405` — `comptime assert is_amd_gpu(), "This function is only supported on AMD GPUs."`
- [ ] `max/kernels/src/layout/layout_tensor.mojo:7340` — `comptime assert is_amd_gpu(), "This function is only supported on AMD GPUs."`
- [ ] `max/kernels/src/layout/layout_tensor.mojo:7454` — `comptime assert is_amd_gpu(), "This function is only supported on AMD GPUs."`
- [ ] `max/kernels/src/layout/layout_tensor.mojo:7584` — `comptime assert is_amd_gpu(), "This function is only supported on AMD GPUs."`
- [ ] `max/kernels/src/layout/layout_tensor.mojo:7608` — `comptime assert is_amd_gpu(), "This function is only supported on AMD GPUs."`
- [ ] `max/kernels/src/layout/layout_tensor.mojo:7898` — `is_amd_gpu()`
- [ ] `max/kernels/src/linalg/gemv.mojo:453` — `is_amd_gpu()`
- [ ] `max/kernels/src/linalg/gemv.mojo:484` — `elif is_amd_gpu():`
- [ ] `max/kernels/src/nn/attention/gpu/mha.mojo:4684` — `elif is_amd_gpu():`
- [ ] `max/kernels/src/nn/softmax.mojo:1865` — `fragment_transpose and is_amd_gpu()`
- [ ] `max/kernels/src/shmem/_rocshmem.mojo:441` — `comptime if is_amd_gpu():`
- [ ] `max/kernels/src/shmem/_rocshmem.mojo:453` — `elif is_amd_gpu():`
- [ ] `max/kernels/src/shmem/_rocshmem.mojo:578` — `comptime if is_amd_gpu():`
- [ ] `max/kernels/src/shmem/_rocshmem.mojo:684` — `comptime if is_amd_gpu():`
- [ ] `max/kernels/src/shmem/ep_comm.mojo:132` — `elif is_amd_gpu():`
- [ ] `max/kernels/src/shmem/ep_comm.mojo:144` — `elif is_amd_gpu():`
- [ ] `max/kernels/src/shmem/ep_comm.mojo:2176` — `comptime if is_amd_gpu():`
- [ ] `max/kernels/src/shmem/ep_comm.mojo:3620` — `comptime if is_amd_gpu():`
- [ ] `max/kernels/src/shmem/shmem_api.mojo:388` — `elif is_amd_gpu() or has_amd_gpu_accelerator():`
- [ ] `max/kernels/src/shmem/shmem_api.mojo:405` — `elif is_amd_gpu() or has_amd_gpu_accelerator():`
- [ ] `max/kernels/src/shmem/shmem_api.mojo:636` — `elif is_amd_gpu():`
- [ ] `max/kernels/src/shmem/shmem_api.mojo:662` — `elif is_amd_gpu():`
- [ ] `max/kernels/src/shmem/shmem_api.mojo:699` — `elif is_amd_gpu():`
- [ ] `max/kernels/src/shmem/shmem_api.mojo:738` — `elif is_amd_gpu():`
- [ ] `max/kernels/src/shmem/shmem_api.mojo:769` — `elif is_amd_gpu() or has_amd_gpu_accelerator():`
- [ ] `max/kernels/src/shmem/shmem_api.mojo:847` — `elif is_amd_gpu():`
- [ ] `max/kernels/src/shmem/shmem_api.mojo:880` — `elif is_amd_gpu() or has_amd_gpu_accelerator():`
- [ ] `max/kernels/src/shmem/shmem_api.mojo:921` — `elif is_amd_gpu():`
- [ ] `max/kernels/src/shmem/shmem_api.mojo:947` — `elif is_amd_gpu():`
- [ ] `max/kernels/src/shmem/shmem_api.mojo:985` — `elif is_amd_gpu():`
