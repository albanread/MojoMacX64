# Three ways to choose a move, and an honest account of which one wants a GPU.
#
# Alpha-beta is the classic answer and it does NOT want a GPU. Its whole
# advantage is that a branch which cannot beat what you already have is never
# examined, so the work each thread does depends on what every other thread
# found -- the opposite of what a GPU is for. Threads would diverge on the
# first cutoff, and an 8x8 board at four ply is a few hundred microseconds of
# CPU anyway. Shipping that on the GPU would be slower and dishonest.
#
# Monte-Carlo playouts DO want a GPU. Play a position out to the end with
# random legal moves, many thousands of times, and count how often each first
# move wins. Every playout is independent, needs no memory beyond two
# registers, and runs the same instructions as its neighbours -- which is the
# shape the hardware is built for. That is the Master player below, and it is
# the reason the board is bitboards rather than Norvig's array.

from std.gpu import global_idx
from max.gpu.host import DeviceContext
from std.memory import Pointer, MutAnyOrigin

from board import (
    legal_moves,
    flips_for,
    popcount,
    bit,
)

# Norvig's weighted squares, from "Paradigms of AI Programming". Corners are
# worth more than anything else because they can never be flipped; the squares
# next to them are worth less than nothing because taking one usually hands
# the corner over.
# The table is symmetric in both axes, so only a quarter of it is written
# down: fold the square into the top-left 4x4 and look it up there.
@always_inline
fn weight_at(index: Int) -> Int:
    var r = index // 8
    var c = index % 8
    if r > 3:
        r = 7 - r
    if c > 3:
        c = 7 - c
    if r == 0:
        if c == 0: return 120
        if c == 1: return -20
        if c == 2: return 20
        return 5
    if r == 1:
        if c == 0: return -20
        if c == 1: return -40
        return -5
    if r == 2:
        if c == 0: return 20
        if c == 1: return -5
        if c == 2: return 15
        return 3
    if c == 0: return 5
    if c == 1: return -5
    return 3


comptime LEVEL_BEGINNER = 0
comptime LEVEL_INTERMEDIATE = 1
comptime LEVEL_ADVANCED = 2
comptime LEVEL_MASTER = 3

comptime WIN = 1000000


@always_inline
fn lowest(b: UInt64) -> UInt64:
    """The lowest set bit on its own."""
    return b & (~b + 1)


fn weighted(own: UInt64, opp: UInt64) -> Int:
    """Norvig's evaluation: our squares minus theirs, by table."""
    var score = 0
    for i in range(64):
        let m = bit(i)
        if (own & m) != 0:
            score += weight_at(i)
        elif (opp & m) != 0:
            score -= weight_at(i)
    return score


fn smart_weighted(own: UInt64, opp: UInt64) -> Int:
    """The table, plus a bonus for corners actually held.

    A corner is already worth 120, but holding one changes the value of the
    squares beside it -- they stop being liabilities once the corner behind
    them is settled. This is a cheap stand-in for real stability analysis.
    """
    var score = weighted(own, opp)
    comptime CORNERS = UInt64(0x8100000000000081)
    score += 30 * popcount(own & CORNERS)
    score -= 30 * popcount(opp & CORNERS)
    return score


fn negamax(
    own: UInt64, opp: UInt64, depth: Int, alpha_in: Int, beta: Int, smart: Bool
) -> Int:
    """Alpha-beta, from the moving player's point of view.

    A player with no move passes; if neither can move the game is over and
    the score is settled by counting discs, not by the table -- at the end a
    disc is worth exactly one disc.
    """
    var alpha = alpha_in
    let moves = legal_moves(own, opp)
    if moves == 0:
        if legal_moves(opp, own) == 0:
            let mine = popcount(own)
            let theirs = popcount(opp)
            if mine > theirs:
                return WIN + mine - theirs
            if mine < theirs:
                return -WIN - theirs + mine
            return 0
        # Pass: the turn goes over, the depth does not.
        return -negamax(opp, own, depth, -beta, -alpha, smart)
    if depth == 0:
        return smart_weighted(own, opp) if smart else weighted(own, opp)

    var best = -WIN * 2
    var m = moves
    while m != 0:
        let one = lowest(m)
        m &= m - 1
        let f = flips_for(own, opp, one)
        let score = -negamax(
            opp ^ f, own | one | f, depth - 1, -beta, -alpha, smart
        )
        if score > best:
            best = score
        if best > alpha:
            alpha = best
        if alpha >= beta:
            break
    return best


