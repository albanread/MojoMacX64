# ===----------------------------------------------------------------------=== #
# Tiled shared-memory matmul on Apple Silicon: first measurable numbers.
#
# This kernel produced wrong answers on every shape with a ragged N until the
# workgroup barrier was marked convergent before optimisation -- loop
# unswitching had been CLONING the barrier per per-lane predicate, so the
# threadgroup never synchronised. Timing it before that was meaningless, and
# was declined on those grounds.
#
# So correctness is checked on EVERY timed shape, not once at the start. A
# fast wrong answer is worth nothing, and the specific failure this kernel had
# was silent -- no error, no validation complaint, just numbers that were low
# by the count of lanes on the wrong side of a branch.
#
# What this is NOT: a comparison against Modular's released compiler. That
# toolchain compiles for Apple Silicon but cannot RUN here -- its AsyncRT
# device symbols are absent from the wheel (JIT: "Symbols not found:
# _AsyncRT_DeviceContext_deviceName, ..."). It is a compile-time oracle only.
# The comparison here is GPU against a CPU reference on the same machine.
#
# Shapes deliberately include ragged dimensions. 512 is 16*32 exactly; 502,
# 511 and 513 are not multiples of the 32-wide tile, and the ragged-N case is
# the one that was broken.
# ===----------------------------------------------------------------------=== #

from std.math import ceildiv
from std.gpu import global_idx, thread_idx
from max.gpu.sync import barrier
from max.gpu.host import DeviceContext
from layout import TileTensor, Coord, row_major
from std.memory import unsafe_stack_allocation, alloc
from std.time import perf_counter_ns
from std.benchmark import keep

comptime tile_size = 32


