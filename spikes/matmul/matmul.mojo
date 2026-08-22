from std.gpu import global_idx, thread_idx, block_idx, block_dim
from max.gpu.sync import barrier
from max.gpu.host import DeviceContext
from std.memory import stack_allocation
from std.memory import AddressSpace
from std.time import perf_counter_ns

comptime M = 1024
comptime N = 1024
comptime K = 1024
comptime TILE = 16


def matmul_kernel(
    c: Pointer[Float32, MutAnyOrigin],
    a: Pointer[Float32, MutAnyOrigin],
    b: Pointer[Float32, MutAnyOrigin],
):
    var tx = thread_idx.x
    var ty = thread_idx.y
    var col = block_idx.x * TILE + tx
    var row = block_idx.y * TILE + ty

    var asub = stack_allocation[
        TILE * TILE, Float32, address_space = AddressSpace.SHARED
    ]()
    var bsub = stack_allocation[
        TILE * TILE, Float32, address_space = AddressSpace.SHARED
    ]()

    var acc = Float32(0)
    for t in range(K // TILE):
        asub[ty * TILE + tx] = a[unsafe_offset = row * K + (t * TILE + tx)]
        bsub[ty * TILE + tx] = b[unsafe_offset = (t * TILE + ty) * N + col]
        barrier()
        for k in range(TILE):
            acc += asub[ty * TILE + k] * bsub[k * TILE + tx]
        barrier()
    c[unsafe_offset = row * N + col] = acc


def main() raises:
    var ctx = DeviceContext(api="metal")
    print("device:", ctx.name())

    var a = ctx.enqueue_create_buffer[DType.float32](M * K)
    var b = ctx.enqueue_create_buffer[DType.float32](K * N)
    var c = ctx.enqueue_create_buffer[DType.float32](M * N)

    with a.map_to_host() as ah, b.map_to_host() as bh:
        for i in range(M * K):
            ah[i] = Float32((i % 7) - 3)
        for i in range(K * N):
            bh[i] = Float32((i % 5) - 2)

    var f = ctx.compile_function[matmul_kernel]()
    # warmup
    ctx.enqueue_function(f, c, a, b, grid_dim=(N // TILE, M // TILE), block_dim=(TILE, TILE))
    ctx.synchronize()

    comptime iters = 20
    var t0 = perf_counter_ns()
    for _ in range(iters):
        ctx.enqueue_function(f, c, a, b, grid_dim=(N // TILE, M // TILE), block_dim=(TILE, TILE))
    ctx.synchronize()
    var t1 = perf_counter_ns()

    var secs = Float64(t1 - t0) / 1e9 / Float64(iters)
    var gflops = (2.0 * Float64(M) * Float64(N) * Float64(K)) / secs / 1e9
    print("matmul", M, "x", N, "x", K, ":", secs * 1000.0, "ms  ", gflops, "GFLOP/s")

    # verify a few elements against a CPU reference
    var wrong = 0
    with c.map_to_host() as ch, a.map_to_host() as ah, b.map_to_host() as bh:
        for r in range(0, M, 251):
            for cc in range(0, N, 257):
                var want = Float32(0)
                for k in range(K):
                    want += ah[r * K + k] * bh[k * N + cc]
                var d = ch[r * N + cc] - want
                if d > 1e-1 or d < -1e-1:
                    wrong += 1
    print("verify:", wrong, "wrong")
    if wrong == 0:
        print("MATMUL-ON-VEGA: PASS")
