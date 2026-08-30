# Othello, on a green felt board, with four computer players.
#
# A port of a Common Lisp demo, and an excuse to answer a question honestly:
# where does a GPU help a board game, and where does it not?
#
#   * Alpha-beta does not want a GPU. Its whole advantage is skipping branches
#     that cannot matter, which makes the work each thread does depend on what
#     the others found -- the opposite of what the hardware is for. Four ply
#     on an 8x8 board is 81 microseconds of CPU here. Nothing to accelerate.
#
#   * Monte-Carlo playouts do. Play the position out at random a few thousand
#     times per candidate move and count the wins: every game is independent,
#     holds its whole state in two registers, and runs the same instructions
#     as its neighbours. Measured on this machine, 16,384 playouts take
#     136.8 ms on the CPU and 3.4 ms on the Apple GPU -- 40x, and the
#     difference between a strong player that stalls and one that answers
#     while your hand is still on the mouse.
#
# So the Master level is a GPU player and the others are not, which is the
# useful answer rather than the flattering one.
#
# The event loop is hand-rolled rather than `[NSApp run]` for the reason
# mandelbrot gives: a DeviceContext cannot live in a `named_global`, and a
# Cocoa callback cannot reach a local, so the loop that owns the GPU has to
# be the loop that drives the app. The view's handlers only set flags.

from std.objc import (
    Obj,
    Cls,
    load_framework,
    ObjCClass,
    ObjCObject,
    msg_send,
    nsstring,
    autoreleasepool,
    named_global,
    extern_object,
    CGPoint,
    CGSize,
    CGRect,
)
from std.memory import OpaquePointer
from std.ffi import external_call, c_char
from std.os import getenv
from std.time import perf_counter_ns
from max.gpu.host import DeviceContext

from board import (
    legal_moves,
    flips_for,
    popcount,
    bit,
    start_black,
    start_white,
)
from ai import (
    best_by_search,
    best_by_playouts_gpu,
    best_by_playouts_cpu,
    lowest,
    next_random,
    nth_bit,
    LEVEL_BEGINNER,
    LEVEL_INTERMEDIATE,
    LEVEL_ADVANCED,
    LEVEL_MASTER,
    PLAYOUTS_PER_MOVE,
)

comptime P = OpaquePointer[MutUntrackedOrigin]

comptime CELL = 58.0
comptime MARGIN = 20.0
comptime BOARD = CELL * 8.0
comptime STATUS_H = 56.0
comptime WIN_W = BOARD + MARGIN * 2.0
comptime WIN_H = BOARD + MARGIN * 2.0 + STATUS_H

# The game, in globals, because the view's handlers and the pump both need it
# and neither can pass anything to the other.
comptime g_black = named_global["oth.black", Int]
comptime g_white = named_global["oth.white", Int]
comptime g_black_turn = named_global["oth.turn", Int]
comptime g_level = named_global["oth.level", Int]
comptime g_over = named_global["oth.over", Int]
comptime g_thinking = named_global["oth.thinking", Int]
comptime g_last_ms = named_global["oth.lastms", Int]
comptime g_gpu_ok = named_global["oth.gpu", Int]
comptime g_window = named_global["oth.window", Int]
comptime g_view = named_global["oth.view", Int]

# Set by the callbacks, acted on by the pump.
comptime g_click = named_global["oth.click", Int]     # 1 + square, or 0
comptime g_cmd = named_global["oth.cmd", Int]

comptime CMD_NEW = 1
comptime CMD_QUIT = 2
comptime CMD_LEVEL = 4


@always_inline
fn board_black() -> UInt64:
    return UInt64(g_black()[])


@always_inline
fn board_white() -> UInt64:
    return UInt64(g_white()[])


fn set_board(black: UInt64, white: UInt64):
    g_black()[] = Int(black)
    g_white()[] = Int(white)


fn new_game():
    set_board(start_black(), start_white())
    g_black_turn()[] = 1
    g_over()[] = 0
    g_last_ms()[] = 0


fn level_name(level: Int) -> String:
    if level == LEVEL_BEGINNER:
        return String("Beginner")
    if level == LEVEL_INTERMEDIATE:
        return String("Intermediate")
    if level == LEVEL_ADVANCED:
        return String("Advanced")
    return String("Master · GPU") if g_gpu_ok()[] != 0 else String("Master · CPU")


# ── Colour ──────────────────────────────────────────────────────────────────


fn rgb(r: Int, g: Int, b: Int) -> ObjCObject:
    return Cls["NSColor"]().colorWithSRGBRed_green_blue_alpha(
        Float64(r) / 255.0, Float64(g) / 255.0, Float64(b) / 255.0, 1.0
    )


