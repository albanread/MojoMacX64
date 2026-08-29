# ===----------------------------------------------------------------------=== #
# Fluid — a native macOS app written entirely in Mojo.
#
# Stable Fluids (Jos Stam, SIGGRAPH 1999). Drag the mouse and coloured dye
# swirls through a velocity field that is advected along itself and then made
# divergence-free by a Jacobi pressure solve. Every kernel is Mojo, running on
# the Apple GPU through this fork's AIR backend; the frame is handed to a
# `CAMetalLayer`. No shader anywhere in the pipeline.
#
# The solver is `fluid_smoke.mojo`, which runs the same kernels headless and
# checks them (mass conservation to 0.6%, post-projection divergence within
# ±0.05). Run that first if this ever looks wrong -- it separates "the physics
# broke" from "the window broke".
#
# WHY THIS SPIKE EXISTS, beyond being nice to look at: mandelbrot is one
# dispatch per frame and life is none, so neither measures launch cost. A
# fluids step is ~35 dependent dispatches, which makes per-dispatch overhead
# the dominant term. Measured on an M4:
#
#     sync   10.19 ms/step   (and 17.31 on a cold run -- 70% spread)
#     async   1.99 ms/step   (±0.2% across runs)
#
# 5.1x, and the variance collapses. That is 0.234 ms of round trip per
# dispatch, in the same ballpark as the 0.40 ms measured independently for
# short kernels. Synchronously the physics alone eats a whole 60fps frame.
#
#     ./fluid                          # synchronous launch
#     APPLEGPU_ASYNC_LAUNCH=1 ./fluid  # deferred wait, drained on read
#
# ===----------------------------------------------------------------------=== #

from std.objc import (
    ObjCClass,
    ObjCObject,
    msg_send,
    send,
    nsstring,
    autoreleasepool,
    named_global,
    sel,
)
from std.ffi import external_call, _get_kgen_string, c_char
from std.memory import OpaquePointer, Pointer
from std.gpu import global_idx
from max.gpu.host import DeviceContext
from std.time import perf_counter_ns

comptime P = OpaquePointer[MutUntrackedOrigin]


@always_inline
def _sym[name: StaticString]() -> P:
    """Address of a symbol in a linked framework (here: a CFString constant)."""
    return P(
        _mlir_value=__mlir_op.`pop.extern_ptr_symbol`[
            name=_get_kgen_string[name](),
            alignment=Int(1).__mlir_index__(),
            _type=P._mlir_type,
        ]()
    )

# Simulation grid, and the window it is magnified into. The sim is coarser
# than the display on purpose: the pressure solve is the expensive part and
# scales with cell count, while the eye is perfectly happy with a bilinear
# magnification of a smooth field.
comptime W = 320
comptime H = 240
comptime N = W * H
comptime SCALE = 3
comptime WIN_W = W * SCALE  # 960
comptime WIN_H = H * SCALE  # 720
comptime PIXELS = WIN_W * WIN_H

comptime DT = Float32(0.125)
comptime JACOBI_ITERS = 30
comptime DYE_FADE = Float32(0.997)
comptime VEL_FADE = Float32(0.995)

comptime BLOCK = 256
comptime GRID = (N + BLOCK - 1) // BLOCK
comptime PIX_GRID = (PIXELS + BLOCK - 1) // BLOCK

comptime F32 = Pointer[Float32, MutAnyOrigin]
comptime U32 = Pointer[UInt32, MutAnyOrigin]


# ===----------------------------------------------------------------------=== #
# Cocoa structs, by value across the ABI.
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
# Sampling. The boundary rule is stated once, here: clamp, which lets fluid
# slide along a wall rather than leak through it.
# ===----------------------------------------------------------------------=== #


@always_inline
def _clampi(v: Int, lo: Int, hi: Int) -> Int:
    if v < lo:
        return lo
    if v > hi:
        return hi
    return v


@always_inline
def _at(f: F32, x: Int, y: Int) -> Float32:
    return f[unsafe_offset=_clampi(y, 0, H - 1) * W + _clampi(x, 0, W - 1)]


@always_inline
def _bilinear(f: F32, x: Float32, y: Float32) -> Float32:
    var x0 = Int(x)
    var y0 = Int(y)
    if x < Float32(0):
        x0 = Int(x) - 1
    if y < Float32(0):
        y0 = Int(y) - 1
    var fx = x - Float32(x0)
    var fy = y - Float32(y0)
    var a = _at(f, x0, y0)
    var b = _at(f, x0 + 1, y0)
    var c = _at(f, x0, y0 + 1)
    var d = _at(f, x0 + 1, y0 + 1)
    var top = a + (b - a) * fx
    var bot = c + (d - c) * fx
    return top + (bot - top) * fy


