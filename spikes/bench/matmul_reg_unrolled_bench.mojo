# ===----------------------------------------------------------------------=== #
# Register-blocked tiled matmul: the benchmark that tests the compilers.
#
# The companion kernel, matmul_sram_bench.mojo, is bound by threadgroup-memory
# bandwidth: it reads TWO threadgroup values per FMA, 0.25 flops per byte, and
# both ports measured to date sit near a tenth of their ALU peak with their
# arithmetic units starved. A ranking on that kernel ranks memory subsystems.
#
# This one gives each thread a 4x4 block of outputs. Per step it reads 4 values
# from each tile and issues 16 FMAs -- 8 reads for 32 flops, 1 flop per byte,
# FOUR TIMES the arithmetic intensity. That moves the bottleneck off
# threadgroup memory and onto register allocation and instruction scheduling,
# which is where a backend can actually distinguish itself.
#
# Same harness as the companion: all-ones inputs so every output must equal K
# exactly, correctness checked on EVERY timed shape, ragged shapes included
# because those are the ones that break.
# ===----------------------------------------------------------------------=== #

from std.math import ceildiv
from std.gpu import block_idx, thread_idx
from max.gpu.sync import barrier
from max.gpu.host import DeviceContext
from std.memory import unsafe_stack_allocation, alloc
from std.time import perf_counter_ns
from std.benchmark import keep

# 64x64 output tile per threadgroup, 16 deep in K, computed by 16x16 threads
# each owning a 4x4 block. 8 KB of threadgroup memory, well inside the 64 KB
# a GCN workgroup has.
comptime BM = 64
comptime BN = 64
comptime BK = 16
comptime TM = 4
comptime TN = 4
comptime NTHREAD = (BM // TM) * (BN // TN)  # 256


def matmul_reg(
    a_ptr: UnsafePointer[Float32, MutAnyOrigin],
    b_ptr: UnsafePointer[Float32, MutAnyOrigin],
    c_ptr: UnsafePointer[Float32, MutAnyOrigin],
    M_dev: Int32,
    N_dev: Int32,
    K_dev: Int32,
):
    var M = Int(M_dev)
    var N = Int(N_dev)
    var K = Int(K_dev)

    var a_shared = unsafe_stack_allocation[
        BM * BK, DType.float32, address_space = AddressSpace.SHARED
    ]()
    var b_shared = unsafe_stack_allocation[
        BK * BN, DType.float32, address_space = AddressSpace.SHARED
    ]()

    var tx = Int(thread_idx.x)
    var ty = Int(thread_idx.y)
    var tid = ty * (BN // TN) + tx
    var block_row = Int(block_idx.y) * BM
    var block_col = Int(block_idx.x) * BN

    # 4x4 accumulators, held in registers.
    var acc = SIMD[DType.float32, TM * TN](0)

    var offset = 0
    while offset < K:
        # Cooperative load: 256 threads, 1024 elements per tile, 4 each.
        for i in range(BM * BK // NTHREAD):
            var e = tid + i * NTHREAD
            var r = e // BK
            var c = e % BK
            var gr = block_row + r
            var gc = offset + c
            a_shared[e] = (
                a_ptr[gr * K + gc] if (gr < M and gc < K) else Float32(0)
            )
        for i in range(BK * BN // NTHREAD):
            var e = tid + i * NTHREAD
            var r = e // BN
            var c = e % BN
            var gr = offset + r
            var gc = block_col + c
            b_shared[e] = (
                b_ptr[gr * N + gc] if (gr < K and gc < N) else Float32(0)
            )

        barrier()

        # The point of the whole kernel: 8 threadgroup reads, 16 FMAs.
        comptime for k in range(BK):
            var ra = SIMD[DType.float32, TM](0)
            var rb = SIMD[DType.float32, TN](0)
            comptime for i in range(TM):
                ra[i] = a_shared.load((ty * TM + i) * BK + k)
            comptime for j in range(TN):
                rb[j] = b_shared.load(k * BN + tx * TN + j)
            comptime for i in range(TM):
                comptime for j in range(TN):
                    acc[i * TN + j] += ra[i] * rb[j]

        barrier()
        offset += BK

    comptime for i in range(TM):
        comptime for j in range(TN):
            var gr = block_row + ty * TM + i
            var gc = block_col + tx * TN + j
            if gr < M and gc < N:
                c_ptr[gr * N + gc] = acc[i * TN + j]


def bench_shape[M: Int, N: Int, K: Int](ctx: DeviceContext, label: StaticString) raises:
    comptime iters = 20
    comptime reps = 3

    var a_dev = ctx.enqueue_create_buffer[DType.float32](M * K)
    var b_dev = ctx.enqueue_create_buffer[DType.float32](K * N)
    var c_dev = ctx.enqueue_create_buffer[DType.float32](M * N)

    with a_dev.map_to_host() as h:
        for i in range(M * K):
            h[i] = Float32(1)
    with b_dev.map_to_host() as h:
        for i in range(K * N):
            h[i] = Float32(1)

    ctx.enqueue_function[matmul_reg](
        a_dev, b_dev, c_dev, Int32(M), Int32(N), Int32(K),
        grid_dim=(ceildiv(N, BN), ceildiv(M, BM)),
        block_dim=(BN // TN, BM // TM),
    )
    ctx.synchronize()

    var gpu_ms = 1.0e30
    for _ in range(reps):
        var g0 = perf_counter_ns()
        for _ in range(iters):
            ctx.enqueue_function[matmul_reg](
                a_dev, b_dev, c_dev, Int32(M), Int32(N), Int32(K),
                grid_dim=(ceildiv(N, BN), ceildiv(M, BM)),
                block_dim=(BN // TN, BM // TM),
            )
        ctx.synchronize()
        var ms = Float64(perf_counter_ns() - g0) / Float64(iters) / 1_000_000.0
        if ms < gpu_ms:
            gpu_ms = ms

    var bad = 0
    with c_dev.map_to_host() as h:
        for i in range(M * N):
            if h[i] != Float32(K):
                bad += 1

    var gflops = (2.0 * Float64(M) * Float64(N) * Float64(K)) / (gpu_ms * 1.0e6)
    print(
        label, " M=", M, " N=", N, " K=", K,
        " | gpu=", gpu_ms, "ms  gflops=", gflops,
        " | ", "EXACT" if bad == 0 else "WRONG",
        "" if bad == 0 else String(bad),
    )


def main() raises:
    print("== register-blocked matmul (comptime-unrolled), f32, 64x64 tile, 4x4 per thread")
    print("== correctness is exact-equality on every timed shape")
    with DeviceContext() as ctx:
        print("device:", ctx.name())
        bench_shape[512, 512, 512](ctx, "aligned  ")
        bench_shape[1024, 1024, 1024](ctx, "aligned  ")
        bench_shape[2048, 2048, 2048](ctx, "aligned  ")
        bench_shape[513, 502, 511](ctx, "ragged   ")
        bench_shape[1025, 1022, 1023](ctx, "ragged   ")
