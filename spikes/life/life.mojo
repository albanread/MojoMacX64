# ===----------------------------------------------------------------------=== #
# Conway's Game of Life — a native Cocoa version, in Mojo.
#
# What the pygame example doesn't do, and this does:
#   · pause and resume, and single-step while paused
#   · draw cells with the mouse (and erase with shift or the right button)
#   · colour cells by AGE — newborns burn white-hot, survivors settle through
#     green to deep blue, and cells that die leave a fading ember trail, so you
#     can see the structure of a pattern rather than a flat green mask
#   · clear, randomise, and speed control, with live stats in the title bar
#
# Rendering is a BGRA buffer blitted into a CAMetalLayer drawable, the same
# path the Mandelbrot uses. Every AppKit call goes through std.objc, and the
# view's mouse/key handlers are Mojo functions on a class defined at runtime.
# ===----------------------------------------------------------------------=== #

from std.objc import (
    ObjCClass,
    ObjCObject,
    msg_send,
    send,
    nsstring,
    autoreleasepool,
    ObjCClassBuilder,
    new_instance,
    named_global,
    sel,
)
from std.ffi import external_call, c_char
from std.memory import OpaquePointer, Pointer
from std.collections.string.string_span import _get_kgen_string
from std.random import random_ui64
from std.time import perf_counter_ns

comptime P = OpaquePointer[MutUntrackedOrigin]

comptime CELL = 6
comptime GRID_W = 180
comptime GRID_H = 120
comptime WIN_W = GRID_W * CELL  # 1080
comptime WIN_H = GRID_H * CELL  # 720
comptime CELLS = GRID_W * GRID_H
comptime PIXELS = WIN_W * WIN_H
comptime MAX_AGE = 64


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



@always_inline
def _sym[name: StaticString]() -> P:
    return P(
        _mlir_value=__mlir_op.`pop.extern_ptr_symbol`[
            name=_get_kgen_string[name](),
            alignment=Int(1).__mlir_index__(),
            _type=P._mlir_type,
        ]()
    )


def alloc_zeroed(count: Int, size: Int) -> Int:
    """Zeroed heap memory that nothing in Mojo owns.

    The buffers must outlive `main`'s locals: Mojo destroys a value at its LAST
    USE, not at end of scope, so a `List` whose `.unsafe_ptr()` we stash is
    freed immediately and every stored pointer dangles -- which shows up much
    later as a corrupted allocator, nowhere near the cause. Owning the memory
    outside Mojo makes the lifetime explicit and correct.
    """
    var sym = _sym["calloc"]()
    var call = Pointer(to=sym).unsafe_bitcast[
        def(Int, Int, /) thin abi("C") -> P
    ]()[]
    return Int(call(count, size))


# ── State (callbacks get no closure, so it lives in named globals) ───────────
comptime g_alive = named_global["life.alive", Int]  # UInt8*  per cell 0/1
comptime g_next = named_global["life.next", Int]  # UInt8*  scratch
comptime g_age = named_global["life.age", Int]  # UInt16* generations survived
comptime g_decay = named_global["life.decay", Int]  # UInt8*  ember trail
comptime g_frame = named_global["life.frame", Int]  # UInt32* BGRA pixels

comptime g_layer = named_global["life.layer", Int]
comptime g_queue = named_global["life.queue", Int]
comptime g_window = named_global["life.window", Int]
comptime g_running = named_global["life.running", Int]
comptime g_gen = named_global["life.gen", Int]
comptime g_speed = named_global["life.speed", Int]  # evolve every N ticks
comptime g_tick = named_global["life.tick", Int]
comptime g_dirty = named_global["life.dirty", Int]


@always_inline
def alive_ptr() -> Pointer[UInt8, MutUntrackedOrigin]:
    return Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=g_alive()[]
    )


@always_inline
def next_ptr() -> Pointer[UInt8, MutUntrackedOrigin]:
    return Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=g_next()[])


@always_inline
def age_ptr() -> Pointer[UInt16, MutUntrackedOrigin]:
    return Pointer[UInt16, MutUntrackedOrigin](unsafe_from_address=g_age()[])


@always_inline
def decay_ptr() -> Pointer[UInt8, MutUntrackedOrigin]:
    return Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=g_decay()[]
    )