@always_inline
def _expf(x: Float32) -> Float32:
    """exp, written out so host and device share one definition.

    Only ever called with x in [-9, 0] (the splat falloff), so the range
    reduction below does not need to be general.
    """
    if x < Float32(-20.0):
        return Float32(0)
    var k = x * Float32(1.44269504)  # 1/ln 2
    var ki = Float32(Int(k) - (1 if k < Float32(0) else 0))
    var f = (k - ki) * Float32(0.69314718)
    var poly = Float32(1) + f * (
        Float32(1)
        + f * (Float32(0.5) + f * (Float32(0.16666667) + f * Float32(0.04166667)))
    )
    var n = Int(ki)
    var scale = Float32(1)
    var i = 0
    while i < -n:
        scale *= Float32(0.5)
        i += 1
    return poly * scale


# ===----------------------------------------------------------------------=== #
# Kernels
# ===----------------------------------------------------------------------=== #


def advect_kernel(dst: F32, src: F32, u: F32, v: F32, dt: Float32, fade: Float32):
    """Semi-Lagrangian advection: trace backwards, sample where it came from.

    Unconditionally stable whatever the time step, which is the whole reason
    Stam's method is used here rather than a forward difference.
    """
    var idx = Int(global_idx.x)
    if idx < N:
        var px = Float32(idx % W) - dt * u[unsafe_offset=idx]
        var py = Float32(idx // W) - dt * v[unsafe_offset=idx]
        dst[unsafe_offset=idx] = _bilinear(src, px, py) * fade


def divergence_kernel(div: F32, u: F32, v: F32):
    var idx = Int(global_idx.x)
    if idx < N:
        var x = idx % W
        var y = idx // W
        div[unsafe_offset=idx] = Float32(0.5) * (
            (_at(u, x + 1, y) - _at(u, x - 1, y))
            + (_at(v, x, y + 1) - _at(v, x, y - 1))
        )


def jacobi_kernel(p_next: F32, p: F32, div: F32):
    """One Jacobi sweep of the pressure Poisson equation.

    Ping-ponged rather than updated in place: a Jacobi step reads the previous
    iterate's whole neighbourhood, and writing in place would feed half-new
    values back in, silently turning this into Gauss-Seidel with a
    thread-order-dependent answer.
    """
    var idx = Int(global_idx.x)
    if idx < N:
        var x = idx % W
        var y = idx // W
        var s = (
            _at(p, x - 1, y) + _at(p, x + 1, y)
            + _at(p, x, y - 1) + _at(p, x, y + 1)
        )
        p_next[unsafe_offset=idx] = (s - div[unsafe_offset=idx]) * Float32(0.25)


def project_kernel(u: F32, v: F32, p: F32):
    """Subtract the pressure gradient, leaving a divergence-free field."""
    var idx = Int(global_idx.x)
    if idx < N:
        var x = idx % W
        var y = idx // W
        u[unsafe_offset=idx] -= Float32(0.5) * (_at(p, x + 1, y) - _at(p, x - 1, y))
        v[unsafe_offset=idx] -= Float32(0.5) * (_at(p, x, y + 1) - _at(p, x, y - 1))


def splat_kernel(field: F32, cx: Float32, cy: Float32, radius: Float32, amount: Float32):
    """Add a soft Gaussian blob: the mouse, or a starting puff."""
    var idx = Int(global_idx.x)
    if idx < N:
        var dx = Float32(idx % W) - cx
        var dy = Float32(idx // W) - cy
        var r2 = radius * radius
        var d2 = dx * dx + dy * dy
        if d2 < r2 * Float32(9.0):
            field[unsafe_offset=idx] += amount * _expf(-d2 / r2)


def render_kernel(dst: U32, dr: F32, dg: F32, db: F32):
    """Magnify the dye field into the window, as packed BGRA8.

    Bilinear rather than nearest: the field is smooth, and point-sampling a
    320x240 grid into 960x720 would show the simulation's cells rather than
    the fluid. Tone-mapped with x/(1+x) so a heavy drag saturates gracefully
    instead of clipping to white.
    """
    var idx = Int(global_idx.x)
    if idx < PIXELS:
        var sx = Float32(idx % WIN_W) / Float32(SCALE)
        var sy = Float32(idx // WIN_W) / Float32(SCALE)
        var r = _bilinear(dr, sx, sy)
        var g = _bilinear(dg, sx, sy)
        var b = _bilinear(db, sx, sy)
        r = r / (Float32(1) + r)
        g = g / (Float32(1) + g)
        b = b / (Float32(1) + b)
        var ri = UInt32(Int(r * Float32(255.0)))
        var gi = UInt32(Int(g * Float32(255.0)))
        var bi = UInt32(Int(b * Float32(255.0)))
        # BGRA8Unorm, little-endian: B in the low byte.
        dst[unsafe_offset=idx] = (
            bi | (gi << 8) | (ri << 16) | (UInt32(255) << 24)
        )




# ===----------------------------------------------------------------------=== #
# Saving a frame.
#
# PNG rather than the PPM the smoke test writes, because a saved shot is meant
# to be looked at and sent to people. libz is on every Mac, so deflate and the
# CRC come from there rather than being reimplemented -- a PNG is otherwise
# just four length-tagged chunks.
# ===----------------------------------------------------------------------=== #


@always_inline
def _be32(v: UInt32) -> SIMD[DType.uint8, 4]:
    """PNG is big-endian throughout; arm64 is not."""
    return SIMD[DType.uint8, 4](
        UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
        UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF),
    )


def _put_chunk(
    fh: Int, tag: StaticString, data: Pointer[UInt8, MutUntrackedOrigin], n: Int
):
    """One PNG chunk: length, 4-char type, payload, CRC over type+payload."""
    # Keep the raw address: the CRC covers type+data, i.e. this buffer from
    # byte 4 on, and a pointer four bytes in is easiest built from the integer.
    var hdr_addr = Int(external_call["malloc", P](Int(8)))
    var hdr = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=hdr_addr)
    var tail = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=hdr_addr + 4
    )
    var L = _be32(UInt32(n))
    for i in range(4):
        hdr[unsafe_offset=i] = L[i]
    var t = tag.as_bytes()
    for i in range(4):
        hdr[unsafe_offset=4 + i] = t[i]
    _ = external_call["fwrite", Int](
        hdr.unsafe_bitcast[NoneType](), Int(1), Int(8), fh
    )
    if n > 0:
        _ = external_call["fwrite", Int](
            data.unsafe_bitcast[NoneType](), Int(1), n, fh
        )
    # CRC covers the type and the data, but not the length.
    var crc = external_call["crc32", UInt64](
        UInt64(0), tail.unsafe_bitcast[NoneType](), UInt32(4)
    )
    if n > 0:
        crc = external_call["crc32", UInt64](
            crc, data.unsafe_bitcast[NoneType](), UInt32(n)
        )
    var C = _be32(UInt32(crc & UInt64(0xFFFFFFFF)))
    for i in range(4):
        hdr[unsafe_offset=i] = C[i]
    _ = external_call["fwrite", Int](
        hdr.unsafe_bitcast[NoneType](), Int(1), Int(4), fh
    )
    external_call["free", NoneType](hdr.unsafe_bitcast[NoneType]())


