# The music-line parser: the half of ABC that is not headers.
#
# This is the part with the sharp edges. The notation is terse, ambiguous in
# places, and every real tune uses the ambiguous parts:
#
#   * `(` opens a slur, unless a digit follows, in which case it opens a
#     tuplet and the digit is part of it
#   * `[` opens a chord, unless the second character is a letter and the third
#     a colon, in which case it is an inline field
#   * `|` is a bar line, unless a digit follows, in which case it is also the
#     start of a first or second ending
#   * an accidental holds for the rest of the bar, so the second F in
#     `^F A F` is also sharp -- and the third F, in the next bar, is not
#
# That last rule is the one worth being careful about. It is what makes ABC
# readable to a musician, and a parser that skips it plays wrong notes in
# roughly every tune that has an accidental in it.

from model import (
    Tune, Event, Voice, TICKS_PER_QUARTER, TICKS_PER_WHOLE,
    EV_NOTE, EV_REST, EV_BAR, EV_TEMPO, EV_KEY, EV_METER, EV_VOICE,
    F_CHORD, F_TIE, F_GRACE, F_GCHORD,
    BAR_SINGLE, BAR_DOUBLE, BAR_REPEAT_START, BAR_REPEAT_END,
    BAR_ENDING_1, BAR_ENDING_2, BAR_THIN_THICK,
    letter_index, letter_semitone, key_alter, key_sharps_for, midi_for,
    configured_voice,
)

comptime NO_ACCIDENTAL = 99
comptime GCHORD_VOICE_BASE = 100


struct MusicCtx(Copyable, Movable):
    """What the parser has to remember between characters, and between lines.

    `bar_acc` is the accidental state for the current bar: one entry per
    letter, NO_ACCIDENTAL when the key signature governs.
    """

    var voice: Int
    var bar_acc: Int           # seven 4-bit fields, one per letter
    var tuplet_left: Int       # notes still inside a tuplet
    var tuplet_num: Int        # each of them lasts num/den of its written value
    var tuplet_den: Int
    var broken: Int            # >0 after '>', <0 after '<', magnitude = count
    var in_grace: Bool
    var last_note: Int         # index in tune.events of the last note emitted
    var gchord_root: Int       # the chord symbol in force, or -1
    var gchord_kind: Int

    fn __init__(out self):
        self.voice = 1
        self.bar_acc = 0
        self.tuplet_left = 0
        self.tuplet_num = 1
        self.tuplet_den = 1
        self.broken = 0
        self.in_grace = False
        self.last_note = -1
        self.gchord_root = -1
        self.gchord_kind = 0

    fn clear_bar(mut self):
        self.bar_acc = 0

    fn acc_of(self, letter: Int) -> Int:
        """The accidental in force for a letter this bar, or NO_ACCIDENTAL."""
        let nib = (self.bar_acc >> (letter * 4)) & 0xF
        return NO_ACCIDENTAL if nib == 0 else nib - 8

    fn set_acc(mut self, letter: Int, alter: Int):
        # Biased by 8 so that zero can mean "nothing set": a natural sign is
        # an accidental too, and storing it as 0 would erase it.
        let nib = (alter + 8) & 0xF
        self.bar_acc = (self.bar_acc & ~(0xF << (letter * 4))) | (
            nib << (letter * 4)
        )


@always_inline
fn is_digit(c: Int) -> Bool:
    return c >= 48 and c <= 57


@always_inline
fn is_note_letter(c: Int) -> Bool:
    return (c >= 65 and c <= 71) or (c >= 97 and c <= 103)


def read_int(line: String, start: Int) -> List[Int]:
    """A run of digits. Returns [value, next, found]."""
    let b = line.as_bytes()
    var i = start
    var v = 0
    var found = 0
    while i < len(b) and is_digit(Int(b[i])):
        v = v * 10 + (Int(b[i]) - 48)
        i += 1
        found = 1
    var out = List[Int]()
    out.append(v)
    out.append(i)
    out.append(found)
    return out^


