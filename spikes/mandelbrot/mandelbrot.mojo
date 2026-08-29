# ===----------------------------------------------------------------------=== #
# Cocoa Mandelbrot — a native macOS app in Mojo.
#
# The Mac answer to the Windows D3D example. Every pixel is computed by a Mojo
# kernel on the AMD Radeon Pro Vega II (through the fork's AIR backend); the CPU
# only decides what it looks like and hands the frame to a CAMetalLayer.
#
# It first times the same mandelbrot on the CPU and on the GPU, prints the
# speedup, then opens a proper NSWindow with a live-zooming fractal at 60fps.
#
# NOTHING here is written against a hand-rolled ObjC binding: NSApplication,
# NSWindow, NSView, CAMetalLayer and CAMetalDrawable are all driven through
# std.objc, with every selector, dispatch stub, argument count and register
# file checked at compile time against the SDK database.
# ===----------------------------------------------------------------------=== #

from std.gpu import global_idx
from std.math import cos
from max.gpu.host import DeviceContext
from std.time import perf_counter_ns
from std.objc import (
    load_framework,
    ObjCClass,
    ObjCObject,
    msg_send,
    send,
    autoreleasepool,
)
from std.ffi import external_call, c_char
from std.memory import OpaquePointer

comptime P = OpaquePointer[MutUntrackedOrigin]

comptime WIDTH = 1024
comptime HEIGHT = 768
comptime PIXELS = WIDTH * HEIGHT
comptime MAX_ITER = 256


# ===----------------------------------------------------------------------=== #
# Geometry structs (layouts checked against the SDK in the demo's asserts).
# ===----------------------------------------------------------------------=== #


@fieldwise_init
struct CGPoint(Copyable, Movable):
    var x: Float64
    var y: Float64


@fieldwise_init
struct CGSize(Copyable, Movable):
    var width: Float64
    var height: Float64


@fieldwise_init
struct CGRect(Copyable, Movable):
    var origin: CGPoint
    var size: CGSize


# An MTLRegion is {origin:{x,y,z}, size:{w,h,d}} of NSUInteger — 48 bytes, so a
# by-value (stack) argument to replaceRegion:.
@fieldwise_init
struct MTLOrigin(Copyable, Movable):
    var x: Int
    var y: Int
    var z: Int


@fieldwise_init
struct MTLSize(Copyable, Movable):
    var width: Int
    var height: Int
    var depth: Int


@fieldwise_init
struct MTLRegion(Copyable, Movable):
    var origin: MTLOrigin
    var size: MTLSize


# ===----------------------------------------------------------------------=== #
# The mandelbrot itself — identical arithmetic on GPU and CPU.
# ===----------------------------------------------------------------------=== #


def mandelbrot_kernel(
    escape: Pointer[UInt32, MutAnyOrigin],
    center_x: Float32,
    center_y: Float32,
    scale: Float32,
):
    var idx = Int(global_idx.x)
    if idx < PIXELS:
        var px = idx % WIDTH
        var py = idx // WIDTH
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
        escape[unsafe_offset=idx] = n


comptime TAU = Float32(6.28318530718)


def mandelbrot_color_kernel(
    dst: Pointer[UInt32, MutAnyOrigin],
    center_x: Float32,
    center_y: Float32,
    scale: Float32,
    phase: Float32,
):
    var idx = Int(global_idx.x)
    if idx < PIXELS:
        var px = idx % WIDTH
        var py = idx // WIDTH
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

        var pixel: UInt32
        if n >= UInt32(MAX_ITER):
            # inside the set: near-black plum, like the Windows shader
            pixel = _pack(13, 3, 5)
        else:
            # Inigo Quilez cosine palette: three cosines a third of a cycle
            # apart give a smooth rainbow that shifts with `phase`.
            var tt = Float32(n) / Float32(64) + phase
            var r = Float32(0.5) + Float32(0.5) * cos(TAU * (tt + Float32(0.00)))
            var g = Float32(0.5) + Float32(0.5) * cos(TAU * (tt + Float32(0.33)))
            var b = Float32(0.5) + Float32(0.5) * cos(TAU * (tt + Float32(0.67)))
            pixel = _pack(
                UInt32(b * Float32(255)),
                UInt32(g * Float32(255)),
                UInt32(r * Float32(255)),
            )
        dst[unsafe_offset=idx] = pixel


@always_inline
def _pack(b: UInt32, g: UInt32, r: UInt32) -> UInt32:
    # BGRA8Unorm little-endian: byte0=B, byte1=G, byte2=R, byte3=A.
    return b | (g << 8) | (r << 16) | (UInt32(255) << 24)


def mandelbrot_cpu(
    escape: Pointer[UInt32, MutAnyOrigin],
    cx0: Float32,
    cy0: Float32,
    scale: Float32,
):
    for idx in range(PIXELS):
        var px = idx % WIDTH
        var py = idx // WIDTH
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
        escape[unsafe_offset=idx] = n


