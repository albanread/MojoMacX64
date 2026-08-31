# The player routine: what runs fifty times a second and pokes the chip.
#
# This is the part people forget when they say "chip music". The chip has three
# voices and no memory of anything; everything that makes a C64 tune sound
# like a C64 tune happens up here, in a routine the raster interrupt called
# once per frame:
#
#   * a chord is played by switching one voice between its three notes on
#     consecutive frames, fast enough that the ear hears a chord and slow
#     enough that it shimmers -- the arpeggio, and the single most recognisable
#     sound of the machine
#   * a held note is kept alive by sweeping the pulse width every frame,
#     because a static pulse wave goes lifeless in about half a second
#   * vibrato, portamento and drums are all just registers being rewritten on
#     a schedule
#
# So the interesting code is not the oscillator. It is this: fifty edits a
# second to a handful of registers, and out comes music.
#
# The routine is an `fn` -- a plain C function pointer -- because it is called
# from inside the audio callback, on CoreAudio's real-time thread. It
# allocates nothing and cannot raise. Building a score does both, so that
# happens up front, in ordinary code.

from std.memory import Pointer, MutUntrackedOrigin, OpaquePointer
from std.ffi import external_call
from chip import (
    P, get, put, vget, vput, set_freq_hz, set_pulse_width, set_wave, set_adsr,
    gate_on, gate_off, route_filter, set_filter, _sin,
    S_FRAME, PLAYER_BASE, WAVE_PULSE, WAVE_SAW, WAVE_TRI, WAVE_NOISE, FILT_LP,
    V_PW, V_WAVE,
)

# ── The score in memory ─────────────────────────────────────────────────────
# One flat block of Ints, four per event: three notes and a duration. Three
# notes because an event may be a chord, and a chord on this chip is an
# arpeggio. A note of -1 is a rest.

comptime EVENT_SLOTS = 4
comptime E_N0 = 0
comptime E_N1 = 1
comptime E_N2 = 2
comptime E_FRAMES = 3

# Player state, indexed from PLAYER_BASE in the chip's own block.
comptime PL_SCORE = 0       # address of the event block
comptime PL_LOOP = 1
comptime PL_DONE = 2
comptime PL_VBASE = 8
comptime PL_VSTRIDE = 8
comptime PV_FIRST = 0       # index of this voice's first event
comptime PV_COUNT = 1
comptime PV_CURSOR = 2
comptime PV_LEFT = 3        # frames left in the current event
comptime PV_ARP = 4         # which note of a chord is sounding
comptime PV_N0 = 5
comptime PV_N1 = 6
comptime PV_N2 = 7

comptime PI_BASE = 40       # per-voice instrument settings
comptime PI_STRIDE = 8
comptime PI_PWM = 0         # pulse-width sweep speed, 0 for none
comptime PI_VIB = 1         # vibrato depth in cents, 0 for none
comptime PI_DRUM = 2        # retune downwards over the note: a drum
comptime PI_TRANSPOSE = 3


@always_inline
fn pget(st: P, slot: Int) -> Int:
    return get(st, PLAYER_BASE + slot)


@always_inline
fn pput(st: P, slot: Int, value: Int):
    put(st, PLAYER_BASE + slot, value)


@always_inline
fn pvget(st: P, voice: Int, field: Int) -> Int:
    return pget(st, PL_VBASE + voice * PL_VSTRIDE + field)


@always_inline
fn pvput(st: P, voice: Int, field: Int, value: Int):
    pput(st, PL_VBASE + voice * PL_VSTRIDE + field, value)


@always_inline
fn piget(st: P, voice: Int, field: Int) -> Int:
    return pget(st, PI_BASE + voice * PI_STRIDE + field)


@always_inline
fn piput(st: P, voice: Int, field: Int, value: Int):
    pput(st, PI_BASE + voice * PI_STRIDE + field, value)


# ── Pitch ───────────────────────────────────────────────────────────────────


@always_inline
fn semitone_ratio(k: Int) -> Float64:
    """2^(k/12) for k in 0..11, written out rather than computed.

    A power function would do, but this is called from the audio thread and
    the twelve values are the whole of Western tuning.
    """
    if k == 0: return 1.0
    if k == 1: return 1.0594630943592953
    if k == 2: return 1.122462048309373
    if k == 3: return 1.189207115002721
    if k == 4: return 1.2599210498948732
    if k == 5: return 1.3348398541700344
    if k == 6: return 1.4142135623730951
    if k == 7: return 1.4983070768766815
    if k == 8: return 1.5874010519681994
    if k == 9: return 1.681792830507429
    if k == 10: return 1.7817974362806785
    return 1.887748625363387