def read_duration(line: String, start: Int, unit_ticks: Int) -> List[Int]:
    """The length that follows a note, rest or chord. Returns [ticks, next].

    ABC writes a multiplier, a divisor after `/`, or both: `A2`, `A/2`, `A/`,
    `A//`, `A3/2`. A bare `/` halves, and each extra `/` halves again.
    """
    var i = start
    var mul = 1
    var div = 1

    let m = read_int(line, i)
    if m[2] != 0:
        mul = m[0]
        i = m[1]

    let b = line.as_bytes()
    while i < len(b) and Int(b[i]) == 47:      # '/'
        i += 1
        let d = read_int(line, i)
        if d[2] != 0:
            div *= d[0]
            i = d[1]
        else:
            div *= 2

    var ticks = (unit_ticks * mul) // div
    if ticks < 1:
        ticks = 1
    var out = List[Int]()
    out.append(ticks)
    out.append(i)
    return out^


def read_note(
    line: String, start: Int, mut ctx: MusicCtx, key_sharps: Int,
    transpose: Int, octave_shift: Int,
) -> List[Int]:
    """One note's pitch. Returns [ok, midi, next].

    Accidentals are applied and recorded: an explicit one governs the rest of
    the bar for that letter, and in its absence the key signature governs.
    """
    let b = line.as_bytes()
    var i = start
    var alter = NO_ACCIDENTAL

    # ^ and _ may be doubled; = cancels.
    while i < len(b):
        let c = Int(b[i])
        if c == 94:            # ^
            alter = 1 if alter == NO_ACCIDENTAL else alter + 1
            i += 1
        elif c == 95:          # _
            alter = -1 if alter == NO_ACCIDENTAL else alter - 1
            i += 1
        elif c == 61:          # =
            alter = 0
            i += 1
        else:
            break

    var out = List[Int]()
    if i >= len(b) or not is_note_letter(Int(b[i])):
        out.append(0)
        out.append(0)
        out.append(start + 1)
        return out^

    let c = Int(b[i])
    var upper = c
    var octave = 5             # ABC's C is middle C, MIDI 60
    if c >= 97:
        upper = c - 32
        octave = 6
    let letter = letter_index(upper)
    i += 1

    while i < len(b):
        let m = Int(b[i])
        if m == 39:            # ' raises an octave
            octave += 1
            i += 1
        elif m == 44:          # , lowers one
            octave -= 1
            i += 1
        else:
            break

    if alter != NO_ACCIDENTAL:
        ctx.set_acc(letter, alter)
    var applied = key_alter(key_sharps, letter)
    let held = ctx.acc_of(letter)
    if held != NO_ACCIDENTAL:
        applied = held

    out.append(1)
    out.append(midi_for(letter, octave + octave_shift, applied, transpose))
    out.append(i)
    return out^


fn chord_intervals(kind: Int, index: Int) -> Int:
    """Semitones above the root for a chord symbol's third and fifth.

    Only the shapes that change which notes sound: major, minor, diminished,
    augmented, and the sevenths built on them.
    """
    # kind: 0 maj, 1 min, 2 dim, 3 aug, 4 dom7, 5 min7, 6 maj7
    if index == 0:
        return 0
    if index == 1:
        if kind == 1 or kind == 2 or kind == 5:
            return 3
        return 4
    if index == 2:
        if kind == 2:
            return 6
        if kind == 3:
            return 8
        return 7
    # The seventh, when there is one.
    if kind == 4 or kind == 5:
        return 10
    if kind == 6:
        return 11
    return -1


