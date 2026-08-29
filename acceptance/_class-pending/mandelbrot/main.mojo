# ===----------------------------------------------------------------------=== #
# Mandelbrot — a native macOS app written entirely in Mojo.
#
# Every pixel is computed AND coloured by one Mojo kernel on the Apple GPU;
# the CPU's whole job is to hand the frame to a `CAMetalLayer`. No shader
# anywhere in the pipeline. It first times the same fractal on the CPU and the
# GPU and prints the speedup, then opens a window that zooms into the seahorse
# valley at 60fps.
#
#   click    recenter on the point under the mouse
#   space    pause the zoom (the palette keeps drifting)
#   r        start again from the whole set
#   q / esc  quit, as does closing the window
#
# Ported from spikes/mandelbrot and converted to the current patterns, the
# same conversion life and fluid had:
#
#   * CGPoint/CGSize/CGRect come from std.objc rather than being redeclared
#     here -- they are TrivialRegisterPassable there, which is what the C ABI
#     says they are. The MTL structs stay local: they are Metal's, not
#     CoreGraphics's, and the SDK database is asked about layouts either way.
#   * The mouse and keyboard arrive through a `class` the runtime calls, not
#     by picking events apart in the pump. The handlers only set flags: the
#     frame loop owns every Metal and GPU call, so a callback arriving
#     between two frames cannot race one (the fluid demo's doctrine).
#   * The GPU context and its buffers are locals in `main`. That is why the
#     event loop is a hand-rolled pump rather than `[NSApp run]`: a
#     DeviceContext cannot live in a `named_global`, and locals cannot be
#     reached from a callback -- so the loop that owns them drives the app.
#
# MANDEL_FRAMES=N renders N frames and exits, without taking the screen: the
# window comes up Accessory and unfocused, so a harness run never steals the
# desktop from whoever is working. That lesson was learned the loud way.
# ===----------------------------------------------------------------------=== #

from std.gpu import global_idx
from std.math import cos
from max.gpu.host import DeviceContext
from std.time import perf_counter_ns
from std.os import getenv
from std.objc import (
    load_framework,
    ObjCClass,
    ObjCObject,
    msg_send,
    send,
    nsstring,
    autoreleasepool,
    named_global,
    CGPoint,
    CGSize,
    CGRect,
)
from std.ffi import external_call, c_char
from std.memory import OpaquePointer, Pointer

comptime P = OpaquePointer[MutUntrackedOrigin]

comptime WIDTH = 1024
comptime HEIGHT = 768
comptime PIXELS = WIDTH * HEIGHT
comptime MAX_ITER = 256

comptime BLOCK = 256
comptime GRID = (PIXELS + BLOCK - 1) // BLOCK

# Where the zoom starts, and where it dives: the seahorse valley.
comptime CX0 = Float32(-0.743643)
comptime CY0 = Float32(0.131826)

comptime TAU = Float32(6.28318530718)


# ===----------------------------------------------------------------------=== #
# Metal structs, by value across the ABI. An MTLRegion is 48 bytes of
# NSUInteger, so it goes to `replaceRegion:` on the stack, not in registers.
# ===----------------------------------------------------------------------=== #


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
# The kernels. One computes escape counts, for the CPU-vs-GPU timing; the
# other computes and colours a frame in a single dispatch, for the window.
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


@always_inline
def _pack(b: UInt32, g: UInt32, r: UInt32) -> UInt32:
    # BGRA8Unorm little-endian: byte0=B, byte1=G, byte2=R, byte3=A.
    return b | (g << 8) | (r << 16) | (UInt32(255) << 24)


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
            # Inside the set: near-black plum.
            pixel = _pack(13, 3, 5)
        else:
            # Inigo Quilez cosine palette: three cosines a third of a cycle
            # apart give a smooth rainbow that drifts with `phase`.
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


def mandelbrot_cpu(
    escape: Pointer[UInt32, MutAnyOrigin],
    cx0: Float32,
    cy0: Float32,
    scale: Float32,
):
    """The same arithmetic, one core, for the honest comparison."""
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


# ===----------------------------------------------------------------------=== #
# Input arrives on Cocoa's schedule; frames happen on ours. The handlers set
# flags and the frame loop acts on them, which keeps every GPU and Metal call
# on the one thread that owns them. Bits, not booleans, so two things in one
# frame do not lose each other.
# ===----------------------------------------------------------------------=== #

comptime CMD_CLICK = 1
comptime CMD_PAUSE = 2
comptime CMD_RESET = 4
comptime CMD_QUIT = 8

comptime g_cmd = named_global["mandel.cmd", Int]
comptime g_click_x = named_global["mandel.click.x", Int]
comptime g_click_y = named_global["mandel.click.y", Int]