fn rect(x: Float64, y: Float64, w: Float64, h: Float64) -> CGRect:
    return CGRect(CGPoint(x, y), CGSize(w, h))


fn fill_rect(r: CGRect, colour: ObjCObject):
    Obj["NSColor"](colour.addr()).setFill()
    _ = external_call["NSRectFill", NoneType](r)


fn fill_oval(r: CGRect, colour: ObjCObject):
    Obj["NSColor"](colour.addr()).setFill()
    let path = Cls["NSBezierPath"]().bezierPathWithOvalInRect(r)
    Obj["NSBezierPath"](path.addr()).fill()


# ── Drawing ─────────────────────────────────────────────────────────────────


fn draw_board():
    with autoreleasepool():
        # The felt, and the frame around it.
        fill_rect(rect(0.0, 0.0, WIN_W, WIN_H), rgb(24, 26, 30))
        fill_rect(
            rect(MARGIN, MARGIN + STATUS_H, BOARD, BOARD), rgb(45, 110, 60)
        )

        # Grid lines, drawn as thin rectangles: a board this size needs nine
        # of them each way and no path object.
        let line = rgb(28, 74, 40)
        for i in range(9):
            let o = Float64(i) * CELL
            fill_rect(
                rect(MARGIN + o - 0.5, MARGIN + STATUS_H, 1.0, BOARD), line
            )
            fill_rect(
                rect(MARGIN, MARGIN + STATUS_H + o - 0.5, BOARD, 1.0), line
            )

        let black = board_black()
        let white = board_white()
        let hints = legal_moves(black, white) if g_black_turn()[] != 0 else UInt64(0)

        for row in range(8):
            for col in range(8):
                let m = bit(row * 8 + col)
                # Row 0 is the top of the board; the view is not flipped, so
                # the top row is the highest y.
                let x = MARGIN + Float64(col) * CELL
                let y = MARGIN + STATUS_H + Float64(7 - row) * CELL
                if (black & m) != 0:
                    fill_oval(
                        rect(x + 5.0, y + 5.0, CELL - 10.0, CELL - 10.0),
                        rgb(18, 18, 20),
                    )
                elif (white & m) != 0:
                    fill_oval(
                        rect(x + 5.0, y + 5.0, CELL - 10.0, CELL - 10.0),
                        rgb(245, 245, 238),
                    )
                elif (hints & m) != 0:
                    # A move you may play. Small, so it reads as advice
                    # rather than as a disc already placed.
                    fill_oval(
                        rect(
                            x + CELL * 0.5 - 5.0,
                            y + CELL * 0.5 - 5.0,
                            10.0,
                            10.0,
                        ),
                        rgb(86, 150, 100),
                    )


fn draw_text(text: String, x: Float64, y: Float64, size: Float64,
             colour: ObjCObject):
    with autoreleasepool():
        let font = Cls["NSFont"]().monospacedDigitSystemFontOfSize_weight(
            size, Float64(0.0)
        )
        var attrs = Cls["NSMutableDictionary"]().dictionary()
        Obj["NSMutableDictionary"](attrs.addr()).setObject_forKey(
            font.ptr(), extern_object["NSFontAttributeName"]().ptr()
        )
        Obj["NSMutableDictionary"](attrs.addr()).setObject_forKey(
            colour.ptr(),
            extern_object["NSForegroundColorAttributeName"]().ptr(),
        )
        Obj["NSString"](nsstring(text).addr()).drawAtPoint_withAttributes(
            CGPoint(x, y), attrs.ptr()
        )


fn draw_status():
    let black = board_black()
    let white = board_white()
    let b = popcount(black)
    let w = popcount(white)
    let ink = rgb(250, 250, 240)

    var line = String("B:") + String(b) + String("  W:") + String(w)
    line += String("   ") + level_name(g_level()[])
    draw_text(line, MARGIN, 28.0, 15.0, ink)

    var note = String()
    if g_over()[] != 0:
        if b > w:
            note = String("Black wins by ") + String(b - w)
        elif w > b:
            note = String("White wins by ") + String(w - b)
        else:
            note = String("Drawn")
        note += String("   ·  N for a new game")
    elif g_thinking()[] != 0:
        note = String("White is thinking…")
    elif g_black_turn()[] != 0:
        note = String("Your move  ·  N new  ·  B I A M level  ·  Q quit")
    else:
        note = String("White to play")
    if g_last_ms()[] > 0 and g_over()[] == 0:
        note += String("   (") + String(g_last_ms()[]) + String(" ms)")
    draw_text(note, MARGIN, 8.0, 11.0, rgb(170, 175, 165))