def save_png(path: String, bgra: Pointer[UInt32, MutUntrackedOrigin]) -> Bool:
    """Write the current frame. Returns False rather than raising: a failed
    screenshot must never take the demo down mid-drag."""
    # Raw PNG scanlines: one filter byte (0 = none) then RGB, alpha dropped.
    var stride = WIN_W * 3 + 1
    var raw_n = stride * WIN_H
    var raw_addr = Int(external_call["malloc", P](Int(raw_n)))
    if raw_addr == 0:
        return False
    var raw = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=raw_addr)
    for y in range(WIN_H):
        var row = y * stride
        raw[unsafe_offset=row] = UInt8(0)
        for x in range(WIN_W):
            var px = bgra[unsafe_offset=y * WIN_W + x]
            var o = row + 1 + x * 3
            raw[unsafe_offset=o] = UInt8((px >> 16) & UInt32(255))      # R
            raw[unsafe_offset=o + 1] = UInt8((px >> 8) & UInt32(255))   # G
            raw[unsafe_offset=o + 2] = UInt8(px & UInt32(255))          # B

    var cap = UInt64(raw_n + raw_n // 100 + 4096)
    var comp = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(external_call["malloc", P](Int(cap)))
    )
    var clen = Pointer[UInt64, MutUntrackedOrigin](
        unsafe_from_address=Int(external_call["malloc", P](Int(8)))
    )
    clen[] = cap
    var rc = external_call["compress2", Int32](
        comp.unsafe_bitcast[NoneType](), clen,
        raw.unsafe_bitcast[NoneType](), UInt64(raw_n), Int32(6),
    )
    if rc != Int32(0):
        external_call["free", NoneType](raw.unsafe_bitcast[NoneType]())
        external_call["free", NoneType](comp.unsafe_bitcast[NoneType]())
        external_call["free", NoneType](clen.unsafe_bitcast[NoneType]())
        return False

    # Both need to be lvalues: as_c_string_slice mutates (it appends the NUL).
    var mode = String("wb")
    var local_path = path
    var fh = Int(external_call["fopen", P](
        local_path.as_c_string_slice(), mode.as_c_string_slice()
    ))
    if fh == 0:
        external_call["free", NoneType](raw.unsafe_bitcast[NoneType]())
        external_call["free", NoneType](comp.unsafe_bitcast[NoneType]())
        external_call["free", NoneType](clen.unsafe_bitcast[NoneType]())
        return False

    var sig = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(external_call["malloc", P](Int(8)))
    )
    var sigbytes = SIMD[DType.uint8, 8](137, 80, 78, 71, 13, 10, 26, 10)
    for i in range(8):
        sig[unsafe_offset=i] = sigbytes[i]
    _ = external_call["fwrite", Int](
        sig.unsafe_bitcast[NoneType](), Int(1), Int(8), fh
    )

    # IHDR: width, height, 8-bit, colour type 2 (truecolour), no interlace.
    var ihdr = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(external_call["malloc", P](Int(13)))
    )
    var wb = _be32(UInt32(WIN_W))
    var hb = _be32(UInt32(WIN_H))
    for i in range(4):
        ihdr[unsafe_offset=i] = wb[i]
        ihdr[unsafe_offset=4 + i] = hb[i]
    ihdr[unsafe_offset=8] = UInt8(8)
    ihdr[unsafe_offset=9] = UInt8(2)
    ihdr[unsafe_offset=10] = UInt8(0)
    ihdr[unsafe_offset=11] = UInt8(0)
    ihdr[unsafe_offset=12] = UInt8(0)
    _put_chunk(fh, "IHDR", ihdr, 13)
    _put_chunk(fh, "IDAT", comp, Int(clen[]))
    _put_chunk(fh, "IEND", ihdr, 0)
    _ = external_call["fclose", Int32](fh)

    external_call["free", NoneType](sig.unsafe_bitcast[NoneType]())
    external_call["free", NoneType](ihdr.unsafe_bitcast[NoneType]())
    external_call["free", NoneType](raw.unsafe_bitcast[NoneType]())
    external_call["free", NoneType](comp.unsafe_bitcast[NoneType]())
    external_call["free", NoneType](clen.unsafe_bitcast[NoneType]())
    return True