def colorize(
    escape: Pointer[UInt32, MutAnyOrigin], bgra: Pointer[UInt8, MutAnyOrigin]
):
    """Map escape counts to BGRA8 pixels: inside the set is black, outside a
    smooth blue-gold band by iteration count."""
    for i in range(PIXELS):
        var n = Int(escape[unsafe_offset=i])
        var b: UInt8
        var g: UInt8
        var r: UInt8
        if n >= MAX_ITER:
            b = 0
            g = 0
            r = 0
        else:
            var t = n * 6
            r = UInt8(min(255, t))
            g = UInt8(min(255, t // 2 + 40))
            b = UInt8(min(255, 120 + t // 3))
        bgra[unsafe_offset = i * 4 + 0] = b
        bgra[unsafe_offset = i * 4 + 1] = g
        bgra[unsafe_offset = i * 4 + 2] = r
        bgra[unsafe_offset = i * 4 + 3] = 255


# ===----------------------------------------------------------------------=== #
# Small Cocoa helpers.
# ===----------------------------------------------------------------------=== #


def nsstring(s: String) -> ObjCObject:
    var NSString = ObjCClass.lookup["NSString"]()
    var local = s
    return msg_send[
        ObjCObject, "NSString", "stringWithUTF8String:", is_class=True
    ](NSString.as_object(), local.as_c_string_slice())


def main() raises:
    # A JIT process links nothing against AppKit, so NSApplication resolves
    # to nil and every message to it silently no-ops -- no window, no error.
    # Fail loudly instead; the failure this prevents is invisible.
    if not load_framework["AppKit"]():
        print("FATAL: could not load AppKit")
        return
    comptime cx = Float32(-0.743643)
    comptime cy = Float32(0.131826)
    var scale = Float32(3.0) / Float32(WIDTH)
    var phase = Float32(0.0)

    # Layouts are checked against the SDK before anything runs.
    from std.sys import size_of
    from std.sys._cocoakb import cocoakb_struct_size

    comptime assert size_of[CGRect]() == cocoakb_struct_size["CGRect"]()

    # ── Timing: same fractal, CPU then GPU ──────────────────────────────────
    print("Mandelbrot", WIDTH, "x", HEIGHT, ",", MAX_ITER, "iterations")

    var cpu_list = List[UInt32](length=PIXELS, fill=0)
    var cpu_buf = cpu_list.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    var t0 = perf_counter_ns()
    mandelbrot_cpu(cpu_buf, cx, cy, scale)
    var t1 = perf_counter_ns()
    var cpu_ms = Float64(t1 - t0) / 1e6
    print("  CPU:", cpu_ms, "ms")

    var ctx = DeviceContext(api="metal")
    print("  GPU:", ctx.name())
    var dev = ctx.enqueue_create_buffer[DType.uint32](PIXELS)
    var kern = ctx.compile_function[mandelbrot_kernel]()
    var color_kern = ctx.compile_function[mandelbrot_color_kernel]()
    comptime block = 256
    comptime grid = (PIXELS + block - 1) // block
    ctx.enqueue_function(
        kern, dev, cx, cy, scale, grid_dim=(grid), block_dim=(block)
    )
    ctx.synchronize()
    var g0 = perf_counter_ns()
    ctx.enqueue_function(
        kern, dev, cx, cy, scale, grid_dim=(grid), block_dim=(block)
    )
    ctx.synchronize()
    var g1 = perf_counter_ns()
    var gpu_ms = Float64(g1 - g0) / 1e6
    print("  GPU:", gpu_ms, "ms  (", cpu_ms / gpu_ms, "x faster )")

    # ── Window + Metal layer ────────────────────────────────────────────────
    with autoreleasepool():
        var NSApplication = ObjCClass.lookup["NSApplication"]()
        var app = msg_send[
            ObjCObject, "NSApplication", "sharedApplication", is_class=True
        ](NSApplication.as_object())
        _ = msg_send[Bool, "NSApplication", "setActivationPolicy:"](app, Int(0))

        var NSWindow = ObjCClass.lookup["NSWindow"]()
        var win = msg_send[ObjCObject, "NSWindow", "alloc", is_class=True](
            NSWindow.as_object()
        )
        var frame = CGRect(
            CGPoint(120.0, 120.0), CGSize(Float64(WIDTH), Float64(HEIGHT))
        )
        win = msg_send[
            ObjCObject,
            "NSWindow",
            "initWithContentRect:styleMask:backing:defer:",
        ](win, frame, Int(15), Int(2), Bool(False))
        _ = msg_send[ObjCObject, "NSWindow", "setTitle:"](
            win, nsstring(String("Mojo Mandelbrot — Vega II")).ptr()
        )

        # Metal device for the display layer + its command queue.
        var display_dev = ObjCObject(
            Int(external_call["MTLCreateSystemDefaultDevice", P]())
        )
        var queue = send[ObjCObject, "newCommandQueue"](display_dev)

        # CAMetalLayer on the window's content view.
        var CAMetalLayer = ObjCClass.lookup["CAMetalLayer"]()
        var layer = msg_send[
            ObjCObject, "CAMetalLayer", "layer", is_class=True
        ](CAMetalLayer.as_object())
        _ = send[ObjCObject, "setDevice:"](layer, display_dev.ptr())
        # MTLPixelFormatBGRA8Unorm = 80
        _ = msg_send[ObjCObject, "CAMetalLayer", "setPixelFormat:"](
            layer, Int(80)
        )
        _ = msg_send[ObjCObject, "CAMetalLayer", "setFramebufferOnly:"](
            layer, Bool(False)
        )
        _ = msg_send[ObjCObject, "CAMetalLayer", "setDrawableSize:"](
            layer, CGSize(Float64(WIDTH), Float64(HEIGHT))
        )

        var content = msg_send[ObjCObject, "NSWindow", "contentView"](win)
        _ = msg_send[ObjCObject, "NSView", "setWantsLayer:"](
            content, Bool(True)
        )
        _ = msg_send[ObjCObject, "NSView", "setLayer:"](content, layer.ptr())

        _ = msg_send[ObjCObject, "NSWindow", "makeKeyAndOrderFront:"](
            win, app.ptr()
        )
        _ = msg_send[ObjCObject, "NSApplication", "activateIgnoringOtherApps:"](
            app, Bool(True)
        )

        # Host BGRA frame buffer and the MTLRegion covering the whole texture.
        var frame_list = List[UInt8](length=PIXELS * 4, fill=0)
        var bgra = frame_list.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
        var region = MTLRegion(
            MTLOrigin(0, 0, 0), MTLSize(WIDTH, HEIGHT, 1)
        )

        # Event-pump constants.
        var NSDate = ObjCClass.lookup["NSDate"]()
        var mode = nsstring(String("kCFRunLoopDefaultMode"))

        print("Rendering. Close the window to quit.")
        var frames = 0
        var running = True
        var loop_start = perf_counter_ns()

        while running:
            # Drain pending events; stop when the window closes.
            while True:
                var past = msg_send[
                    ObjCObject, "NSDate", "distantPast", is_class=True
                ](NSDate.as_object())
                var ev = msg_send[
                    ObjCObject,
                    "NSApplication",
                    "nextEventMatchingMask:untilDate:inMode:dequeue:",
                ](app, UInt64.MAX, past.ptr(), mode.ptr(), Bool(True))
                if ev.is_nil():
                    break
                _ = msg_send[ObjCObject, "NSApplication", "sendEvent:"](
                    app, ev.ptr()
                )
            var visible = msg_send[Bool, "NSWindow", "isVisible"](win)
            if not visible:
                running = False
                break

            # Compute AND colour this frame in one Mojo kernel on the Vega II
            # -- the whole pipeline is Mojo, no shader. Output is packed BGRA8.
            ctx.enqueue_function(
                color_kern,
                dev,
                cx,
                cy,
                scale,
                phase,
                grid_dim=(grid),
                block_dim=(block),
            )
            ctx.synchronize()
            with dev.map_to_host() as pix:
                var src = pix.unsafe_ptr().bitcast[UInt8]()
                for k in range(PIXELS * 4):
                    bgra[unsafe_offset=k] = src[unsafe_offset=k]

            var drawable = msg_send[
                ObjCObject, "CAMetalLayer", "nextDrawable"
            ](layer)
            if not drawable.is_nil():
                var tex = msg_send[
                    ObjCObject, "CAMetalDrawable", "texture"
                ](drawable)
                # -[MTLTexture replaceRegion:mipmapLevel:withBytes:bytesPerRow:]
                _ = send[
                    ObjCObject,
                    "replaceRegion:mipmapLevel:withBytes:bytesPerRow:",
                ](tex, region, Int(0), bgra.bitcast[NoneType](), Int(WIDTH * 4))

                var cb = send[ObjCObject, "commandBuffer"](queue)
                _ = send[ObjCObject, "presentDrawable:"](cb, drawable.ptr())
                _ = send[ObjCObject, "commit"](cb)

            frames += 1
            if frames % 120 == 0:
                var now = perf_counter_ns()
                var fps = Float64(frames) / (Float64(now - loop_start) / 1e9)
                print("  frame", frames, "—", fps, "fps")
            # Drift the palette and zoom toward the seahorse valley, then reset.
            phase += Float32(0.004)
            scale *= Float32(0.985)
            if scale < Float32(3.0) / Float32(WIDTH) * Float32(1e-4):
                scale = Float32(3.0) / Float32(WIDTH)

        var loop_end = perf_counter_ns()
        var secs = Float64(loop_end - loop_start) / 1e9
        if secs > 0.0:
            print("Rendered", frames, "frames in", secs, "s (",
                  Float64(frames) / secs, "fps )")
