# ===----------------------------------------------------------------------=== #
# Tiled shared-memory matmul across aligned and ragged dimensions.
#
# test_matmul_1_sram exercises exactly one shape -- 513 x 502 x 511, all three
# ragged -- and checks only the last 10x10 of the output. That is enough to
# see a failure and not nearly enough to attribute one: with every dimension
# ragged, a fault in the M edge, the N edge and the K tail are
# indistinguishable.
#
# This walks the combinations separately and compares the WHOLE output, so a
# failing cell can be attributed to the dimension that is ragged. Inputs stay
# all-ones so the golden value is K everywhere; the interesting information is
# WHICH shapes fail, not by how much.
#
# Two known defects this is built to separate, both diagnosed on
# 513 x 502 x 511:
#
#   ragged N -- the tile loop is unswitched on `col < N`, a PER-LANE
#     predicate, and each unswitched version carries its own cloned
#     air.wg.barrier. Lanes on either side of the split reach different
#     barrier instances, so the threadgroup never actually synchronises and
#     each output row sees only the lanes from its own branch.
#
#   ragged K -- tile_and_unswitch(0, K, 32, K_remainder) never reaches its
#     residue path for K=511: the 31-wide tile consumes the tail with
#     full_tile=True. The last tile then indexes a_shared as
#     localRow*31 + localCol from a 32-wide block, so (r,31) and (r+1,0)
#     collide, and lane 31 loads a[row][K] unchecked.
# ===----------------------------------------------------------------------=== #

from std.math import ceildiv
from std.gpu import global_idx, thread_idx
from max.gpu.sync import barrier
from max.gpu.host import DeviceContext
from layout import TileTensor, Coord, row_major
from std.memory import unsafe_stack_allocation

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

    # Deliberately NOT tile_and_unswitch: this walks K with one fixed 32-wide
    # tile and bounds-checks every load, so the shared layout is always 32-wide
    # and the K tail cannot produce the aliasing the production helper does.
    # It isolates the barrier/divergence question from the K-tail question.
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


def check_shape[
    M: Int, N: Int, K: Int
](ctx: DeviceContext, label: StaticString) raises -> Int:
    var a_dev = ctx.enqueue_create_buffer[DType.float32](M * K)
    var b_dev = ctx.enqueue_create_buffer[DType.float32](K * N)
    var c_dev = ctx.enqueue_create_buffer[DType.float32](M * N)

    with a_dev.map_to_host() as h:
        for i in range(M * K):
            h[i] = Float32(1)
    with b_dev.map_to_host() as h:
        for i in range(K * N):
            h[i] = Float32(1)
    with c_dev.map_to_host() as h:
        for i in range(M * N):
            h[i] = Float32(0)

    ctx.enqueue_function[matmul_sram](
        a_dev, b_dev, c_dev, Int32(M), Int32(N), Int32(K),
        grid_dim=(ceildiv(N, tile_size), ceildiv(M, tile_size)),
        block_dim=(tile_size, tile_size),
    )
    ctx.synchronize()

    # WHOLE output, not a corner: a corner cannot tell you which edge failed.
    var bad = 0
    var first_r = -1
    var first_c = -1
    var first_v = Float32(0)
    with c_dev.map_to_host() as h:
        for i in range(M):
            for j in range(N):
                # map_to_host indexing yields a scalar wrapper; normalize it
                # before comparing so the oracle tests the numeric value, not
                # wrapper identity/overload behaviour.
                var v = Float32(h[i * N + j])
                if v != Float32(K):
                    if bad == 0:
                        first_r = i
                        first_c = j
                        first_v = v
                    bad += 1
    if bad == 0:
        print("  PASS ", label, " M=", M, " N=", N, " K=", K)
    else:
        print(
            "  FAIL ", label, " M=", M, " N=", N, " K=", K,
            " bad=", bad, "/", M * N,
            " first=[", first_r, ",", first_c, "]=", first_v,
            " want=", K,
        )
    # Returned rather than raised: the point of this file is the whole
    # dimension matrix, and stopping at the first ragged shape that breaks
    # hides which of the others break too. main() raises once, at the end.
    return bad


def main() raises:
    var failed = 0
    with DeviceContext() as ctx:
        # 512 is 16*32 exactly; 502/511/513 are deliberately ragged.
        failed += check_shape[512, 512, 512](ctx, "all aligned      ")
        failed += check_shape[513, 512, 512](ctx, "ragged M only    ")
        failed += check_shape[512, 502, 512](ctx, "ragged N only    ")
        failed += check_shape[512, 512, 511](ctx, "ragged K only    ")
        failed += check_shape[513, 502, 512](ctx, "ragged M+N       ")
        failed += check_shape[513, 512, 511](ctx, "ragged M+K       ")
        failed += check_shape[512, 502, 511](ctx, "ragged N+K       ")
        failed += check_shape[513, 502, 511](ctx, "all ragged       ")
    print("dimension matrix complete")
    # Without this the file was a report, not a test: every shape was compared
    # element by element and a mismatch printed "FAIL", but main() still exited
    # 0, so a ragged-shape regression would have been recorded as a pass.
    if failed != 0:
        raise Error(
            "matmul dimension matrix: "
            + String(failed)
            + " mismatched element(s) across the shapes above"
        )
