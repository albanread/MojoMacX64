# CHIP — a chip-tune synthesiser, in Mojo

Three voices, a resonant filter, and a player routine that rewrites the
registers fifty times a second. It sounds like a Commodore 64 because it does
what a Commodore 64 did, not because it plays samples of one.

    cocoamojo --build examples/chip/main.mojo -I examples/chip -o /tmp/chip
    /tmp/chip                              # the built-in tune
    /tmp/chip examples/chip/tunes/ode.abc   # an ABC tune

    SPACE pause   1 2 3 mute a voice   < > cutoff   - + resonance
    F filter mode   Q quit

## Why this example exists

Every other example here draws. This one has a deadline.

CoreAudio calls a render callback on a real-time thread it owns: a C function
pointer, invoked every 10.7 ms, that must fill 512 samples before the speaker
runs dry. It may not allocate, may not take a lock, and may not raise. Miss
the deadline and you hear it.

Mojo turns out to be on both sides of that boundary without a shim:

- **`fn` is a foreign-callable C-ABI function.** So `render` in
  [main.mojo](main.mojo) *is* an `AURenderCallback` — installed straight into
  the audio unit with `AudioUnitSetProperty`. There is no C file in this
  build and no Objective-C.
- **`class` declares a real Objective-C class.** So the same program's window
  is an `NSView` subclass that AppKit dispatches to normally.

One process, two threads, two languages' worth of ABI, and nothing hand-written
to bridge them. That is the thing worth showing.

`cocoamojo` links AudioToolbox for every program, the way it already links
AppKit and Metal, so this builds with no extra flags.

(`AVAudioSourceNode` would have been the modern API, and it takes an
Objective-C block. Mojo cannot construct a block, so this uses the older
AudioUnit path, where the callback is a plain function pointer. That is a real
limitation, and it is also why the older API is the right one here.)

## What is in the chip

[chip.mojo](chip.mojo) is a 6581-flavoured synthesiser, not an emulator —
rechip already exists, is cycle-exact, and is thousands of lines of measured
analogue behaviour. This is the arithmetic that gives the 6581 its voice,
small enough to read in one sitting.

The 6581 is integer hardware, so the model is integer arithmetic. The only
floating point is the filter and the final sample.

| Part | What makes it sound right |
| --- | --- |
| Oscillators | 24-bit phase accumulators, stepped in 24.8 fixed point so the pitch is exact |
| Waveforms | triangle, sawtooth, pulse, and the real 23-bit noise LFSR with its actual output taps — which is why the noise rasps instead of hissing |
| Combined | selecting two waveforms ANDs them, as on the chip |
| Envelope | decays by the chip's period-stretching table (÷2 below level 93, then ÷4, ÷8, ÷16, ÷30) rather than an exponential curve |
| Ring mod | one XOR of the previous voice's top bit into this one's triangle |
| Hard sync | the previous voice's wrap resets this accumulator |
| Filter | a two-pole state-variable filter, multimode, with resonance |

The envelope table is the single detail that matters most. Replace it with a
smooth exponential and the thing stops sounding like a C64 and starts
sounding like a synthesiser.

## What is in the player

[tune.mojo](tune.mojo) is the part people forget. The chip has three voices
and no memory; everything that makes a C64 tune sound like one happens in the
routine that ran off the raster interrupt:

- a **chord** is one voice switching between three notes on consecutive
  frames — fast enough to hear as a chord, slow enough to shimmer. The
  arpeggio is the most recognisable sound the machine made.
- a **held note** is kept alive by sweeping the pulse width every frame,
  because a static pulse wave goes lifeless in about half a second
- a **drum** is noise plus a downward pitch sweep, because the chip has no
  percussion

The routine is an `fn` and is called from inside the audio callback, on the
beat, exactly where the interrupt would have been.

## ABC tunes

[abc.mojo](abc.mojo) reads ABC notation — headers, accidentals held to the end
of the bar, key signatures including modes, broken rhythm, and `V:` for up to
three voices. An ABC chord `[CEG]` becomes an arpeggio, which is the correct
translation rather than a convenient one.

Repeats are ignored rather than expanded, so a tune plays through once per
loop. Slurs, ties, grace notes and decorations are skipped: they change
nothing a chip can hear.

## Two bugs worth keeping

**A `let` that aliased a loop counter.** `let drum_first = i` names `i`'s
storage rather than copying it, so the recorded index followed the loop and
voice 2 was pointed past the end of the score block. It read whatever the heap
held; when that happened to be a note of several billion, `midi_hz`'s octave
normalisation became a loop that never finished — on the audio thread, where a
hang is silence rather than a crash. It froze about three runs in five, which
is exactly the failure rate that makes you blame the audio system.

`midi_hz` now clamps its input as well. On a real-time thread a value that is
merely wrong and a value that hangs are different severities.

**A font built inside `drawRect:`.** Asking for a font on every string, thirty
times a second, eventually returned nil, and a nil value in an attributes
dictionary raises — surfacing as a trap deep inside AppKit with a stack that
mentions nothing about fonts. The fonts are now made once and retained.

Both were found by measuring rather than reading: a counter that stopped
advancing, then the offending value printed from the thread that could
safely print it.