@always_inline
def frame_ptr() -> Pointer[UInt32, MutUntrackedOrigin]:
    return Pointer[UInt32, MutUntrackedOrigin](
        unsafe_from_address=g_frame()[]
    )


# ── The simulation ──────────────────────────────────────────────────────────


def evolve():
    """One generation, with the neighbour count on a wrapped torus so gliders
    sail off one edge and back in the other."""
    var alive = alive_ptr()
    var nxt = next_ptr()
    var age = age_ptr()
    var decay = decay_ptr()

    for y in range(GRID_H):
        var up = (y + GRID_H - 1) % GRID_H * GRID_W
        var mid = y * GRID_W
        var dn = (y + 1) % GRID_H * GRID_W
        for x in range(GRID_W):
            var l = (x + GRID_W - 1) % GRID_W
            var r = (x + 1) % GRID_W
            var n = (
                Int(alive[unsafe_offset = up + l])
                + Int(alive[unsafe_offset = up + x])
                + Int(alive[unsafe_offset = up + r])
                + Int(alive[unsafe_offset = mid + l])
                + Int(alive[unsafe_offset = mid + r])
                + Int(alive[unsafe_offset = dn + l])
                + Int(alive[unsafe_offset = dn + x])
                + Int(alive[unsafe_offset = dn + r])
            )
            var i = mid + x
            var was = alive[unsafe_offset=i] != 0
            var now = (was and (n == 2 or n == 3)) or ((not was) and n == 3)
            nxt[unsafe_offset=i] = 1 if now else 0
            if now:
                var a = age[unsafe_offset=i]
                if a < UInt16(MAX_AGE):
                    age[unsafe_offset=i] = a + 1
            else:
                age[unsafe_offset=i] = 0
                if was:
                    decay[unsafe_offset=i] = 200  # fresh ember

    # Swap the buffers by swapping the globals -- no copying.
    var a = g_alive()[]
    g_alive()[] = g_next()[]
    g_next()[] = a

    # Fade the embers.
    var d = decay_ptr()
    for i in range(CELLS):
        var v = d[unsafe_offset=i]
        if v > UInt8(0):
            d[unsafe_offset=i] = v - 8 if v > UInt8(8) else UInt8(0)

    g_gen()[] += 1


@always_inline
def pack(b: Int, g: Int, r: Int) -> UInt32:
    return UInt32(b) | (UInt32(g) << 8) | (UInt32(r) << 16) | (
        UInt32(255) << 24
    )