def parse_chord_symbol(text: String) -> List[Int]:
    """A "Am7" style symbol. Returns [ok, root_midi, kind]."""
    var out = List[Int]()
    let b = text.as_bytes()
    if len(b) == 0:
        out.append(0)
        out.append(0)
        out.append(0)
        return out^
    var tonic = Int(b[0])
    if tonic >= 97 and tonic <= 122:
        tonic -= 32
    let letter = letter_index(tonic)
    if letter < 0:
        out.append(0)
        out.append(0)
        out.append(0)
        return out^

    var i = 1
    var alter = 0
    if i < len(b) and Int(b[i]) == 35:        # #
        alter = 1
        i += 1
    elif i < len(b) and Int(b[i]) == 98:      # b
        alter = -1
        i += 1

    var rest = String("")
    for k in range(i, len(b)):
        let c = Int(b[k])
        rest += chr(c + 32 if c >= 65 and c <= 90 else c)

    var kind = 0
    if rest.startswith("maj7"):
        kind = 6
    elif rest.startswith("m7") or rest.startswith("min7"):
        kind = 5
    elif rest.startswith("dim"):
        kind = 2
    elif rest.startswith("aug") or rest.startswith("+"):
        kind = 3
    elif rest.startswith("m") and not rest.startswith("maj"):
        kind = 1
    elif rest.startswith("7"):
        kind = 4

    # Root in the octave below middle C, where an accompaniment belongs.
    out.append(1)
    out.append(midi_for(letter, 4, alter, 0))
    out.append(kind)
    return out^


fn tuplet_default_den(p: Int, compound: Bool) -> Int:
    """How many notes' worth of time a `(p` tuplet occupies.

    The defaults are ABC's own, and they depend on the meter: in compound
    time a (3 is still three in the time of two, but (5, (7 and (9 change.
    """
    if p == 2: return 3
    if p == 3: return 2
    if p == 4: return 3
    if p == 6: return 2
    if p == 8: return 3
    if p == 5 or p == 7 or p == 9:
        return 3 if compound else 2
    return 2


