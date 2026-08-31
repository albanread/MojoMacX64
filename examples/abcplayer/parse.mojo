# Reading a whole file: headers, then music, with fields allowed in both.
#
# ABC's header ends at the K: field, which is the one rule that makes the
# format parseable at all -- everything before it configures the tune, and
# everything after it is music, except that field lines are still allowed in
# the body and most real tunes use them for voice switches.

from model import (
    Tune, Event, Voice, new_voice, TICKS_PER_WHOLE,
    EV_NOTE, EV_REST, EV_BAR, key_sharps_for,
)
from music import (
    MusicCtx, parse_music_line, read_int, read_fraction, apply_tempo,
)


def parse_abc(source: String, mut tune: Tune):
    """Parse the first tune in an ABC file.

    The tune is passed in rather than returned. Returning a struct that owns
    several Lists by value crashes this compiler in DialectConversion --
    "incorrect # of replacement values" -- before any of this code runs, the
    same way a struct with ten List fields does.
    """
    var ctx = MusicCtx()
    var in_header = True
    var seen_length = False
    var meter_num = 4
    var meter_den = 4
    var unit_num = 1
    var unit_den = 8
    var key_sharps = 0
    var started = False

    let lines = source.split(String("\n"))
    for li in range(len(lines)):
        var raw_line = String(lines[li])
        # A trailing carriage return is invisible and breaks every comparison
        # that follows it, so it goes first. The trimmed copy is a new String:
        # assigning a slice of a String back over itself aliases the buffer it
        # is reading from.
        var line = raw_line
        if raw_line.endswith("\r"):
            line = String(raw_line[byte = 0 : len(raw_line.as_bytes()) - 1])
        let b = line.as_bytes()
        if len(b) == 0:
            continue
        if Int(b[0]) == 37:              # % comment or %% directive
            continue

        # A field line: one letter, a colon, and the value.
        let is_field = (
            len(b) >= 2 and Int(b[1]) == 58
            and (
                (Int(b[0]) >= 65 and Int(b[0]) <= 90)
                or (Int(b[0]) >= 97 and Int(b[0]) <= 122)
            )
        )

        if is_field:
            let field = Int(b[0])
            # Sliced, not rebuilt character by character: `chr(byte)` turns
            # each byte of a multi-byte character into its own codepoint, so
            # a title with an accent in it comes out as mojibake.
            let body = String(line[byte = 2 : len(b)])
            let value = String(body.strip())

            if field == 88:              # X: a new tune begins
                if started:
                    break                # only the first tune in the file
                started = True
            elif field == 84:            # T
                if len(tune.title.as_bytes()) == 0:
                    tune.title = value
            elif field == 67:            # C
                tune.composer = value
            elif field == 76:            # L
                let f = read_fraction(value, 1, 8)
                unit_num = f[0]
                unit_den = f[1]
                seen_length = True
                tune.default_unit_num = unit_num
                tune.default_unit_den = unit_den
                apply_to_all_voices(tune, unit_num, unit_den, -1, -1, -999)
            elif field == 77:            # M
                let f = read_fraction(value, 4, 4)
                meter_num = f[0]
                meter_den = f[1]
                if not seen_length:
                    # ABC's rule: under three-quarters of a whole note the
                    # default unit is a sixteenth, otherwise an eighth.
                    unit_num = 1
                    unit_den = 16 if (
                        Float64(meter_num) / Float64(meter_den) < 0.75
                    ) else 8
                tune.default_unit_num = unit_num
                tune.default_unit_den = unit_den
                tune.default_meter_num = meter_num
                tune.default_meter_den = meter_den
                apply_to_all_voices(tune, unit_num, unit_den, meter_num, meter_den, -999)
            elif field == 81:            # Q
                apply_tempo(value, tune)
            elif field == 75:            # K
                key_sharps = key_sharps_for(value)
                tune.default_key_sharps = key_sharps
                apply_to_all_voices(tune, -1, -1, -1, -1, key_sharps)
                # K: ends the header. Fields after it are still legal.
                in_header = False
                ctx.clear_bar()
            elif field == 86:            # V
                let v = read_int(value, 0)
                let number = v[0] if v[2] != 0 else 1
                ctx.voice = number
                let vi = tune.ensure_voice(number)
                # A voice mentioned for the first time inherits the tune's
                # settings, not the previous voice's position.
                tune.voices[vi].unit_num = unit_num
                tune.voices[vi].unit_den = unit_den
                tune.voices[vi].meter_num = meter_num
                tune.voices[vi].meter_den = meter_den
                if not in_header:
                    tune.voices[vi].key_sharps = key_sharps
                ctx.clear_bar()
                # A V: line may carry settings of its own: clef, transpose,
                # name, and an octave shift.
                apply_voice_settings(value, tune, vi)
            elif field == 119:           # w: lyrics -- nothing to sound
                continue
            continue

        if in_header:
            continue
        parse_music_line(line, tune, ctx)

    # A tune with no explicit voice still has one.
    if len(tune.voices) == 0:
        _ = tune.ensure_voice(1)


def apply_to_all_voices(
    mut tune: Tune, unit_num: Int, unit_den: Int,
    meter_num: Int, meter_den: Int, key_sharps: Int,
):
    """Push a header change into every voice. -1 and -999 mean "leave alone"."""
    for i in range(len(tune.voices)):
        if unit_num > 0:
            tune.voices[i].unit_num = unit_num
            tune.voices[i].unit_den = unit_den
        if meter_num > 0:
            tune.voices[i].meter_num = meter_num
            tune.voices[i].meter_den = meter_den
        if key_sharps != -999:
            tune.voices[i].key_sharps = key_sharps


def apply_voice_settings(value: String, mut tune: Tune, vi: Int):
    """The `name=`, `transpose=` and `octave=` parts of a V: field."""
    let b = value.as_bytes()
    var i = 0
    while i < len(b):
        # Find the next key=value pair.
        while i < len(b) and Int(b[i]) == 32:
            i += 1
        var key = String("")
        while i < len(b) and Int(b[i]) != 61 and Int(b[i]) != 32:
            key += chr(Int(b[i]))
            i += 1
        if i >= len(b) or Int(b[i]) != 61:
            continue
        i += 1
        var val = String("")
        if i < len(b) and Int(b[i]) == 34:       # quoted
            i += 1
            while i < len(b) and Int(b[i]) != 34:
                val += chr(Int(b[i]))
                i += 1
            i += 1
        else:
            while i < len(b) and Int(b[i]) != 32:
                val += chr(Int(b[i]))
                i += 1

        let lower = String(key.lower())
        if lower == "name" or lower == "nm":
            tune.voices[vi].name = val
        elif lower == "transpose":
            var negative = False
            var at = 0
            let vb = val.as_bytes()
            if len(vb) > 0 and Int(vb[0]) == 45:
                negative = True
                at = 1
            let t = read_int(val, at)
            if t[2] != 0:
                tune.voices[vi].transpose = -t[0] if negative else t[0]
        elif lower == "octave":
            var negative = False
            var at = 0
            let vb = val.as_bytes()
            if len(vb) > 0 and Int(vb[0]) == 45:
                negative = True
                at = 1
            let o = read_int(val, at)
            if o[2] != 0:
                tune.voices[vi].octave_shift = -o[0] if negative else o[0]
