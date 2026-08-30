# ===----------------------------------------------------------------------=== #
# Fernwind — the fern meadow again, computed by the GPU, swaying in the wind.
#
# examples/ferns grows its picture the honest sequential way: the chaos game
# is one point chasing itself, so a fern is one thread's work and the CPU
# plots a few hundred points a frame into an accumulating picture. That is
# why those ferns cannot move -- the picture IS the accumulation.
#
# This is the fractal-flame answer. Twenty-four thousand GPU threads each run
# their own short chaos game -- a burn-in to land on the attractor, then a
# plotted stretch -- and their hits meet in shared density buffers through
# atomic adds. Seven million points a frame, a fresh fern from scratch every
# frame, and redrawing from scratch is what buys the animation: the MAPS can
# change per frame, so the wind lives in the mathematics. Each fern's climb
# map is rotated a fraction of a degree by a gusting wind field, and because
# that map applies recursively up the plant, a uniform rotation compounds
# into a progressive bend -- stems lean, tips whip, exactly like wind.
#
#   click    plant a fern where you clicked (lower means closer means bigger)
#   space    still the air
#   r        reseed the landscape
#   q / esc  quit, as does closing the window
#
# The lawn and the cloud sky are painted once per landscape by the CPU, as in
# examples/ferns, and uploaded; a shade kernel composites the fern densities
# over that backdrop with a saturating curve, so density does the shading and
# nothing blows out. Same current patterns throughout: std.objc geometry, a
# `class` whose handlers only set flags, the frame loop owning every GPU and
# Metal call. The design rests on two facts proved by a probe before it was
# written: Atomic.fetch_add lowers through the AIR backend without losing
# increments, and host writes through map_to_host reach the next dispatch.
#
# FERNWIND_FRAMES=N renders N frames and exits as an unfocused Accessory.
# FERNWIND_DUMP=path writes the final frame as raw BGRA on the way out.
# ===----------------------------------------------------------------------=== #

from std.gpu import global_idx
from std.atomic import Atomic
from std.math import cos, sin
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

comptime W = 1024
comptime H = 640
comptime PIXELS = W * H

comptime MAX_FERNS = 24
comptime SEED_FERNS = 12
comptime HORIZON = Float64(H) * 0.55

# The flame: streams x plotted iterations = points per frame. On the M4 this
# is far below the frame budget; the tone curve's K is tuned to this density.
comptime STREAMS = 24576
comptime ITERS = 280
comptime BURN = 12
comptime BLOCK = 256
comptime GRID = (STREAMS + BLOCK - 1) // BLOCK
comptime PIX_GRID = (PIXELS + BLOCK - 1) // BLOCK

# Per-fern parameter record, in Float32 slots. Header: [0] fern count,
# [1] frame seed. Ferns start at slot 8, stride 40:
#   +0 base_x  +1 base_y  +2 scale  +3 flip  +4 r  +5 g  +6 b
#   +7 lean_c  +8 lean_s
#   +9 .. +36  four maps x (a, b, c, d, e, f, cumulative p)
comptime PARAM_HEAD = 8
comptime PARAM_STRIDE = 40
comptime PARAM_FLOATS = PARAM_HEAD + MAX_FERNS * PARAM_STRIDE

comptime BLADES = 14000
comptime NCX = 9
comptime NCY = 5
comptime NFX = 25
comptime NFY = 13


# ===----------------------------------------------------------------------=== #
# Metal structs, by value across the ABI (48 bytes, so on the stack).
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
# The fern, as in fern/ifs.mojo: four affine maps, and the shape is in the
# numbers. Map 1 is the climb -- the one the wind gets to bend.
# ===----------------------------------------------------------------------=== #


@fieldwise_init
struct Affine(ImplicitlyCopyable, Movable):
    """Affine map: x' = a x + b y + e,  y' = c x + d y + f, taken with probability p."""

    var a: Float64
    var b: Float64
    var c: Float64
    var d: Float64
    var e: Float64
    var f: Float64
    var p: Float64


def barnsley() -> List[Affine]:
    var maps = List[Affine]()
    maps.append(Affine(0.00, 0.00, 0.00, 0.16, 0.0, 0.00, 0.01))
    maps.append(Affine(0.85, 0.04, -0.04, 0.85, 0.0, 1.60, 0.85))
    maps.append(Affine(0.20, -0.26, 0.23, 0.22, 0.0, 1.60, 0.07))
    maps.append(Affine(-0.15, 0.28, 0.26, 0.24, 0.0, 0.44, 0.07))
    return maps^


