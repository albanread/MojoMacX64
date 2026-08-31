# ABC notation in, chip registers out.
#
# ABC is how folk tunes are written down when they are written for a computer:
# a few header fields, then letters for notes. It is the natural input for
# this synthesiser because the tunes already exist in it by the thousand, and
# because turning one into chip music is exactly the translation this example
# is about -- notes are a score, and a chip wants a schedule of register
# writes.
#
# The subset here is the one real tunes actually use:
#
#   headers      X: T: M: L: Q: K: V:
#   notes        A-G a-g, with , and ' for octaves
#   accidentals  ^ sharp, _ flat, = natural, held to the end of the bar
#   key          K: sets the signature, including minor and the usual modes
#   lengths      A2  A/  A/2  A3/2
#   rests        z, with the same lengths
#   chords       [CEG] -- which become an arpeggio, the C64 way
#   broken       a>b and a<b
#   voices       V:1 V:2 V:3, mapped to the chip's three
#
# Ignored on purpose, because they change nothing a chip can hear: slurs,
# ties, grace notes, decorations, chord symbols, and repeat marks. Repeats
# are ignored rather than expanded, so a tune plays through once per loop.

from std.memory import Pointer, MutUntrackedOrigin, OpaquePointer
from std.ffi import external_call
from chip import P
from tune import score_alloc, score_put, voice_part, EVENT_SLOTS

comptime MAX_VOICES = 3


@fieldwise_init
struct AbcTune(Movable):
    """A parsed tune: flat events, and where each voice's part begins."""

    var events: List[Int]    # four Ints per event: n0, n1, n2, frames
    var first: List[Int]
    var count: List[Int]
    var title: String


@always_inline
fn is_digit(c: Int) -> Bool:
    return c >= 48 and c <= 57


@always_inline
fn letter_semitone(c: Int) -> Int:
    """C D E F G A B as offsets from C. -1 if it is not a note letter."""
    if c == 67: return 0    # C
    if c == 68: return 2    # D
    if c == 69: return 4    # E
    if c == 70: return 5    # F
    if c == 71: return 7    # G
    if c == 65: return 9    # A
    if c == 66: return 11   # B
    return -1


@always_inline
fn letter_index(c: Int) -> Int:
    """C=0 D=1 E=2 F=3 G=4 A=5 B=6, for the accidental tables."""
    if c == 67: return 0
    if c == 68: return 1
    if c == 69: return 2
    if c == 70: return 3
    if c == 71: return 4
    if c == 65: return 5
    if c == 66: return 6
    return -1


@always_inline
fn sharp_order(k: Int) -> Int:
    """Sharps arrive F C G D A E B; flats take the same list backwards.

    Returned as indices into the C D E F G A B tables, which is the whole of
    the circle of fifths and the only reason this is short.
    """
    if k == 0: return 3    # F
    if k == 1: return 0    # C
    if k == 2: return 4    # G
    if k == 3: return 1    # D
    if k == 4: return 5    # A
    if k == 5: return 2    # E
    return 6               # B


