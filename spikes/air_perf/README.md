# AIR performance oracles

`fma_peak_bench.mojo` measures the schedule produced for independent Float32
recurrence chains held in one thread. It is intentionally small enough to run
while changing the AIR backend and large enough that a synchronization round
trip does not dominate every sample.

Build and run it through the CocoaMojo distribution:

```bash
cocoamojo --build fma_peak_bench.mojo -o /tmp/fma_peak_bench
/tmp/fma_peak_bench
APPLEGPU_SYNC_LAUNCH=1 /tmp/fma_peak_bench
```

On an M4 Max, 30 August 2026, the asynchronous-default runtime reduced the
warm 32-dispatch sample from 12.44 to 8.64 ms at four chains, 15.10 to 11.04
ms at eight chains, and 22.20 to 16.61 ms at sixteen chains. Checksums were
identical in both modes. This is 1.44x, 1.37x, and 1.34x throughput,
respectively.

Command-buffer batching is intentionally visible here as a separate runtime
axis. Ten alternating runs were neutral at four and eight chains and roughly
1% faster at sixteen; these kernels are compute-bound once warm. The
35-dispatch fluid workload improves by about 12%, which confirms that batching
removes submission overhead rather than changing generated arithmetic.

The LLVM wide-vector scalarizer was tested both as float4 fragments
(`APPLEGPU_AIR_SCALARIZE_MIN_BITS=128`) and as scalars (`=32`). Neither
improved the stable width-4/8/16 results. Explicit SIMD widths 32 and 64 are a
separate capability failure on this M4 Max: metallib creation succeeds, but
pipeline-state creation terminates the Metal compiler connection with
`XPC_ERROR_CONNECTION_INTERRUPTED`, with scalarization on or off. Do not
enable the scalarizer by default on the strength of IR shape alone. Reduce the
width-32 PSO failure, then split wide per-thread values before the form that
causes Apple's compiler to fail.