# ===----------------------------------------------------------------------=== #
# Apple Events: driving the demo from outside the process.
#
# The handler runs on AppKit's Apple Event delivery, which is emphatically not
# where a GPU dispatch belongs -- it can arrive between any two frames, and the
# DeviceContext and its dozen buffers are locals in `main` besides. So a
# handler does one thing: set a pending-command flag. The frame loop picks it
# up, acts, and clears it, which keeps every Metal call on the one thread that
# owns them.
#
# The event class is 'FLUD' and the IDs are the verbs below. `fluidctl` sends
# them; `osascript` cannot, because addressing a bare Mach-O executable that is
# not an application bundle needs a raw process-id descriptor rather than a
# `tell application` clause.
# ===----------------------------------------------------------------------=== #

comptime AE_CLASS = 0x464C5544  # 'FLUD'
comptime AE_SNAP = 0x736E6170  # 'snap'
comptime AE_CLEAR = 0x636C7220  # 'clr '
comptime AE_RAIN = 0x7261696E  # 'rain'
comptime AE_PAUSE = 0x70617573  # 'paus'
comptime AE_QUIT = 0x71756974  # 'quit'

# Bit flags, so two commands arriving in one frame do not lose each other.
comptime CMD_SNAP = 1
comptime CMD_CLEAR = 2
comptime CMD_RAIN = 4
comptime CMD_PAUSE = 8
comptime CMD_QUIT = 16

comptime g_cmd = named_global["fluid.cmd", Int]


def _ae_event_id(event: P) -> Int:
    """The four-char event ID out of the descriptor."""
    return msg_send[Int, "NSAppleEventDescriptor", "eventID"](
        ObjCObject(Int(event))
    )


class FluidAEHandler:
    """The Apple Event target.

    `handleEvent:withReplyEvent:` is not a selector the SDK declares, so its
    `v@:@@` encoding is derived from the two object arguments rather than
    looked up. There is no IMP and no `cmd` slot: instantiating the class is
    what registers it.
    """

    def handleEvent_withReplyEvent_(
        self, event: ObjCObject, reply: ObjCObject
    ):
        handle_apple_event(event.ptr())