def parse_music_line(line: String, mut tune: Tune, mut ctx: MusicCtx):
    """Read one line of music, appending events to the tune."""
    let b = line.as_bytes()
    let n = len(b)
    var i = 0

    while i < n:
        let c = Int(b[i])

        if c == 32 or c == 9:
            i += 1
            continue
        if c == 37:                      # % comment
            break
        if c == 92:                      # \ line continuation
            i += 1
            continue

        var vi = tune.ensure_voice(ctx.voice)

        # ── Inline field, chord, or ending ──────────────────────────────────
        if c == 91:                      # [
            if i + 2 < n and Int(b[i + 2]) == 58:      # [X:...]
                var close = i + 3
                while close < n and Int(b[close]) != 93:
                    close += 1
                let field = Int(b[i + 1])
                var value = String("")
                for k in range(i + 3, close):
                    value += chr(Int(b[k]))
                # Parsed here, applied here: the parse returns numbers so
                # that nothing has to hand `mut tune` to another function.
                let setting = parse_inline_field(field, String(value.strip()))
                if setting[0] == 1:              # V:
                    ctx.voice = setting[1]
                    _ = tune.ensure_voice(ctx.voice)
                    ctx.clear_bar()
                elif setting[0] == 2:            # K:
                    let kv = tune.ensure_voice(ctx.voice)
                    tune.voices[kv].key_sharps = setting[1]
                    ctx.clear_bar()
                elif setting[0] == 3:            # L:
                    let lv = tune.ensure_voice(ctx.voice)
                    tune.voices[lv].unit_num = setting[1]
                    tune.voices[lv].unit_den = setting[2]
                elif setting[0] == 4:            # M:
                    let mv = tune.ensure_voice(ctx.voice)
                    tune.voices[mv].meter_num = setting[1]
                    tune.voices[mv].meter_den = setting[2]
                elif setting[0] == 5:            # Q:
                    tune.tempo_bpm = setting[1]
                    tune.tempo_num = setting[2]
                    tune.tempo_den = setting[3]
                i = close + 1 if close < n else n
                continue
            if i + 1 < n and is_digit(Int(b[i + 1])):  # [1 or [2 -- an ending
                let e = read_int(line, i + 1)
                tune.events.append(Event(
                    kind=EV_BAR, voice=ctx.voice, tick=tune.voices[vi].tick,
                    duration=0, midi=0, velocity=0,
                    aux=BAR_ENDING_1 if e[0] == 1 else BAR_ENDING_2, flags=0,
                ))
                ctx.clear_bar()
                i = e[1]
                continue

            # A chord: every note inside sounds at the same tick, and the
            # chord's own length -- written after the bracket -- governs.
            i += 1
            var first = True
            var members = 0
            # A copy, not a name for the slot: the list may be grown below,
            # and a `let` bound into it would dangle.
            var start_tick = tune.voices[vi].tick
            var member_ticks = 0
            while i < n and Int(b[i]) != 93:
                if Int(b[i]) == 32:
                    i += 1
                    continue
                let r = read_note(
                    line, i, ctx, tune.voices[vi].key_sharps,
                    tune.voices[vi].transpose, tune.voices[vi].octave_shift,
                )
                if r[0] == 0:
                    i = r[2]
                    continue
                i = r[2]
                # A member may carry its own length; the first one's wins if
                # the chord has none of its own.
                let unit = (TICKS_PER_WHOLE * tune.voices[vi].unit_num) // tune.voices[vi].unit_den
                let d = read_duration(line, i, unit)
                i = d[1]
                if first:
                    member_ticks = d[0]
                tune.events.append(Event(
                    kind=EV_NOTE, voice=ctx.voice, tick=start_tick,
                    duration=d[0], midi=r[1],
                    velocity=tune.voices[vi].velocity, aux=0,
                    flags=0 if first else F_CHORD,
                ))
                ctx.last_note = len(tune.events) - 1
                members += 1
                first = False
            if i < n:
                i += 1                    # past ']'

            let unit = (TICKS_PER_WHOLE * tune.voices[vi].unit_num) // tune.voices[vi].unit_den
            let after = read_duration(line, i, unit)
            var ticks = member_ticks
            if after[1] > i:
                ticks = after[0]
                i = after[1]
            ticks = adjust_for_tuplet_and_broken(ticks, ctx)
            # Every member takes the chord's final length.
            for k in range(members):
                let at = len(tune.events) - 1 - k
                tune.events[at].duration = ticks
            if members > 0 and not ctx.in_grace:
                tune.voices[vi].tick = start_tick + ticks
            continue

        # ── Bar lines ───────────────────────────────────────────────────────
        if c == 124 or c == 58:          # | or :
            var kind = BAR_SINGLE
            if c == 58:                  # :| or ::
                if i + 1 < n and Int(b[i + 1]) == 124:
                    kind = BAR_REPEAT_END
                    i += 2
                    if i < n and Int(b[i]) == 58:
                        kind = BAR_REPEAT_START
                        i += 1
                else:
                    i += 1
            else:
                i += 1
                if i < n and Int(b[i]) == 58:        # |:
                    kind = BAR_REPEAT_START
                    i += 1
                elif i < n and Int(b[i]) == 124:     # ||
                    kind = BAR_DOUBLE
                    i += 1
                elif i < n and Int(b[i]) == 93:      # |]
                    kind = BAR_THIN_THICK
                    i += 1
            tune.events.append(Event(
                kind=EV_BAR, voice=ctx.voice, tick=tune.voices[vi].tick,
                duration=0, midi=0, velocity=0, aux=kind, flags=0,
            ))
            # Mirror the bar into the accompaniment voice, so repeats expand
            # the chords alongside the melody they belong to. Written out here
            # rather than called: handing a `mut Tune` on to a second function
            # while this one still holds it miscompiles into a crash at the
            # call, with no diagnostic.
            var g_at = -1
            for k in range(len(tune.voices)):
                if tune.voices[k].number == GCHORD_VOICE_BASE + ctx.voice:
                    g_at = k
            if g_at >= 0:
                tune.events.append(Event(
                    kind=EV_BAR, voice=GCHORD_VOICE_BASE + ctx.voice,
                    tick=tune.voices[g_at].tick, duration=0, midi=0,
                    velocity=0, aux=kind, flags=0,
                ))
            ctx.clear_bar()
            # A digit straight after a bar line opens an ending.
            if i < n and is_digit(Int(b[i])):
                let e = read_int(line, i)
                tune.events.append(Event(
                    kind=EV_BAR, voice=ctx.voice, tick=tune.voices[vi].tick,
                    duration=0, midi=0, velocity=0,
                    aux=BAR_ENDING_1 if e[0] == 1 else BAR_ENDING_2, flags=0,
                ))
                i = e[1]
            continue

        # ── Chord symbols, decorations, grace notes ─────────────────────────
        if c == 34:                      # "Am7"
            var close = i + 1
            var text = String("")
            while close < n and Int(b[close]) != 34:
                text += chr(Int(b[close]))
                close += 1
            let s = parse_chord_symbol(text)
            if s[0] != 0:
                ctx.gchord_root = s[1]
                ctx.gchord_kind = s[2]
            i = close + 1 if close < n else n
            continue
        if c == 33 or c == 43:           # !decoration! or +decoration+
            var close = i + 1
            while close < n and Int(b[close]) != c:
                close += 1
            i = close + 1 if close < n else n
            continue
        if c == 123:                     # { grace notes }
            ctx.in_grace = True
            i += 1
            continue
        if c == 125:
            ctx.in_grace = False
            i += 1
            continue
        if c == 40:                      # ( -- slur, or a tuplet if a digit follows
            if i + 1 < n and is_digit(Int(b[i + 1])):
                let p = read_int(line, i + 1)
                i = p[1]
                var q = tuplet_default_den(
                    p[0], tune.voices[vi].meter_den == 8
                    and (tune.voices[vi].meter_num % 3) == 0
                )
                var r = p[0]
                if i < n and Int(b[i]) == 58:        # (p:q or (p:q:r
                    let qq = read_int(line, i + 1)
                    if qq[2] != 0:
                        q = qq[0]
                    i = qq[1]
                    if i < n and Int(b[i]) == 58:
                        let rr = read_int(line, i + 1)
                        if rr[2] != 0:
                            r = rr[0]
                        i = rr[1]
                ctx.tuplet_left = r
                ctx.tuplet_num = q
                ctx.tuplet_den = p[0]
                continue
            i += 1
            continue
        if c == 41:                      # ) slur close
            i += 1
            continue
        if c == 45:                      # - tie
            if ctx.last_note >= 0:
                tune.events[ctx.last_note].flags = (
                    tune.events[ctx.last_note].flags | F_TIE
                )
            i += 1
            continue
        if c == 62 or c == 60:           # > or <
            # Broken rhythm. The mark lengthens the note before it and
            # shortens the note after, or the other way round for `<`.
            #
            # Written out rather than called for the reason the chord code
            # gives: passing `mut tune` on to another function from here
            # crashes the compiler at the call site.
            let mark = c
            var count = 0
            while i < n and Int(b[i]) == mark:
                count += 1
                i += 1
            if ctx.last_note >= 0:
                var half = 2
                for _ in range(1, count):
                    half *= 2
                let at = ctx.last_note
                var was = tune.events[at].duration
                var now = was // half
                if mark == 62:
                    now = (was * (2 * half - 1)) // half
                tune.events[at].duration = now
                let owner = tune.events[at].voice
                for k in range(len(tune.voices)):
                    if tune.voices[k].number == owner:
                        var t = tune.voices[k].tick
                        tune.voices[k].tick = t + (now - was)
            ctx.broken = count if mark == 62 else -count
            continue

        # ── Rests ───────────────────────────────────────────────────────────
        if c == 122 or c == 120:         # z, x
            i += 1
            let unit = (TICKS_PER_WHOLE * tune.voices[vi].unit_num) // tune.voices[vi].unit_den
            let d = read_duration(line, i, unit)
            i = d[1]
            let ticks = adjust_for_tuplet_and_broken(d[0], ctx)
            tune.events.append(Event(
                kind=EV_REST, voice=ctx.voice, tick=tune.voices[vi].tick,
                duration=ticks, midi=0, velocity=0, aux=0, flags=0,
            ))
            # Read, add, write back. `+=` through a List subscript updates a
            # temporary and throws it away: the rest would occupy no time and
            # every note after it would arrive early, with nothing to show
            # for it in the parse.
            var rest_at = tune.voices[vi].tick
            tune.voices[vi].tick = rest_at + ticks
            continue
        if c == 90:                      # Z -- whole measures of rest
            i += 1
            let m = read_int(line, i)
            let bars = m[0] if m[2] != 0 else 1
            i = m[1]
            let bar_ticks = (
                TICKS_PER_WHOLE * tune.voices[vi].meter_num
            ) // tune.voices[vi].meter_den
            let ticks = bar_ticks * bars
            tune.events.append(Event(
                kind=EV_REST, voice=ctx.voice, tick=tune.voices[vi].tick,
                duration=ticks, midi=0, velocity=0, aux=0, flags=0,
            ))
            var bars_at = tune.voices[vi].tick
            tune.voices[vi].tick = bars_at + ticks
            continue

        # ── A note ──────────────────────────────────────────────────────────
        if is_note_letter(c) or c == 94 or c == 95 or c == 61:
            let r = read_note(
                line, i, ctx, tune.voices[vi].key_sharps,
                tune.voices[vi].transpose, tune.voices[vi].octave_shift,
            )
            if r[0] == 0:
                i = r[2]
                continue
            i = r[2]
            let unit = (TICKS_PER_WHOLE * tune.voices[vi].unit_num) // tune.voices[vi].unit_den
            let d = read_duration(line, i, unit)
            i = d[1]
            var ticks = adjust_for_tuplet_and_broken(d[0], ctx)

            # A copy, not a name for the slot: the list may be grown below,
            # and a `let` bound into it would dangle.
            var start_tick = tune.voices[vi].tick
            var flags = 0
            if ctx.in_grace:
                # A grace note sounds but steals no time from the bar.
                flags = F_GRACE
                ticks = TICKS_PER_QUARTER // 8
            tune.events.append(Event(
                kind=EV_NOTE, voice=ctx.voice, tick=start_tick,
                duration=ticks, midi=r[1],
                velocity=tune.voices[vi].velocity, aux=0, flags=flags,
            ))
            ctx.last_note = len(tune.events) - 1

            # The voice's clock is advanced before the chord is emitted:
            # emit_gchord may create the accompaniment voice, and growing the
            # voice list invalidates any index held across the call.
            if not ctx.in_grace:
                tune.voices[vi].tick = start_tick + ticks
            if ctx.gchord_root >= 0 and not ctx.in_grace:
                # Written out rather than called: handing `mut tune` on to a
                # second function while this one holds it crashes at the call.
                # The chord sounds in its own voice, so a chord symbol never
                # advances the melody's clock -- which is what putting the
                # tones in the melody voice would do.
                let gvoice = GCHORD_VOICE_BASE + ctx.voice
                var g_index = -1
                for k in range(len(tune.voices)):
                    if tune.voices[k].number == gvoice:
                        g_index = k
                if g_index < 0:
                    tune.voices.append(configured_voice(gvoice, 1, 8, 4, 4, 0))
                    g_index = len(tune.voices) - 1
                for k in range(4):
                    let step = chord_intervals(ctx.gchord_kind, k)
                    if step < 0:
                        continue
                    var gnote = ctx.gchord_root + step
                    if gnote > 127:
                        gnote = 127
                    tune.events.append(Event(
                        kind=EV_NOTE, voice=gvoice, tick=start_tick,
                        duration=ticks, midi=gnote, velocity=52, aux=0,
                        flags=F_GCHORD if k == 0 else (F_GCHORD | F_CHORD),
                    ))
                tune.voices[g_index].tick = start_tick + ticks
            continue

        # Anything else is notation this player does not sound: lyrics
        # alignment, user-defined symbols, and the like.
        i += 1