fn best_by_search(own: UInt64, opp: UInt64, depth: Int, smart: Bool) -> UInt64:
    """The move alpha-beta likes, as a single bit."""
    var moves = legal_moves(own, opp)
    if moves == 0:
        return 0
    var best_move = lowest(moves)
    var best = -WIN * 2
    var m = moves
    while m != 0:
        let one = lowest(m)
        m &= m - 1
        let f = flips_for(own, opp, one)
        let score = -negamax(
            opp ^ f, own | one | f, depth - 1, -WIN * 2, WIN * 2, smart
        )
        if score > best:
            best = score
            best_move = one
    return best_move


# ── Random play, shared by the CPU and the GPU ──────────────────────────────
# xorshift64*, because a playout needs a stream of numbers and nothing else:
# no state beyond one register, no tables, and the same three lines on both
# sides of the machine.


@always_inline
fn next_random(state: UInt64) -> UInt64:
    var x = state
    x ^= x >> 12
    x ^= x << 25
    x ^= x >> 27
    return x


@always_inline
fn nth_bit(b: UInt64, n: Int) -> UInt64:
    """The n-th set bit, counting from the low end."""
    var x = b
    for _ in range(n):
        x &= x - 1
    return lowest(x)


@always_inline
fn playout(black_in: UInt64, white_in: UInt64, black_to_move: Bool,
           seed: UInt64) -> Int:
    """Play to the end at random. Returns +1 if black wins, -1 white, 0 drawn.

    The same function runs on the CPU and inside the GPU kernel. It touches
    no memory, which is why ten thousand copies of it can run at once.
    """
    var black = black_in
    var white = white_in
    var turn_black = black_to_move
    var rng = seed | 1
    var passes = 0
    while passes < 2:
        let own = black if turn_black else white
        let opp = white if turn_black else black
        let moves = legal_moves(own, opp)
        if moves == 0:
            passes += 1
            turn_black = not turn_black
            continue
        passes = 0
        rng = next_random(rng)
        let count = popcount(moves)
        let pick = nth_bit(moves, Int(rng % UInt64(count)))
        let f = flips_for(own, opp, pick)
        if turn_black:
            black = black | pick | f
            white = white ^ f
        else:
            white = white | pick | f
            black = black ^ f
        turn_black = not turn_black
    let b = popcount(black)
    let w = popcount(white)
    # Written as arithmetic rather than a three-way branch on purpose. The
    # obvious `if b > w: 1 elif w > b: -1 else: 0` is folded into LLVM's
    # three-way compare intrinsic, and the Metal backend has no such
    # instruction -- the kernel then fails to link with "Undefined symbols:
    # llvm.scmp.i32.i64", which says nothing about what wrote it.
    # `Int(b > w) - Int(w > b)` is ALSO folded: zext(a>b) - zext(b>a) is the
    # canonical shape LLVM turns into scmp. This one is not that shape.
    return Int(b > w) * 2 - Int(b != w)


# ── The GPU player ──────────────────────────────────────────────────────────

comptime PLAYOUTS_PER_MOVE = 4096
comptime GPU_BLOCK = 256


