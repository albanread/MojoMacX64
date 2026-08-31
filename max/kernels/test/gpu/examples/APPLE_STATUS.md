# Mojo GPU examples on Apple silicon

Status measured on 30 August 2026 on an Apple M4 Max with the CocoaMojo AIR
compiler, the source-built AppleGPURT from this experiment, and both
`MTL_DEBUG_LAYER=1` and `MTL_SHADER_VALIDATION=1` enabled.

## Result

Ten of the eleven examples compile, create Metal pipelines, execute, and pass
their numerical oracle. The remaining example is explicitly NVIDIA-only and
requires an `mma` operation for which it has no Apple implementation.

| Example | Apple result | Oracle or boundary exercised |
| --- | --- | --- |
| `test_mandelbrot` | Pass | CPU/GPU image comparison |
| `test_matmul_1_sram` | Pass | Ragged 513x502x511 shared-memory matmul |
| `test_matmul_sram_dims` | Pass | Eight aligned and ragged dimension combinations |
| `test_matmul_int` | Pass, Apple exclusion removed | Full 512x512 integer result, not a printed sample |
| `test_matmul_kernel_10` | Pass | Full optimized-versus-naive 4096x4096 result |
| `test_double_buffer_gemm` | Pass, Apple exclusion removed | Full optimized-versus-naive 8192x8192 result |
| `test_scatterND` | Pass, manual tag removed | Full reference tensor comparison |
| `test_stencil1d` | Pass | Global and shared variants match FileCheck output |
| `test_stencil2d` | Pass | Global and shared variants match FileCheck output |
| `test_stencil_gpu` | Pass | Average/max pooling variants match host references |
| `test_tiled_matmul_backtoback` | NVIDIA-only | Compile reaches `mma` and fails the target capability assertion |

The package-level Bazel command does not currently reach Mojo compilation. It
fails first while linking `bazel/mlir-shared/libMLIR.dylib` because LLVM C++
symbols are unresolved. The matrix above was therefore compiled directly with
the CocoaMojo distribution and run against the experiment runtime. This is a
build-graph blocker, not an AIR or numerical result, and the Bazel gate still
needs to be restored.

## Fixes made

`test_matmul_int` was not failing on Apple; its incompatibility marker was
stale. The test now scans all 262,144 outputs and fails on the first mismatch.

`test_scatterND` had drifted from current Mojo APIs. Its device scalars were
host-sized `Int`, its `TileTensor` address spaces did not match the copy API,
and its multiline specialization expression never called the test function.
Those are source/test defects rather than AIR limitations. The repaired test
now executes and its manual tag is removed.

`test_double_buffer_gemm` assumed every non-NVIDIA GPU used AMD-style wave64
geometry. Apple uses 32-lane SIMD groups. Its original tile also exceeded the
Apple threadgroup-memory budget. The Apple specialization now uses 128 threads
and a 64x128x8 tile; Metal reports 25,088 bytes of static threadgroup storage.
Three 200-run samples sustained 4.46-4.51 TFLOP/s. The equally sized 128x64x8
orientation was numerically correct but sustained only 4.12-4.18 TFLOP/s, so
the selected orientation is about 8% faster on this M4 Max.

`test_matmul_kernel_10` now uses an 8-deep K tile on Apple. This preserves its
output and warp geometry while reducing Metal's reported static threadgroup
storage from 33,280 to 16,640 bytes. Its benchmark reports 1,707.8
GElements/s versus 500.6 GElements/s for the naive comparison kernel, a 3.41x
speedup, while the full result comparison passes.

AppleGPURT now checks the pipeline's static storage plus launch-time dynamic
storage against `maxThreadgroupMemoryLength` before creating an encoder. An
invalid kernel therefore returns a located runtime error instead of triggering
a Metal API-validation process abort. The runtime smoke covers the rejection
and passes in batched, asynchronous-unbatched, and synchronous modes.

## Systemic findings and recommended changes

1. **Select kernels by capability, not by “NVIDIA versus everything else.”**
   The double-buffer example treated Apple as AMD in both subgroup layout and
   tile shape. Move SIMD width, maximum threadgroup bytes, and preferred tile
   geometry into the Apple target profile. Kernel dispatch should consume
   those properties; chip- or vendor-name branches should be a last resort.

2. **Explain the non-monotonic static-storage accounting.** The lowered BK=8
   variants show an exact 2x ratio: `test_matmul_kernel_10` declares 8,320
   bytes of shared arrays and its pipeline reports 16,640, while the tuned
   double-buffer kernel declares 12,544 and reports 25,088. Yet the original
   128x128x16 double-buffer tile is rejected at pipeline creation with 33,280
   bytes, equal to its declared arrays rather than twice them. Retain pre- and
   post-legalization AIR for minimal one- and two-array kernels and determine
   whether allocation liveness, unswitching, inlining, or AIR metadata explains
   the discontinuity. Correct accounting may recover deeper K tiles and
   performance.

3. **Make static storage part of the compiler/runtime contract.** Emit an
   expected static-threadgroup byte count in the kernel manifest, verify it
   after pipeline creation, and fail compilation when the target limit is
   exceeded. Runtime preflight remains necessary for device variation, but an
   oversized static specialization should normally be rejected before launch.

4. **Require numerical oracles in examples promoted to tests.** Printing a
   10x10 corner allowed integer matmul to appear useful without proving the
   other 262,044 cells. Every example in the default test set should compare
   its complete output, a deterministic digest, or a deliberately sampled set
   whose coverage is stated.

5. **Separate compiler diagnostics from capability results.** `test_stencil_gpu`
   executes correctly even though the current legality logger reports
   `llvm.maxnum.f32` as an unresolved external. Register known driver-accepted
   intrinsics or lower them explicitly so successful kernels do not train
   developers to ignore legality output.

6. **Keep the tensor-core boundary explicit.** Back-to-back matmul is not a
   generic matmul failure; it is written around NVIDIA `mma`. Keep its NVIDIA
   constraint. An Apple version should be a distinct specialization using the
   supported 8x8 simdgroup-matrix path on M4 and the capability-gated 16x16 path
   on M5, with a scalar/shared-memory fallback only if its performance is
   measured and acceptable.
