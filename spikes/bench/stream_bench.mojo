# ===----------------------------------------------------------------------=== #
# STREAM-style bandwidth: the memory-bound counterpart to the matmul.
#
# matmul_sram_bench is compute-bound and says how fast the arithmetic goes.
# It says nothing about the path the data takes to get there, and on Apple
# Silicon that path is the interesting one: unified memory means there is no
# host-to-device copy in the usual sense, and a kernel that looks
# compute-bound on a discrete GPU can be bandwidth-bound here.
#
# Four kernels, in the classic STREAM shapes, so the numbers are comparable to
# published figures for other hardware:
#
#   copy   c[i] = a[i]              2 arrays touched
#   scale  b[i] = q * c[i]          2
#   add    c[i] = a[i] + b[i]       3
#   triad  a[i] = b[i] + q * c[i]   3
#
# Bytes moved counts reads AND writes, which is the STREAM convention. Quoting
# only reads would roughly halve every figure here.
#
# Correctness is checked on every timed kernel, for the same reason as in the
# matmul: this port has already shipped a silent wrong answer that a
# throughput number would have flattered.
# ===----------------------------------------------------------------------=== #

from std.gpu import global_idx
from max.gpu.host import DeviceContext
from std.time import perf_counter_ns

comptime block = 256


def k_copy(
    dst: UnsafePointer[Float32, MutAnyOrigin],
    src: UnsafePointer[Float32, MutAnyOrigin],
    n_dev: Int32,
):
    var i = Int(global_idx.x)
    if i < Int(n_dev):
        dst[i] = src[i]


def k_scale(
    dst: UnsafePointer[Float32, MutAnyOrigin],
    src: UnsafePointer[Float32, MutAnyOrigin],
    q: Float32,
    n_dev: Int32,
):
    var i = Int(global_idx.x)
    if i < Int(n_dev):
        dst[i] = q * src[i]


def k_add(
    dst: UnsafePointer[Float32, MutAnyOrigin],
    a: UnsafePointer[Float32, MutAnyOrigin],
    b: UnsafePointer[Float32, MutAnyOrigin],
    n_dev: Int32,
):
    var i = Int(global_idx.x)
    if i < Int(n_dev):
        dst[i] = a[i] + b[i]


def k_triad(
    dst: UnsafePointer[Float32, MutAnyOrigin],
    b: UnsafePointer[Float32, MutAnyOrigin],
    c: UnsafePointer[Float32, MutAnyOrigin],
    q: Float32,
    n_dev: Int32,
):
    var i = Int(global_idx.x)
    if i < Int(n_dev):
        dst[i] = b[i] + q * c[i]


def report(
    label: StaticString, samples: List[Float64], bytes_moved: Float64, ok: Bool
) raises:
    var s = samples.copy()
    for i in range(len(s)):
        for j in range(i + 1, len(s)):
            if s[j] < s[i]:
                var t = s[i]
                s[i] = s[j]
                s[j] = t
    var lo = s[0]
    var med = s[len(s) // 2]
    var hi = s[len(s) - 1]
    # GB/s from ms: bytes / (ms * 1e6)
    print(
        "  ", label,
        " GB/s min/med/max= ", bytes_moved / (hi * 1.0e6),
        " / ", bytes_moved / (med * 1.0e6),
        " / ", bytes_moved / (lo * 1.0e6),
        "  spread= ", 100.0 * (hi - lo) / med, "%",
        " | ", "EXACT" if ok else "WRONG",
    )


def main() raises:
    comptime n = 1 << 24          # 16 Mi elements = 64 MB per array
    comptime iters = 20
    comptime reps = 5
    comptime q = Float32(3.0)
    comptime grid = (n + block - 1) // block

    print("== STREAM-style bandwidth, f32, n =", n, "(", n * 4 // (1 << 20), "MB per array)")
    print("== bytes counted as reads + writes, the STREAM convention")
    with DeviceContext() as ctx:
        print("device:", ctx.name())
        var a = ctx.enqueue_create_buffer[DType.float32](n)
        var b = ctx.enqueue_create_buffer[DType.float32](n)
        var c = ctx.enqueue_create_buffer[DType.float32](n)
        with a.map_to_host() as h:
            for i in range(n):
                h[i] = Float32(1)
        with b.map_to_host() as h:
            for i in range(n):
                h[i] = Float32(2)
        with c.map_to_host() as h:
            for i in range(n):
                h[i] = Float32(0)

        var bytes2 = 2.0 * Float64(n) * 4.0
        var bytes3 = 3.0 * Float64(n) * 4.0

        # --- copy: c = a ---
        var s1 = List[Float64]()
        ctx.enqueue_function[k_copy](c, a, Int32(n), grid_dim=(grid), block_dim=(block))
        ctx.synchronize()
        for _ in range(reps):
            var t = perf_counter_ns()
            for _ in range(iters):
                ctx.enqueue_function[k_copy](c, a, Int32(n), grid_dim=(grid), block_dim=(block))
            ctx.synchronize()
            s1.append(Float64(perf_counter_ns() - t) / Float64(iters) / 1_000_000.0)
        var ok1 = True
        with c.map_to_host() as h:
            for i in range(0, n, 4096):
                if h[i] != Float32(1):
                    ok1 = False
        report("copy ", s1, bytes2, ok1)

        # --- scale: b = q * c ---
        var s2 = List[Float64]()
        ctx.enqueue_function[k_scale](b, c, q, Int32(n), grid_dim=(grid), block_dim=(block))
        ctx.synchronize()
        for _ in range(reps):
            var t = perf_counter_ns()
            for _ in range(iters):
                ctx.enqueue_function[k_scale](b, c, q, Int32(n), grid_dim=(grid), block_dim=(block))
            ctx.synchronize()
            s2.append(Float64(perf_counter_ns() - t) / Float64(iters) / 1_000_000.0)
        var ok2 = True
        with b.map_to_host() as h:
            for i in range(0, n, 4096):
                if h[i] != Float32(3):
                    ok2 = False
        report("scale", s2, bytes2, ok2)

        # --- add: c = a + b ---
        var s3 = List[Float64]()
        ctx.enqueue_function[k_add](c, a, b, Int32(n), grid_dim=(grid), block_dim=(block))
        ctx.synchronize()
        for _ in range(reps):
            var t = perf_counter_ns()
            for _ in range(iters):
                ctx.enqueue_function[k_add](c, a, b, Int32(n), grid_dim=(grid), block_dim=(block))
            ctx.synchronize()
            s3.append(Float64(perf_counter_ns() - t) / Float64(iters) / 1_000_000.0)
        var ok3 = True
        with c.map_to_host() as h:
            for i in range(0, n, 4096):
                if h[i] != Float32(4):
                    ok3 = False
        report("add  ", s3, bytes3, ok3)

        # --- triad: a = b + q * c ---
        var s4 = List[Float64]()
        ctx.enqueue_function[k_triad](a, b, c, q, Int32(n), grid_dim=(grid), block_dim=(block))
        ctx.synchronize()
        for _ in range(reps):
            var t = perf_counter_ns()
            for _ in range(iters):
                ctx.enqueue_function[k_triad](a, b, c, q, Int32(n), grid_dim=(grid), block_dim=(block))
            ctx.synchronize()
            s4.append(Float64(perf_counter_ns() - t) / Float64(iters) / 1_000_000.0)
        var ok4 = True
        with a.map_to_host() as h:
            for i in range(0, n, 4096):
                if h[i] != Float32(15):
                    ok4 = False
        report("triad", s4, bytes3, ok4)