def adjust_for_tuplet_and_broken(ticks_in: Int, mut ctx: MusicCtx) -> Int:
    """Apply a running tuplet and a pending broken-rhythm mark."""
    var ticks = ticks_in
    if ctx.tuplet_left > 0:
        ticks = (ticks * ctx.tuplet_num) // ctx.tuplet_den
        ctx.tuplet_left -= 1
    if ctx.broken != 0:
        # The note after `>` is shortened; after `<` it is lengthened. The
        # note before was adjusted when the mark was read.
        var half = 2
        for _ in range(1, abs(ctx.broken)):
            half *= 2
        if ctx.broken > 0:
            ticks = ticks // half
        else:
            ticks = (ticks * (2 * half - 1)) // half
        ctx.broken = 0
    if ticks < 1:
        ticks = 1
    return ticks


def parse_inline_field(field: Int, value: String) -> List[Int]:
    """An inline `[K:G]`, `[M:3/4]`, `[L:1/16]`, `[Q:...]` or `[V:2]`.

    Returns [what, a, b, c] rather than editing the tune, so that the caller
    -- which already holds the tune mutably -- can apply it without passing
    that borrow on.
    """
    var out = List[Int]()
    if field == 86:                      # V
        let v = read_int(value, 0)
        out.append(1)
        out.append(v[0] if v[2] != 0 else 1)
        out.append(0)
        out.append(0)
        return out^
    if field == 75:                      # K
        out.append(2)
        out.append(key_sharps_for(value))
        out.append(0)
        out.append(0)
        return out^
    if field == 76:                      # L
        let f = read_fraction(value, 1, 8)
        out.append(3)
        out.append(f[0])
        out.append(f[1])
        out.append(0)
        return out^
    if field == 77:                      # M
        let f = read_fraction(value, 4, 4)
        out.append(4)
        out.append(f[0])
        out.append(f[1])
        out.append(0)
        return out^
    if field == 81:                      # Q
        let t = parse_tempo(value)
        out.append(5)
        out.append(t[0])
        out.append(t[1])
        out.append(t[2])
        return out^
    out.append(0)
    out.append(0)
    out.append(0)
    out.append(0)
    return out^


