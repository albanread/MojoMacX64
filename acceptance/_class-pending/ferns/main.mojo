# ===----------------------------------------------------------------------=== #
# Ferns — a landscape of Barnsley ferns, growing live in a window.
#
# A dozen ferns in different shades of green, each an iterated function
# system played as the chaos game: one point chased through four affine maps,
# tens of thousands of times, plotted where it lands. Every frame each fern
# grows by a few hundred points, so the landscape assembles in front of you —
# stems first, then fronds, then the fine leaf texture as points pile up.
# Farther ferns are smaller, dimmer and bluer. They grow out of a procedural
# lawn — fourteen thousand individual grass blades, taller and greener up
# close — under a dusk sky whose clouds come from two octaves of value noise.
# Everything is drawn by the CPU into one BGRA buffer that a `CAMetalLayer`
# presents. When the landscape is fully grown it holds for a moment, then a
# new one seeds, sky and lawn and all.
#
#   click    plant a fern where you clicked — lower on screen means closer,
#            so it comes up bigger
#   space    pause the growing
#   r        clear the ground and reseed
#   q / esc  quit, as does closing the window
#
# The same current patterns as the mandelbrot and fluid examples: geometry
# from std.objc, a `class` the runtime calls whose handlers only set flags,
# and a frame loop that owns the buffer and every Metal call. The IFS pieces
# (Affine, barnsley, the xorshift Rng) mirror fern/ifs.mojo, which renders
# one fern to a PNG — example folders are self-contained, so the forty lines
# are carried rather than imported across a sibling boundary.
#
# FERNS_FRAMES=N renders N frames and exits as an unfocused Accessory, so a
# harness run never takes the screen from whoever is working. FERNS_DUMP=path
# writes the final frame as raw BGRA on the way out -- what a harness (or a
# reviewer) needs to see the landscape without a screen.
# ===----------------------------------------------------------------------=== #

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
# Every fern finishes in about the same number of frames regardless of size,
# so the landscape matures together rather than the big ones dragging on.
comptime GROW_FRAMES = 600
comptime HOLD_FRAMES = 300  # grown landscape lingers ~5 s, then reseeds

# Where the ground meets the sky, and how deep the ground band is.
comptime HORIZON = Float64(H) * 0.55


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
# The fern itself, as in fern/ifs.mojo: four affine maps and the shape is in
# the numbers. Map 0 is the stem, map 1 the climb, maps 2 and 3 the two
# lowest fronds.
# ===----------------------------------------------------------------------=== #


@fieldwise_init
struct Affine(ImplicitlyCopyable, Movable):
    """x' = a x + b y + e,  y' = c x + d y + f, chosen with probability p."""

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
    """xorshift64*, deterministic: the same landscape grows on every run,
    which is what lets a harness assert anything about the picture."""

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
    """One plant: where it stands, how big, what shade, and how far it has
    grown. The chaos-game point (x, y) is the whole growing state -- the
    picture so far lives in the framebuffer, not here."""

    var base_x: Float64  # where the stem meets the ground, in pixels
    var base_y: Float64
    var scale: Float64  # pixels per IFS unit; the fern is ~10 units tall
    var lean_c: Float64  # cos/sin of a small lean, applied about the base
    var lean_s: Float64
    var flip: Float64  # ±1: half the ferns face the other way
    var r: Int  # the fern's full colour, reached by accumulation
    var g: Int
    var b: Int
    var x: Float64  # the chaos-game point, in IFS coordinates
    var y: Float64
    var plotted: Int
    var target: Int
    var delay: Int  # frames to wait before sprouting


