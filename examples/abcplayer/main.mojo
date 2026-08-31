# An ABC player, in Mojo, with two ways to make the sound.
#
#   --chip   three chip voices: pulse, saw, noise, filter (the fun one)
#   --midi   Apple's DLS synthesiser, General MIDI (the dull, correct one)
#   --write  a Standard MIDI File, and no playing at all
#
# Both backends share one render callback and one schedule. That is the point
# of the design: the tune is turned into a list of "at sample N, do this",
# and the only thing a backend decides is what "this" means. Nothing about
# timing is duplicated, so nothing about timing can differ between them.
#
# The events are dispatched at sample offsets inside the buffer, not at buffer
# boundaries and not by waking a thread. For the MIDI backend that means
# MusicDeviceMIDIEvent is handed the offset directly; the synth applies the
# note at that sample. For the chip it means the buffer is rendered in spans
# between events. Either way a note begins on the sample it was written for.

from std.objc import (
    Obj, Cls, load_framework, ObjCClass, ObjCObject, msg_send, nsstring,
    autoreleasepool, named_global, extern_object, CGPoint, CGSize, CGRect,
)
from std.memory import Pointer, MutUntrackedOrigin, OpaquePointer
from std.ffi import external_call, c_char
from std.time import sleep
from std.sys import argv

from chip import (
    P, chip_new, get, put, vget, vput, set_wave, set_adsr, set_filter,
    route_filter, set_volume, set_pulse_width, PLAYER_BASE, SAMPLE_RATE,
    V_ENV, WAVE_PULSE, WAVE_SAW, WAVE_TRI, FILT_LP,
)
from model import Tune, EV_NOTE
from parse import parse_abc
from repeats import expand_repeats
from schedule import Step, build_schedule, resolve_ties, ticks_per_beat
from chipplay import (
    flatten_schedule, render_scheduled, midi_to_hz,
    SC_ADDR, SC_COUNT, SC_CURSOR, SC_SAMPLE, SC_END, SC_LOOP, SC_PAUSE,
    SC_DONE, SC_VOICE_NOTE, STEP_SLOTS,
)
from schedule import SE_NOTE_ON, SE_NOTE_OFF
from midi import write_midi

# UI and backend state, in the tail of the chip's player region. chipplay
# owns slots 0..23 there; these start well clear of them.
comptime UI_SCOPE = 32
comptime UI_SCOPE_POS = 33
comptime UI_BACKEND = 34
comptime UI_SYNTH = 35           # the DLS synth's AudioUnit, as an address

comptime BACKEND_CHIP = 0
comptime BACKEND_MIDI = 1
comptime SCOPE_LEN = 1024

comptime g_chip = named_global["abc.chip", Int]
comptime g_view = named_global["abc.view", Int]
comptime g_cmd = named_global["abc.cmd", Int]
comptime g_font_title = named_global["abc.font.title", Int]
comptime g_font_body = named_global["abc.font.body", Int]
comptime g_font_small = named_global["abc.font.small", Int]

comptime CMD_QUIT = 1

# ── CoreAudio ───────────────────────────────────────────────────────────────

comptime kAudioUnitType_Output = 0x61756F75
comptime kAudioUnitSubType_DefaultOutput = 0x64656620
comptime kAudioUnitType_MusicDevice = 0x61756D75
comptime kAudioUnitSubType_DLSSynth = 0x646C7320
comptime kAudioUnitManufacturer_Apple = 0x6170706C
comptime kAudioFormatLinearPCM = 0x6C70636D
comptime kAudioFormatFlagIsFloat = 1
comptime kAudioFormatFlagIsPacked = 8
comptime kAudioFormatFlagIsNonInterleaved = 32
comptime kAudioUnitProperty_StreamFormat = 8
comptime kAudioUnitProperty_SetRenderCallback = 23
comptime kAudioUnitScope_Input = 1
comptime kAudioUnitScope_Output = 0

comptime AURenderCallback = fn(P, P, P, UInt32, UInt32, P, /) -> Int32


