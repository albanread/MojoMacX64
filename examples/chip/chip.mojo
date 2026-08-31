# A 6581-flavoured synthesiser: three voices, ADSR, a resonant filter.
#
# Not an emulator. rechip exists, it is cycle-exact, and it is thousands of
# lines of measured analogue behaviour. This is the other thing -- the
# arithmetic that gives the 6581 its voice, written plainly, small enough to
# read in one sitting and fast enough to run under a real-time deadline.
#
# What makes it sound like a chip rather than like a generic synth:
#
#   * the oscillators are 24-bit phase accumulators, so the pitch drifts in
#     the same quantised way and the waveforms have the same hard edges
#   * the noise is the actual 23-bit LFSR with the actual output taps, which
#     is why it rasps instead of hissing
#   * the envelope decays by the chip's period-stretching table rather than
#     by an exponential curve, which is the difference between a C64 snare
#     and a beep
#   * the pulse width is a register you are expected to modulate every frame
#
# The chip is integer hardware, so this is integer arithmetic. The only
# floating point is the filter and the final sample.
#
# All state lives in one flat block, because that is what a chip is: a bank
# of registers plus some internal counters. The block is passed to the render
# callback through CoreAudio's inRefCon, so nothing here needs a global and
# two chips could run at once.

from std.memory import Pointer, MutUntrackedOrigin, OpaquePointer
from std.ffi import external_call

comptime P = OpaquePointer[MutUntrackedOrigin]

# The PAL machine's clock. Every frequency register in every chip tune ever
# written was chosen against this number.
comptime CLOCK_PAL = 985248
comptime SAMPLE_RATE = 48000

# A frame is one turn of the player routine: 50 Hz, the vertical blank the
# interrupt hung off. Every C64 tune is written in these units.
comptime FRAME_SAMPLES = SAMPLE_RATE // 50

comptime WAVE_TRI = 1
comptime WAVE_SAW = 2
comptime WAVE_PULSE = 4
comptime WAVE_NOISE = 8

comptime FILT_LP = 1
comptime FILT_BP = 2
comptime FILT_HP = 4

comptime ENV_IDLE = 0
comptime ENV_ATTACK = 1
comptime ENV_DECAY = 2
comptime ENV_SUSTAIN = 3
comptime ENV_RELEASE = 4

# ── The state block ─────────────────────────────────────────────────────────
# Slot indices into one calloc'd array of Int64. Chip state, addressed the way
# a chip is addressed. The float slots are the same memory read through a
# Float64 view; they are numbered apart so the two views never collide.

comptime S_TICK = 0        # samples left until the next 50 Hz frame
comptime S_CUTOFF = 1      # 11-bit filter cutoff register
comptime S_RES = 2         # 4-bit resonance
comptime S_FMODE = 3       # FILT_LP | FILT_BP | FILT_HP
comptime S_VOL = 4         # 4-bit master volume
comptime S_FRAME = 5       # frames elapsed since the chip was made
comptime S_DIRTY = 6       # filter coefficients need recomputing

comptime S_LOW = 8         # float: filter lowpass state
comptime S_BAND = 9        # float: filter bandpass state
comptime S_F = 10          # float: filter frequency coefficient
comptime S_Q = 11          # float: filter damping

comptime V_BASE = 16
comptime V_STRIDE = 16
comptime V_ACC = 0         # phase accumulator, 24 bits with 8 fractional
comptime V_STEP = 1        # per-sample increment, same fixed point
comptime V_PW = 2          # 12-bit pulse width
comptime V_WAVE = 3        # waveform bits
comptime V_GATE = 4
comptime V_AINC = 5        # envelope increments, 16.16 fixed point
comptime V_DINC = 6
comptime V_SUS = 7         # sustain level, 0..255
comptime V_RINC = 8
comptime V_ENV = 9         # envelope level, 16.16 fixed point
comptime V_PHASE = 10
comptime V_LFSR = 11
comptime V_RING = 12       # ring-modulate voice n by voice n-1
comptime V_SYNC = 13       # hard-sync voice n to voice n-1
comptime V_FILT = 14       # route this voice through the filter
comptime V_PREV = 15       # last accumulator, for edge detection

