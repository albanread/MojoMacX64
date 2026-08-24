# ===----------------------------------------------------------------------=== #
# Pure-compute FMA throughput: a benchmark for the COMPILER, not the memory.
#
# The other two rank memory subsystems. matmul_sram is bound by threadgroup
# bandwidth (0.25 flops/byte of LDS traffic); stream_bench is bound by DRAM by
# construction. Neither can show a compiler improvement, because neither is
# limited by anything a compiler controls.
#
# matmul_reg caught a real backend defect -- NVPTX putting a dynamically
# indexed accumulator in DRAM-backed local memory, 118x -- but by accident.
# It was built to move the bottleneck onto registers, not to measure the move.
#
# This one is deliberate. The inner loop touches NO memory at all:
#
#   CHAINS independent accumulators, each `acc = fma(acc, x, y)`
#
# Dependent within a chain, independent across chains. So the achievable rate
# is set by three things a compiler decides and nothing else:
#
#   1. whether the comptime-bounded loops UNROLL
#   2. whether the accumulators stay in REGISTERS
#   3. how well independent chains are INTERLEAVED to cover FMA latency
#
# CHAINS is swept, because the shape of the curve is the diagnosis. A backend
# that schedules well rises with CHAINS and then flattens at the point where
# FMA latency is covered. One that spills falls off as CHAINS grows. One that
# does not unroll never gets near peak at any width.
#
# Report GFLOP/s and, next to it, the emitted-code shape -- FMA count, branch
# count, spill slots. A number alone says a backend is slow; the pair says
# why, and moves when the compiler is fixed. That is the point of the whole
# exercise: this benchmark must be able to REGISTER an improvement.
# ===----------------------------------------------------------------------=== #

from std.gpu import global_idx
from max.gpu.host import DeviceContext
from std.time import perf_counter_ns

comptime block = 256
comptime groups = 512          # threadgroups; 512*256 = 131072 threads
comptime steps = 4096          # k-steps per thread


def fma_chains[CHAINS: Int](
    dst: UnsafePointer[Float32, MutAnyOrigin], n_dev: Int32
):
    var tid = Int(global_idx.x)
    # Seeded from the thread id so nothing is a compile-time constant and the
    # whole loop cannot be folded away.
    var x = Float32(tid) * Float32(1e-7) + Float32(1.0000001)
    var y = Float32(tid) * Float32(1e-8) + Float32(0.9999999)

    var acc = SIMD[DType.float32, CHAINS](0)
    comptime for c in range(CHAINS):
        acc[c] = Float32(c) * Float32(1e-6)

    for _ in range(steps):
        comptime for c in range(CHAINS):
            acc[c] = acc[c] * x + y

    var total = Float32(0)
    comptime for c in range(CHAINS):
        total += acc[c]
    if tid < Int(n_dev):
        dst[tid] = total


def bench[CHAINS: Int](ctx: DeviceContext) raises:
    comptime iters = 10
    comptime reps = 5
    comptime n = groups * block

    var dst = ctx.enqueue_create_buffer[DType.float32](n)

    ctx.enqueue_function[fma_chains[CHAINS]](
        dst, Int32(n), grid_dim=(groups), block_dim=(block)
    )
    ctx.synchronize()

    var samples = List[Float64]()
    for _ in range(reps):
        var t = perf_counter_ns()
        for _ in range(iters):
            ctx.enqueue_function[fma_chains[CHAINS]](
                dst, Int32(n), grid_dim=(groups), block_dim=(block)
            )
        ctx.synchronize()
        samples.append(Float64(perf_counter_ns() - t) / Float64(iters) / 1_000_000.0)
    for i in range(len(samples)):
        for j in range(i + 1, len(samples)):
            if samples[j] < samples[i]:
                var tmp = samples[i]
                samples[i] = samples[j]
                samples[j] = tmp
    var lo = samples[0]
    var med = samples[len(samples) // 2]
    var hi = samples[len(samples) - 1]

    # 2 flops per FMA, CHAINS per step, steps per thread, n threads.
    var flops = 2.0 * Float64(CHAINS) * Float64(steps) * Float64(n)

    # The result must be consumed or the entire loop is dead code. This
    # benchmark measures nothing at all if that happens, and it would look
    # like a spectacular score rather than a broken test.
    var live = Float32(0)
    with dst.map_to_host() as h:
        live = h[0] + h[n - 1]

    print(
        "  chains=", CHAINS,
        " gflops min/med/max=", flops / (hi * 1.0e6),
        "/", flops / (med * 1.0e6),
        "/", flops / (lo * 1.0e6),
        "  spread=", 100.0 * (hi - lo) / med, "%",
        "  live=", live,
    )


def main() raises:
    print("== pure-FMA throughput: no memory in the inner loop")
    print("== rises with chains while latency is being covered, then flattens")
    with DeviceContext() as ctx:
        print("device:", ctx.name())
        bench[1](ctx)
        bench[2](ctx)
        bench[4](ctx)
        bench[8](ctx)
        bench[16](ctx)
        bench[32](ctx)
