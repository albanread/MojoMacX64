# Measure how the AIR backend schedules wide, independent Float32 arithmetic.
#
# Apple GPU SIMD is across threads. A wide Mojo SIMD value held by one thread
# therefore has to become independent scalar/float4 operations before it can
# execute. This benchmark deliberately keeps CHAINS independent recurrence
# chains live in each thread and reports enough work to make dispatch latency
# negligible. It is an oracle for AIR lowering changes, not an application
# benchmark.

from std.gpu import global_idx
from std.math import iota
from std.time import perf_counter_ns
from max.gpu.host import DeviceContext

comptime N = 32768
comptime ITERS = 4096
comptime REPEATS = 32
comptime BLOCK = 256
comptime GRID = (N + BLOCK - 1) // BLOCK


def fma_chains[CHAINS: Int](
    dst: Pointer[Float32, MutAnyOrigin], n: Int32
):
    var idx = Int(global_idx.x)
    var xf = Float32(idx)
    # Per-thread operands prevent the loop from being folded into a constant.
    var mul = xf * Float32(1.0e-7) + Float32(1.0000001)
    var add = xf * Float32(1.0e-8) + Float32(0.9999999)
    var acc = iota[DType.float32, CHAINS]() * Float32(1.0e-6)
    for _ in range(ITERS):
        acc = mul * acc + add
    if idx < Int(n):
        dst[unsafe_offset=idx] = acc.reduce_add()


def bench[CHAINS: Int](ctx: DeviceContext) raises:
    var dst = ctx.enqueue_create_buffer[DType.float32](N)
    var kernel = ctx.compile_function[fma_chains[CHAINS]]()

    # Compile/pipeline creation and the first dispatch are outside the sample.
    ctx.enqueue_function(
        kernel, dst, Int32(N), grid_dim=(GRID), block_dim=(BLOCK)
    )
    ctx.synchronize()

    var begin = perf_counter_ns()
    for _ in range(REPEATS):
        ctx.enqueue_function(
            kernel, dst, Int32(N), grid_dim=(GRID), block_dim=(BLOCK)
        )
    ctx.synchronize()
    var elapsed_ns = perf_counter_ns() - begin

    var elapsed_s = Float64(elapsed_ns) / 1.0e9
    var flops = Float64(N) * Float64(ITERS) * Float64(CHAINS) * 2.0
    flops *= Float64(REPEATS)
    var tflops = flops / elapsed_s / 1.0e12

    # Force a host-visible correctness observation after the timed region.
    var checksum: Float32
    with dst.map_to_host() as host:
        checksum = Float32(host[0]) + Float32(host[N - 1])
    print(
        "chains=", CHAINS,
        " elapsed_ms=", Float64(elapsed_ns) / 1.0e6,
        " TFLOP/s=", tflops,
        " checksum=", checksum,
    )


def main() raises:
    var ctx = DeviceContext(api="metal")
    print("AIR FMA schedule —", ctx.name())
    bench[4](ctx)
    bench[8](ctx)
    bench[16](ctx)
    # Explicit SIMD widths 32 and 64 are a separate capability boundary on
    # this M4 Max: the metallib loads, but Metal's pipeline compiler terminates
    # its XPC connection for either scalarizer setting. Keep this performance
    # oracle runnable; widen it again when that compiler boundary is reduced.