def cell_color(age: UInt16, decay: UInt8) -> UInt32:
    """Colour tells you the cell's history.

    A newborn burns white; over its first generations it cools through cyan to
    green; a long survivor settles into deep blue. A cell that has just died
    leaves an ember that fades to the background. So a glider reads as a
    bright head with a warm tail, and a still life sits quiet and blue.
    """
    if age == UInt16(0):
        if decay == UInt8(0):
            return pack(22, 18, 16)  # background
        var d = Int(decay)
        # ember: dim orange-red fading out
        return pack(16 + d // 8, 24 + d // 4, 40 + d // 2)

    var a = Int(age)
    if a <= 2:
        return pack(235, 250, 255)  # newborn: white-hot
    if a <= 6:
        # cooling: white-cyan -> cyan
        var t = (a - 2) * 255 // 4
        return pack(235, 250 - t // 6, 255 - t)
    if a <= 20:
        # cyan -> green
        var t = (a - 6) * 255 // 14
        return pack(235 - t, 250, 40)
    # settled: green -> deep blue
    var t = (a - 20) * 255 // (MAX_AGE - 20)
    if t > 255:
        t = 255
    return pack(40 + t // 2, 250 - t, 40 + t // 3)


def render():
    """Paint the grid into the BGRA frame buffer, one CELL x CELL block per
    cell, leaving a one-pixel gutter so the lattice stays legible."""
    var alive = alive_ptr()
    var age = age_ptr()
    var decay = decay_ptr()
    var frame = frame_ptr()
    comptime bg = pack(14, 12, 11)

    for cy in range(GRID_H):
        for cx in range(GRID_W):
            var i = cy * GRID_W + cx
            var color = (
                cell_color(age[unsafe_offset=i], decay[unsafe_offset=i])
                if (alive[unsafe_offset=i] != 0)
                or decay[unsafe_offset=i] != UInt8(0)
                else bg
            )
            var px0 = cx * CELL
            var py0 = cy * CELL
            for dy in range(CELL - 1):
                var row = (py0 + dy) * WIN_W + px0
                for dx in range(CELL - 1):
                    frame[unsafe_offset = row + dx] = color
            # gutter column and row stay background
            for dy in range(CELL):
                frame[unsafe_offset = (py0 + dy) * WIN_W + px0 + CELL - 1] = bg
            for dx in range(CELL):
                frame[unsafe_offset = (py0 + CELL - 1) * WIN_W + px0 + dx] = bg


def randomize():
    var alive = alive_ptr()
    var age = age_ptr()
    var decay = decay_ptr()
    for i in range(CELLS):
        var on = random_ui64(0, 4) == 0
        alive[unsafe_offset=i] = 1 if on else 0
        age[unsafe_offset=i] = 1 if on else 0
        decay[unsafe_offset=i] = 0
    g_gen()[] = 0
    g_dirty()[] = 1


def clear_grid():
    var alive = alive_ptr()
    var age = age_ptr()
    var decay = decay_ptr()
    for i in range(CELLS):
        alive[unsafe_offset=i] = 0
        age[unsafe_offset=i] = 0
        decay[unsafe_offset=i] = 0
    g_gen()[] = 0
    g_dirty()[] = 1


def population() -> Int:
    var alive = alive_ptr()
    var n = 0
    for i in range(CELLS):
        if alive[unsafe_offset=i] != 0:
            n += 1
    return n


# ── Painting cells with the mouse ───────────────────────────────────────────


def paint_at(win_x: Float64, win_y: Float64, erase: Bool):
    """`win_*` is in window coordinates (origin bottom-left); the grid runs
    top-down, so the y axis is flipped here."""
    var cx = Int(win_x) // CELL
    var cy = (WIN_H - Int(win_y)) // CELL
    if cx < 0 or cx >= GRID_W or cy < 0 or cy >= GRID_H:
        return
    var alive = alive_ptr()
    var age = age_ptr()
    var decay = decay_ptr()
    # A 2x2 dab, so drawing feels like a pen rather than a pixel hunt.
    for dy in range(2):
        for dx in range(2):
            var x = cx + dx
            var y = cy + dy
            if x >= GRID_W or y >= GRID_H:
                continue
            var i = y * GRID_W + x
            if erase:
                alive[unsafe_offset=i] = 0
                age[unsafe_offset=i] = 0
            else:
                alive[unsafe_offset=i] = 1
                if age[unsafe_offset=i] == UInt16(0):
                    age[unsafe_offset=i] = 1
                decay[unsafe_offset=i] = 0
    g_dirty()[] = 1


def event_point(event: P) -> CGPoint:
    """-[NSEvent locationInWindow] -> NSPoint (16 bytes, returned in two SSE
    registers, so the plain objc_msgSend path carries it)."""
    return msg_send[CGPoint, "NSEvent", "locationInWindow"](ObjCObject(Int(event)))


def event_has_shift(event: P) -> Bool:
    var flags = msg_send[Int, "NSEvent", "modifierFlags"](
        ObjCObject(Int(event))
    )
    return (flags & 131072) != 0  # NSEventModifierFlagShift


# ── View callbacks (Mojo functions Cocoa calls) ─────────────────────────────


def on_mouse_down(self_: P, cmd: P, event: P) abi("C"):
    var p = event_point(event)
    paint_at(p.x, p.y, event_has_shift(event))


def on_mouse_dragged(self_: P, cmd: P, event: P) abi("C"):
    var p = event_point(event)
    paint_at(p.x, p.y, event_has_shift(event))


def on_right_mouse_down(self_: P, cmd: P, event: P) abi("C"):
    var p = event_point(event)
    paint_at(p.x, p.y, True)


def on_right_mouse_dragged(self_: P, cmd: P, event: P) abi("C"):
    var p = event_point(event)
    paint_at(p.x, p.y, True)


def accepts_first_responder(self_: P, cmd: P) abi("C") -> Bool:
    return True


def on_key_down(self_: P, cmd: P, event: P) abi("C"):
    # No pool here: this is called from AppKit's own event dispatch, which
    # already has one, and every object read is autoreleased by the caller.
    var chars = msg_send[
        ObjCObject, "NSEvent", "charactersIgnoringModifiers"
    ](ObjCObject(Int(event)))
    if chars.is_nil():
        return
    var p = msg_send[P, "NSString", "UTF8String"](chars)
    if Int(p) == 0:
        return
    var s = String(unsafe_from_utf8_ptr=p.unsafe_bitcast[c_char]())
    if len(s.as_bytes()) == 0:
        return
    var c = s.as_bytes()[0]

    if c == UInt8(ord(" ")):
        g_running()[] = 0 if g_running()[] != 0 else 1
    elif c == UInt8(ord("c")):
        clear_grid()
    elif c == UInt8(ord("r")):
        randomize()
    elif c == UInt8(ord(".")):
        evolve()  # single step (most useful while paused)
        g_dirty()[] = 1
    elif c == UInt8(ord("]")):
        if g_speed()[] > 1:
            g_speed()[] -= 1
    elif c == UInt8(ord("[")):
        if g_speed()[] < 30:
            g_speed()[] += 1


def update_title():
    if True:
        var state = "running" if g_running()[] != 0 else "paused"
        var title = (
            String("Life — gen ")
            + String(g_gen()[])
            + "  ·  pop "
            + String(population())
            + "  ·  "
            + state
            + "  ·  speed "
            + String(31 - g_speed()[])
            + "   [space] pause  [drag] draw  [⇧drag] erase  [.] step  [r]"
            + " random  [c] clear  [ [ ] ] speed"
        )
        _ = msg_send[ObjCObject, "NSWindow", "setTitle:"](
            ObjCObject(g_window()[]), nsstring(title).ptr()
        )


def present():
    """Blit the frame buffer into the layer's next drawable.

    No early return: this runs inside the tick's autorelease pool, and
    returning out of a `with` block skips the pop.
    """
    var layer = ObjCObject(g_layer()[])
    var drawable = msg_send[ObjCObject, "CAMetalLayer", "nextDrawable"](layer)
    if not drawable.is_nil():
        var tex = msg_send[ObjCObject, "CAMetalDrawable", "texture"](drawable)
        var region = MTLRegion(
            MTLOrigin(0, 0, 0), MTLSize(WIN_W, WIN_H, 1)
        )
        _ = send[
            ObjCObject, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:"
        ](
            tex,
            region,
            Int(0),
            P(unsafe_from_address=g_frame()[]),
            Int(WIN_W * 4),
        )
        var cb = send[ObjCObject, "commandBuffer"](ObjCObject(g_queue()[]))
        _ = send[ObjCObject, "presentDrawable:"](cb, drawable.ptr())
        _ = send[ObjCObject, "commit"](cb)


def on_tick(self_: P, cmd: P, timer: P) abi("C"):
    with autoreleasepool():
        var stepped = False
        if g_running()[] != 0:
            g_tick()[] += 1
            if g_tick()[] >= g_speed()[]:
                g_tick()[] = 0
                evolve()
                stepped = True
        if stepped or g_dirty()[] != 0:
            g_dirty()[] = 0
            render()
            present()
            update_title()


def should_terminate(self_: P, cmd: P, app: P) abi("C") -> Bool:
    return True


def main() raises:
    # Buffers owned outside Mojo -- see alloc_zeroed for why a List would be
    # freed out from under these pointers.
    g_alive()[] = alloc_zeroed(CELLS, 1)
    g_next()[] = alloc_zeroed(CELLS, 1)
    g_age()[] = alloc_zeroed(CELLS, 2)
    g_decay()[] = alloc_zeroed(CELLS, 1)
    g_frame()[] = alloc_zeroed(PIXELS, 4)
    g_running()[] = 1
    g_speed()[] = 3
    randomize()

    with autoreleasepool():
        var NSApplication = ObjCClass.lookup["NSApplication"]()
        var app = msg_send[
            ObjCObject, "NSApplication", "sharedApplication", is_class=True
        ](NSApplication.as_object())
        _ = msg_send[Bool, "NSApplication", "setActivationPolicy:"](app, Int(0))

        var db = ObjCClassBuilder("LifeDelegate")
        db.add_method["applicationShouldTerminateAfterLastWindowClosed:"](
            should_terminate
        )
        var delegate = new_instance(db^.register())
        _ = msg_send[ObjCObject, "NSApplication", "setDelegate:"](
            app, delegate.ptr()
        )

        # A view class whose mouse and key handlers are Mojo functions.
        var vb = ObjCClassBuilder["NSView"]("LifeView")
        vb.add_method["mouseDown:"](on_mouse_down)
        vb.add_method["mouseDragged:"](on_mouse_dragged)
        vb.add_method["rightMouseDown:"](on_right_mouse_down)
        vb.add_method["rightMouseDragged:"](on_right_mouse_dragged)
        vb.add_method["keyDown:"](on_key_down)
        vb.add_method["acceptsFirstResponder"](accepts_first_responder)
        var LifeView = vb^.register()

        # Timer target.
        var ab = ObjCClassBuilder("LifeActions")
        ab.add_method["tick:", encoding="v@:@"](on_tick)
        var actions = new_instance(ab^.register())
        _ = external_call["objc_retain", P](actions.ptr())

        var win = msg_send[ObjCObject, "NSWindow", "alloc", is_class=True](
            ObjCClass.lookup["NSWindow"]().as_object()
        )
        win = msg_send[
            ObjCObject,
            "NSWindow",
            "initWithContentRect:styleMask:backing:defer:",
        ](
            win,
            CGRect(
                CGPoint(100.0, 100.0), CGSize(Float64(WIN_W), Float64(WIN_H))
            ),
            Int(15),
            Int(2),
            Bool(False),
        )
        g_window()[] = win.addr()

        var view = msg_send[ObjCObject, "NSView", "alloc", is_class=True](
            LifeView.as_object()
        )
        view = msg_send[ObjCObject, "NSView", "initWithFrame:"](
            view,
            CGRect(
                CGPoint(0.0, 0.0), CGSize(Float64(WIN_W), Float64(WIN_H))
            ),
        )
        _ = external_call["objc_retain", P](view.ptr())

        var display_dev = ObjCObject(
            Int(external_call["MTLCreateSystemDefaultDevice", P]())
        )
        var queue = send[ObjCObject, "newCommandQueue"](display_dev)
        _ = external_call["objc_retain", P](queue.ptr())
        g_queue()[] = queue.addr()

        var CAMetalLayer = ObjCClass.lookup["CAMetalLayer"]()
        var layer = msg_send[
            ObjCObject, "CAMetalLayer", "layer", is_class=True
        ](CAMetalLayer.as_object())
        _ = send[ObjCObject, "setDevice:"](layer, display_dev.ptr())
        _ = msg_send[ObjCObject, "CAMetalLayer", "setPixelFormat:"](
            layer, Int(80)  # MTLPixelFormatBGRA8Unorm
        )
        _ = msg_send[ObjCObject, "CAMetalLayer", "setFramebufferOnly:"](
            layer, Bool(False)
        )
        _ = msg_send[ObjCObject, "CAMetalLayer", "setDrawableSize:"](
            layer, CGSize(Float64(WIN_W), Float64(WIN_H))
        )
        _ = external_call["objc_retain", P](layer.ptr())
        g_layer()[] = layer.addr()

        _ = msg_send[ObjCObject, "NSView", "setWantsLayer:"](view, True)
        _ = msg_send[ObjCObject, "NSView", "setLayer:"](view, layer.ptr())
        _ = msg_send[ObjCObject, "NSWindow", "setContentView:"](
            win, view.ptr()
        )
        _ = msg_send[ObjCObject, "NSWindow", "makeFirstResponder:"](
            win, view.ptr()
        )

        _ = msg_send[
            ObjCObject,
            "NSTimer",
            "scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:",
            is_class=True,
        ](
            ObjCClass.lookup["NSTimer"]().as_object(),
            Float64(1.0 / 60.0),
            actions.ptr(),
            sel["tick:"]().ptr(),
            actions.ptr(),
            Bool(True),
        )

        render()
        update_title()
        _ = msg_send[ObjCObject, "NSWindow", "makeKeyAndOrderFront:"](
            win, app.ptr()
        )
        _ = msg_send[
            ObjCObject, "NSApplication", "activateIgnoringOtherApps:"
        ](app, Bool(True))

    var app2 = msg_send[
        ObjCObject, "NSApplication", "sharedApplication", is_class=True
    ](ObjCClass.lookup["NSApplication"]().as_object())
    _ = msg_send[ObjCObject, "NSApplication", "run"](app2)