fn render(
    ref_con: P,
    action_flags: P,
    timestamp: P,
    bus: UInt32,
    frames: UInt32,
    io_data: P,
) -> Int32:
    """Fill one buffer. Runs on CoreAudio's real-time thread.

    The buffer list is two non-interleaved float channels: an AudioBuffer is
    {UInt32 channels; UInt32 bytes; void* data} and the list's array starts at
    offset 8, so channel i's data pointer sits at 16 + i*16.
    """
    let st = ref_con
    let n = Int(frames)
    let words = io_data.unsafe_bitcast[Int]()
    let left_addr = words[unsafe_offset=2]
    if left_addr == 0:
        return 0
    let nbuffers = Int(io_data.unsafe_bitcast[UInt32]()[unsafe_offset=0])
    var right_addr = 0
    if nbuffers > 1:
        right_addr = words[unsafe_offset=4]

    let left = Pointer[Float32, MutUntrackedOrigin](
        unsafe_from_address=left_addr
    )

    if get(st, PLAYER_BASE + UI_PAUSE_SLOT()) != 0:
        for i in range(n):
            left[unsafe_offset=i] = Float32(0.0)
        if right_addr != 0:
            let right = Pointer[Float32, MutUntrackedOrigin](
                unsafe_from_address=right_addr
            )
            for i in range(n):
                right[unsafe_offset=i] = Float32(0.0)
        return 0

    if get(st, PLAYER_BASE + UI_BACKEND) == BACKEND_MIDI:
        render_midi(st, action_flags, timestamp, frames, io_data, n)
    else:
        render_scheduled(st, left, n)
        if right_addr != 0:
            let right = Pointer[Float32, MutUntrackedOrigin](
                unsafe_from_address=right_addr
            )
            for i in range(n):
                right[unsafe_offset=i] = left[unsafe_offset=i]

    # A copy for the scope. Unsynchronised on purpose: a torn sweep costs one
    # frame of a wrong picture, where a lock would cost a click.
    let scope_addr = get(st, PLAYER_BASE + UI_SCOPE)
    if scope_addr != 0:
        let scope = Pointer[Float32, MutUntrackedOrigin](
            unsafe_from_address=scope_addr
        )
        var pos = get(st, PLAYER_BASE + UI_SCOPE_POS)
        for i in range(n):
            scope[unsafe_offset=pos] = left[unsafe_offset=i]
            pos += 1
            if pos >= SCOPE_LEN:
                pos = 0
        put(st, PLAYER_BASE + UI_SCOPE_POS, pos)
    return 0


@always_inline
fn UI_PAUSE_SLOT() -> Int:
    return SC_PAUSE


fn render_midi(
    st: P, action_flags: P, timestamp: P, frames: UInt32, io_data: P, n: Int
):
    """Dispatch this buffer's MIDI events, then pull the synth into it.

    `MusicDeviceMIDIEvent` takes an offset in samples from the start of the
    buffer being rendered, so an event 137 samples in is applied 137 samples
    in -- the same accuracy the chip backend gets by rendering in spans, and
    the reason this player does not need a scheduling thread at all.
    """
    let synth = P(unsafe_from_address=get(st, PLAYER_BASE + UI_SYNTH))
    let addr = get(st, PLAYER_BASE + SC_ADDR)
    if addr != 0:
        let sched = Pointer[Int, MutUntrackedOrigin](unsafe_from_address=addr)
        let count = get(st, PLAYER_BASE + SC_COUNT)
        let start = get(st, PLAYER_BASE + SC_SAMPLE)
        var cursor = get(st, PLAYER_BASE + SC_CURSOR)
        while cursor < count:
            let at = cursor * STEP_SLOTS
            let when = sched[unsafe_offset=at]
            if when >= start + n:
                break
            var offset = when - start
            if offset < 0:
                offset = 0
            let note = sched[unsafe_offset=at + 3]
            let velocity = sched[unsafe_offset=at + 4]
            # Voices beyond the sixteen MIDI channels fold onto the last one.
            var channel = sched[unsafe_offset=at + 2] - 1
            if channel < 0:
                channel = 0
            if channel >= 9:
                channel += 1
            if channel > 15:
                channel = 15
            if sched[unsafe_offset=at + 1] == SE_NOTE_ON:
                _ = external_call["MusicDeviceMIDIEvent", Int32](
                    synth, UInt32(0x90 | channel), UInt32(note),
                    UInt32(velocity), UInt32(offset),
                )
            else:
                _ = external_call["MusicDeviceMIDIEvent", Int32](
                    synth, UInt32(0x80 | channel), UInt32(note),
                    UInt32(0), UInt32(offset),
                )
            cursor += 1
        put(st, PLAYER_BASE + SC_CURSOR, cursor)
        put(st, PLAYER_BASE + SC_SAMPLE, start + n)
        if cursor >= count and start + n > get(st, PLAYER_BASE + SC_END):
            if get(st, PLAYER_BASE + SC_LOOP) != 0:
                put(st, PLAYER_BASE + SC_CURSOR, 0)
                put(st, PLAYER_BASE + SC_SAMPLE, 0)
            else:
                put(st, PLAYER_BASE + SC_DONE, 1)

    # Pull the synth straight into the buffer we were handed.
    _ = external_call["AudioUnitRender", Int32](
        synth, action_flags, timestamp, UInt32(0), frames, io_data
    )