struct Rng(Movable):
    """Random numbers: xorshift64* on the host, deterministic -- the same meadow, every run."""

    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed

    def next(mut self) -> Float64:
        self.state ^= self.state >> 12
        self.state ^= self.state << 25
        self.state ^= self.state >> 27
        let x = self.state * 2685821657736338717
        return Float64(x >> 11) / Float64(1 << 53)


@fieldwise_init
struct Fern(ImplicitlyCopyable, Movable):
    """One plant's standing state. The bend is computed fresh each frame from
    the wind, so nothing here moves except by being recalculated."""

    var base_x: Float64
    var base_y: Float64
    var scale: Float64
    var lean0: Float64  # the fern's own resting lean, radians
    var flip: Float64
    var r: Int
    var g: Int
    var b: Int
    var phase: Float64  # where this fern sits in the travelling gusts
    var supple: Float64  # how much the wind moves it; taller bends more


def make_fern(mut rng: Rng, base_x: Float64, base_y: Float64) -> Fern:
    """Depth does the design work: how far below the horizon a fern stands
    sets its size, brightness and blue-shift, so the meadow recedes."""
    var t = (base_y - HORIZON) / (Float64(H) - HORIZON)
    if t < 0.0:
        t = 0.0
    elif t > 1.0:
        t = 1.0
    let scale = 5.0 + t * 16.0 + rng.next() * 2.0
    let dim = 0.45 + 0.55 * t
    let g_ = Int((120.0 + rng.next() * 135.0) * dim)
    let r_ = Int((15.0 + rng.next() * 75.0) * dim)
    let b_ = Int((25.0 + rng.next() * 65.0 + (1.0 - t) * 45.0) * dim)
    let lean0 = (rng.next() - 0.5) * 0.20
    let flip = 1.0 if rng.next() < 0.5 else -1.0
    let phase = base_x * 0.006 + rng.next() * 0.8
    let supple = 0.55 + 0.45 * t + rng.next() * 0.25
    return Fern(base_x, base_y, scale, lean0, flip, r_, g_, b_, phase, supple)


# ===----------------------------------------------------------------------=== #
# The kernels.
# ===----------------------------------------------------------------------=== #


@always_inline
def _xorshift32(s: UInt32) -> UInt32:
    var x = s
    x ^= x << 13
    x ^= x >> 17
    x ^= x << 5
    return x


def chaos_kernel(
    nacc: Pointer[UInt32, MutAnyOrigin],
    racc: Pointer[UInt32, MutAnyOrigin],
    gacc: Pointer[UInt32, MutAnyOrigin],
    bacc: Pointer[UInt32, MutAnyOrigin],
    params: Pointer[Float32, MutAnyOrigin],
):
    """One thread, one short chaos game.

    The stream picks its fern by thread id, burns in unplotted so its point
    is ON the attractor before anyone sees it, then plots its stretch with
    four atomic adds per hit: a count, and the fern's colour weighted in, so
    overlapping ferns blend by evidence rather than by draw order.
    """
    var idx = Int(global_idx.x)
    if idx >= STREAMS:
        return
    let nf = Int(params[unsafe_offset=0])
    if nf <= 0:
        return
    let seed = UInt32(Int(params[unsafe_offset=1]))
    let fern = idx % nf
    let at = PARAM_HEAD + fern * PARAM_STRIDE

    let base_x = params[unsafe_offset = at + 0]
    let base_y = params[unsafe_offset = at + 1]
    let scale = params[unsafe_offset = at + 2]
    let flip = params[unsafe_offset = at + 3]
    let cr = UInt32(Int(params[unsafe_offset = at + 4]))
    let cg = UInt32(Int(params[unsafe_offset = at + 5]))
    let cb = UInt32(Int(params[unsafe_offset = at + 6]))
    let lean_c = params[unsafe_offset = at + 7]
    let lean_s = params[unsafe_offset = at + 8]

    # A stream's randomness must differ per thread AND per frame, or every
    # frame replots the same points and the flame strobes.
    var state = UInt32(idx) * 2654435761 ^ seed
    state = _xorshift32(state | 1)

    var x = Float32(0)
    var y = Float32(0)
    for step in range(BURN + ITERS):
        state = _xorshift32(state)
        let roll = Float32(state >> 8) * Float32(5.9604645e-08)  # 1/2^24
        # Cumulative probabilities were prepared on the host, so choosing a
        # map is three compares and no adds.
        var m = at + 9
        if roll > params[unsafe_offset = m + 6]:
            m += 7
            if roll > params[unsafe_offset = m + 6]:
                m += 7
                if roll > params[unsafe_offset = m + 6]:
                    m += 7
        let nx = (
            params[unsafe_offset = m + 0] * x
            + params[unsafe_offset = m + 1] * y
            + params[unsafe_offset = m + 4]
        )
        let ny = (
            params[unsafe_offset = m + 2] * x
            + params[unsafe_offset = m + 3] * y
            + params[unsafe_offset = m + 5]
        )
        x = nx
        y = ny
        if step < BURN:
            continue
        # IFS space to the meadow: flip, lean about the base, scale, stand.
        let fx = x * flip * scale
        let fy = y * scale
        let px = Int(base_x + fx * lean_c + fy * lean_s)
        let py = Int(base_y - fy * lean_c + fx * lean_s)
        if px < 0 or px >= W or py < 0 or py >= H:
            continue
        let pat = py * W + px
        _ = Atomic.fetch_add(nacc.unsafe_offset(pat), UInt32(1))
        _ = Atomic.fetch_add(racc.unsafe_offset(pat), cr)
        _ = Atomic.fetch_add(gacc.unsafe_offset(pat), cg)
        _ = Atomic.fetch_add(bacc.unsafe_offset(pat), cb)