# ── The view ────────────────────────────────────────────────────────────────


class OthelloView(NSView):
    def drawRect_(self, dirty: CGRect):
        draw_board()
        draw_status()

    def acceptsFirstResponder(self) -> Bool:
        return True

    def mouseDown_(self, event: ObjCObject):
        # Only a flag: the pump owns the game, and the GPU, and the redraw.
        #
        # The point comes back through the TYPED msg_send. An NSPoint is two
        # doubles returned in registers, and the dynamic `Obj[...]` path does
        # not describe that to the ABI -- the call returns nothing usable and
        # every click lands on the same wrong square, silently.
        let at = msg_send[CGPoint, "NSEvent", "locationInWindow"](event)
        let col = Int((at.x - MARGIN) // CELL)
        let row = 7 - Int((at.y - MARGIN - STATUS_H) // CELL)
        if col >= 0 and col < 8 and row >= 0 and row < 8:
            g_click()[] = 1 + row * 8 + col

    def keyDown_(self, event: ObjCObject):
        # No pool: AppKit's dispatch already has one, and every object read
        # here is autoreleased by the caller.
        let chars = msg_send[
            ObjCObject, "NSEvent", "charactersIgnoringModifiers"
        ](event)
        if chars.is_nil():
            return
        let p = msg_send[P, "NSString", "UTF8String"](chars)
        if Int(p) == 0:
            return
        let text = String(unsafe_from_utf8_ptr=p.unsafe_bitcast[c_char]())
        if len(text.as_bytes()) == 0:
            return
        let c = Int(text.as_bytes()[0])
        if c == 110 or c == 78:              # n
                g_cmd()[] = g_cmd()[] | CMD_NEW
            elif c == 113 or c == 81 or c == 27:  # q or escape
                g_cmd()[] = g_cmd()[] | CMD_QUIT
            elif c == 98 or c == 66:             # b
                g_level()[] = LEVEL_BEGINNER
                g_cmd()[] = g_cmd()[] | CMD_LEVEL
            elif c == 105 or c == 73:            # i
                g_level()[] = LEVEL_INTERMEDIATE
                g_cmd()[] = g_cmd()[] | CMD_LEVEL
            elif c == 97 or c == 65:             # a
                g_level()[] = LEVEL_ADVANCED
                g_cmd()[] = g_cmd()[] | CMD_LEVEL
            elif c == 109 or c == 77:            # m
                g_level()[] = LEVEL_MASTER
                g_cmd()[] = g_cmd()[] | CMD_LEVEL


fn redraw():
    if g_view()[] != 0:
        Obj["NSView"](ObjCObject(g_view()[]).addr()).setNeedsDisplay(True)


# ── Playing ─────────────────────────────────────────────────────────────────


fn apply_move(move: UInt64):
    """Place a disc for whoever is to move, and turn the turn over."""
    let black_turn = g_black_turn()[] != 0
    let black = board_black()
    let white = board_white()
    let own = black if black_turn else white
    let opp = white if black_turn else black
    let f = flips_for(own, opp, move)
    if f == 0:
        return
    if black_turn:
        set_board(black | move | f, white ^ f)
    else:
        set_board(black ^ f, white | move | f)
    g_black_turn()[] = 0 if black_turn else 1


fn settle_turn():
    """Pass for a player with no move, and end the game when neither has one."""
    for _ in range(2):
        let black = board_black()
        let white = board_white()
        let black_turn = g_black_turn()[] != 0
        let own = black if black_turn else white
        let opp = white if black_turn else black
        if legal_moves(own, opp) != 0:
            return
        if legal_moves(opp, own) == 0:
            g_over()[] = 1
            return
        g_black_turn()[] = 0 if black_turn else 1


fn computer_move_cpu(seed: UInt64) -> UInt64:
    """Everything but Master, which needs the GPU the pump owns."""
    let black = board_black()
    let white = board_white()
    let own = white
    let opp = black
    let level = g_level()[]
    if level == LEVEL_BEGINNER:
        let moves = legal_moves(own, opp)
        if moves == 0:
            return 0
        let count = popcount(moves)
        return nth_bit(moves, Int(next_random(seed | 1) % UInt64(count)))
    if level == LEVEL_INTERMEDIATE:
        return best_by_search(own, opp, 3, False)
    if level == LEVEL_ADVANCED:
        return best_by_search(own, opp, 4, True)
    # Master with no GPU: the same playouts, fewer of them, on the CPU.
    return best_by_playouts_cpu(black, white, False, seed, 512)


def main() raises:
    if not load_framework["AppKit"]():
        raise Error("could not load AppKit")

    new_game()
    g_level()[] = LEVEL_ADVANCED

    # The GPU, if this machine has one. Master falls back to CPU playouts if
    # not, which is worth doing rather than hiding the level.
    var have_gpu = False
    var ctx = DeviceContext(api="metal")
    try:
        _ = best_by_playouts_gpu(ctx, board_black(), board_white(), False, 1)
        have_gpu = True
    except:
        have_gpu = False
    g_gpu_ok()[] = 1 if have_gpu else 0

    with autoreleasepool():
        var NSApplication = ObjCClass.lookup["NSApplication"]()
        var app = msg_send[
            ObjCObject, "NSApplication", "sharedApplication", is_class=True
        ](NSApplication.as_object())
        _ = msg_send[Bool, "NSApplication", "setActivationPolicy:"](app, Int(0))

        var view = ObjCObject(OthelloView().__objc_id)
        _ = msg_send[ObjCObject, "NSView", "setFrame:"](
            view, rect(0.0, 0.0, WIN_W, WIN_H)
        )
        _ = external_call["objc_retain", P](view.ptr())
        g_view()[] = view.addr()

        var win = msg_send[ObjCObject, "NSWindow", "alloc", is_class=True](
            ObjCClass.lookup["NSWindow"]().as_object()
        )
        win = msg_send[
            ObjCObject,
            "NSWindow",
            "initWithContentRect:styleMask:backing:defer:",
        ](
            win,
            rect(120.0, 120.0, WIN_W, WIN_H),
            Int(15),
            Int(2),
            Bool(False),
        )
        g_window()[] = win.addr()
        _ = msg_send[ObjCObject, "NSWindow", "setTitle:"](
            win, nsstring(String("Othello")).ptr()
        )
        _ = msg_send[ObjCObject, "NSWindow", "setContentView:"](
            win, view.ptr()
        )
        _ = msg_send[ObjCObject, "NSWindow", "makeFirstResponder:"](
            win, view.ptr()
        )
        _ = msg_send[ObjCObject, "NSWindow", "makeKeyAndOrderFront:"](
            win, win.ptr()
        )
        _ = msg_send[
            ObjCObject, "NSApplication", "activateIgnoringOtherApps:"
        ](app, Bool(True))
        _ = msg_send[ObjCObject, "NSApplication", "finishLaunching"](app)

        var NSDate = ObjCClass.lookup["NSDate"]()
        var mode = nsstring(String("kCFRunLoopDefaultMode"))
        var rng = UInt64(perf_counter_ns()) | 1
        var running = True

        print("Othello.  You are black.  N new game · B I A M level · Q quit")
        print("Master level uses the GPU:", "yes" if have_gpu else "no (CPU playouts)")

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

            # Read the flag out BEFORE clearing it. `let` binds by reference
            # here, so `let cmd = g_cmd()[]` is a live view of the global and
            # not a snapshot: clearing the global first makes every later
            # read of `cmd` return zero, and the command silently evaporates.
            if g_cmd()[] != 0:
                let quit = (g_cmd()[] & CMD_QUIT) != 0
                let fresh = (g_cmd()[] & CMD_NEW) != 0
                g_cmd()[] = 0
                if quit:
                    running = False
                    continue
                if fresh:
                    new_game()
                redraw()

            # The human's move, if one is waiting and it is legal.
            # Same rule: the square is taken out of the global before the
            # global is cleared.
            if g_click()[] != 0:
                let m = bit(g_click()[] - 1)
                g_click()[] = 0
                if g_over()[] == 0 and g_black_turn()[] != 0:
                    if (legal_moves(board_black(), board_white()) & m) != 0:
                        apply_move(m)
                        settle_turn()
                        redraw()

            # The computer's, on the thread that owns the GPU.
            if g_over()[] == 0 and g_black_turn()[] == 0:
                g_thinking()[] = 1
                redraw()
                rng = next_random(rng)
                let t0 = perf_counter_ns()
                var move = UInt64(0)
                if g_level()[] == LEVEL_MASTER and have_gpu:
                    move = best_by_playouts_gpu(
                        ctx, board_black(), board_white(), False, rng
                    )
                else:
                    move = computer_move_cpu(rng)
                let t1 = perf_counter_ns()
                g_last_ms()[] = Int((t1 - t0) // 1000000)
                g_thinking()[] = 0
                if move != 0:
                    apply_move(move)
                settle_turn()
                redraw()

        print("Final:  black", popcount(board_black()),
              " white", popcount(board_white()))