def handle_apple_event(event: P):
    var eid = _ae_event_id(event)
    if eid == AE_SNAP:
        g_cmd()[] |= CMD_SNAP
    elif eid == AE_CLEAR:
        g_cmd()[] |= CMD_CLEAR
    elif eid == AE_RAIN:
        g_cmd()[] |= CMD_RAIN
    elif eid == AE_PAUSE:
        g_cmd()[] |= CMD_PAUSE
    elif eid == AE_QUIT:
        g_cmd()[] |= CMD_QUIT


def install_apple_events():
    """Register one handler for every verb in the FLUD class."""
    var handler = ObjCObject(FluidAEHandler().__objc_id)
    _ = external_call["objc_retain", P](handler.ptr())

    var mgr = msg_send[
        ObjCObject,
        "NSAppleEventManager",
        "sharedAppleEventManager",
        is_class=True,
    ](ObjCClass.lookup["NSAppleEventManager"]().as_object())

    for eid in [AE_SNAP, AE_CLEAR, AE_RAIN, AE_PAUSE, AE_QUIT]:
        _ = msg_send[
            ObjCObject,
            "NSAppleEventManager",
            "setEventHandler:andSelector:forEventClass:andEventID:",
        ](
            mgr,
            handler.ptr(),
            sel["handleEvent:withReplyEvent:"]().ptr(),
            UInt32(AE_CLASS),
            UInt32(eid),
        )


# ===----------------------------------------------------------------------=== #
# Host-side colour: a hue that advances with every drag, so a session paints
# through the spectrum instead of one muddy colour.
# ===----------------------------------------------------------------------=== #


def hue_rgb(h: Float32) -> Tuple[Float32, Float32, Float32]:
    var x = h - Float32(Int(h))  # fract
    var s = x * Float32(6.0)
    var i = Int(s)
    var f = s - Float32(i)
    if i == 0:
        return (Float32(1), f, Float32(0))
    if i == 1:
        return (Float32(1) - f, Float32(1), Float32(0))
    if i == 2:
        return (Float32(0), Float32(1), f)
    if i == 3:
        return (Float32(0), Float32(1) - f, Float32(1))
    if i == 4:
        return (f, Float32(0), Float32(1))
    return (Float32(1), Float32(0), Float32(1) - f)