class MandelbrotView(NSView):
    """The window's content view. Cocoa calls these; they only set flags.

    Every selector here is the SDK's, so each encoding is looked up rather
    than derived, and a wrong signature is a compile error quoting AppKit.
    """

    def acceptsFirstResponder(self) -> Bool:
        # Keystrokes come to the view, not to a beep.
        return True

    def isFlipped(self) -> Bool:
        # Origin at the top-left, exactly as the kernel counts pixels, so a
        # click converts to a pixel without anyone flipping an axis.
        return True

    def mouseDown_(self, event: ObjCObject):
        var at = msg_send[CGPoint, "NSEvent", "locationInWindow"](event)
        var view = ObjCObject(self.__objc_id)
        var local = msg_send[CGPoint, "NSView", "convertPoint:fromView:"](
            view, at, ObjCObject(0).ptr()
        )
        g_click_x()[] = Int(local.x)
        g_click_y()[] = Int(local.y)
        g_cmd()[] |= CMD_CLICK

    def keyDown_(self, event: ObjCObject):
        var chars = msg_send[
            ObjCObject, "NSEvent", "charactersIgnoringModifiers"
        ](event)
        var p = msg_send[P, "NSString", "UTF8String"](chars)
        if Int(p) == 0:
            return
        var key = String(unsafe_from_utf8_ptr=p.unsafe_bitcast[c_char]())
        if key == " ":
            g_cmd()[] |= CMD_PAUSE
        elif key == "r":
            g_cmd()[] |= CMD_RESET
        elif key == "q" or key == "\x1b":
            g_cmd()[] |= CMD_QUIT


