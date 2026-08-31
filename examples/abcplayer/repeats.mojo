# Repeats, expanded properly -- including first and second endings.
#
# `|: A |1 B :|2 C |` plays A B A C. That is the whole point of the notation
# and it is the case naive expanders get wrong: duplicating the text between
# `|:` and `:|` gives A B A B, so the tune ends on the wrong phrase every
# time. Endings are not decoration; they are how a repeated strain gets out
# of itself.
#
# The expansion works on events rather than on text. By this point every note
# already knows its voice and its length, so replaying a section is copying a
# range and re-stamping the clock -- and a repeat that crosses a line break,
# or sits inside one voice of several, needs no special handling at all.

from model import (
    Tune, Event, EV_NOTE, EV_REST, EV_BAR,
    F_CHORD, F_GRACE,
    BAR_REPEAT_START, BAR_REPEAT_END, BAR_ENDING_1, BAR_ENDING_2,
)


def expand_repeats(mut tune: Tune):
    """Rewrite the event list with every repeated section played out."""
    var expanded = List[Event]()

    for vi in range(len(tune.voices)):
        let voice = tune.voices[vi].number

        # This voice's events, in the order they were written.
        var own = List[Int]()
        for i in range(len(tune.events)):
            if tune.events[i].voice == voice:
                own.append(i)
        if len(own) == 0:
            continue

        # Walk once, appending a replay each time a `:|` is reached.
        var order = List[Int]()
        var repeat_start = 0
        var ending1 = -1
        var i = 0
        while i < len(own):
            let ev = tune.events[own[i]]
            if ev.kind == EV_BAR and ev.aux == BAR_REPEAT_START:
                repeat_start = i
                ending1 = -1
                order.append(own[i])
            elif ev.kind == EV_BAR and ev.aux == BAR_ENDING_1:
                ending1 = i
                order.append(own[i])
            elif ev.kind == EV_BAR and ev.aux == BAR_REPEAT_END:
                order.append(own[i])
                # The replay stops where the first ending begins, so the
                # second pass falls through into the second ending.
                let stop = ending1 if ending1 >= 0 else i
                for k in range(repeat_start, stop):
                    order.append(own[k])
                ending1 = -1
                repeat_start = i
            else:
                order.append(own[i])
            i += 1

        # Re-stamp the clock. Only what occupies time advances it: a chord's
        # later members sound with the first, a grace note steals nothing,
        # and a bar line is a marker.
        var tick = 0
        var group_tick = 0
        for k in range(len(order)):
            var ev = tune.events[order[k]]
            if ev.kind == EV_BAR:
                ev.tick = tick
                expanded.append(ev)
                continue
            if (ev.flags & F_CHORD) != 0 or (ev.flags & F_GRACE) != 0:
                # A chord's later members sound with the note that opened the
                # group, which is the tick *before* it advanced the clock --
                # using the current tick instead spreads a chord out into an
                # arpeggio, one member per beat, which is audibly wrong and
                # looks like a parser bug rather than a re-timing one.
                ev.tick = group_tick
                expanded.append(ev)
                continue
            group_tick = tick
            ev.tick = tick
            expanded.append(ev)
            tick += ev.duration
        tune.voices[vi].tick = tick

    tune.events = expanded^


def total_ticks(tune: Tune) -> Int:
    """The end of the longest voice."""
    var last = 0
    for i in range(len(tune.events)):
        let end = tune.events[i].tick + tune.events[i].duration
        if end > last:
            last = end
    return last