def key_signature(key: String) -> List[Int]:
    """Semitone offsets for C D E F G A B implied by a K: field.

    Sharps arrive in the order F C G D A E B and flats in the reverse, which
    is the whole of the circle of fifths and the only reason this is short.
    """
    var acc = List[Int]()
    for _ in range(7):
        acc.append(0)
    if len(key.as_bytes()) == 0:
        return acc^

    let b = key.as_bytes()
    var tonic = Int(b[0])
    if tonic >= 97 and tonic <= 122:
        tonic -= 32  # upper case

    var index = letter_index(tonic)
    if index < 0:
        return acc^

    # Position on the circle of fifths: F=-1, C=0, G=1, D=2, A=3, E=4, B=5.
    var fifths = 0
    if tonic == 70: fifths = -1
    elif tonic == 67: fifths = 0
    elif tonic == 71: fifths = 1
    elif tonic == 68: fifths = 2
    elif tonic == 65: fifths = 3
    elif tonic == 69: fifths = 4
    elif tonic == 66: fifths = 5

    var at = 1
    if len(b) > 1 and Int(b[1]) == 35:      # '#'
        fifths += 7
        at = 2
    elif len(b) > 1 and Int(b[1]) == 98:    # 'b'
        fifths -= 7
        at = 2

    # A mode shifts the signature: minor is three flats' worth of fifths down
    # from its relative major, and the others follow the same rule.
    var rest = String("")
    for i in range(at, len(b)):
        let c = Int(b[i])
        if c == 32:
            continue
        rest += chr(c + 32 if c >= 65 and c <= 90 else c)
    if rest.startswith("m") and not rest.startswith("maj"):
        fifths -= 3
    elif rest.startswith("dor"):
        fifths -= 2
    elif rest.startswith("mix"):
        fifths -= 1
    elif rest.startswith("lyd"):
        fifths += 1
    elif rest.startswith("phr"):
        fifths -= 4
    elif rest.startswith("loc"):
        fifths -= 5

    var n = fifths
    var k = 0
    while n > 0 and k < 7:
        acc[sharp_order(k)] = 1
        n -= 1
        k += 1
    n = -fifths
    k = 0
    while n > 0 and k < 7:
        acc[sharp_order(6 - k)] = -1
        n -= 1
        k += 1
    return acc^


def parse_fraction(text: String, fallback_num: Int, fallback_den: Int) -> List[Int]:
    """`3/4` and `1/8` and `120` all parse; returns [num, den]."""
    var num = 0
    var den = 0
    var seen_slash = False
    var any_digit = False
    for i in range(len(text.as_bytes())):
        let c = Int(text.as_bytes()[i])
        if is_digit(c):
            any_digit = True
            if seen_slash:
                den = den * 10 + (c - 48)
            else:
                num = num * 10 + (c - 48)
        elif c == 47:
            seen_slash = True
        elif c == 32:
            continue
        else:
            break
    var out = List[Int]()
    if not any_digit:
        out.append(fallback_num)
        out.append(fallback_den)
        return out^
    out.append(num if num > 0 else fallback_num)
    out.append(den if den > 0 else 1)
    return out^


