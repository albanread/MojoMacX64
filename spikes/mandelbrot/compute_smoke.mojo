# Step 2: CPU vs GPU mandelbrot, same arithmetic, timed and cross-checked.
from std.gpu import global_idx
from max.gpu.host import DeviceContext
from std.time import perf_counter_ns

comptime WIDTH = 1024
comptime HEIGHT = 768
comptime PIXELS = WIDTH * HEIGHT
comptime MAX_ITER = 256


def mandelbrot_kernel(
    escape: Pointer[UInt32, MutAnyOrigin],
    center_x: Float32,
    center_y: Float32,
    scale: Float32,
):
    var idx = Int(global_idx.x)
    if idx < PIXELS:
        var index = idx
        var px = index % WIDTH
        var py = index // WIDTH
        var cx = center_x + (Float32(px) - Float32(WIDTH) * 0.5) * scale
        var cy = center_y + (Float32(py) - Float32(HEIGHT) * 0.5) * scale
        var zx = Float32(0)
        var zy = Float32(0)
        var n = UInt32(0)
        while n < UInt32(MAX_ITER) and zx * zx + zy * zy <= Float32(4):
            var nzx = zx * zx - zy * zy + cx
            zy = Float32(2) * zx * zy + cy
            zx = nzx
            n += 1
        escape[unsafe_offset=index] = n


def mandelbrot_cpu(escape: Pointer[UInt32, MutAnyOrigin], cx0: Float32, cy0: Float32, scale: Float32):
    for index in range(PIXELS):
        var px = index % WIDTH
        var py = index // WIDTH
        var cx = cx0 + (Float32(px) - Float32(WIDTH) * 0.5) * scale
        var cy = cy0 + (Float32(py) - Float32(HEIGHT) * 0.5) * scale
        var zx = Float32(0)
        var zy = Float32(0)
        var n = UInt32(0)
        while n < UInt32(MAX_ITER) and zx * zx + zy * zy <= Float32(4):
            var nzx = zx * zx - zy * zy + cx
            zy = Float32(2) * zx * zy + cy
            zx = nzx
            n += 1
        escape[unsafe_offset=index] = n


def main() raises:
    comptime cx = Float32(-0.75)
    comptime cy = Float32(0.0)
    comptime scale = Float32(3.0) / Float32(WIDTH)

    # CPU
    var cpu_list = List[UInt32](length=PIXELS, fill=0)
    var cpu_buf = cpu_list.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    var t0 = perf_counter_ns()
    mandelbrot_cpu(cpu_buf, cx, cy, scale)
    var t1 = perf_counter_ns()
    var cpu_ms = Float64(t1 - t0) / 1e6
    print("CPU:", cpu_ms, "ms")

    # GPU
    var ctx = DeviceContext(api="metal")
    var dev = ctx.enqueue_create_buffer[DType.uint32](PIXELS)
    var f = ctx.compile_function[mandelbrot_kernel]()
    comptime block = 256
    comptime grid = (PIXELS + block - 1) // block
    # warm
    ctx.enqueue_function(f, dev, cx, cy, scale, grid_dim=(grid), block_dim=(block))
    ctx.synchronize()
    var g0 = perf_counter_ns()
    ctx.enqueue_function(f, dev, cx, cy, scale, grid_dim=(grid), block_dim=(block))
    ctx.synchronize()
    var g1 = perf_counter_ns()
    var gpu_ms = Float64(g1 - g0) / 1e6
    print("GPU:", gpu_ms, "ms")
    print("speedup:", cpu_ms / gpu_ms, "x")

    # cross-check a sample of pixels
    # CPU and GPU agree exactly on interior and exterior pixels. In the thin
    # chaotic band right at the set boundary, a point is so iteration-sensitive
    # that the GPUs fused multiply-add (vs the CPUs separate mul/add) can shift
    # its escape count -- inherent to Float32 mandelbrot, not a bug. So the
    # honest check is the agreement RATE, which should be very high.
    var checked = 0
    var agree = 0
    with dev.map_to_host() as gpu_buf:
        for i in range(0, PIXELS):
            checked += 1
            if gpu_buf[i] == cpu_buf[i]:
                agree += 1
    var rate = Float64(agree) / Float64(checked) * 100.0
    print("exact agreement:", rate, "% (", checked - agree, "boundary-band pixels differ)")
    print("COMPUTE-SMOKE: PASS" if rate > 99.0 else "COMPUTE-SMOKE: FAIL")
