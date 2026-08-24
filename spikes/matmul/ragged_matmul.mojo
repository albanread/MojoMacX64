# Ragged-dimension tiled matmul: M,N are NOT multiples of TILE, so the guards
# `row < M` / `col < N` are per-lane predicates on a tile edge -- exactly the
# shape that lets loop unswitching clone a barrier.
from std.gpu import thread_idx, block_idx
from max.gpu.sync import barrier
from max.gpu.host import DeviceContext
from std.memory import stack_allocation, AddressSpace

comptime M = 100
comptime N = 100
comptime K = 64
comptime TILE = 16


def mm(c: Pointer[Float32, MutAnyOrigin], a: Pointer[Float32, MutAnyOrigin], b: Pointer[Float32, MutAnyOrigin]):
    var tx = thread_idx.x
    var ty = thread_idx.y
    var col = Int(block_idx.x * TILE + tx)
    var row = Int(block_idx.y * TILE + ty)
    var asub = stack_allocation[TILE * TILE, Float32, address_space=AddressSpace.SHARED]()
    var bsub = stack_allocation[TILE * TILE, Float32, address_space=AddressSpace.SHARED]()
    var acc = Float32(0)
    for t in range(K // TILE):
        var ac = t * TILE + Int(tx)
        var br = t * TILE + Int(ty)
        asub[Int(ty) * TILE + Int(tx)] = a[unsafe_offset = row * K + ac] if (row < M and ac < K) else Float32(0)
        bsub[Int(ty) * TILE + Int(tx)] = b[unsafe_offset = br * N + col] if (br < K and col < N) else Float32(0)
        barrier()
        for k in range(TILE):
            acc += asub[Int(ty) * TILE + k] * bsub[k * TILE + Int(tx)]
        barrier()
    if row < M and col < N:
        c[unsafe_offset = row * N + col] = acc


def main() raises:
    var ctx = DeviceContext(api="metal")
    var a = ctx.enqueue_create_buffer[DType.float32](M * K)
    var b = ctx.enqueue_create_buffer[DType.float32](K * N)
    var c = ctx.enqueue_create_buffer[DType.float32](M * N)
    with a.map_to_host() as ah, b.map_to_host() as bh:
        for i in range(M * K): ah[i] = Float32((i % 5) + 1)
        for i in range(K * N): bh[i] = Float32((i % 3) + 1)
    var f = ctx.compile_function[mm]()
    comptime GX = (N + TILE - 1) // TILE
    comptime GY = (M + TILE - 1) // TILE
    ctx.enqueue_function(f, c, a, b, grid_dim=(GX, GY), block_dim=(TILE, TILE))
    ctx.synchronize()
    var wrong = 0
    var first = String("")
    with c.map_to_host() as ch, a.map_to_host() as ah, b.map_to_host() as bh:
        for r in range(0, M, 7):
            for cc in range(0, N, 11):
                var want = Float32(0)
                for k in range(K):
                    want += ah[r * K + k] * bh[k * N + cc]
                var got = ch[r * N + cc]
                var d = got - want
                if d > 0.5 or d < -0.5:
                    wrong += 1
                    if len(first.as_bytes()) == 0:
                        first = String("[") + String(r) + "," + String(cc) + "] got " + String(got) + " want " + String(want)
    print("ragged", M, "x", N, "x", K, "-> wrong:", wrong)
    if wrong > 0: print("  first:", first)
    print("RAGGED-MATMUL: PASS" if wrong == 0 else "RAGGED-MATMUL: FAIL")