def make_fern(mut rng: Rng, base_x: Float64, base_y: Float64) -> Fern:
    """A fern for a spot on the ground. Depth does the design work: how far
    below the horizon it stands sets its size, brightness and blue-shift, so
    nearer ferns come up bigger and greener."""
    var t = (base_y - HORIZON) / (Float64(H) - HORIZON)  # 0 far .. 1 near
    if t < 0.0:
        t = 0.0
    elif t > 1.0:
        t = 1.0
    let scale = 5.0 + t * 16.0 + rng.next() * 2.0
    let dim = 0.45 + 0.55 * t
    # A shade of green per fern: yellow-greens up close, dusty blue-greens in
    # the distance.
    let g_ = Int((120.0 + rng.next() * 135.0) * dim)
    let r_ = Int((15.0 + rng.next() * 75.0) * dim)
    let b_ = Int((25.0 + rng.next() * 65.0 + (1.0 - t) * 45.0) * dim)
    let lean = (rng.next() - 0.5) * 0.24
    var c = 1.0 - lean * lean * 0.5  # cos, small-angle
    var s = lean
    let flip = 1.0 if rng.next() < 0.5 else -1.0
    # Bigger ferns need more points to fill; everyone matures together.
    let target = Int(scale * scale * 380.0)
    let delay = Int(rng.next() * 150.0)
    return Fern(
        base_x, base_y, scale, c, s, flip,
        r_, g_, b_, 0.0, 0.0, 0, target, delay,
    )


# ===----------------------------------------------------------------------=== #
# Input arrives on Cocoa's schedule; frames happen on ours. Handlers set
# flags, the frame loop acts on them — bits, so two things in one frame do
# not lose each other.
# ===----------------------------------------------------------------------=== #

comptime CMD_CLICK = 1
comptime CMD_PAUSE = 2
comptime CMD_RESET = 4
comptime CMD_QUIT = 8

comptime g_cmd = named_global["ferns.cmd", Int]
comptime g_click_x = named_global["ferns.click.x", Int]
comptime g_click_y = named_global["ferns.click.y", Int]


class FernView(NSView):
    """The window's content view. Cocoa calls these; they only set flags."""

    def acceptsFirstResponder(self) -> Bool:
        return True

    def isFlipped(self) -> Bool:
        # Origin top-left, matching the framebuffer's rows, so a click is
        # already a pixel.
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


comptime BLADES = 14000

# The cloud lattice: value noise, bilinearly interpolated. Coarse carries the
# cloud masses, fine breaks their edges up.
comptime NCX = 9
comptime NCY = 5
comptime NFX = 25
comptime NFY = 13


def _lattice(mut rng: Rng, nx: Int, ny: Int) -> List[Float64]:
    var out = List[Float64]()
    for _k in range(nx * ny):
        out.append(rng.next())
    return out^


def _bilerp(lat: List[Float64], nx: Int, ny: Int, u: Float64, v: Float64) -> Float64:
    """The lattice sampled smoothly at (u, v) in [0,1]²."""
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
    # Smoothstep the fractions, or the lattice shows through as diamonds.
    fx = fx * fx * (3.0 - 2.0 * fx)
    fy = fy * fy * (3.0 - 2.0 * fy)
    let a = lat[yi * nx + xi]
    let b = lat[yi * nx + xi + 1]
    let c = lat[(yi + 1) * nx + xi]
    let d = lat[(yi + 1) * nx + xi + 1]
    return (a * (1.0 - fx) + b * fx) * (1.0 - fy) + (
        c * (1.0 - fx) + d * fx
    ) * fy