def playout_kernel(
    wins: Pointer[Int32, MutAnyOrigin],
    black: UInt64,
    white: UInt64,
    moves_lo: UInt64,
    move_count: Int32,
    black_to_move: Int32,
    seed: UInt64,
):
    """One thread, one playout.

    Threads are laid out as (move, playout): thread i studies move
    i // PLAYOUTS_PER_MOVE, so a whole warp works on the same candidate and
    walks the same code with different dice.
    """
    let idx = Int(global_idx.x)
    let total = Int(move_count) * PLAYOUTS_PER_MOVE
    if idx >= total:
        return
    let which = idx // PLAYOUTS_PER_MOVE
    var m = moves_lo
    for _ in range(which):
        m &= m - 1
    let move = m & (~m + 1)

    let mover_black = black_to_move != 0
    let own = black if mover_black else white
    let opp = white if mover_black else black
    let f = flips_for(own, opp, move)
    var nb = black
    var nw = white
    if mover_black:
        nb = black | move | f
        nw = white ^ f
    else:
        nw = white | move | f
        nb = black ^ f

    # A distinct stream per thread. Mixing the index in avoids every thread
    # replaying the same game, which is the only way this can be wrong and
    # still look plausible.
    let r = playout(nb, nw, not mover_black, seed ^ (UInt64(idx) * 0x9E3779B97F4A7C15))
    # Score from the mover's point of view, so higher is always better.
    # Written per thread and summed on the way back: an atomic per playout
    # would serialise exactly the thing that is supposed to be parallel, and
    # the reduction is 4096 additions per move on a CPU that is idle anyway.
    wins[unsafe_offset=idx] = Int32(r) if mover_black else Int32(-r)


def best_by_playouts_gpu(
    ctx: DeviceContext,
    black: UInt64,
    white: UInt64,
    black_to_move: Bool,
    seed: UInt64,
) raises -> UInt64:
    """The move that wins most random games, decided on the GPU.

    Every legal move gets PLAYOUTS_PER_MOVE games played to the end from the
    position it leads to. One thread plays one game. The threads never talk
    to each other and never touch memory until the last line, which is why
    this is worth moving off the CPU at all.
    """
    let own = black if black_to_move else white
    let opp = white if black_to_move else black
    let moves = legal_moves(own, opp)
    if moves == 0:
        return 0
    let count = popcount(moves)
    let total = count * PLAYOUTS_PER_MOVE

    var kern = ctx.compile_function[playout_kernel]()
    var results = ctx.enqueue_create_buffer[DType.int32](total)
    let blocks = (total + GPU_BLOCK - 1) // GPU_BLOCK
    ctx.enqueue_function(
        kern, results, black, white, moves, Int32(count),
        Int32(1) if black_to_move else Int32(0), seed,
        grid_dim=(blocks), block_dim=(GPU_BLOCK),
    )
    ctx.synchronize()

    # The reduction is deliberately here and not in the kernel: an atomic per
    # playout would serialise the one part that is supposed to be parallel,
    # and this is a few thousand additions on a CPU that is waiting anyway.
    var best_move = UInt64(0)
    var best_score = -(1 << 60)
    with results.map_to_host() as host:
        let src = host.unsafe_ptr()
        var m = moves
        var which = 0
        while m != 0:
            let one = lowest(m)
            m &= m - 1
            var sum = 0
            for k in range(PLAYOUTS_PER_MOVE):
                sum += Int(src[which * PLAYOUTS_PER_MOVE + k])
            if sum > best_score:
                best_score = sum
                best_move = one
            which += 1
    return best_move


def best_by_playouts_cpu(
    black: UInt64, white: UInt64, black_to_move: Bool, seed: UInt64, per_move: Int
) -> UInt64:
    """The same idea on the CPU, for comparison and as a fallback when there
    is no Metal device to talk to."""
    let own = black if black_to_move else white
    let opp = white if black_to_move else black
    let moves = legal_moves(own, opp)
    if moves == 0:
        return 0
    var best_move = lowest(moves)
    var best_score = -(1 << 60)
    var m = moves
    var which = 0
    while m != 0:
        let one = lowest(m)
        m &= m - 1
        let f = flips_for(own, opp, one)
        var nb = black
        var nw = white
        if black_to_move:
            nb = black | one | f
            nw = white ^ f
        else:
            nw = white | one | f
            nb = black ^ f
        var sum = 0
        for k in range(per_move):
            let r = playout(
                nb, nw, not black_to_move,
                seed ^ (UInt64(which * per_move + k) * 0x9E3779B97F4A7C15),
            )
            sum += r if black_to_move else -r
        if sum > best_score:
            best_score = sum
            best_move = one
        which += 1
    return best_move