def shade_kernel(
    frame: Pointer[UInt32, MutAnyOrigin],
    backdrop: Pointer[UInt32, MutAnyOrigin],
    nacc: Pointer[UInt32, MutAnyOrigin],
    racc: Pointer[UInt32, MutAnyOrigin],
    gacc: Pointer[UInt32, MutAnyOrigin],
    bacc: Pointer[UInt32, MutAnyOrigin],
):
    """Densities over the backdrop. The mean of the accumulated colour is the
    fern's true shade wherever ferns overlap; coverage n/(n+K) is a curve
    that density can push toward opaque but never past it, so the spine goes
    solid and the wisps stay wisps and nothing blows out to white."""
    var idx = Int(global_idx.x)
    if idx >= PIXELS:
        return
    let back = backdrop[unsafe_offset=idx]
    let n = nacc[unsafe_offset=idx]
    if n == 0:
        frame[unsafe_offset=idx] = back
        return
    let dens = Float32(Int(n))
    let a = dens / (dens + Float32(3.0))
    let mr = Float32(Int(racc[unsafe_offset=idx])) / dens
    let mg = Float32(Int(gacc[unsafe_offset=idx])) / dens
    let mb = Float32(Int(bacc[unsafe_offset=idx])) / dens
    let br = Float32(Int((back >> 16) & 0xFF))
    let bg = Float32(Int((back >> 8) & 0xFF))
    let bb = Float32(Int(back & 0xFF))
    let outr = UInt32(Int(br + (mr - br) * a))
    let outg = UInt32(Int(bg + (mg - bg) * a))
    let outb = UInt32(Int(bb + (mb - bb) * a))
    frame[unsafe_offset=idx] = (
        outb | (outg << 8) | (outr << 16) | (UInt32(255) << 24)
    )


# ===----------------------------------------------------------------------=== #
# The backdrop: cloud sky and lawn, painted by the CPU once per landscape,
# exactly as in examples/ferns.
# ===----------------------------------------------------------------------=== #


def _lattice(mut rng: Rng, nx: Int, ny: Int) -> List[Float64]:
    var out = List[Float64]()
    for _k in range(nx * ny):
        out.append(rng.next())
    return out^


def _bilerp(lat: List[Float64], nx: Int, ny: Int, u: Float64, v: Float64) -> Float64:
    var x = u * Float64(nx - 1)
    var y = v * Float64(ny - 1)
    var xi = Int(x)
    var yi = Int(y)
    if xi >= nx - 1:
        xi = nx - 2
    if yi >= ny - 1:
        yi = ny - 2
    var fx = x - Float64(xi)
    var fy = y - Float64(yi)
    fx = fx * fx * (3.0 - 2.0 * fx)
    fy = fy * fy * (3.0 - 2.0 * fy)
    let a = lat[yi * nx + xi]
    let b = lat[yi * nx + xi + 1]
    let c = lat[(yi + 1) * nx + xi]
    let d = lat[(yi + 1) * nx + xi + 1]
    return (a * (1.0 - fx) + b * fx) * (1.0 - fy) + (
        c * (1.0 - fx) + d * fx
    ) * fy