def main() raises:
    # AppKit is not linked into a JIT-run process; without this the
    # NSApplication lookup is nil and the app exits silently.
    if not load_framework["AppKit"]():
        raise Error("could not load AppKit")

    # MANDEL_FRAMES=N: render N frames and exit, politely.
    var frame_limit = 0
    let door = getenv("MANDEL_FRAMES")
    if door != "":
        frame_limit = Int(door)

    var cx = CX0
    var cy = CY0
    comptime SCALE0 = Float32(3.0) / Float32(WIDTH)
    var scale = SCALE0
    var phase = Float32(0.0)

    # ── Timing: the same fractal, one CPU core then the GPU ────────────────
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
    # Warm, then time: the first launch carries compilation and wiring.
    ctx.enqueue_function(kern, dev, cx, cy, scale, grid_dim=(GRID), block_dim=(BLOCK))
    ctx.synchronize()
    var g0 = perf_counter_ns()
    ctx.enqueue_function(kern, dev, cx, cy, scale, grid_dim=(GRID), block_dim=(BLOCK))
    ctx.synchronize()
    var g1 = perf_counter_ns()
    var gpu_ms = Float64(g1 - g0) / 1e6
    print("  GPU:", gpu_ms, "ms  (", cpu_ms / gpu_ms, "x faster )")

    # Host-side frame, owned outside Mojo's lifetime checker on purpose: the
    # pointer crosses into `replaceRegion:` every frame.
    var bgra = Pointer[UInt32, MutUntrackedOrigin](
        unsafe_from_address=Int(external_call["calloc", P](Int(PIXELS), Int(4)))
    )

    # ── The window ─────────────────────────────────────────────────────────
    with autoreleasepool():
        var app = msg_send[
            ObjCObject, "NSApplication", "sharedApplication", is_class=True
        ](ObjCClass.lookup["NSApplication"]().as_object())
        # Regular, unless this is an unattended run -- in which case the app
        # stays an Accessory and never takes the screen from whoever is
        # actually working.
        _ = msg_send[Bool, "NSApplication", "setActivationPolicy:"](
            app, Int(1) if frame_limit != 0 else Int(0)
        )

        var win = msg_send[ObjCObject, "NSWindow", "alloc", is_class=True](
            ObjCClass.lookup["NSWindow"]().as_object()
        )
        win = msg_send[
            ObjCObject,
            "NSWindow",
            "initWithContentRect:styleMask:backing:defer:",
        ](
            win,
            CGRect(CGPoint(120.0, 120.0), CGSize(Float64(WIDTH), Float64(HEIGHT))),
            Int(15),
            Int(2),
            Bool(False),
        )
        _ = msg_send[ObjCObject, "NSWindow", "setTitle:"](
            win, nsstring(String("Mandelbrot — every pixel is Mojo")).ptr()
        )

        # The content view is ours: instantiating the class registers it,
        # methods, encodings and all.
        var view = ObjCObject(MandelbrotView().__objc_id)
        _ = msg_send[ObjCObject, "NSView", "setFrame:"](
            view,
            CGRect(CGPoint(0.0, 0.0), CGSize(Float64(WIDTH), Float64(HEIGHT))),
        )

        # Metal: the display device, its queue, and the layer the frame lands
        # on. `send` rather than `msg_send` for the protocol methods -- the
        # concrete classes behind MTLDevice and friends are private, so there
        # is no public class name for the database to check them against.
        var display_dev = ObjCObject(
            Int(external_call["MTLCreateSystemDefaultDevice", P]())
        )
        var queue = send[ObjCObject, "newCommandQueue"](display_dev)
        _ = external_call["objc_retain", P](queue.ptr())

        var layer = msg_send[ObjCObject, "CAMetalLayer", "layer", is_class=True](
            ObjCClass.lookup["CAMetalLayer"]().as_object()
        )
        _ = send[ObjCObject, "setDevice:"](layer, display_dev.ptr())
        _ = msg_send[ObjCObject, "CAMetalLayer", "setPixelFormat:"](
            layer, Int(80)  # MTLPixelFormatBGRA8Unorm
        )
        _ = msg_send[ObjCObject, "CAMetalLayer", "setFramebufferOnly:"](
            layer, Bool(False)
        )
        _ = msg_send[ObjCObject, "CAMetalLayer", "setDrawableSize:"](
            layer, CGSize(Float64(WIDTH), Float64(HEIGHT))
        )
        _ = external_call["objc_retain", P](layer.ptr())

        _ = msg_send[ObjCObject, "NSView", "setWantsLayer:"](view, True)
        _ = msg_send[ObjCObject, "NSView", "setLayer:"](view, layer.ptr())
        _ = msg_send[ObjCObject, "NSWindow", "setContentView:"](win, view.ptr())
        _ = msg_send[Bool, "NSWindow", "makeFirstResponder:"](win, view.ptr())
        _ = msg_send[ObjCObject, "NSWindow", "makeKeyAndOrderFront:"](
            win, app.ptr()
        )
        if frame_limit == 0:
            _ = msg_send[
                ObjCObject, "NSApplication", "activateIgnoringOtherApps:"
            ](app, Bool(True))
        # A hand-rolled pump must call this itself; it is where AppKit
        # finishes wiring the run loop that `[NSApp run]` would have wired.
        _ = msg_send[ObjCObject, "NSApplication", "finishLaunching"](app)

        var region = MTLRegion(MTLOrigin(0, 0, 0), MTLSize(WIDTH, HEIGHT, 1))
        var NSDate = ObjCClass.lookup["NSDate"]()
        var mode = nsstring(String("kCFRunLoopDefaultMode"))

        print("Rendering. click recenters · space pauses · r resets · q quits")
        var frames = 0
        var running = True
        var paused = False
        var loop_start = perf_counter_ns()

        while running:
            # ── events, drained; the view's handlers set flags ─────────────
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
            if not msg_send[Bool, "NSWindow", "isVisible"](win):
                break

            # ── the flags, on the thread that owns the GPU ─────────────────
            var pending = g_cmd()[]
            if pending != 0:
                g_cmd()[] = 0
                if (pending & CMD_CLICK) != 0:
                    # The view is flipped, so the click is already in the
                    # kernel's coordinates.
                    cx += (Float32(g_click_x()[]) - Float32(WIDTH) * 0.5) * scale
                    cy += (Float32(g_click_y()[]) - Float32(HEIGHT) * 0.5) * scale
                if (pending & CMD_PAUSE) != 0:
                    paused = not paused
                if (pending & CMD_RESET) != 0:
                    cx = CX0
                    cy = CY0
                    scale = SCALE0
                    paused = False
                if (pending & CMD_QUIT) != 0:
                    running = False

            # ── one frame: compute and colour in a single Mojo dispatch ────
            ctx.enqueue_function(
                color_kern, dev, cx, cy, scale, phase,
                grid_dim=(GRID), block_dim=(BLOCK),
            )
            ctx.synchronize()
            with dev.map_to_host() as pix:
                var src = pix.unsafe_ptr()
                for k in range(PIXELS):
                    bgra[unsafe_offset=k] = src[unsafe_offset=k]

            var drawable = msg_send[ObjCObject, "CAMetalLayer", "nextDrawable"](
                layer
            )
            if not drawable.is_nil():
                var tex = msg_send[ObjCObject, "CAMetalDrawable", "texture"](
                    drawable
                )
                _ = send[
                    ObjCObject,
                    "replaceRegion:mipmapLevel:withBytes:bytesPerRow:",
                ](tex, region, Int(0), bgra.unsafe_bitcast[NoneType](),
                  Int(WIDTH * 4))
                var cb = send[ObjCObject, "commandBuffer"](queue)
                _ = send[ObjCObject, "presentDrawable:"](cb, drawable.ptr())
                _ = send[ObjCObject, "commit"](cb)

            frames += 1
            if not paused:
                # Drift the palette and dive; bottom out rather than vanish.
                phase += Float32(0.004)
                scale *= Float32(0.985)
                if scale < SCALE0 * Float32(1e-4):
                    scale = SCALE0
            if frames % 120 == 0:
                var now = perf_counter_ns()
                var fps = Float64(frames) / (Float64(now - loop_start) / 1e9)
                # Also to stdout: the title bar is invisible to a captured
                # run, which is every run that is not a person watching.
                print("  frame", frames, "—", fps, "fps")
                _ = msg_send[ObjCObject, "NSWindow", "setTitle:"](
                    win,
                    nsstring(
                        String("Mandelbrot — ") + String(Int(fps)) + " fps"
                    ).ptr(),
                )
            if frame_limit != 0 and frames >= frame_limit:
                running = False

        var secs = Float64(perf_counter_ns() - loop_start) / 1e9
        if secs > 0.0:
            print(
                "Rendered", frames, "frames in", secs, "s (",
                Float64(frames) / secs, "fps )",
            )
