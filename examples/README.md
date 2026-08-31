# Examples

Each folder here is a project: a folder with a `main.mojo` in it. Open one in
Roast (File ▸ Open Folder…) and press ⌘R. Output appears in the console pane,
which opens itself when a build starts and toggles with ⌘0.

    hello/        the smallest thing that runs — one file
    fern/         Barnsley's fern, saved as a png — three files, so a
                  project with more than one file in it
    window/       a Cocoa window with a button, in Mojo
    life/         Conway's Life: a real app -- mouse, keyboard, a Metal
                  layer, and three `class` declarations Cocoa calls into
    fluid/        Stable Fluids on the GPU, every kernel written in Mojo
    mandelbrot/   a live-zooming fractal at 60fps, every pixel computed
                  and coloured by one Mojo kernel on the Apple GPU
    othello/      the board game, and an honest answer to where a GPU helps
                  a computer player -- and where it does not
    chip/         a chip-tune synthesiser: three voices, a resonant filter,
                  and a Mojo `fn` serving as CoreAudio's render callback on
                  a real-time thread. Plays ABC notation.
    abcplayer/    a full ABC notation player -- parser, repeats, tuplets,
                  MIDI file output -- scheduled to the sample, playing
                  through either the chip or General MIDI
    ferns/        a landscape of Barnsley ferns growing live over a
                  procedural lawn, under a cloudy dusk sky (CPU)
    fernwind/     the same meadow swaying in the wind: every fern redrawn
                  from scratch each frame by 24,576 GPU chaos-game streams
    life-python/  Conway again, drawn by PYGAME instead of Cocoa: the
                  same program in two windowing worlds. Needs a Python
                  environment — see its README

    And the largest example is not in this folder: File ▸ Open IDE Source
    opens Roast's own source — the editor you are reading this in, written
    in the language it edits.

    From Modular's own example collection, running here unmodified:

    operators/    a Complex struct wearing the full operator set — Mojo's
                  object model, with a std.testing suite beside it
    process/      child processes from std.os — spawn, wait, poll, kill
    vector-add/   the canonical first GPU kernel, TileTensor and all
    grayscale/    a 2D image kernel on the GPU
    tiled-matmul/ shared-memory tiles and barriers, with a validation pass

## What a project is

A folder. There is no project file and nothing to generate.

Mojo has no link step: the compiler is given one file and follows its imports
from there, so a project needs an entry point rather than a file list. Roast
looks for one in this order:

1. `main.mojo` in the project root — the convention, and what these examples use
2. the file on screen, if it is in the root and declares a top-level `main` —
   with several to choose from, the one being looked at is the one meant
3. the one non-test file in the root that declares a top-level `main`
4. the file on screen

Step 4 is what makes a single loose file still buildable: open one file, press
⌘B, and it builds that file. There is no separate single-file mode — it is the
same question with a smaller answer.

Step 3 ignores `*_test.mojo` because every test suite declares a `main` and
none of them is what the project is. And "declares a `main`" means at the start
of a line: `ide/build.mojo` explains this rule using the exact string it
searches for, so a plain substring scan nominates it as the entry point of the
whole editor.

The binary lands in `<project>/build/<name>`. ⌘R runs it with the project
folder as its working directory, which is why `fern/` writes its png into
`fern/` rather than wherever Roast was started from. A failed build does not
run anything; the console shows why, and the caret goes to the first error —
opening the file if it is not open, since the error is often in something
`main.mojo` imported and you have never had on screen.

Imports resolve from the entry point's own directory, so a project with several
files puts them beside `main.mojo` and imports them by name — `fern/` is
`main.mojo`, `ifs.mojo` and `png.mojo` doing exactly that.

That is also the limit: a module in a *sibling* folder is not found, because
nothing tells the compiler to look there. Sharing code between projects needs an
include path, and an include path needs somewhere to write it down. That is the
first thing a project file would be for, and until something needs it there
isn't one.

## Notes on the examples

`fern/` writes a real PNG with no library behind it: `png.mojo` is a CRC, an
Adler-32, and deflate's stored mode, which is about eighty lines and compresses
nothing — the file comes out around 2 MB for 720×960. Swapping in real
compression is a self-contained exercise if anyone wants it.

`mandelbrot/` needs a GPU. It times the same fractal on one CPU core and on
the GPU before opening the window — on an M4 Max the difference is a couple
of hundred times — then zooms into the seahorse valley until you click
somewhere better. The cross-checking of GPU against CPU arithmetic lives on
as `spikes/mandelbrot/compute_smoke.mojo`.

`ferns/` is `fern/`'s showy sibling: the same four affine maps, but a dozen
plants in different shades of green growing point-by-point at 60fps, out of a
lawn of fourteen thousand procedural grass blades, under value-noise clouds.
Click to plant another — lower on screen means closer, so it comes up bigger.

`fernwind/` is the fractal-flame answer to `ferns/`. The CPU version cannot
move -- its picture IS the accumulation -- so this one redraws every fern from
scratch each frame: thousands of GPU threads each run a short chaos game and
their hits meet in density buffers through atomic adds. Redrawing from
scratch is what buys the wind: each fern's climb map is rotated a fraction of
a degree by a travelling gust field, and because that map applies recursively
up the plant, the rotation compounds into a progressive bend -- stems lean,
tips whip. `mandelbrot/`, `fluid/` and `fernwind/` compute on the GPU;
`life/` and `ferns/` compute on the CPU and use Metal only to present.

`life/`, `fluid/`, `mandelbrot/`, `ferns/` and `fernwind/` are the ones that
look like applications.

The last five are Modular's, copied from `mojo/examples/` and `max/examples/`
in this same tree with nothing changed but the filename — including
`DeviceContext()` with no arguments, which resolves to the Apple GPU here.
That is the point of carrying them: upstream's own teaching examples, warp
primitives aside, build and run through this fork's AIR backend as written.
`tiled-matmul/` is the strongest proof in the set — shared-memory tiles and
barrier synchronisation, finishing with its own validation pass. Both declare
Objective-C classes with `class` — the view whose mouse and key handlers Cocoa
calls, the app delegate, the timer target, the Apple Event handler — so there
is no `ObjCClassBuilder`, no hand-written type encoding, and no `cmd` slot
anywhere in them. `fluid/` is Jos Stam's Stable Fluids with every kernel
compiled through this fork's AIR backend; there is no shader in the pipeline.
