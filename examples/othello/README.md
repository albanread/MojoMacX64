# Othello

A port of a Common Lisp demo, and an answer to a question worth asking of any
board game: **does the computer player want a GPU?**

The short answer is that half of it does, and the useful part of this example
is which half — and why.

    ⌘R to run.  You are black.
    N   new game        Q or Esc  quit
    B   Beginner        I  Intermediate
    A   Advanced        M  Master (GPU)

## The board is two integers

Norvig's version in *Paradigms of AI Programming* uses a 100-element array
with a border of sentinel squares, so a walk off the edge hits a wall rather
than wrapping onto the opposite rank. That is the right shape for a language
with arrays and no wide integers, and it costs a bounds check per step in
eight directions.

A board is 64 squares and a machine word is 64 bits, so a position is two
words: the squares one player holds and the squares the other holds. Every
rule becomes shifts and masks — the sentinel border becomes a mask applied
after the shift, and generating every legal move is eight shifted, masked
propagations with no branches that depend on the position.

`board.mojo` is 120 lines and the whole ruleset. It is checked against the
published perft numbers, which is the only way to be sure a move generator is
right:

    perft 1 = 4        perft 5 = 1396
    perft 2 = 12       perft 6 = 8200
    perft 3 = 56       perft 7 = 55092
    perft 4 = 244

## Where the GPU does not help

**Alpha-beta.** Its whole advantage is never examining a branch that cannot
change the answer, which makes the work each thread does depend on what the
other threads have already found. That is the opposite of what the hardware
is for: threads diverge at the first cutoff and the pruning — the entire
point — has to be given up to keep them in step.

It also does not need help. Measured here:

    depth 3     22 µs
    depth 4     81 µs
    depth 6  1,009 µs

Eighty-one microseconds. Moving that to a GPU would make it slower, and
saying otherwise would be a demo rather than an argument.

## Where it does

**Monte-Carlo playouts.** Play the position out to the end with random legal
moves, a few thousand times per candidate, and keep the move that wins most
often. Every playout is independent, holds its entire state in two registers,
touches no memory until it reports one integer, and runs exactly the same
instructions as its neighbours. That is the shape the hardware is built for.

16,384 playouts from the opening position:

    CPU      136.8 ms
    GPU        3.4 ms      40x

Both pick the same move, which is the cheap correctness check worth doing
whenever the same algorithm exists twice.

The speed is not the interesting part — the strength is. Given the GPU, a
level that would take most of a second per move on the CPU answers while your
hand is still on the mouse, so it can afford to be the strongest player here.
Six games against the best CPU level:

    Master (GPU playouts)  6 - 0  Advanced (alpha-beta, 4 ply)

with margins from 6 to 26 discs, and all six games played in half a second.

So the bitboards are not a micro-optimisation. They are the reason a thread
can hold a whole game, which is the reason the GPU player exists at all.

## Why the event loop is hand-rolled

A `DeviceContext` cannot live in a `named_global`, and a Cocoa callback
cannot reach a local — so the loop that owns the GPU has to be the loop that
drives the app, as in `mandelbrot/`. The view's mouse and key handlers only
set flags; the pump owns the board, the GPU and the redraw. Nothing that
touches Metal runs from a callback.

## Files

    board.mojo    the rules, as shifts and masks
    ai.mojo       four players, and the kernel one of them runs
    main.mojo     the window, the drawing, and the pump

## One thing the compiler taught us

The kernel would not link, with:

    Undefined symbols: llvm.scmp.i32.i64

Deciding a winner with `if b > w: 1 elif w > b: -1 else: 0` is folded into
LLVM's three-way compare intrinsic, and the Metal backend has no such
instruction. Writing it as `Int(b > w) - Int(w > b)` does not help — that is
the *canonical* shape the fold looks for. `Int(b > w) * 2 - Int(b != w)` is
the same function in a form the optimiser leaves alone.