def make_unit(atype: Int, subtype: Int) raises -> P:
    var desc = external_call["calloc", P](Int(5), Int(4))
    let d = desc.unsafe_bitcast[UInt32]()
    d[unsafe_offset=0] = UInt32(atype)
    d[unsafe_offset=1] = UInt32(subtype)
    d[unsafe_offset=2] = UInt32(kAudioUnitManufacturer_Apple)
    var nil_addr = 0
    let comp = external_call["AudioComponentFindNext", P](
        P(unsafe_from_address=nil_addr), desc
    )
    if Int(comp) == 0:
        raise Error("audio component not found")
    var slot = external_call["calloc", P](Int(1), Int(8))
    let rc = external_call["AudioComponentInstanceNew", Int32](comp, slot)
    if rc != 0:
        raise Error("could not instantiate the audio unit")
    return P(unsafe_from_address=slot.unsafe_bitcast[Int]()[unsafe_offset=0])


def stereo_format() -> P:
    """The canonical AudioUnit format: 32-bit float, two non-interleaved
    channels. Both backends speak it, so neither needs a conversion."""
    var asbd = external_call["calloc", P](Int(40), Int(1))
    asbd.unsafe_bitcast[Float64]()[unsafe_offset=0] = Float64(SAMPLE_RATE)
    let a = asbd.unsafe_bitcast[UInt32]()
    a[unsafe_offset=2] = UInt32(kAudioFormatLinearPCM)
    a[unsafe_offset=3] = UInt32(
        kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        | kAudioFormatFlagIsNonInterleaved
    )
    a[unsafe_offset=4] = UInt32(4)     # bytes per packet
    a[unsafe_offset=5] = UInt32(1)     # frames per packet
    a[unsafe_offset=6] = UInt32(4)     # bytes per frame
    a[unsafe_offset=7] = UInt32(2)     # channels
    a[unsafe_offset=8] = UInt32(32)    # bits per channel
    return asbd


def start_audio(st: P, backend: Int) raises -> Int:
    if not load_framework["AudioToolbox"]():
        raise Error("could not load AudioToolbox")

    if backend == BACKEND_MIDI:
        let synth = make_unit(
            kAudioUnitType_MusicDevice, kAudioUnitSubType_DLSSynth
        )
        var rc = external_call["AudioUnitSetProperty", Int32](
            synth, UInt32(kAudioUnitProperty_StreamFormat),
            UInt32(kAudioUnitScope_Output), UInt32(0), stereo_format(),
            UInt32(40),
        )
        rc = external_call["AudioUnitInitialize", Int32](synth)
        if rc != 0:
            raise Error("could not initialise the DLS synth")
        put(st, PLAYER_BASE + UI_SYNTH, Int(synth))

    let unit = make_unit(kAudioUnitType_Output, kAudioUnitSubType_DefaultOutput)
    var rc = external_call["AudioUnitSetProperty", Int32](
        unit, UInt32(kAudioUnitProperty_StreamFormat),
        UInt32(kAudioUnitScope_Input), UInt32(0), stereo_format(), UInt32(40),
    )
    if rc != 0:
        raise Error("could not set the stream format")

    var cbfn: AURenderCallback = render
    let fn_addr = Pointer(to=cbfn).unsafe_bitcast[Int]()[]
    var cbs = external_call["calloc", P](Int(2), Int(8))
    cbs.unsafe_bitcast[Int]()[unsafe_offset=0] = fn_addr
    cbs.unsafe_bitcast[Int]()[unsafe_offset=1] = Int(st)
    rc = external_call["AudioUnitSetProperty", Int32](
        unit, UInt32(kAudioUnitProperty_SetRenderCallback),
        UInt32(kAudioUnitScope_Input), UInt32(0), cbs, UInt32(16),
    )
    if rc != 0:
        raise Error("could not install the render callback")

    rc = external_call["AudioUnitInitialize", Int32](unit)
    if rc != 0:
        raise Error("could not initialise the output unit")
    rc = external_call["AudioOutputUnitStart", Int32](unit)
    if rc != 0:
        raise Error("could not start the output unit")
    return Int(unit)


