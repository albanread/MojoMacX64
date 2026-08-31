# The data model: what an ABC tune becomes once it has been read.
#
# Two decisions shape everything else here.
#
# **Time is an integer.** Durations are counted in ticks at 480 per quarter
# note -- 1920 per whole note -- and never in seconds or doubles. That number
# is the standard MIDI resolution and it divides exactly by everything ABC can
# ask for: a 1/64 note is 30 ticks, a triplet eighth is 160, a dotted quarter
# is 720. Nothing rounds, so a tune that should land on the bar line does,
# however many tuplets and dots came before it. Floating-point timestamps drift
# by a fraction of a tick per note, which is inaudible until a few hundred
# notes have gone by and the voices are visibly apart.
#
# **A key signature is arithmetic, not a table.** The alteration a key applies
# to a letter follows from the circle of fifths, so `key_alter` computes it
# rather than storing seven numbers per key. The whole of Western key
# signatures is two orderings of the same seven letters.

comptime TICKS_PER_QUARTER = 480
comptime TICKS_PER_WHOLE = TICKS_PER_QUARTER * 4

# Event kinds. A flat tagged record rather than a variant: Mojo has no
# std::variant, and the fields a note needs are the fields a rest needs with
# two of them unused, so the union buys nothing here.
comptime EV_NOTE = 0
comptime EV_REST = 1
comptime EV_BAR = 2
comptime EV_TEMPO = 3
comptime EV_KEY = 4
comptime EV_METER = 5
comptime EV_VOICE = 6

# Flags on an event.
comptime F_CHORD = 1        # sounds together with the event before it
comptime F_TIE = 2          # tied into the next note of the same pitch
comptime F_GRACE = 4        # a grace note: sounds, but steals no time
comptime F_GCHORD = 8       # generated from a "Am7" chord symbol

# Bar kinds, in the `aux` field of an EV_BAR.
comptime BAR_SINGLE = 0
comptime BAR_DOUBLE = 1
comptime BAR_REPEAT_START = 2
comptime BAR_REPEAT_END = 3
comptime BAR_ENDING_1 = 4
comptime BAR_ENDING_2 = 5
comptime BAR_THIN_THICK = 6


@fieldwise_init
struct Event(ImplicitlyCopyable, Copyable, Movable):
    """One thing that happens, at one time, in one voice.

    `tick` and `duration` are absolute and relative ticks. `aux` carries the
    kind-specific number: beats per minute for a tempo, the bar kind for a
    bar, the sharp count for a key.
    """

    var kind: Int
    var voice: Int
    var tick: Int
    var duration: Int
    var midi: Int
    var velocity: Int
    var aux: Int
    var flags: Int


@fieldwise_init
struct Voice(Copyable, Movable):
    """Per-voice state: what the parser has to remember while reading a part.

    ABC lets any of this change mid-tune through an inline field, so it is
    state rather than configuration.
    """

    var number: Int
    var name: String
    var key_sharps: Int
    var unit_num: Int          # L: as a fraction of a whole note
    var unit_den: Int
    var meter_num: Int
    var meter_den: Int
    var transpose: Int
    var octave_shift: Int
    var instrument: Int        # General MIDI program
    var channel: Int
    var velocity: Int
    var muted: Bool
    var tick: Int              # where this voice has reached


fn configured_voice(
    number: Int, unit_num: Int, unit_den: Int,
    meter_num: Int, meter_den: Int, key_sharps: Int,
) -> Voice:
    """A voice starting life with the tune's header settings."""
    return Voice(
        number=number, name=String(""), key_sharps=key_sharps,
        unit_num=unit_num, unit_den=unit_den,
        meter_num=meter_num, meter_den=meter_den,
        transpose=0, octave_shift=0, instrument=0, channel=-1,
        velocity=80, muted=False, tick=0,
    )


fn new_voice(number: Int) -> Voice:
    return Voice(
        number=number, name=String(""), key_sharps=0,
        unit_num=1, unit_den=8, meter_num=4, meter_den=4,
        transpose=0, octave_shift=0, instrument=0, channel=-1,
        velocity=80, muted=False, tick=0,
    )


struct Tune(Movable):
    """A parsed tune: the events, the voices, and what the headers said."""

    var title: String
    var composer: String
    var events: List[Event]
    var voices: List[Voice]
    var tempo_bpm: Int
    var tempo_num: Int         # the note value the tempo counts, e.g. 1/4
    var tempo_den: Int
    # Header defaults. A voice can be mentioned for the first time in the
    # music, long after L: and K: were read, so the tune has to remember what
    # a new voice should start life with -- otherwise a tune whose header says
    # L:1/4 plays in eighths and nothing in the parse looks wrong.
    var default_unit_num: Int
    var default_unit_den: Int
    var default_meter_num: Int
    var default_meter_den: Int
    var default_key_sharps: Int
    var errors: List[String]

    fn __init__(out self):
        self.title = String("")
        self.composer = String("")
        self.events = List[Event]()
        self.voices = List[Voice]()
        self.tempo_bpm = 120
        self.tempo_num = 1
        self.tempo_den = 4
        self.default_unit_num = 1
        self.default_unit_den = 8
        self.default_meter_num = 4
        self.default_meter_den = 4
        self.default_key_sharps = 0
        self.errors = List[String]()

    fn voice_index(self, number: Int) -> Int:
        """Where this voice number lives in `voices`, or -1."""
        for i in range(len(self.voices)):
            if self.voices[i].number == number:
                return i
        return -1

    fn ensure_voice(mut self, number: Int) -> Int:
        """The index of a voice, creating it if this is its first mention."""
        let at = self.voice_index(number)
        if at >= 0:
            return at
        # The defaults are read into locals before the list is grown: this
        # compiler will not take a read of `self` in the same expression that
        # appends to a list `self` owns, and says so by crashing in
        # DialectConversion rather than by diagnosing it.
        var un = self.default_unit_num
        var ud = self.default_unit_den
        var mn = self.default_meter_num
        var md = self.default_meter_den
        var ks = self.default_key_sharps
        self.voices.append(configured_voice(number, un, ud, mn, md, ks))
        return len(self.voices) - 1

    fn note(mut self, err: String):
        # Bounded: a malformed file should not be able to exhaust memory
        # through the error list alone.
        if len(self.errors) < 200:
            self.errors.append(err)