fn midi_hz(note_in: Int) -> Float64:
    """MIDI note to frequency: 69 is A4, and A4 is 440 Hz.

    The clamp is not decoration. This runs on the audio thread, and the
    octave normalisation below is a loop over the octave count -- so a note
    of a few billion is not a wrong pitch, it is a hang, and a hang here
    stops the speaker rather than raising anything.
    """
    var note = note_in
    if note < 0:
        note = 0
    elif note > 127:
        note = 127
    let offset = note - 69
    var octave = offset // 12
    let semi = offset - octave * 12
    var hz = 440.0 * semitone_ratio(semi)
    while octave > 0:
        hz *= 2.0
        octave -= 1
    while octave < 0:
        hz *= 0.5
        octave += 1
    return hz


# ── Building a score ────────────────────────────────────────────────────────


fn score_alloc(events: Int) -> Int:
    """A block big enough for `events` events. Returns its address."""
    return Int(external_call["calloc", P](Int(events * EVENT_SLOTS), Int(8)))


fn score_put(
    score: Int, index: Int, n0: Int, n1: Int, n2: Int, frames: Int
):
    let ev = Pointer[Int, MutUntrackedOrigin](unsafe_from_address=score)
    let at = index * EVENT_SLOTS
    ev[unsafe_offset=at + E_N0] = n0
    ev[unsafe_offset=at + E_N1] = n1
    ev[unsafe_offset=at + E_N2] = n2
    ev[unsafe_offset=at + E_FRAMES] = frames


fn player_reset(st: P):
    """Rewind every voice to the start of its part."""
    for v in range(3):
        pvput(st, v, PV_CURSOR, 0)
        pvput(st, v, PV_LEFT, 0)
        pvput(st, v, PV_ARP, 0)
    pput(st, PL_DONE, 0)


fn player_attach(st: P, score: Int, loop: Bool):
    pput(st, PL_SCORE, score)
    pput(st, PL_LOOP, 1 if loop else 0)
    player_reset(st)


fn voice_part(st: P, voice: Int, first: Int, count: Int):
    pvput(st, voice, PV_FIRST, first)
    pvput(st, voice, PV_COUNT, count)


# ── The routine itself ──────────────────────────────────────────────────────


fn player_tick(st: P) -> None:
    """One frame. Called from the audio callback, fifty times a second."""
    let score = pget(st, PL_SCORE)
    if score == 0:
        return
    let ev = Pointer[Int, MutUntrackedOrigin](unsafe_from_address=score)
    let frame = get(st, S_FRAME)
    var all_done = 1

    for v in range(3):
        let count = pvget(st, v, PV_COUNT)
        if count == 0:
            continue

        # Take a new event when the last one has run out.
        if pvget(st, v, PV_LEFT) <= 0:
            var cursor = pvget(st, v, PV_CURSOR)
            if cursor >= count:
                if pget(st, PL_LOOP) != 0:
                    cursor = 0
                else:
                    gate_off(st, v)
                    pvput(st, v, PV_COUNT, 0)
                    continue
            let at = (pvget(st, v, PV_FIRST) + cursor) * EVENT_SLOTS
            let n0 = ev[unsafe_offset=at + E_N0]
            pvput(st, v, PV_N0, n0)
            pvput(st, v, PV_N1, ev[unsafe_offset=at + E_N1])
            pvput(st, v, PV_N2, ev[unsafe_offset=at + E_N2])
            pvput(st, v, PV_LEFT, ev[unsafe_offset=at + E_FRAMES])
            pvput(st, v, PV_CURSOR, cursor + 1)
            pvput(st, v, PV_ARP, 0)
            if n0 < 0:
                gate_off(st, v)
            else:
                gate_on(st, v)

        all_done = 0
        # `var`, not `let`: `let` names the storage rather than copying it, so
        # a value read that way reads back changed once the slot is written --
        # and the drum's pitch below is derived from this counter.
        var left = pvget(st, v, PV_LEFT)
        pvput(st, v, PV_LEFT, left - 1)

        let n0 = pvget(st, v, PV_N0)
        if n0 < 0:
            continue

        # The arpeggio. Three notes, one per frame, and the ear hears a chord.
        var note = n0
        let n1 = pvget(st, v, PV_N1)
        if n1 >= 0:
            let n2 = pvget(st, v, PV_N2)
            let width = 3 if n2 >= 0 else 2
            let which = frame % width
            if which == 1:
                note = n1
            elif which == 2:
                note = n2

        var hz = midi_hz(note + piget(st, v, PI_TRANSPOSE))

        # A drum is a note that falls. The chip has no percussion; every C64
        # drum is noise plus a downward sweep, done from up here.
        let drum = piget(st, v, PI_DRUM)
        if drum != 0:
            let age = 0 if left < 0 else (24 - left)
            if age > 0:
                var fall = 1.0
                for _ in range(age):
                    fall *= 0.82
                hz *= fall

        # Vibrato, delayed slightly so short notes stay clean.
        let vib = piget(st, v, PI_VIB)
        if vib != 0:
            let cents = Float64(vib) * _sin(Float64(frame) * 0.55)
            hz *= 1.0 + cents / 1200.0

        set_freq_hz(st, v, hz)

        # Pulse-width modulation: a slow triangle, never reaching the ends,
        # where the wave would go silent.
        let pwm = piget(st, v, PI_PWM)
        if pwm != 0:
            let cycle = (frame * pwm) % 4096
            let sweep = cycle if cycle < 2048 else (4096 - cycle)
            set_pulse_width(st, v, 512 + sweep)

    if all_done != 0:
        pput(st, PL_DONE, 1)