def paint_backdrop(host: Pointer[UInt32, MutUntrackedOrigin], mut rng: Rng):
    """Dusk sky with value-noise clouds, then the lawn: thousands of blades,
    taller and brighter the nearer they stand, painted back to front."""
    let coarse = _lattice(rng, NCX, NCY)
    let fine = _lattice(rng, NFX, NFY)

    for py in range(H):
        if Float64(py) < HORIZON:
            let t = Float64(py) / HORIZON
            var r = 10.0 + t * 36.0
            var g = 12.0 + t * 28.0
            var b = 34.0 + t * 24.0
            for px in range(W):
                let u = Float64(px) / Float64(W)
                var n = 0.65 * _bilerp(coarse, NCX, NCY, u, t) + 0.35 * _bilerp(
                    fine, NFX, NFY, u, t
                )
                var cloud = (n - 0.52) / 0.30
                if cloud < 0.0:
                    cloud = 0.0
                elif cloud > 1.0:
                    cloud = 1.0
                cloud = cloud * cloud * (3.0 - 2.0 * cloud)
                cloud *= 0.75 - 0.55 * t
                let cr = r + (96.0 - r) * cloud
                let cg = g + (100.0 - g) * cloud
                let cb = b + (122.0 - b) * cloud
                host[unsafe_offset = py * W + px] = (
                    UInt32(Int(cb)) | (UInt32(Int(cg)) << 8)
                    | (UInt32(Int(cr)) << 16) | (UInt32(255) << 24)
                )
        else:
            let t = (Float64(py) - HORIZON) / (Float64(H) - HORIZON)
            let r = Int(16.0 - t * 7.0)
            let g = Int(26.0 - t * 9.0)
            let b = Int(13.0 - t * 6.0)
            let pixel = (
                UInt32(b) | (UInt32(g) << 8) | (UInt32(r) << 16)
                | (UInt32(255) << 24)
            )
            for px in range(W):
                host[unsafe_offset = py * W + px] = pixel

    for k in range(BLADES):
        let depth = Float64(k) / Float64(BLADES)
        let by = HORIZON + 2.0 + depth * (Float64(H) - HORIZON - 3.0)
        let bx = rng.next() * Float64(W)
        let t = (by - HORIZON) / (Float64(H) - HORIZON)
        let h = 2.0 + t * 11.0 + rng.next() * 3.0
        let lean = (rng.next() - 0.5) * 4.0
        let dim = 0.40 + 0.60 * t
        let gr = (44.0 + rng.next() * 66.0) * dim
        let rr = (9.0 + rng.next() * 24.0) * dim
        let br = (11.0 + rng.next() * 26.0) * dim
        var i = 0.0
        while i < h:
            let a = i / h
            let px = Int(bx + lean * a * a)
            let py = Int(by - i)
            if px >= 0 and px < W and py >= 0 and py < H:
                let lit = 0.72 + 0.42 * a
                host[unsafe_offset = py * W + px] = (
                    UInt32(Int(br * lit)) | (UInt32(Int(gr * lit)) << 8)
                    | (UInt32(Int(rr * lit)) << 16) | (UInt32(255) << 24)
                )
            i += 1.0


# ===----------------------------------------------------------------------=== #
# Input: handlers set flags, the frame loop acts on them.
# ===----------------------------------------------------------------------=== #

comptime CMD_CLICK = 1
comptime CMD_PAUSE = 2
comptime CMD_RESET = 4
comptime CMD_QUIT = 8

comptime g_cmd = named_global["fernwind.cmd", Int]
comptime g_click_x = named_global["fernwind.click.x", Int]
comptime g_click_y = named_global["fernwind.click.y", Int]


