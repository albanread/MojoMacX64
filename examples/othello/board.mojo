# Othello, as two 64-bit words.
#
# Norvig's version in "Paradigms of AI Programming" uses a 100-element array
# with a border of sentinel squares, so a walk off the edge hits a wall
# instead of wrapping. That is the right shape for a language with arrays and
# no wide integers, and it costs a bounds check per step in eight directions.
#
# A board is 64 squares and a machine word is 64 bits, so the whole position
# is two words: the squares this player holds, and the squares the opponent
# holds. Every rule becomes shifts and masks over those words -- no loops over
# directions, no bounds checks, no branches that depend on the position.
#
# That matters twice over here. It is faster on the CPU, and it is the reason
# a GPU player is possible at all: a thread that plays a whole game needs two
# registers for the board, and every thread executes the same instructions
# regardless of what its game looks like.
#
# Bit i is row i // 8, column i % 8, with row 0 at the top and column 0 on the
# left -- the order the board is drawn in, so the UI never has to flip.

comptime NOT_LEFT = UInt64(0xFEFEFEFEFEFEFEFE)   # every column but the first
comptime NOT_RIGHT = UInt64(0x7F7F7F7F7F7F7F7F)  # every column but the last

comptime DIR_E = 0
comptime DIR_W = 1
comptime DIR_S = 2
comptime DIR_N = 3
comptime DIR_SE = 4
comptime DIR_SW = 5
comptime DIR_NE = 6
comptime DIR_NW = 7


@always_inline
fn shift(b: UInt64, dir: Int) -> UInt64:
    """One step in a direction, with the wrap masked off.

    Shifting east moves bit 7 (the last column) into bit 8 (the first column
    of the next row), which is a move through the edge of the board. Masking
    after the shift is what the sentinel border was for.
    """
    if dir == DIR_E:
        return (b << 1) & NOT_LEFT
    if dir == DIR_W:
        return (b >> 1) & NOT_RIGHT
    if dir == DIR_S:
        return b << 8
    if dir == DIR_N:
        return b >> 8
    if dir == DIR_SE:
        return (b << 9) & NOT_LEFT
    if dir == DIR_SW:
        return (b << 7) & NOT_RIGHT
    if dir == DIR_NE:
        return (b >> 7) & NOT_LEFT
    return (b >> 9) & NOT_RIGHT


@always_inline
fn legal_moves(own: UInt64, opp: UInt64) -> UInt64:
    """Every square this player may play, as a bitboard.

    A legal move sits on an empty square, at the far end of an unbroken run
    of opponent discs that starts next to one of ours. The run is grown six
    times because a line of eight squares can hold at most six discs between
    the two ends.
    """
    var empty = ~(own | opp)
    var moves = UInt64(0)
    for dir in range(8):
        var run = shift(own, dir) & opp
        for _ in range(5):
            run |= shift(run, dir) & opp
        moves |= shift(run, dir) & empty
    return moves


@always_inline
fn flips_for(own: UInt64, opp: UInt64, move: UInt64) -> UInt64:
    """The discs a move turns over. Empty if the move is not legal."""
    var flipped = UInt64(0)
    for dir in range(8):
        var run = shift(move, dir) & opp
        for _ in range(5):
            run |= shift(run, dir) & opp
        # The run only counts if one of ours closes it. Anything else -- an
        # empty square, or the edge -- and nothing turns over.
        if (shift(run, dir) & own) != 0:
            flipped |= run
    return flipped


@always_inline
fn popcount(b: UInt64) -> Int:
    """How many discs. The obvious loop, not the clever one: it runs once per
    move on the CPU and once per finished game on the GPU."""
    var n = 0
    var x = b
    while x != 0:
        x &= x - 1
        n += 1
    return n


@always_inline
fn bit(index: Int) -> UInt64:
    return UInt64(1) << UInt64(index)


@always_inline
fn square(row: Int, col: Int) -> UInt64:
    return bit(row * 8 + col)


fn start_black() -> UInt64:
    # d5 and e4 in the usual notation; row 3 col 4 and row 4 col 3 here.
    return square(3, 4) | square(4, 3)


fn start_white() -> UInt64:
    return square(3, 3) | square(4, 4)