def paint_backdrop(bgra: Pointer[UInt32, MutUntrackedOrigin], mut rng: Rng):
    """The world the ferns grow into, painted once per landscape.

    A dusk sky, deep indigo at the top warming toward the horizon, with
    clouds from two octaves of value noise — a coarse lattice for the masses,
    a fine one to roughen their edges, faded out near the horizon where real
    clouds thin into haze. Below it, ground and then the lawn: thousands of
    individual grass blades, each with its own height, lean, and slightly
    different green, taller and brighter the nearer they stand. The ferns are
    plotted over all of it, frame by frame.
    """
    let coarse = _lattice(rng, NCX, NCY)
    let fine = _lattice(rng, NFX, NFY)

    for py in range(H):
        if Float64(py) < HORIZON:
            let t = Float64(py) / HORIZON  # 0 top .. 1 horizon
            # Dusk gradient: indigo up high, a warm grey band low.
            var r = 10.0 + t * 36.0
            var g = 12.0 + t * 28.0
            var b = 34.0 + t * 24.0
            for px in range(W):
                let u = Float64(px) / Float64(W)
                var n = 0.65 * _bilerp(coarse, NCX, NCY, u, t) + 0.35 * _bilerp(
                    fine, NFX, NFY, u, t
                )
                # Only the upper range of the noise is cloud; the rest stays
                # sky. Smoothstep the edge, and thin everything toward the
                # horizon.
                var cloud = (n - 0.52) / 0.30
                if cloud < 0.0:
                    cloud = 0.0
                elif cloud > 1.0:
                    cloud = 1.0
                cloud = cloud * cloud * (3.0 - 2.0 * cloud)
                cloud *= 0.75 - 0.55 * t
                # Moonlit grey, blended over the gradient.
                let cr = r + (96.0 - r) * cloud
                let cg = g + (100.0 - g) * cloud
                let cb = b + (122.0 - b) * cloud
                bgra[unsafe_offset = py * W + px] = (
                    UInt32(Int(cb)) | (UInt32(Int(cg)) << 8)
                    | (UInt32(Int(cr)) << 16) | (UInt32(255) << 24)
                )
        else:
            # Bare earth under the lawn: dark moss, darker with nearness, so
            # the gaps between blades read as shadow rather than void.
            let t = (Float64(py) - HORIZON) / (Float64(H) - HORIZON)
            let r = Int(16.0 - t * 7.0)
            let g = Int(26.0 - t * 9.0)
            let b = Int(13.0 - t * 6.0)
            let pixel = (
                UInt32(b) | (UInt32(g) << 8) | (UInt32(r) << 16)
                | (UInt32(255) << 24)
            )
            for px in range(W):
                bgra[unsafe_offset = py * W + px] = pixel

    # The lawn. Back to front, so near blades overpaint far ones the way
    # nearness does.
    for k in range(BLADES):
        let depth = Float64(k) / Float64(BLADES)  # 0 far .. 1 near
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
                # Tips catch the light.
                let lit = 0.72 + 0.42 * a
                bgra[unsafe_offset = py * W + px] = (
                    UInt32(Int(br * lit)) | (UInt32(Int(gr * lit)) << 8)
                    | (UInt32(Int(rr * lit)) << 16) | (UInt32(255) << 24)
                )
            i += 1.0


@always_inline
def plot(
    bgra: Pointer[UInt32, MutUntrackedOrigin],
    px: Int,
    py: Int,
    r: Int,
    g: Int,
    b: Int,
):
    """One chaos-game hit: the pixel moves a quarter of the way to the
    fern's own colour. Density does the shading — a wisp brushed once stays
    mostly backdrop, a spine hit hundreds of times converges to the full
    shade and stops there. The first version added saturating increments,
    and dense regions blew out to white; converging can overshoot nothing,
    and it occludes correctly whether the pixel underneath was a dark sky or
    a bright grass tip."""
    if px < 0 or px >= W or py < 0 or py >= H:
        return
    let at = py * W + px
    let old = bgra[unsafe_offset=at]
    var ob = Int(old & 0xFF)
    var og = Int((old >> 8) & 0xFF)
    var orr = Int((old >> 16) & 0xFF)
    ob += (b - ob) // 4
    og += (g - og) // 4
    orr += (r - orr) // 4
    if ob == Int(old & 0xFF) and b != ob:
        ob += 1 if b > ob else -1
    if og == Int((old >> 8) & 0xFF) and g != og:
        og += 1 if g > og else -1
    if orr == Int((old >> 16) & 0xFF) and r != orr:
        orr += 1 if r > orr else -1
    bgra[unsafe_offset=at] = (
        UInt32(ob) | (UInt32(og) << 8) | (UInt32(orr) << 16)
        | (UInt32(255) << 24)
    )