comptime STATE_SLOTS = V_BASE + 3 * V_STRIDE

# The player routine, as a type: a C function pointer taking the chip. The
# alias is needed because `fn(...)` is only spelled this way in a type
# position the parser recognises as one.
comptime Tick = fn(P, /) -> None

# The player routine keeps its own state after the chip's.
comptime PLAYER_BASE = STATE_SLOTS
comptime PLAYER_SLOTS = 96
comptime TOTAL_SLOTS = PLAYER_BASE + PLAYER_SLOTS


@always_inline
fn ints(st: P) -> Pointer[Int, MutUntrackedOrigin]:
    return st.unsafe_bitcast[Int]()


@always_inline
fn floats(st: P) -> Pointer[Float64, MutUntrackedOrigin]:
    return st.unsafe_bitcast[Float64]()


@always_inline
fn get(st: P, slot: Int) -> Int:
    return ints(st)[unsafe_offset=slot]


@always_inline
fn put(st: P, slot: Int, value: Int):
    ints(st)[unsafe_offset=slot] = value


@always_inline
fn fget(st: P, slot: Int) -> Float64:
    return floats(st)[unsafe_offset=slot]


@always_inline
fn fput(st: P, slot: Int, value: Float64):
    floats(st)[unsafe_offset=slot] = value


@always_inline
fn vget(st: P, voice: Int, field: Int) -> Int:
    return ints(st)[unsafe_offset=V_BASE + voice * V_STRIDE + field]


@always_inline
fn vput(st: P, voice: Int, field: Int, value: Int):
    ints(st)[unsafe_offset=V_BASE + voice * V_STRIDE + field] = value


fn chip_new() -> P:
    """Allocate a chip and set it to a sane silence."""
    let st = external_call["calloc", P](Int(TOTAL_SLOTS), Int(8))
    put(st, S_VOL, 15)
    put(st, S_CUTOFF, 1024)
    put(st, S_RES, 0)
    put(st, S_FMODE, FILT_LP)
    put(st, S_DIRTY, 1)
    put(st, S_TICK, FRAME_SAMPLES)
    for v in range(3):
        # The LFSR must not start at zero: all-zeroes is a fixed point of the
        # shift, and the noise would be silence forever.
        vput(st, v, V_LFSR, 0x7FFFF8)
        vput(st, v, V_PW, 2048)
        vput(st, v, V_WAVE, WAVE_PULSE)
        set_adsr(st, v, 0, 9, 0, 9)
    return st


fn chip_free(st: P):
    external_call["free", NoneType](st)


# ── Registers ───────────────────────────────────────────────────────────────
# The interface a player routine pokes. These take the same numbers a C64
# player would write, so a tune ported from real chip data keeps its values.