fn stop_audio(unit_addr: Int):
    if unit_addr == 0:
        return
    let unit = P(unsafe_from_address=unit_addr)
    _ = external_call["AudioOutputUnitStop", Int32](unit)
    _ = external_call["AudioUnitUninitialize", Int32](unit)


# ── The window ──────────────────────────────────────────────────────────────

comptime WIN_W = 780.0
comptime WIN_H = 460.0
comptime FRAME = 20.0

comptime g_title = named_global["abc.title", Int]      # an NSString, retained
comptime g_subtitle = named_global["abc.subtitle", Int]
comptime g_backend_name = named_global["abc.backend", Int]


fn rgb(r: Int, g: Int, b: Int) -> ObjCObject:
    return Cls["NSColor"]().colorWithSRGBRed_green_blue_alpha(
        Float64(r) / 255.0, Float64(g) / 255.0, Float64(b) / 255.0, 1.0
    )


fn rect(x: Float64, y: Float64, w: Float64, h: Float64) -> CGRect:
    return CGRect(CGPoint(x, y), CGSize(w, h))


fn fill_rect(r: CGRect, colour: ObjCObject):
    Obj["NSColor"](colour.addr()).setFill()
    _ = external_call["NSRectFill", NoneType](r)


fn make_font(size: Float64) -> Int:
    with autoreleasepool():
        let f = Cls["NSFont"]().monospacedSystemFontOfSize_weight(
            size, Float64(0.0)
        )
        if not f.is_nil():
            _ = external_call["objc_retain", P](f.ptr())
            return f.addr()
        let g = Cls["NSFont"]().systemFontOfSize(size)
        if g.is_nil():
            return 0
        _ = external_call["objc_retain", P](g.ptr())
        return g.addr()


fn draw_text(text: String, x: Float64, y: Float64, font_addr: Int,
             colour: ObjCObject):
    with autoreleasepool():
        var attrs = Cls["NSMutableDictionary"]().dictionary()
        if font_addr != 0:
            Obj["NSMutableDictionary"](attrs.addr()).setObject_forKey(
                ObjCObject(font_addr).ptr(),
                extern_object["NSFontAttributeName"]().ptr(),
            )
        Obj["NSMutableDictionary"](attrs.addr()).setObject_forKey(
            colour.ptr(),
            extern_object["NSForegroundColorAttributeName"]().ptr(),
        )
        Obj["NSString"](nsstring(text).addr()).drawAtPoint_withAttributes(
            CGPoint(x, y), attrs.ptr()
        )


fn note_name(midi: Int) -> String:
    if midi < 0:
        return String("---")
    let names = String("C C#D D#E F F#G G#A A#B ")
    let pc = midi % 12
    let octave = midi // 12 - 1
    return names[byte = pc * 2 : pc * 2 + 2] + String(octave)


fn format_time(samples: Int) -> String:
    let total = samples // SAMPLE_RATE
    let minutes = total // 60
    let seconds = total % 60
    var s = String(minutes) + String(":")
    if seconds < 10:
        s += String("0")
    return s + String(seconds)