def main() raises:
    if not load_framework["AppKit"]():
        raise Error("could not load AppKit")

    # FERNS_FRAMES=N: render N frames and exit, politely.
    var frame_limit = 0
    let door = getenv("FERNS_FRAMES")
    if door != "":
        frame_limit = Int(door)

    let maps = barnsley()
    var rng = Rng(0x5EED)
    var ferns = List[Fern]()
    var landscape = 0
    var need_seed = True
    var next_slot = 0  # where a click plants once the meadow is full

    var bgra = Pointer[UInt32, MutUntrackedOrigin](
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
            CGRect(CGPoint(140.0, 140.0), CGSize(Float64(W), Float64(H))),
            Int(15),
            Int(2),
            Bool(False),
        )
        _ = msg_send[ObjCObject, "NSWindow", "setTitle:"](
            win, nsstring(String("Ferns — click to plant")).ptr()
        )

        var view = ObjCObject(FernView().__objc_id)
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
            layer, Int(80)  # MTLPixelFormatBGRA8Unorm
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

        print("Ferns. click plants · space pauses · r reseeds · q quits")
        var frames = 0
        var running = True
        var paused = False
        var grown_for = 0
        var loop_start = perf_counter_ns()

        while running:
            # ── events; the view's handlers set flags ──────────────────────
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

            # ── flags, on the thread that owns the buffer ──────────────────
            var pending = g_cmd()[]
            if pending != 0:
                g_cmd()[] = 0
                if (pending & CMD_CLICK) != 0:
                    var fern = make_fern(
                        rng, Float64(g_click_x()[]), Float64(g_click_y()[])
                    )
                    fern.delay = 0  # a planted fern sprouts now
                    if len(ferns) < MAX_FERNS:
                        ferns.append(fern)
                    else:
                        ferns[next_slot] = fern
                        next_slot = (next_slot + 1) % MAX_FERNS
                if (pending & CMD_PAUSE) != 0:
                    paused = not paused
                if (pending & CMD_RESET) != 0:
                    need_seed = True
                if (pending & CMD_QUIT) != 0:
                    running = False

            # ── a fresh landscape ──────────────────────────────────────────
            if need_seed:
                need_seed = False
                landscape += 1
                grown_for = 0
                next_slot = 0
                while len(ferns) > 0:
                    _ = ferns.pop()
                paint_backdrop(bgra, rng)
                # A dozen spots along the ground band, shuffled in depth.
                for k in range(SEED_FERNS):
                    let bx = (Float64(k) + 0.18 + rng.next() * 0.64) * (
                        Float64(W) / Float64(SEED_FERNS)
                    )
                    let by = HORIZON + 12.0 + rng.next() * (
                        Float64(H) - HORIZON - 24.0
                    )
                    ferns.append(make_fern(rng, bx, by))
                print("landscape", landscape, "—", len(ferns), "ferns")

            # ── grow: a slice of each fern's points, plotted ───────────────
            var all_grown = True
            if not paused:
                for i in range(len(ferns)):
                    var fern = ferns[i]
                    if fern.delay > 0:
                        fern.delay -= 1
                        ferns[i] = fern
                        all_grown = False
                        continue
                    if fern.plotted >= fern.target:
                        continue
                    all_grown = False
                    var steps = max(60, fern.target // GROW_FRAMES)
                    var x = fern.x
                    var y = fern.y
                    for _step in range(steps):
                        # The chaos game: pick a map by weight, apply it.
                        let roll = rng.next()
                        var acc = 0.0
                        var chosen = maps[0]
                        for m in maps:
                            acc += m.p
                            if roll <= acc:
                                chosen = m
                                break
                        let nx = chosen.a * x + chosen.b * y + chosen.e
                        let ny = chosen.c * x + chosen.d * y + chosen.f
                        x = nx
                        y = ny
                        # IFS space to the fern's spot: flip, lean about the
                        # base, scale, and stand it on the ground.
                        let fx = x * fern.flip * fern.scale
                        let fy = y * fern.scale
                        let px = fern.base_x + fx * fern.lean_c + fy * fern.lean_s
                        let py = fern.base_y - fy * fern.lean_c + fx * fern.lean_s
                        plot(bgra, Int(px), Int(py), fern.r, fern.g, fern.b)
                    fern.x = x
                    fern.y = y
                    fern.plotted += steps
                    ferns[i] = fern

            # A grown landscape lingers, then a new one seeds itself.
            if all_grown and not paused:
                grown_for += 1
                if grown_for >= HOLD_FRAMES:
                    need_seed = True

            # ── present ────────────────────────────────────────────────────
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
                "Grew", landscape, "landscape(s) over", frames, "frames in",
                secs, "s (", Float64(frames) / secs, "fps )",
            )

        # The last frame, raw, for eyes that were not at the screen. The
        # write goes through `open`/`write_all`, the same binary-file idiom
        # fern/png.mojo uses.
        let dump = getenv("FERNS_DUMP")
        if dump != "":
            var out = List[UInt8]()
            let bytes = bgra.unsafe_bitcast[UInt8]()
            for k in range(PIXELS * 4):
                out.append(bytes[unsafe_offset=k])
            var f = open(dump, "w")
            f.write_all(Span(out))
            f.close()
            print("dumped", W, "x", H, "BGRA to", dump)