# ── Pitch ───────────────────────────────────────────────────────────────────


@always_inline
fn letter_index(c: Int) -> Int:
    """C D E F G A B as 0..6, or -1. The order is the scale's, not the
    alphabet's, because every table below is in scale order."""
    if c == 67: return 0    # C
    if c == 68: return 1    # D
    if c == 69: return 2    # E
    if c == 70: return 3    # F
    if c == 71: return 4    # G
    if c == 65: return 5    # A
    if c == 66: return 6    # B
    return -1


@always_inline
fn letter_semitone(index: Int) -> Int:
    """Semitones above C for each scale degree."""
    if index == 0: return 0
    if index == 1: return 2
    if index == 2: return 4
    if index == 3: return 5
    if index == 4: return 7
    if index == 5: return 9
    return 11


@always_inline
fn sharp_order(k: Int) -> Int:
    """Sharps arrive F C G D A E B; flats take the same list backwards."""
    if k == 0: return 3    # F
    if k == 1: return 0    # C
    if k == 2: return 4    # G
    if k == 3: return 1    # D
    if k == 4: return 5    # A
    if k == 5: return 2    # E
    return 6               # B


fn key_alter(sharps: Int, letter: Int) -> Int:
    """What a key signature does to one letter: +1, 0 or -1.

    Derived rather than stored. With `sharps` sharps, the first `sharps`
    letters of F C G D A E B are raised; with flats, the first `-sharps` of
    that list read backwards are lowered.
    """
    if sharps > 0:
        for k in range(sharps):
            if k > 6:
                break
            if sharp_order(k) == letter:
                return 1
    elif sharps < 0:
        for k in range(-sharps):
            if k > 6:
                break
            if sharp_order(6 - k) == letter:
                return -1
    return 0


fn key_sharps_for(name: String) -> Int:
    """The sharp count for a K: field: positive sharps, negative flats.

    Handles the mode suffixes, which are not decoration -- a tune marked
    `K:Ador` is in G major's signature, and reading it as A major puts three
    accidentals in the wrong place for the whole tune.
    """
    let b = name.as_bytes()
    if len(b) == 0:
        return 0
    var tonic = Int(b[0])
    if tonic >= 97 and tonic <= 122:
        tonic -= 32
    let index = letter_index(tonic)
    if index < 0:
        return 0

    # Position on the circle of fifths for the natural letters.
    var fifths = 0
    if tonic == 70: fifths = -1      # F
    elif tonic == 67: fifths = 0     # C
    elif tonic == 71: fifths = 1     # G
    elif tonic == 68: fifths = 2     # D
    elif tonic == 65: fifths = 3     # A
    elif tonic == 69: fifths = 4     # E
    elif tonic == 66: fifths = 5     # B

    var at = 1
    if len(b) > 1 and Int(b[1]) == 35:        # '#'
        fifths += 7
        at = 2
    elif len(b) > 1 and Int(b[1]) == 98:      # 'b'
        fifths -= 7
        at = 2

    var rest = String("")
    for i in range(at, len(b)):
        let c = Int(b[i])
        if c == 32 or c == 9:
            continue
        rest += chr(c + 32 if c >= 65 and c <= 90 else c)

    if rest.startswith("maj") or rest.startswith("ion"):
        pass
    elif rest.startswith("m"):        # m, min, minor -- also covers "mix" below
        if rest.startswith("mix"):
            fifths -= 1
        else:
            fifths -= 3
    elif rest.startswith("dor"):
        fifths -= 2
    elif rest.startswith("phr"):
        fifths -= 4
    elif rest.startswith("lyd"):
        fifths += 1
    elif rest.startswith("loc"):
        fifths -= 5
    elif rest.startswith("aeo"):
        fifths -= 3

    if fifths > 7:
        fifths = 7
    elif fifths < -7:
        fifths = -7
    return fifths


fn midi_for(letter: Int, octave: Int, alter: Int, transpose: Int) -> Int:
    """A MIDI note number. Middle C is 60, as everyone else means it.

    ABC's `C` is middle C, so the octave that letter sits in is 5 in the
    (octave * 12) convention -- 5 * 12 + 0 = 60. Writing `base_octave * 12`
    with base_octave 4 gives 48, which is a C, an octave low, and sounds
    plausible enough to survive review.
    """
    var n = octave * 12 + letter_semitone(letter) + alter + transpose
    if n < 0:
        n = 0
    elif n > 127:
        n = 127
    return n