def matmul_sram(
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
    var a = TileTensor(a_ptr, row_major(Coord(M, K)))
    var b = TileTensor(b_ptr, row_major(Coord(K, N)))
    var c = TileTensor(c_ptr, row_major(Coord(M, N)))

    var a_shared = unsafe_stack_allocation[
        tile_size * tile_size, DType.float32, address_space = AddressSpace.SHARED
    ]()
    var b_shared = unsafe_stack_allocation[
        tile_size * tile_size, DType.float32, address_space = AddressSpace.SHARED
    ]()

    var col = global_idx.x
    var row = global_idx.y
    var localCol = thread_idx.x
    var localRow = thread_idx.y
    var result = Float32(0.0)

    var offset = 0
    while offset < K:
        var a_val = a.load[width=1](Coord(Int(row), offset + Int(localCol))) if (
            Int(row) < M and offset + Int(localCol) < K
        ) else Float32(0)
        a_shared[Int(localRow) * tile_size + Int(localCol)] = a_val

        var b_val = b.load[width=1](Coord(offset + Int(localRow), Int(col))) if (
            Int(col) < N and offset + Int(localRow) < K
        ) else Float32(0)
        b_shared[Int(localRow) * tile_size + Int(localCol)] = b_val

        barrier()
        for k in range(tile_size):
            result += a_shared.load(Int(localRow) * tile_size + k) * b_shared.load(
                k * tile_size + Int(localCol)
            )
        barrier()
        offset += tile_size

    if Int(row) < M and Int(col) < N:
        c.store(Coord(Int(row), Int(col)), result)


def bench_shape[M: Int, N: Int, K: Int](ctx: DeviceContext, label: StaticString) raises:
    comptime iters = 20
    comptime reps = 3

    var a_dev = ctx.enqueue_create_buffer[DType.float32](M * K)
    var b_dev = ctx.enqueue_create_buffer[DType.float32](K * N)
    var c_dev = ctx.enqueue_create_buffer[DType.float32](M * N)

    # All-ones, so every output element must equal K exactly. A tolerance
    # would hide precisely the failure mode this kernel had.
    with a_dev.map_to_host() as h:
        for i in range(M * K):
            h[i] = Float32(1)
    with b_dev.map_to_host() as h:
        for i in range(K * N):
            h[i] = Float32(1)

    # Warm up: the first launch pays pipeline creation, which is not what is
    # being measured.
    ctx.enqueue_function[matmul_sram](
        a_dev, b_dev, c_dev, Int32(M), Int32(N), Int32(K),
        grid_dim=(ceildiv(N, tile_size), ceildiv(M, tile_size)),
        block_dim=(tile_size, tile_size),
    )
    ctx.synchronize()

    # Wall time around `iters` launches with ONE synchronize at the end. That
    # measures throughput rather than per-launch latency, which is the honest
    # thing to quote for a kernel that would be run repeatedly. Synchronizing
    # inside the loop would fold queue round-trips into the kernel time.
    # Best of `reps`, not the first measurement. A single timing on a laptop
    # GPU picks up whatever else the machine was doing; the minimum is the
    # closest thing to the kernel's own cost.
    var gpu_ms = 1.0e30
    for _ in range(reps):
        var g0 = perf_counter_ns()
        for _ in range(iters):
            ctx.enqueue_function[matmul_sram](
                a_dev, b_dev, c_dev, Int32(M), Int32(N), Int32(K),
                grid_dim=(ceildiv(N, tile_size), ceildiv(M, tile_size)),
                block_dim=(tile_size, tile_size),
            )
        ctx.synchronize()
        var ms = Float64(perf_counter_ns() - g0) / Float64(iters) / 1_000_000.0
        if ms < gpu_ms:
            gpu_ms = ms

    # Correctness on the SAME buffers that were just timed.
    var bad = 0
    with c_dev.map_to_host() as h:
        for i in range(M * N):
            if h[i] != Float32(K):
                bad += 1

    # CPU reference: naive scalar triple loop, single-threaded. Quoted as
    # context, NOT as a fair opponent -- a tuned multi-threaded SIMD CPU
    # matmul would be far closer. Skipped above 1024 because the naive form
    # takes minutes there and the ratio is already clear.
    #
    # `keep()` is load-bearing: with all-ones inputs and an unused result the
    # optimiser deletes the entire loop, and the first run of this benchmark
    # duly reported 0.0 ms and an infinite speedup.
    var cpu_ms = 0.0
    if M <= 1024:
        var a_host = alloc[Float32](M * K)
        var b_host = alloc[Float32](K * N)
        var c_host = alloc[Float32](M * N)
        for i in range(M * K):
            a_host[i] = Float32(1)
        for i in range(K * N):
            b_host[i] = Float32(1)
        var t0 = perf_counter_ns()
        for i in range(M):
            for j in range(N):
                var acc = Float32(0)
                for k in range(K):
                    acc += a_host[i * K + k] * b_host[k * N + j]
                c_host[i * N + j] = acc
        cpu_ms = Float64(perf_counter_ns() - t0) / 1_000_000.0
        keep(c_host)
        a_host.free()
        b_host.free()
        c_host.free()

    # 2*M*N*K flops for a matmul.
    var gflops = (2.0 * Float64(M) * Float64(N) * Float64(K)) / (gpu_ms * 1.0e6)

    print(
        label, " M=", M, " N=", N, " K=", K,
        " | gpu=", gpu_ms, "ms  gflops=", gflops,
        "  cpu=", cpu_ms, "ms  speedup=",
        (cpu_ms / gpu_ms) if cpu_ms > 0.0 else 0.0, "x",
        " | ", "EXACT" if bad == 0 else "WRONG",
        "" if bad == 0 else String(bad),
    )


def main() raises:
    print("== tiled SRAM matmul, f32, 32x32 tiles")
    print("== correctness is exact-equality on every timed shape")
    with DeviceContext() as ctx:
        print("device:", ctx.name())
        bench_shape[512, 512, 512](ctx, "aligned  ")
        bench_shape[1024, 1024, 1024](ctx, "aligned  ")
        bench_shape[2048, 2048, 2048](ctx, "aligned  ")
        bench_shape[513, 502, 511](ctx, "ragged   ")
        bench_shape[1025, 1022, 1023](ctx, "ragged   ")