def main() raises:
    print("Fluid —", W, "x", H, "sim,", WIN_W, "x", WIN_H, "window")

    var ctx = DeviceContext(api="metal")
    print("  GPU:", ctx.name())

    var u = ctx.enqueue_create_buffer[DType.float32](N)
    var v = ctx.enqueue_create_buffer[DType.float32](N)
    var u0 = ctx.enqueue_create_buffer[DType.float32](N)
    var v0 = ctx.enqueue_create_buffer[DType.float32](N)
    var dr = ctx.enqueue_create_buffer[DType.float32](N)
    var dg = ctx.enqueue_create_buffer[DType.float32](N)
    var db = ctx.enqueue_create_buffer[DType.float32](N)
    var s0 = ctx.enqueue_create_buffer[DType.float32](N)
    var div = ctx.enqueue_create_buffer[DType.float32](N)
    var pr = ctx.enqueue_create_buffer[DType.float32](N)
    var pr0 = ctx.enqueue_create_buffer[DType.float32](N)
    var frame = ctx.enqueue_create_buffer[DType.uint32](PIXELS)

    for buf in [u, v, dr, dg, db, pr]:
        ctx.enqueue_memset(buf, Float32(0))
    ctx.synchronize()

    var advect = ctx.compile_function[advect_kernel]()
    var diverge = ctx.compile_function[divergence_kernel]()
    var jacobi = ctx.compile_function[jacobi_kernel]()
    var project = ctx.compile_function[project_kernel]()
    var splat = ctx.compile_function[splat_kernel]()
    var shade = ctx.compile_function[render_kernel]()

    var bgra = Pointer[UInt32, MutUntrackedOrigin](
        unsafe_from_address=Int(
            external_call["calloc", P](Int(PIXELS), Int(4))
        )
    )

    with autoreleasepool():
        var NSApplication = ObjCClass.lookup["NSApplication"]()
        var app = msg_send[
            ObjCObject, "NSApplication", "sharedApplication", is_class=True
        ](NSApplication.as_object())
        _ = msg_send[Bool, "NSApplication", "setActivationPolicy:"](app, Int(0))

        var win = msg_send[ObjCObject, "NSWindow", "alloc", is_class=True](
            ObjCClass.lookup["NSWindow"]().as_object()
        )
        win = msg_send[
            ObjCObject,
            "NSWindow",
            "initWithContentRect:styleMask:backing:defer:",
        ](
            win,
            CGRect(CGPoint(100.0, 100.0), CGSize(Float64(WIN_W), Float64(WIN_H))),
            Int(15),
            Int(2),
            Bool(False),
        )

        var view = msg_send[ObjCObject, "NSView", "alloc", is_class=True](
            ObjCClass.lookup["NSView"]().as_object()
        )
        view = msg_send[ObjCObject, "NSView", "initWithFrame:"](
            view, CGRect(CGPoint(0.0, 0.0), CGSize(Float64(WIN_W), Float64(WIN_H)))
        )

        var display_dev = ObjCObject(
            Int(external_call["MTLCreateSystemDefaultDevice", P]())
        )
        var queue = send[ObjCObject, "newCommandQueue"](display_dev)
        _ = external_call["objc_retain", P](queue.ptr())

        var CAMetalLayer = ObjCClass.lookup["CAMetalLayer"]()
        var layer = msg_send[ObjCObject, "CAMetalLayer", "layer", is_class=True](
            CAMetalLayer.as_object()
        )
        _ = send[ObjCObject, "setDevice:"](layer, display_dev.ptr())
        _ = msg_send[ObjCObject, "CAMetalLayer", "setPixelFormat:"](layer, Int(80))
        _ = msg_send[ObjCObject, "CAMetalLayer", "setFramebufferOnly:"](
            layer, Bool(False)
        )
        _ = msg_send[ObjCObject, "CAMetalLayer", "setDrawableSize:"](
            layer, CGSize(Float64(WIN_W), Float64(WIN_H))
        )
        _ = external_call["objc_retain", P](layer.ptr())

        _ = msg_send[ObjCObject, "NSView", "setWantsLayer:"](view, True)
        _ = msg_send[ObjCObject, "NSView", "setLayer:"](view, layer.ptr())
        _ = msg_send[ObjCObject, "NSWindow", "setContentView:"](win, view.ptr())
        _ = msg_send[ObjCObject, "NSWindow", "makeKeyAndOrderFront:"](
            win, app.ptr()
        )
        _ = msg_send[ObjCObject, "NSApplication", "activateIgnoringOtherApps:"](
            app, Bool(True)
        )
        # -[NSApplication run] would call this for us; a hand-rolled pump must
        # do it explicitly. Among other things it is where AppKit attaches the
        # Apple Event Mach port to the run loop -- without it the handlers
        # registered below are never reached, however well-formed the event.
        _ = msg_send[ObjCObject, "NSApplication", "finishLaunching"](app)

        var region = MTLRegion(MTLOrigin(0, 0, 0), MTLSize(WIN_W, WIN_H, 1))
        var NSDate = ObjCClass.lookup["NSDate"]()
        var mode = nsstring(String("kCFRunLoopDefaultMode"))

        # A puff to start with, so the window is never blank.
        var c0 = hue_rgb(Float32(0.05))
        ctx.enqueue_function(splat, dr, Float32(W // 2), Float32(H // 2),
                             Float32(18), c0[0] * Float32(2.0),
                             grid_dim=(GRID), block_dim=(BLOCK))
        ctx.enqueue_function(splat, dg, Float32(W // 2), Float32(H // 2),
                             Float32(18), c0[1] * Float32(2.0),
                             grid_dim=(GRID), block_dim=(BLOCK))
        ctx.enqueue_function(splat, db, Float32(W // 2), Float32(H // 2),
                             Float32(18), c0[2] * Float32(2.0),
                             grid_dim=(GRID), block_dim=(BLOCK))
        ctx.enqueue_function(splat, v, Float32(W // 2), Float32(H // 2 + 10),
                             Float32(16), Float32(-14.0),
                             grid_dim=(GRID), block_dim=(BLOCK))
        ctx.synchronize()

        install_apple_events()
        var pid = external_call["getpid", Int32]()
        print("Drag to paint.  [space] pause  [c] clear  [r] rain  [s] save shot")
        print("Scriptable:  ./bazel-bin/spikes/fluidctl", Int(pid),
              "snap|clear|rain|pause|quit")

        var running = True
        var paused = False
        var frames = 0
        var hue = Float32(0.05)
        var shot_wanted = False
        var shots = 0
        # FLUID_AUTOSHOT=<n>: save frame n and quit. Headless capture, and the
        # only way to exercise the PNG writer without a keyboard.
        var autoshot_name = String("FLUID_AUTOSHOT")
        var autoshot_env = external_call["getenv", P](
            autoshot_name.as_c_string_slice()
        )
        var autoshot = 0
        if Int(autoshot_env) != 0:
            autoshot = Int(
                String(
                    unsafe_from_utf8_ptr=autoshot_env.unsafe_bitcast[c_char]()
                )
            )
        var last_x = Float32(-1)
        var last_y = Float32(-1)
        var loop_start = perf_counter_ns()

        while running:
            # ── events ──────────────────────────────────────────────────────
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

                var etype = msg_send[Int, "NSEvent", "type"](ev)
                # 1 = LeftMouseDown, 6 = LeftMouseDragged, 2 = LeftMouseUp
                if etype == 1 or etype == 6:
                    var pt = msg_send[CGPoint, "NSEvent", "locationInWindow"](ev)
                    # Cocoa's origin is bottom-left; the grid's row 0 is the top.
                    var mx = Float32(pt.x) / Float32(SCALE)
                    var my = Float32(Float64(WIN_H) - pt.y) / Float32(SCALE)
                    if etype == 1:
                        last_x = mx
                        last_y = my
                    if last_x >= Float32(0):
                        var vx = (mx - last_x) * Float32(6.0)
                        var vy = (my - last_y) * Float32(6.0)
                        var c = hue_rgb(hue)
                        hue += Float32(0.011)
                        ctx.enqueue_function(splat, u, mx, my, Float32(9),
                                             vx, grid_dim=(GRID), block_dim=(BLOCK))
                        ctx.enqueue_function(splat, v, mx, my, Float32(9),
                                             vy, grid_dim=(GRID), block_dim=(BLOCK))
                        ctx.enqueue_function(splat, dr, mx, my, Float32(7),
                                             c[0] * Float32(0.6),
                                             grid_dim=(GRID), block_dim=(BLOCK))
                        ctx.enqueue_function(splat, dg, mx, my, Float32(7),
                                             c[1] * Float32(0.6),
                                             grid_dim=(GRID), block_dim=(BLOCK))
                        ctx.enqueue_function(splat, db, mx, my, Float32(7),
                                             c[2] * Float32(0.6),
                                             grid_dim=(GRID), block_dim=(BLOCK))
                    last_x = mx
                    last_y = my
                elif etype == 2:
                    last_x = Float32(-1)
                elif etype == 10:  # KeyDown
                    var kc = msg_send[Int, "NSEvent", "keyCode"](ev)
                    # Keys set the same flags the Apple Events do, so there is
                    # one implementation of each verb rather than two.
                    if kc == 49:  # space
                        g_cmd()[] |= CMD_PAUSE
                    elif kc == 8:  # c
                        g_cmd()[] |= CMD_CLEAR
                    elif kc == 1:  # s
                        g_cmd()[] |= CMD_SNAP
                    elif kc == 15:  # r
                        g_cmd()[] |= CMD_RAIN

                _ = msg_send[ObjCObject, "NSApplication", "sendEvent:"](
                    app, ev.ptr()
                )

            # Spin the run loop briefly. `nextEventMatchingMask:` with
            # distantPast polls the event queue and returns at once -- it never
            # services the Mach port Apple Events are delivered on, so without
            # this the handlers registered above are simply never called. Zero
            # timeout with returnAfterSourceHandled=true: drain what is ready,
            # do not block the frame.
            var mode_ref = Pointer[Int, MutUntrackedOrigin](
                unsafe_from_address=Int(_sym["kCFRunLoopDefaultMode"]())
            )
            _ = external_call["CFRunLoopRunInMode", Int32](
                P(unsafe_from_address=mode_ref[]), Float64(0.004), Bool(False)
            )

            # ── pending commands, from a key or an Apple Event ──────────────
            var pending = g_cmd()[]
            if pending != 0:
                g_cmd()[] = 0
                if (pending & CMD_PAUSE) != 0:
                    paused = not paused
                if (pending & CMD_CLEAR) != 0:
                    for buf in [dr, dg, db, u, v]:
                        ctx.enqueue_memset(buf, Float32(0))
                if (pending & CMD_RAIN) != 0:
                    var k = 0
                    while k < 12:
                        var c = hue_rgb(hue)
                        hue += Float32(0.083)
                        var rx = Float32((k * 97 + frames * 31) % W)
                        var ry = Float32((k * 53 + frames * 17) % H)
                        ctx.enqueue_function(splat, dr, rx, ry, Float32(10),
                                             c[0], grid_dim=(GRID), block_dim=(BLOCK))
                        ctx.enqueue_function(splat, dg, rx, ry, Float32(10),
                                             c[1], grid_dim=(GRID), block_dim=(BLOCK))
                        ctx.enqueue_function(splat, db, rx, ry, Float32(10),
                                             c[2], grid_dim=(GRID), block_dim=(BLOCK))
                        ctx.enqueue_function(splat, v, rx, ry, Float32(10),
                                             Float32(-9.0), grid_dim=(GRID),
                                             block_dim=(BLOCK))
                        k += 1
                if (pending & CMD_QUIT) != 0:
                    running = False
                if (pending & CMD_SNAP) != 0:
                    shot_wanted = True

            if not msg_send[Bool, "NSWindow", "isVisible"](win):
                running = False
                break

            # ── one fluid step ──────────────────────────────────────────────
            if not paused:
                ctx.enqueue_function(advect, u0, u, u, v, DT, VEL_FADE,
                                     grid_dim=(GRID), block_dim=(BLOCK))
                ctx.enqueue_function(advect, v0, v, u, v, DT, VEL_FADE,
                                     grid_dim=(GRID), block_dim=(BLOCK))
                ctx.enqueue_function(diverge, div, u0, v0,
                                     grid_dim=(GRID), block_dim=(BLOCK))
                ctx.enqueue_memset(pr, Float32(0))
                for _it in range(JACOBI_ITERS // 2):
                    ctx.enqueue_function(jacobi, pr0, pr, div,
                                         grid_dim=(GRID), block_dim=(BLOCK))
                    ctx.enqueue_function(jacobi, pr, pr0, div,
                                         grid_dim=(GRID), block_dim=(BLOCK))
                ctx.enqueue_function(project, u0, v0, pr,
                                     grid_dim=(GRID), block_dim=(BLOCK))

                # Dye rides the corrected field. Three channels, one kernel,
                # three dispatches -- `s0` is the shared scratch, copied back
                # each time, which keeps the buffer count down.
                ctx.enqueue_function(advect, s0, dr, u0, v0, DT, DYE_FADE,
                                     grid_dim=(GRID), block_dim=(BLOCK))
                ctx.enqueue_copy(dr, s0)
                ctx.enqueue_function(advect, s0, dg, u0, v0, DT, DYE_FADE,
                                     grid_dim=(GRID), block_dim=(BLOCK))
                ctx.enqueue_copy(dg, s0)
                ctx.enqueue_function(advect, s0, db, u0, v0, DT, DYE_FADE,
                                     grid_dim=(GRID), block_dim=(BLOCK))
                ctx.enqueue_copy(db, s0)

                ctx.enqueue_copy(u, u0)
                ctx.enqueue_copy(v, v0)

            # ── shade and present ───────────────────────────────────────────
            ctx.enqueue_function(shade, frame, dr, dg, db,
                                 grid_dim=(PIX_GRID), block_dim=(BLOCK))
            ctx.synchronize()
            with frame.map_to_host() as pix:
                var src = pix.unsafe_ptr()
                for k in range(PIXELS):
                    bgra[unsafe_offset=k] = src[unsafe_offset=k]

            # Save here, not later: `bgra` is exactly what is about to be
            # presented, so the file and the window cannot disagree.
            if shot_wanted:
                shot_wanted = False
                var path = String("/tmp/fluid-") + String(shots) + ".png"
                if save_png(path, bgra):
                    print("saved", path)
                else:
                    print("could not save", path)
                shots += 1

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
                  Int(WIN_W * 4))
                var cb = send[ObjCObject, "commandBuffer"](queue)
                _ = send[ObjCObject, "presentDrawable:"](cb, drawable.ptr())
                _ = send[ObjCObject, "commit"](cb)

            frames += 1
            if autoshot > 0 and frames == autoshot:
                shot_wanted = True
            if autoshot > 0 and frames == autoshot + 1:
                running = False
            if frames % 120 == 0:
                var now = perf_counter_ns()
                var fps = Float64(frames) / (Float64(now - loop_start) / 1e9)
                # Also to stdout: the title bar is invisible to a run captured
                # in a log, which is every run that is not a person watching.
                print("  frame", frames, "—", fps, "fps")
                _ = msg_send[ObjCObject, "NSWindow", "setTitle:"](
                    win,
                    nsstring(
                        String("Fluid — ") + String(Int(fps)) + " fps"
                        + "   [space] pause  [c] clear  [r] rain"
                    ).ptr(),
                )