class FernwindView(NSView):
    """The window's content view. Cocoa calls these; they only set flags."""

    def acceptsFirstResponder(self) -> Bool:
        return True

    def isFlipped(self) -> Bool:
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
    if not load_framework["AppKit"]():
        raise Error("could not load AppKit")

    var frame_limit = 0
    let door = getenv("FERNWIND_FRAMES")
    if door != "":
        frame_limit = Int(door)

    let maps = barnsley()
    var rng = Rng(0x5EED)
    var ferns = List[Fern]()
    var landscape = 0
    var need_seed = True
    var next_slot = 0

    var ctx = DeviceContext(api="metal")
    print("Fernwind —", ctx.name(), "·", STREAMS, "streams x", ITERS, "points")

    var nacc = ctx.enqueue_create_buffer[DType.uint32](PIXELS)
    var racc = ctx.enqueue_create_buffer[DType.uint32](PIXELS)
    var gacc = ctx.enqueue_create_buffer[DType.uint32](PIXELS)
    var bacc = ctx.enqueue_create_buffer[DType.uint32](PIXELS)
    var backdrop = ctx.enqueue_create_buffer[DType.uint32](PIXELS)
    var frame_buf = ctx.enqueue_create_buffer[DType.uint32](PIXELS)
    var params = ctx.enqueue_create_buffer[DType.float32](PARAM_FLOATS)
    ctx.synchronize()

    var chaos = ctx.compile_function[chaos_kernel]()
    var shade = ctx.compile_function[shade_kernel]()

    # The host-side frame the layer uploads from, and the host copy of the
    # backdrop the painter paints into before it goes up to the device.
    var bgra = Pointer[UInt32, MutUntrackedOrigin](
        unsafe_from_address=Int(external_call["calloc", P](Int(PIXELS), Int(4)))
    )
    var back_host = Pointer[UInt32, MutUntrackedOrigin](
        unsafe_from_address=Int(external_call["calloc", P](Int(PIXELS), Int(4)))
    )

    with autoreleasepool():
        var app = msg_send[
            ObjCObject, "NSApplication", "sharedApplication", is_class=True
        ](ObjCClass.lookup["NSApplication"]().as_object())
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
            CGRect(CGPoint(160.0, 160.0), CGSize(Float64(W), Float64(H))),
            Int(15),
            Int(2),
            Bool(False),
        )
        _ = msg_send[ObjCObject, "NSWindow", "setTitle:"](
            win, nsstring(String("Fernwind — the GPU, swaying")).ptr()
        )

        var view = ObjCObject(FernwindView().__objc_id)
        _ = msg_send[ObjCObject, "NSView", "setFrame:"](
            view, CGRect(CGPoint(0.0, 0.0), CGSize(Float64(W), Float64(H)))
        )

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
            layer, Int(80)
        )
        _ = msg_send[ObjCObject, "CAMetalLayer", "setFramebufferOnly:"](
            layer, Bool(False)
        )
        _ = msg_send[ObjCObject, "CAMetalLayer", "setDrawableSize:"](
            layer, CGSize(Float64(W), Float64(H))
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
        _ = msg_send[ObjCObject, "NSApplication", "finishLaunching"](app)

        var region = MTLRegion(MTLOrigin(0, 0, 0), MTLSize(W, H, 1))
        var NSDate = ObjCClass.lookup["NSDate"]()
        var mode = nsstring(String("kCFRunLoopDefaultMode"))

        print("Fernwind. click plants · space stills the air · r reseeds · q quits")
        var frames = 0
        var running = True
        var still = False
        var t = 0.0  # wind time, in frames' worth of seconds -- deterministic
        var loop_start = perf_counter_ns()

        while running:
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

            var pending = g_cmd()[]
            if pending != 0:
                g_cmd()[] = 0
                if (pending & CMD_CLICK) != 0:
                    let fern = make_fern(
                        rng, Float64(g_click_x()[]), Float64(g_click_y()[])
                    )
                    if len(ferns) < MAX_FERNS:
                        ferns.append(fern)
                    else:
                        ferns[next_slot] = fern
                        next_slot = (next_slot + 1) % MAX_FERNS
                if (pending & CMD_PAUSE) != 0:
                    still = not still
                if (pending & CMD_RESET) != 0:
                    need_seed = True
                if (pending & CMD_QUIT) != 0:
                    running = False

            if need_seed:
                need_seed = False
                landscape += 1
                next_slot = 0
                while len(ferns) > 0:
                    _ = ferns.pop()
                paint_backdrop(back_host, rng)
                with backdrop.map_to_host() as up:
                    for k in range(PIXELS):
                        up[k] = back_host[unsafe_offset=k]
                for k in range(SEED_FERNS):
                    let bx = (Float64(k) + 0.18 + rng.next() * 0.64) * (
                        Float64(W) / Float64(SEED_FERNS)
                    )
                    let by = HORIZON + 12.0 + rng.next() * (
                        Float64(H) - HORIZON - 24.0
                    )
                    ferns.append(make_fern(rng, bx, by))
                print("landscape", landscape, "—", len(ferns), "ferns")

            # ── the wind, and this frame's parameters ──────────────────────
            # Gusts travel across the meadow: each fern reads the field a
            # little later the further right it stands. The climb map is
            # rotated by the local wind; recursion turns that uniform
            # rotation into a progressive bend up the plant.
            if not still:
                t += 1.0 / 60.0
            with params.map_to_host() as pw:
                pw[0] = Float32(len(ferns))
                pw[1] = Float32(frames % 8388608)
                for i in range(len(ferns)):
                    let fern = ferns[i]
                    let local = t - fern.phase
                    let gust = 0.6 + 0.4 * sin(local * 0.31 + 1.2)
                    let wind = gust * (
                        0.5 * sin(local * 0.9)
                        + 0.3 * sin(local * 2.3 + 0.8)
                        + 0.2 * sin(local * 0.13)
                    )
                    let lean = fern.lean0 + wind * 0.10 * fern.supple
                    let bend = (
                        wind * 0.030 + 0.010 * sin(local * 3.1)
                    ) * fern.supple * fern.flip
                    let bc = cos(bend)
                    let bs = sin(bend)
                    let at = PARAM_HEAD + i * PARAM_STRIDE
                    pw[at + 0] = Float32(fern.base_x)
                    pw[at + 1] = Float32(fern.base_y)
                    pw[at + 2] = Float32(fern.scale)
                    pw[at + 3] = Float32(fern.flip)
                    pw[at + 4] = Float32(fern.r)
                    pw[at + 5] = Float32(fern.g)
                    pw[at + 6] = Float32(fern.b)
                    pw[at + 7] = Float32(cos(lean))
                    pw[at + 8] = Float32(sin(lean))
                    var acc = 0.0
                    for m in range(4):
                        let src = maps[m]
                        var a = src.a
                        var b = src.b
                        var c = src.c
                        var d = src.d
                        var e = src.e
                        var f = src.f
                        if m == 1:
                            # R(bend) after the climb map: linear part and
                            # translation both rotate, the root stays put.
                            a = bc * src.a - bs * src.c
                            b = bc * src.b - bs * src.d
                            c = bs * src.a + bc * src.c
                            d = bs * src.b + bc * src.d
                            e = bc * src.e - bs * src.f
                            f = bs * src.e + bc * src.f
                        acc += src.p
                        let ma = at + 9 + m * 7
                        pw[ma + 0] = Float32(a)
                        pw[ma + 1] = Float32(b)
                        pw[ma + 2] = Float32(c)
                        pw[ma + 3] = Float32(d)
                        pw[ma + 4] = Float32(e)
                        pw[ma + 5] = Float32(f)
                        pw[ma + 6] = Float32(acc)

            # ── the frame, computed from scratch ───────────────────────────
            ctx.enqueue_memset(nacc, UInt32(0))
            ctx.enqueue_memset(racc, UInt32(0))
            ctx.enqueue_memset(gacc, UInt32(0))
            ctx.enqueue_memset(bacc, UInt32(0))
            ctx.enqueue_function(
                chaos, nacc, racc, gacc, bacc, params,
                grid_dim=(GRID), block_dim=(BLOCK),
            )
            ctx.enqueue_function(
                shade, frame_buf, backdrop, nacc, racc, gacc, bacc,
                grid_dim=(PIX_GRID), block_dim=(BLOCK),
            )
            ctx.synchronize()
            with frame_buf.map_to_host() as pix:
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
                  Int(W * 4))
                var cb = send[ObjCObject, "commandBuffer"](queue)
                _ = send[ObjCObject, "presentDrawable:"](cb, drawable.ptr())
                _ = send[ObjCObject, "commit"](cb)

            frames += 1
            if frames % 240 == 0:
                var now = perf_counter_ns()
                var fps = Float64(frames) / (Float64(now - loop_start) / 1e9)
                print("  frame", frames, "—", fps, "fps")
            if frame_limit != 0 and frames >= frame_limit:
                running = False

        var secs = Float64(perf_counter_ns() - loop_start) / 1e9
        if secs > 0.0:
            print(
                "Swayed", landscape, "landscape(s) over", frames, "frames in",
                secs, "s (", Float64(frames) / secs, "fps )",
            )

        let dump = getenv("FERNWIND_DUMP")
        if dump != "":
            var out = List[UInt8]()
            let bytes = bgra.unsafe_bitcast[UInt8]()
            for k in range(PIXELS * 4):
                out.append(bytes[unsafe_offset=k])
            var f = open(dump, "w")
            f.write_all(Span(out))
            f.close()
            print("dumped", W, "x", H, "BGRA to", dump)