@always_inline
fn set_freq_reg(st: P, voice: Int, freq: Int):
    """The 16-bit frequency register, meaning freq * CLOCK / 2^24 Hz.

    The accumulator is stepped once per output sample rather than once per
    chip cycle, so the register is converted here: eight fractional bits of
    headroom keep the pitch exact instead of a few cents flat in the high
    octaves, where the rounding error would otherwise be audible.
    """
    vput(st, voice, V_STEP, (freq * CLOCK_PAL * 256) // SAMPLE_RATE)


@always_inline
fn set_freq_hz(st: P, voice: Int, hz: Float64):
    """The same thing in Hz, for tunes that were never chip data."""
    set_freq_reg(st, voice, Int(hz * 16777216.0 / Float64(CLOCK_PAL)))


@always_inline
fn set_pulse_width(st: P, voice: Int, pw: Int):
    vput(st, voice, V_PW, pw & 0xFFF)


@always_inline
fn set_wave(st: P, voice: Int, wave: Int):
    vput(st, voice, V_WAVE, wave)


# The chip's attack times in milliseconds, 0..15. Decay and release run three
# times slower for the same index, which is why a C64 bass can have a snap on
# the front and still ring for half a second.
@always_inline
fn attack_ms(index: Int) -> Int:
    if index == 0: return 2
    if index == 1: return 8
    if index == 2: return 16
    if index == 3: return 24
    if index == 4: return 38
    if index == 5: return 56
    if index == 6: return 68
    if index == 7: return 80
    if index == 8: return 100
    if index == 9: return 250
    if index == 10: return 500
    if index == 11: return 800
    if index == 12: return 1000
    if index == 13: return 3000
    if index == 14: return 5000
    return 8000


@always_inline
fn rate_increment(ms: Int) -> Int:
    """Envelope steps per sample, 16.16 fixed point, for a full 0..255 sweep.

    Clamped to at least one so the shortest attack still moves; a zero here
    would hang the envelope in its attack phase and the voice would never
    sound.
    """
    let samples = (ms * SAMPLE_RATE) // 1000
    if samples < 1:
        return 255 << 16
    let inc = (255 << 16) // samples
    return 1 if inc < 1 else inc


fn set_adsr(st: P, voice: Int, a: Int, d: Int, s: Int, r: Int):
    """Attack, decay, sustain, release as the chip's 4-bit register values."""
    vput(st, voice, V_AINC, rate_increment(attack_ms(a)))
    vput(st, voice, V_DINC, rate_increment(attack_ms(d) * 3))
    vput(st, voice, V_SUS, (s & 15) * 17)  # 4 bits scaled to 0..255
    vput(st, voice, V_RINC, rate_increment(attack_ms(r) * 3))


@always_inline
fn gate_on(st: P, voice: Int):
    vput(st, voice, V_GATE, 1)
    vput(st, voice, V_PHASE, ENV_ATTACK)


@always_inline
fn gate_off(st: P, voice: Int):
    vput(st, voice, V_GATE, 0)
    vput(st, voice, V_PHASE, ENV_RELEASE)


@always_inline
fn set_filter(st: P, cutoff: Int, res: Int, mode: Int):
    put(st, S_CUTOFF, cutoff & 0x7FF)
    put(st, S_RES, res & 15)
    put(st, S_FMODE, mode)
    put(st, S_DIRTY, 1)


@always_inline
fn route_filter(st: P, voice: Int, on: Bool):
    vput(st, voice, V_FILT, 1 if on else 0)


@always_inline
fn set_volume(st: P, vol: Int):
    put(st, S_VOL, vol & 15)


# ── Oscillator ──────────────────────────────────────────────────────────────


@always_inline
fn _sin(x: Float64) -> Float64:
    """Sine by series.

    std.math.sin is a `def`, and a `def` may raise. The render callback is an
    `fn` -- non-raising, C-callable -- so it cannot call one. Nine terms is
    far more than a filter coefficient needs.
    """
    # Range reduction in one step, not a loop. Subtracting 2*pi until the
    # argument lands in range is harmless for a filter coefficient and quietly
    # ruinous for vibrato: that argument grows with the frame counter, so the
    # loop gets one iteration longer every fifty frames -- on the audio
    # thread, where the cost eventually shows up as a dropout and never as an
    # error.
    let turns = x * 0.15915494309189535     # 1 / 2*pi
    var t = x - 6.283185307179586 * Float64(Int(turns))
    if t > 3.141592653589793:
        t -= 6.283185307179586
    elif t < -3.141592653589793:
        t += 6.283185307179586
    let t2 = t * t
    var term = t
    var sum = t
    var k = 1
    while k < 9:
        term *= -t2 / Float64((2 * k) * (2 * k + 1))
        sum += term
        k += 1
    return sum


@always_inline
fn waveform(st: P, voice: Int, acc24: Int, ring_source_msb: Int) -> Int:
    """The 12-bit output of one voice's waveform selector.

    Selecting more than one waveform ANDs them together on the real chip --
    an accident of how the outputs are wired, not a design, and the source of
    most of the timbres people remember. The AND is faithful; what it cannot
    reproduce is that the real result also sags with the analogue behaviour
    of the output stage, so combined waveforms here are brighter than a 6581's.
    """
    let wave = vget(st, voice, V_WAVE)
    var out = 0xFFF

    if (wave & WAVE_TRI) != 0:
        # The triangle folds the top bit into the rest, and ring modulation
        # replaces that bit with the previous voice's -- which is the whole
        # of ring modulation on this chip. One XOR, and it is why bells
        # and gongs sound the way they do.
        var folded = acc24
        if ((acc24 ^ ring_source_msb) & 0x800000) != 0:
            folded = (~acc24) & 0xFFFFFF
        out &= (folded >> 11) & 0xFFF

    if (wave & WAVE_SAW) != 0:
        out &= (acc24 >> 12) & 0xFFF

    if (wave & WAVE_PULSE) != 0:
        out &= 0xFFF if ((acc24 >> 12) >= vget(st, voice, V_PW)) else 0

    if (wave & WAVE_NOISE) != 0:
        let lfsr = vget(st, voice, V_LFSR)
        # Eight taps, scattered: bits 22, 20, 16, 13, 11, 7, 4 and 2 become
        # the output's bits 11 down to 4. The low four bits are always zero,
        # which is part of why the noise sounds coarse.
        out &= (
            ((lfsr >> 11) & 0x800)
            | ((lfsr >> 10) & 0x400)
            | ((lfsr >> 7) & 0x200)
            | ((lfsr >> 5) & 0x100)
            | ((lfsr >> 4) & 0x080)
            | ((lfsr >> 1) & 0x040)
            | ((lfsr << 1) & 0x020)
            | ((lfsr << 2) & 0x010)
        )

    if wave == 0:
        return 0
    return out


@always_inline
fn advance_envelope(st: P, voice: Int) -> Int:
    """One sample of the envelope. Returns the level, 0..255.

    The decay and release are not exponential curves. The chip counts down at
    a rate that is divided further as the level falls -- once below 93, then
    54, 26, 14 and 6 -- so the tail flattens in five visible steps. Replacing
    that with a smooth exponential is the single change that makes this
    sound like a synthesiser instead of a games machine.
    """
    let phase = vget(st, voice, V_PHASE)
    if phase == ENV_IDLE:
        return 0

    var env = vget(st, voice, V_ENV)

    if phase == ENV_ATTACK:
        # The attack is linear. Only the falling phases are stretched.
        env += vget(st, voice, V_AINC)
        if env >= (255 << 16):
            env = 255 << 16
            vput(st, voice, V_PHASE, ENV_DECAY)
    elif phase == ENV_DECAY or phase == ENV_RELEASE:
        let level = env >> 16
        var divisor = 1
        if level <= 6:
            divisor = 30
        elif level <= 14:
            divisor = 16
        elif level <= 26:
            divisor = 8
        elif level <= 54:
            divisor = 4
        elif level <= 93:
            divisor = 2
        let step = vget(st, voice, V_DINC if phase == ENV_DECAY else V_RINC)
        env -= step // divisor
        if phase == ENV_DECAY:
            let floor_level = vget(st, voice, V_SUS) << 16
            if env <= floor_level:
                env = floor_level
                vput(st, voice, V_PHASE, ENV_SUSTAIN)
        else:
            if env <= 0:
                env = 0
                vput(st, voice, V_PHASE, ENV_IDLE)

    vput(st, voice, V_ENV, env)
    return env >> 16


fn chip_render(
    st: P,
    dest: Pointer[Float32, MutUntrackedOrigin],
    frames: Int,
    tick: Tick,
):
    """Fill `frames` samples, running the player routine every 50 Hz frame.

    `tick` is a plain C function pointer, so the chip never has to know what
    a tune is -- and the player routine gets called from inside the audio
    callback, on the beat, exactly as a raster interrupt would have.
    """
    if get(st, S_DIRTY) != 0:
        recompute_filter(st)

    for i in range(frames):
        # The 50 Hz frame boundary. A real machine got here by interrupt; the
        # arithmetic is the same either way.
        var countdown = get(st, S_TICK) - 1
        if countdown <= 0:
            countdown = FRAME_SAMPLES
            put(st, S_FRAME, get(st, S_FRAME) + 1)
            tick(st)
            if get(st, S_DIRTY) != 0:
                recompute_filter(st)
        put(st, S_TICK, countdown)

        var dry = 0.0
        var wet = 0.0

        for v in range(3):
            let step = vget(st, voice=v, field=V_STEP)
            # A copy: this is read before V_ACC is written below.
            var prev = vget(st, voice=v, field=V_ACC)
            var acc = (prev + step) & 0xFFFFFFFF

            # Hard sync: when the previous voice's accumulator wraps, this one
            # is slammed back to zero. Two oscillators at unrelated pitches,
            # one resetting the other, is the chip lead sound.
            if vget(st, voice=v, field=V_SYNC) != 0:
                let src = (v + 2) % 3
                let s_now = (vget(st, voice=src, field=V_ACC) >> 8) & 0xFFFFFF
                let s_was = (vget(st, voice=src, field=V_PREV) >> 8) & 0xFFFFFF
                if s_now < s_was:
                    acc = 0

            let acc24 = (acc >> 8) & 0xFFFFFF
            let was24 = (prev >> 8) & 0xFFFFFF

            # The noise register shifts once per rising edge of accumulator
            # bit 19 -- so noise pitch follows the frequency register, and a
            # rising noise sweep is a rising frequency, not a filter.
            if (was24 & 0x80000) == 0 and (acc24 & 0x80000) != 0:
                let lfsr = vget(st, voice=v, field=V_LFSR)
                let feedback = ((lfsr >> 22) ^ (lfsr >> 17)) & 1
                vput(st, voice=v, field=V_LFSR,
                     value=((lfsr << 1) | feedback) & 0x7FFFFF)

            vput(st, voice=v, field=V_PREV, value=prev)
            vput(st, voice=v, field=V_ACC, value=acc)

            var ring_msb = 0
            if vget(st, voice=v, field=V_RING) != 0:
                ring_msb = (vget(st, voice=(v + 2) % 3, field=V_ACC) >> 8) & 0xFFFFFF

            let w = waveform(st, v, acc24, ring_msb)
            let env = advance_envelope(st, v)
            # Centre the waveform before the envelope scales it, or every
            # note-on would put a step of DC through the filter.
            let sample = Float64((w - 2048) * env) / 255.0
            if vget(st, voice=v, field=V_FILT) != 0:
                wet += sample
            else:
                dry += sample

        # A two-pole state-variable filter. The 6581's is analogue, and its
        # curve famously varies between individual chips; this is the honest
        # digital equivalent rather than a model of any particular one.
        let f = fget(st, S_F)
        let q = fget(st, S_Q)
        var low = fget(st, S_LOW)
        var band = fget(st, S_BAND)
        low += f * band
        let high = wet - low - q * band
        band += f * high
        fput(st, S_LOW, low)
        fput(st, S_BAND, band)

        let mode = get(st, S_FMODE)
        var filtered = 0.0
        if (mode & FILT_LP) != 0:
            filtered += low
        if (mode & FILT_BP) != 0:
            filtered += band
        if (mode & FILT_HP) != 0:
            filtered += high

        # Three voices at full envelope reach 3 * 2048; the divisor leaves
        # headroom for the filter's resonant peak, which can exceed the input.
        let mixed = (dry + filtered) * Float64(get(st, S_VOL)) / 15.0
        var value = mixed / 8192.0
        if value > 1.0:
            value = 1.0
        elif value < -1.0:
            value = -1.0
        dest[unsafe_offset=i] = Float32(value)


fn recompute_filter(st: P):
    """Turn the cutoff and resonance registers into filter coefficients.

    The 6581's cutoff curve is notoriously non-linear and differs chip to
    chip, so there is no correct mapping to reproduce -- this is a plain
    linear sweep across the range the chip covers.
    """
    let cutoff = get(st, S_CUTOFF)
    let hz = 200.0 + Float64(cutoff) * 5.8
    var f = 2.0 * _sin(3.141592653589793 * hz / Float64(SAMPLE_RATE))
    if f > 1.4:
        f = 1.4
    fput(st, S_F, f)
    # Resonance 0..15 maps to damping 1.4 down to 0.1: higher resonance is
    # less damping, and the filter rings.
    fput(st, S_Q, 1.4 - Float64(get(st, S_RES)) * 0.086)
    put(st, S_DIRTY, 0)