fn draw_screen():
    let st = P(unsafe_from_address=g_chip()[])
    with autoreleasepool():
        let ink = rgb(228, 232, 240)
        let dim = rgb(128, 138, 158)
        let accent = rgb(120, 220, 160)
        fill_rect(rect(0.0, 0.0, WIN_W, WIN_H), rgb(18, 20, 26))

        let left = FRAME + 8.0
        var y = WIN_H - FRAME - 30.0
        if g_title()[] != 0:
            draw_nsstring(g_title()[], left, y, g_font_title()[], ink)
        y -= 24.0
        if g_subtitle()[] != 0:
            draw_nsstring(g_subtitle()[], left, y, g_font_small()[], dim)

        # ── The scope ───────────────────────────────────────────────────────
        let sx = left
        let sy = 250.0
        let sw = WIN_W - 2.0 * FRAME - 16.0
        let sh = 120.0
        fill_rect(rect(sx, sy, sw, sh), rgb(10, 12, 16))
        let mid = sy + sh / 2.0
        fill_rect(rect(sx, mid, sw, 1.0), rgb(38, 44, 54))
        let scope_addr = get(st, PLAYER_BASE + UI_SCOPE)
        if scope_addr != 0:
            let scope = Pointer[Float32, MutUntrackedOrigin](
                unsafe_from_address=scope_addr
            )
            Obj["NSColor"](accent.addr()).setFill()
            let points = Int(sw) // 2
            for i in range(points):
                let s = Float64(scope[unsafe_offset=(i * SCOPE_LEN) // points])
                let h = s * (sh / 2.0 - 4.0)
                var top = mid
                var height = h
                if h < 0.0:
                    top = mid + h
                    height = -h
                if height < 1.5:
                    height = 1.5
                _ = external_call["NSRectFill", NoneType](
                    rect(sx + Float64(i * 2), top, 2.0, height)
                )

        # ── Position and voices ─────────────────────────────────────────────
        y = 210.0
        let played = get(st, PLAYER_BASE + SC_SAMPLE)
        let total = get(st, PLAYER_BASE + SC_END)
        var line = String("position ") + format_time(played)
        line += String(" / ") + format_time(total)
        if get(st, PLAYER_BASE + SC_PAUSE) != 0:
            line += String("   [paused]")
        draw_text(line, left, y, g_font_body()[], ink)

        # The progress bar, which is the only part of this that a listener
        # actually watches.
        y -= 26.0
        let bar_w = WIN_W - 2.0 * FRAME - 16.0
        fill_rect(rect(left, y, bar_w, 10.0), rgb(34, 38, 48))
        if total > 0:
            var frac = Float64(played) / Float64(total)
            if frac > 1.0:
                frac = 1.0
            fill_rect(rect(left, y, bar_w * frac, 10.0), accent)

        y -= 40.0
        if get(st, PLAYER_BASE + UI_BACKEND) == BACKEND_CHIP:
            draw_text(String("chip voices"), left, y, g_font_small()[], dim)
            y -= 26.0
            for v in range(3):
                let held = get(st, PLAYER_BASE + SC_VOICE_NOTE + v)
                let env = vget(st, v, V_ENV) >> 16
                var row = String("  ") + String(v + 1) + String("   ")
                row += note_name(held) + String("   ")
                draw_text(row, left, y, g_font_body()[],
                          ink if held >= 0 else dim)
                let bx = left + 140.0
                fill_rect(rect(bx, y + 2.0, 200.0, 10.0), rgb(34, 38, 48))
                if env > 0:
                    fill_rect(
                        rect(bx, y + 2.0, 200.0 * Float64(env) / 255.0, 10.0),
                        accent,
                    )
                y -= 24.0
        else:
            draw_text(
                String("General MIDI · Apple DLS synthesiser"),
                left, y, g_font_body()[], ink,
            )

        draw_text(
            String("SPACE pause    Q quit"),
            left, FRAME + 6.0, g_font_small()[], dim,
        )


fn draw_nsstring(addr: Int, x: Float64, y: Float64, font_addr: Int,
                 colour: ObjCObject):
    """Draw a string built once and retained, rather than rebuilt per frame.

    The title does not change; converting it from a Mojo String thirty times
    a second would be work for nothing.
    """
    with autoreleasepool():
        var attrs = Cls["NSMutableDictionary"]().dictionary()
        if font_addr != 0:
            Obj["NSMutableDictionary"](attrs.addr()).setObject_forKey(
                ObjCObject(font_addr).ptr(),
                extern_object["NSFontAttributeName"]().ptr(),
            )
        Obj["NSMutableDictionary"](attrs.addr()).setObject_forKey(
            colour.ptr(),
            extern_object["NSForegroundColorAttributeName"]().ptr(),
        )
        Obj["NSString"](ObjCObject(addr).addr()).drawAtPoint_withAttributes(
            CGPoint(x, y), attrs.ptr()
        )


class AbcView(NSView):
    def drawRect_(self, dirty: CGRect):
        draw_screen()

    def acceptsFirstResponder(self) -> Bool:
        return True

    def keyDown_(self, event: ObjCObject):
        let chars = msg_send[
            ObjCObject, "NSEvent", "charactersIgnoringModifiers"
        ](event)
        if chars.is_nil():
            return
        let p = msg_send[P, "NSString", "UTF8String"](chars)
        if Int(p) == 0:
            return
        let text = String(unsafe_from_utf8_ptr=p.unsafe_bitcast[c_char]())
        if len(text.as_bytes()) == 0:
            return
        let c = Int(text.as_bytes()[0])
        let st = P(unsafe_from_address=g_chip()[])
        if c == 113 or c == 81 or c == 27:
            g_cmd()[] = g_cmd()[] | CMD_QUIT
        elif c == 32:
            let was = get(st, PLAYER_BASE + SC_PAUSE)
            put(st, PLAYER_BASE + SC_PAUSE, 0 if was != 0 else 1)


fn redraw():
    if g_view()[] != 0:
        Obj["NSView"](ObjCObject(g_view()[]).addr()).setNeedsDisplay(True)


def main() raises:
    var path = String("")
    var backend = BACKEND_CHIP
    var write_only = String("")
    let args = argv()
    for i in range(1, len(args)):
        let a = String(args[i])
        if a == "--midi":
            backend = BACKEND_MIDI
        elif a == "--chip":
            backend = BACKEND_CHIP
        elif a.startswith("--write="):
            write_only = String(a[byte=8 : len(a.as_bytes())])
        else:
            path = a
    if len(path.as_bytes()) == 0:
        print("usage: abcplayer <tune.abc> [--chip|--midi] [--write=out.mid]")
        return

    var text = String("")
    try:
        with open(path, "r") as f:
            text = f.read()
    except:
        raise Error("could not read " + path)

    var tune = Tune()
    parse_abc(text, tune)
    expand_repeats(tune)
    resolve_ties(tune)

    var notes = 0
    for i in range(len(tune.events)):
        if tune.events[i].kind == EV_NOTE and tune.events[i].velocity > 0:
            notes += 1
    print("tune:", tune.title, " voices:", len(tune.voices), " notes:", notes)
    print("tempo:", tune.tempo_bpm, "bpm")

    if len(write_only.as_bytes()) > 0:
        if write_midi(tune, write_only):
            print("wrote", write_only)
        else:
            print("could not write", write_only)
        return

    var steps = List[Step]()
    build_schedule(tune, SAMPLE_RATE, steps)
    if len(steps) == 0:
        print("nothing to play")
        return

    if not load_framework["AppKit"]():
        raise Error("could not load AppKit")

    var st = chip_new()
    g_chip()[] = Int(st)
    put(st, PLAYER_BASE + UI_BACKEND, backend)
    put(st, PLAYER_BASE + SC_LOOP, 1)
    put(
        st, PLAYER_BASE + UI_SCOPE,
        Int(external_call["calloc", P](Int(SCOPE_LEN), Int(4))),
    )
    _ = flatten_schedule(steps, st)

    # A chip voice per part: pulse for the melody, saw underneath. The
    # settings are the ones the chip example arrived at, which is the point of
    # having the chip in its own module.
    for v in range(3):
        set_wave(st, v, WAVE_PULSE if v == 0 else WAVE_SAW)
        set_adsr(st, v, 0, 7, 11, 5)
        set_pulse_width(st, v, 1400)
        route_filter(st, v, True)
    set_filter(st, 1500, 6, FILT_LP)
    set_volume(st, 14)

    # The two fixed strings, made once and retained.
    with autoreleasepool():
        let title_str = nsstring(
            tune.title if len(tune.title.as_bytes()) > 0 else String("(untitled)")
        )
        _ = external_call["objc_retain", P](title_str.ptr())
        g_title()[] = title_str.addr()
        var sub = String("")
        if len(tune.composer.as_bytes()) > 0:
            sub += tune.composer + String("   ·   ")
        sub += String(len(tune.voices)) + String(" voices   ·   ")
        sub += String(notes) + String(" notes   ·   ")
        sub += String(tune.tempo_bpm) + String(" bpm   ·   ")
        sub += String("chip" if backend == BACKEND_CHIP else "General MIDI")
        let sub_str = nsstring(sub)
        _ = external_call["objc_retain", P](sub_str.ptr())
        g_subtitle()[] = sub_str.addr()

    g_font_title()[] = make_font(16.0)
    g_font_body()[] = make_font(13.0)
    g_font_small()[] = make_font(11.0)

    let unit = start_audio(st, backend)
    print("playing through the", "DLS synth" if backend == BACKEND_MIDI else "chip")

    with autoreleasepool():
        let NSApplication = ObjCClass.lookup["NSApplication"]()
        let app = msg_send[
            ObjCObject, "NSApplication", "sharedApplication", is_class=True
        ](NSApplication.as_object())
        _ = msg_send[Bool, "NSApplication", "setActivationPolicy:"](app, Int(0))

        let NSWindow = ObjCClass.lookup["NSWindow"]()
        var win = msg_send[ObjCObject, "NSWindow", "alloc", is_class=True](
            NSWindow.as_object()
        )
        win = msg_send[
            ObjCObject, "NSWindow",
            "initWithContentRect:styleMask:backing:defer:",
        ](
            win, CGRect(CGPoint(200.0, 200.0), CGSize(WIN_W, WIN_H)),
            Int(15), Int(2), Bool(False),
        )
        _ = msg_send[ObjCObject, "NSWindow", "setTitle:"](
            win, nsstring(tune.title if len(tune.title.as_bytes()) > 0
                          else String("ABC")).ptr()
        )

        let view = ObjCObject(AbcView().__objc_id)
        _ = msg_send[ObjCObject, "NSView", "setFrame:"](
            view, rect(0.0, 0.0, WIN_W, WIN_H)
        )
        # Retained: the Mojo wrapper releases at the end of this statement,
        # and AppKit would then be drawing into a freed object.
        _ = external_call["objc_retain", P](view.ptr())
        g_view()[] = view.addr()
        _ = msg_send[ObjCObject, "NSWindow", "setContentView:"](win, view.ptr())
        _ = msg_send[ObjCObject, "NSWindow", "makeFirstResponder:"](
            win, view.ptr()
        )
        _ = msg_send[ObjCObject, "NSWindow", "makeKeyAndOrderFront:"](
            win, win.ptr()
        )
        _ = msg_send[ObjCObject, "NSApplication", "activateIgnoringOtherApps:"](
            app, Bool(True)
        )

        let NSDate = ObjCClass.lookup["NSDate"]()
        var mode = nsstring(String("kCFRunLoopDefaultMode"))
        var running = True
        while running:
            while True:
                var past = msg_send[
                    ObjCObject, "NSDate", "distantPast", is_class=True
                ](NSDate.as_object())
                var ev = msg_send[
                    ObjCObject, "NSApplication",
                    "nextEventMatchingMask:untilDate:inMode:dequeue:",
                ](app, UInt64.MAX, past.ptr(), mode.ptr(), Bool(True))
                if ev.is_nil():
                    break
                _ = msg_send[ObjCObject, "NSApplication", "sendEvent:"](
                    app, ev.ptr()
                )
            if not msg_send[Bool, "NSWindow", "isVisible"](win):
                break
            if (g_cmd()[] & CMD_QUIT) != 0:
                break
            redraw()
            sleep(0.033)

    stop_audio(unit)
    print("stopped.")