def parse_abc(source: String) -> AbcTune:
    """Parse a tune. Durations come out in 50 Hz frames."""
    var events = List[Int]()
    var first = List[Int]()
    var count = List[Int]()
    for _ in range(MAX_VOICES):
        first.append(0)
        count.append(0)

    # Per-voice event lists, concatenated at the end so each voice's part is
    # contiguous -- the player walks a part with one cursor and no indirection.
    var parts = List[List[Int]]()
    for _ in range(MAX_VOICES):
        parts.append(List[Int]())

    var title = String("")
    var unit_num = 1
    var unit_den = 8         # L: defaults to an eighth for most meters
    var beat_num = 1
    var beat_den = 4
    var bpm = 120
    var key_acc = key_signature(String("C"))
    var voice = 0
    var have_length = False
    var meter_num = 4
    var meter_den = 4

    let lines = source.split(String("\n"))
    for li in range(len(lines)):
        var line = String(lines[li])
        let raw = line.as_bytes()
        if len(raw) == 0:
            continue

        # A header field is a letter, a colon, and the rest of the line.
        if len(raw) >= 2 and Int(raw[1]) == 58:
            let field = Int(raw[0])
            var body = String("")
            for i in range(2, len(raw)):
                body += chr(Int(raw[i]))
            var value = String(body.strip())
            if field == 84:            # T:
                if len(title.as_bytes()) == 0:
                    title = value
            elif field == 76:          # L:
                let f = parse_fraction(value, 1, 8)
                unit_num = f[0]
                unit_den = f[1]
                have_length = True
            elif field == 77:          # M:
                if not value.startswith("C"):
                    let f = parse_fraction(value, 4, 4)
                    meter_num = f[0]
                    meter_den = f[1]
                if not have_length:
                    # ABC's rule: under 3/4 of a whole note the unit is a
                    # sixteenth, otherwise an eighth.
                    unit_num = 1
                    unit_den = 16 if (
                        Float64(meter_num) / Float64(meter_den) < 0.75
                    ) else 8
            elif field == 81:          # Q:
                # Q:1/4=120, or bare Q:120.
                var eq = -1
                for i in range(len(value.as_bytes())):
                    if Int(value.as_bytes()[i]) == 61:
                        eq = i
                if eq >= 0:
                    let bf = parse_fraction(String(value[byte=0:eq]), 1, 4)
                    beat_num = bf[0]
                    beat_den = bf[1]
                    let rest = String(value[byte = eq + 1 : len(value.as_bytes())])
                    let tf = parse_fraction(rest, 120, 1)
                    bpm = tf[0]
                else:
                    let tf = parse_fraction(value, 120, 1)
                    bpm = tf[0]
            elif field == 75:          # K:
                key_acc = key_signature(value)
            elif field == 86:          # V:
                let vf = parse_fraction(value, 1, 1)
                voice = vf[0] - 1
                if voice < 0:
                    voice = 0
                if voice >= MAX_VOICES:
                    voice = MAX_VOICES - 1
            continue

        # ── Music ───────────────────────────────────────────────────────────
        # Frames for one unit note: 50 a second, a beat is 60/bpm seconds,
        # and a unit is (unit/beat) beats.
        let seconds_per_beat = 60.0 / Float64(bpm)
        let units_per_beat = (
            Float64(beat_num) / Float64(beat_den)
        ) / (Float64(unit_num) / Float64(unit_den))
        var unit_frames = Int(
            50.0 * seconds_per_beat / units_per_beat + 0.5
        )
        if unit_frames < 1:
            unit_frames = 1

        var bar_acc = List[Int]()
        for _ in range(7):
            bar_acc.append(99)   # 99 means "no accidental this bar"

        var i = 0
        let n = len(raw)
        var pending_broken = 0    # +1 after '>', -1 after '<'
        while i < n:
            let c = Int(raw[i])

            if c == 37:                      # % comment
                break
            if c == 32 or c == 9:
                i += 1
                continue
            if c == 124 or c == 58:          # | or :  -- a bar line
                for k in range(7):
                    bar_acc[k] = 99
                i += 1
                continue
            if c == 34:                      # "chord symbol"
                i += 1
                while i < n and Int(raw[i]) != 34:
                    i += 1
                i += 1
                continue
            if c == 33 or c == 43:           # !decoration! or +decoration+
                let closer = c
                i += 1
                while i < n and Int(raw[i]) != closer:
                    i += 1
                i += 1
                continue
            if c == 123:                     # {grace notes}
                while i < n and Int(raw[i]) != 125:
                    i += 1
                i += 1
                continue
            if c == 40 or c == 41 or c == 45:  # slurs and ties
                i += 1
                continue
            if c == 62:                      # >
                pending_broken = 1
                i += 1
                continue
            if c == 60:                      # <
                pending_broken = -1
                i += 1
                continue

            var notes = List[Int]()
            var is_rest = False
            var consumed = False

            if c == 91:                      # [
                # An inline field like [K:G] is a header, not a chord.
                if i + 2 < n and Int(raw[i + 2]) == 58:
                    while i < n and Int(raw[i]) != 93:
                        i += 1
                    i += 1
                    continue
                i += 1
                while i < n and Int(raw[i]) != 93:
                    let r = read_note(line, i, key_acc, bar_acc)
                    if r[0] == 0:
                        i += 1
                        continue
                    if len(notes) < 3:
                        notes.append(r[1])
                    i = r[2]
                i += 1
                consumed = True
            elif c == 122 or c == 90 or c == 120:   # z, Z, x -- rests
                is_rest = True
                i += 1
                consumed = True
            else:
                let r = read_note(line, i, key_acc, bar_acc)
                if r[0] != 0:
                    notes.append(r[1])
                    i = r[2]
                    consumed = True
                else:
                    i += 1
                    continue

            if not consumed:
                continue

            # The length multiplier that follows a note, a chord or a rest.
            var mul = 1
            var div = 1
            var digits = 0
            while i < n and is_digit(Int(raw[i])):
                digits = digits * 10 + (Int(raw[i]) - 48)
                i += 1
            if digits > 0:
                mul = digits
            if i < n and Int(raw[i]) == 47:
                i += 1
                var d2 = 0
                while i < n and is_digit(Int(raw[i])):
                    d2 = d2 * 10 + (Int(raw[i]) - 48)
                    i += 1
                div = d2 if d2 > 0 else 2

            var frames = (unit_frames * mul) // div
            if frames < 1:
                frames = 1

            # Broken rhythm: the pair either side of > is dotted, and the
            # sign says which half gets the dot.
            if pending_broken != 0:
                if pending_broken > 0:
                    frames = (frames + 1) // 2
                else:
                    frames = (frames * 3) // 2
                pending_broken = 0
            elif len(parts[voice]) >= EVENT_SLOTS:
                pass

            var n0 = -1
            var n1 = -1
            var n2 = -1
            if not is_rest and len(notes) > 0:
                n0 = notes[0]
                if len(notes) > 1:
                    n1 = notes[1]
                if len(notes) > 2:
                    n2 = notes[2]
            parts[voice].append(n0)
            parts[voice].append(n1)
            parts[voice].append(n2)
            parts[voice].append(frames)

            # The other half of a broken pair, applied to the note just added.
            if i < n and (Int(raw[i]) == 62 or Int(raw[i]) == 60):
                let at = len(parts[voice]) - 1
                if Int(raw[i]) == 62:
                    parts[voice][at] = (parts[voice][at] * 3) // 2
                    pending_broken = 1
                else:
                    parts[voice][at] = (parts[voice][at] + 1) // 2
                    pending_broken = -1
                i += 1

    # Lay the parts out end to end.
    for v in range(MAX_VOICES):
        first[v] = len(events) // EVENT_SLOTS
        count[v] = len(parts[v]) // EVENT_SLOTS
        for k in range(len(parts[v])):
            events.append(parts[v][k])

    return AbcTune(events^, first^, count^, title)


