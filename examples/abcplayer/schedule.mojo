# Turning a tune into a list of things to do at exact sample times.
#
# This is where the timing claim is either true or not. A tick is an exact
# integer; a sample is an exact integer; the conversion between them is one
# multiply and one divide in 64-bit, rounded once. Nothing accumulates.
#
# The alternative -- the one their C++ uses and the one most players use -- is
# to work in seconds as doubles and sleep until each event is due:
#
#     std::this_thread::sleep_until(start + seconds(event_time));
#
# That asks the operating system to wake a thread at a moment, which it will
# do late by whatever the scheduler is busy with: a millisecond or two idle,
# tens under load. At 120bpm a semiquaver is 125 ms, so a 5 ms error is 4% of
# a note -- audible as looseness, and worse, it varies. Scheduling by sample
# index instead means an event lands on the sample it was written for, and the
# only jitter left is the buffer boundary, which the callback already knows
# about and can subtract exactly.

from model import (
    Tune, Event, EV_NOTE, EV_REST, EV_BAR, F_TIE, F_CHORD, F_GRACE,
    TICKS_PER_WHOLE,
)

comptime SE_NOTE_ON = 0
comptime SE_NOTE_OFF = 1


@fieldwise_init
struct Step(ImplicitlyCopyable, Copyable, Movable):
    """One thing to do, at one sample."""

    var sample: Int
    var kind: Int
    var voice: Int
    var midi: Int
    var velocity: Int


fn ticks_per_beat(tune: Tune) -> Int:
    """How many ticks the tempo's beat lasts. Q:1/4=120 makes this 480."""
    var t = (TICKS_PER_WHOLE * tune.tempo_num) // tune.tempo_den
    if t < 1:
        t = 1
    return t


fn tick_to_sample(tick: Int, bpm: Int, per_beat: Int, sample_rate: Int) -> Int:
    """Exact, and rounded once at the end rather than accumulated.

    sample = tick * (60 / bpm) * sample_rate / ticks_per_beat, done as one
    integer expression. The numerator is at most a few times 10^12 for any
    real tune, which is comfortably inside 64 bits.
    """
    let denom = bpm * per_beat
    if denom <= 0:
        return 0
    return (tick * sample_rate * 60 + denom // 2) // denom


def resolve_ties(mut tune: Tune):
    """Join a tied note to the note it is tied to.

    A tie means one sound, not two: the second note is not struck. Extending
    the first and dropping the second is what makes `C-C` a half note and not
    two quarters with a seam.
    """
    for i in range(len(tune.events)):
        if tune.events[i].kind != EV_NOTE:
            continue
        if (tune.events[i].flags & F_TIE) == 0:
            continue
        let voice = tune.events[i].voice
        let pitch = tune.events[i].midi
        let end = tune.events[i].tick + tune.events[i].duration
        # The next note of the same pitch in the same voice, if it starts
        # exactly where this one ends.
        for j in range(i + 1, len(tune.events)):
            if tune.events[j].kind != EV_NOTE:
                continue
            if tune.events[j].voice != voice:
                continue
            if tune.events[j].tick < end:
                continue
            if tune.events[j].tick > end:
                break
            if tune.events[j].midi == pitch:
                var held = tune.events[i].duration
                tune.events[i].duration = held + tune.events[j].duration
                # Silenced rather than removed: removing it would move every
                # index after it, and the outer loop is holding one.
                tune.events[j].velocity = 0
                tune.events[i].flags = tune.events[i].flags & ~F_TIE
            break


def build_schedule(tune: Tune, sample_rate: Int, mut steps: List[Step]):
    """Every note-on and note-off, in time order, in samples."""
    let per_beat = ticks_per_beat(tune)
    let bpm = tune.tempo_bpm if tune.tempo_bpm > 0 else 120

    for i in range(len(tune.events)):
        let ev = tune.events[i]
        if ev.kind != EV_NOTE:
            continue
        if ev.velocity <= 0:
            continue                     # swallowed by a tie
        let on = tick_to_sample(ev.tick, bpm, per_beat, sample_rate)
        var off_tick = ev.tick + ev.duration
        # Lift the note a little early so repeated pitches are re-struck
        # rather than running together. A twentieth of the note, capped, is
        # about what a player does without thinking about it.
        var gap = ev.duration // 20
        let max_gap = per_beat // 16
        if gap > max_gap:
            gap = max_gap
        if gap > 0 and ev.duration > gap:
            off_tick -= gap
        let off = tick_to_sample(off_tick, bpm, per_beat, sample_rate)
        steps.append(Step(
            sample=on, kind=SE_NOTE_ON, voice=ev.voice,
            midi=ev.midi, velocity=ev.velocity,
        ))
        steps.append(Step(
            sample=off if off > on else on + 1, kind=SE_NOTE_OFF,
            voice=ev.voice, midi=ev.midi, velocity=0,
        ))

    sort_steps(steps)


def sort_steps(mut steps: List[Step]):
    """Merge sort by sample, with note-off before note-on at the same instant.

    The tie-break matters: when one note ends exactly as another begins on the
    same voice, releasing first leaves the voice free for the new note. The
    other order steals a voice that is about to be freed and drops a note.
    """
    let n = len(steps)
    if n < 2:
        return
    var scratch = List[Step]()
    for i in range(n):
        scratch.append(steps[i])

    var width = 1
    while width < n:
        var lo = 0
        while lo < n:
            let mid = lo + width if lo + width < n else n
            let hi = lo + 2 * width if lo + 2 * width < n else n
            var a = lo
            var b = mid
            var k = lo
            while a < mid and b < hi:
                if step_before(steps[a], steps[b]):
                    scratch[k] = steps[a]
                    a += 1
                else:
                    scratch[k] = steps[b]
                    b += 1
                k += 1
            while a < mid:
                scratch[k] = steps[a]
                a += 1
                k += 1
            while b < hi:
                scratch[k] = steps[b]
                b += 1
                k += 1
            lo += 2 * width
        for i in range(n):
            steps[i] = scratch[i]
        width *= 2


@always_inline
fn step_before(a: Step, b: Step) -> Bool:
    if a.sample != b.sample:
        return a.sample < b.sample
    return a.kind > b.kind          # NOTE_OFF (1) sorts before NOTE_ON (0)