def read_fraction(text: String, fallback_num: Int, fallback_den: Int) -> List[Int]:
    """`3/4`, or `C` and `C|` for common and cut time."""
    var out = List[Int]()
    if text.startswith("C|"):
        out.append(2)
        out.append(2)
        return out^
    if text.startswith("C"):
        out.append(4)
        out.append(4)
        return out^
    let a = read_int(text, 0)
    if a[2] == 0:
        out.append(fallback_num)
        out.append(fallback_den)
        return out^
    var i = a[1]
    let b = text.as_bytes()
    if i < len(b) and Int(b[i]) == 47:
        let d = read_int(text, i + 1)
        out.append(a[0])
        out.append(d[0] if d[2] != 0 and d[0] > 0 else fallback_den)
        return out^
    out.append(a[0])
    out.append(1)
    return out^


def parse_tempo(value: String) -> List[Int]:
    """`Q:1/4=120` or `Q:120`. Returns [bpm, num, den]."""
    var out = List[Int]()
    var eq = -1
    let b = value.as_bytes()
    for i in range(len(b)):
        if Int(b[i]) == 61:
            eq = i
    var bpm = 120
    var num = 1
    var den = 4
    if eq >= 0:
        let f = read_fraction(String(value[byte=0:eq]), 1, 4)
        num = f[0]
        den = f[1]
        let t = read_int(String(value[byte = eq + 1 : len(b)]), 0)
        if t[2] != 0:
            bpm = t[0]
    else:
        let t = read_int(value, 0)
        if t[2] != 0:
            bpm = t[0]
    out.append(bpm)
    out.append(num)
    out.append(den)
    return out^


def apply_tempo(value: String, mut tune: Tune):
    """`Q:1/4=120`, `Q:120`, or a quoted form with text around it."""
    var eq = -1
    let b = value.as_bytes()
    for i in range(len(b)):
        if Int(b[i]) == 61:
            eq = i
    if eq >= 0:
        let f = read_fraction(String(value[byte=0:eq]), 1, 4)
        tune.tempo_num = f[0]
        tune.tempo_den = f[1]
        let t = read_int(String(value[byte = eq + 1 : len(b)]), 0)
        if t[2] != 0:
            tune.tempo_bpm = t[0]
    else:
        let t = read_int(value, 0)
        if t[2] != 0:
            tune.tempo_bpm = t[0]
            tune.tempo_num = 1
            tune.tempo_den = 4