# ── Instruments ─────────────────────────────────────────────────────────────
# Three voices, three jobs. These are the register settings, given names.


fn instrument_lead(st: P, voice: Int):
    set_wave(st, voice, WAVE_PULSE)
    set_adsr(st, voice, 0, 7, 11, 6)
    piput(st, voice, PI_PWM, 7)
    piput(st, voice, PI_VIB, 14)
    route_filter(st, voice, False)


fn instrument_bass(st: P, voice: Int):
    set_wave(st, voice, WAVE_SAW)
    set_adsr(st, voice, 0, 6, 8, 5)
    piput(st, voice, PI_PWM, 0)
    piput(st, voice, PI_VIB, 0)
    route_filter(st, voice, True)


fn instrument_drum(st: P, voice: Int):
    set_wave(st, voice, WAVE_NOISE)
    set_adsr(st, voice, 0, 5, 0, 4)
    piput(st, voice, PI_DRUM, 1)
    piput(st, voice, PI_PWM, 0)
    piput(st, voice, PI_VIB, 0)
    route_filter(st, voice, False)


# ── A tune ──────────────────────────────────────────────────────────────────
# Eight bars in A minor, written the way a C64 tune is written: a bass line in
# eighth notes, chords as arpeggios, and noise on the backbeat.

comptime EIGHTH = 10        # frames -- 50 Hz / 10 = 150 bpm in eighths
comptime QUARTER = 20


def build_demo(st: P) -> Int:
    """Fill a score block and point the three voices at their parts."""
    comptime BARS = 8
    comptime LEAD_EVENTS = BARS * 4
    comptime BASS_EVENTS = BARS * 8
    comptime DRUM_EVENTS = BARS * 4
    let score = score_alloc(LEAD_EVENTS + BASS_EVENTS + DRUM_EVENTS)

    # The chord under each bar: A minor, F, G, A minor, and around again.
    var i = 0
    for bar in range(BARS):
        let which = bar % 4
        var root = 57      # A3
        var third = 60     # C4
        var fifth = 64     # E4
        if which == 1:
            root = 53      # F3
            third = 57
            fifth = 60
        elif which == 2:
            root = 55      # G3
            third = 59
            fifth = 62
        for _ in range(4):
            score_put(score, i, root + 12, third + 12, fifth + 12, QUARTER)
            i += 1
    voice_part(st, 0, 0, LEAD_EVENTS)

    # The bass: root, root, fifth, root -- the pattern every C64 tune uses,
    # because it works and it fits in one voice.
    # `var`, not `let`. `let` names the storage of `i` rather than copying
    # it, so the index recorded here would follow `i` as the loop below
    # advances it -- and voice_part would then be handed 96 instead of 32,
    # pointing this voice at another voice's events and, past the end of the
    # block, at whatever the heap holds. That read is what hung the audio
    # thread: a note of a few billion is an octave loop that never finishes.
    var bass_first = i
    for bar in range(BARS):
        let which = bar % 4
        var root = 33      # A1
        var fifth = 40     # E2
        if which == 1:
            root = 29      # F1
            fifth = 36
        elif which == 2:
            root = 31      # G1
            fifth = 38
        for step in range(8):
            var n = root
            if step == 2 or step == 6:
                n = fifth
            elif step == 5:
                n = root + 12
            score_put(score, i, n, -1, -1, EIGHTH)
            i += 1
    voice_part(st, 1, bass_first, BASS_EVENTS)

    # Drums: a hit on two and four, a rest between.
    var drum_first = i
    for _ in range(BARS):
        score_put(score, i, -1, -1, -1, QUARTER)
        i += 1
        score_put(score, i, 69, -1, -1, QUARTER)
        i += 1
        score_put(score, i, -1, -1, -1, QUARTER)
        i += 1
        score_put(score, i, 71, -1, -1, QUARTER)
        i += 1
    voice_part(st, 2, drum_first, DRUM_EVENTS)

    instrument_lead(st, 0)
    instrument_bass(st, 1)
    instrument_drum(st, 2)
    set_filter(st, 1100, 9, FILT_LP)
    player_attach(st, score, True)
    return score