def read_note(
    line: String, start: Int, key_acc: List[Int], mut bar_acc: List[Int]
) -> List[Int]:
    """Read one note at `start`. Returns [ok, midi, next_index].

    An explicit accidental holds for the rest of the bar, which is the rule
    that makes ABC readable and the one a naive parser always misses.
    """
    var out = List[Int]()
    let raw = line.as_bytes()
    var i = start
    let n = len(raw)
    var accidental = 99

    while i < n:
        let c = Int(raw[i])
        if c == 94:        # ^
            accidental = 1 if accidental == 99 else accidental + 1
            i += 1
        elif c == 95:      # _
            accidental = -1 if accidental == 99 else accidental - 1
            i += 1
        elif c == 61:      # =
            accidental = 0
            i += 1
        else:
            break

    if i >= n:
        out.append(0)
        out.append(0)
        out.append(start + 1)
        return out^

    var c = Int(raw[i])
    var octave = 5          # ABC's C is MIDI 60, which is octave 5 here
    var upper = c
    if c >= 97 and c <= 103:      # a-g are an octave up
        upper = c - 32
        octave = 6
    let semi = letter_semitone(upper)
    if semi < 0:
        out.append(0)
        out.append(0)
        out.append(start + 1)
        return out^
    i += 1

    while i < n:
        let m = Int(raw[i])
        if m == 39:        # '
            octave += 1
            i += 1
        elif m == 44:      # ,
            octave -= 1
            i += 1
        else:
            break

    let index = letter_index(upper)
    if accidental != 99:
        bar_acc[index] = accidental
    var adjust = key_acc[index]
    if bar_acc[index] != 99:
        adjust = bar_acc[index]

    out.append(1)
    out.append(octave * 12 + semi + adjust)
    out.append(i)
    return out^


def install_abc(st: P, tune: AbcTune) -> Int:
    """Copy a parsed tune into a score block the player can walk."""
    let total = len(tune.events) // EVENT_SLOTS
    if total == 0:
        return 0
    let score = score_alloc(total)
    let ev = Pointer[Int, MutUntrackedOrigin](unsafe_from_address=score)
    for k in range(len(tune.events)):
        ev[unsafe_offset=k] = tune.events[k]
    for v in range(MAX_VOICES):
        voice_part(st, v, tune.first[v], tune.count[v])
    return score
