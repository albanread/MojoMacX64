# A chip-tune synthesiser with a window, in Mojo.
#
# The point of this example is the thread boundary. CoreAudio calls a render
# callback on a real-time thread it owns: a C function pointer, invoked every
# few milliseconds, with a hard deadline and no permission to allocate, lock,
# or raise. Cocoa draws on the main thread. The two never wait for each other.
#
# Mojo can be on both sides of that, which is the thing worth showing:
#
#   * `fn` is a foreign-callable C-ABI function -- so `render` below IS an
#     AURenderCallback, installed straight into the audio unit with no shim,
#     no Objective-C, and no C file in the build
#   * `class` declares a real Objective-C class -- so the same program's view
#     is an NSView subclass AppKit dispatches to normally
#
# The audio path allocates nothing after startup. All chip state lives in one
# block passed through CoreAudio's inRefCon, which is why there is no global
# holding the chip and why two of these could run at once.
#
# The screen is the C64's own palette, because it seemed rude to do otherwise.

from std.objc import (
    Obj,
    Cls,
    load_framework,
    ObjCClass,
    ObjCObject,
    msg_send,
    nsstring,
    autoreleasepool,
    named_global,
    extern_object,
    CGPoint,
    CGSize,
    CGRect,
)
from std.memory import Pointer, MutUntrackedOrigin, OpaquePointer
from std.ffi import external_call, c_char
from std.time import sleep
from std.sys import argv

from chip import (
    P, chip_new, chip_render, get, put, vget, vput, set_filter,
    S_CUTOFF, S_RES, S_FMODE, S_FRAME, V_ENV, V_WAVE, V_PHASE, V_STEP,
    PLAYER_BASE, SAMPLE_RATE, CLOCK_PAL,
    WAVE_TRI, WAVE_SAW, WAVE_PULSE, WAVE_NOISE, FILT_LP, FILT_BP, FILT_HP,
)
from tune import (
    build_demo, player_tick, player_attach, instrument_lead, instrument_bass,
)
from abc import parse_abc, install_abc

# ── The UI's own slots ──────────────────────────────────────────────────────
# The tail of the chip's player region is unused by the player, so the parts
# the interface owns live there. That keeps the render callback reachable from
# one pointer: it is handed the chip, and everything hangs off that.

comptime UI_SCOPE = 64       # address of the scope ring buffer
comptime UI_SCOPE_POS = 65
comptime UI_PAUSE = 66
comptime UI_MUTE = 68        # three slots, one per voice
comptime UI_SAVED_WAVE = 72  # three slots: what a muted voice was playing

comptime SCOPE_LEN = 1024

comptime g_chip = named_global["chip.state", Int]
comptime g_view = named_global["chip.view", Int]
comptime g_cmd = named_global["chip.cmd", Int]
comptime g_quit = named_global["chip.quit", Int]

# The fonts, made once and retained. Building a font inside drawRect: is both
# wasteful and unreliable: at thirty frames a second the font this asked for
# eventually came back nil, and a nil value into an attributes dictionary
# raises -- which surfaces as a trap inside AppKit's drawing machinery with a
# stack that mentions nothing about fonts.
comptime g_font_title = named_global["chip.font.title", Int]
comptime g_font_body = named_global["chip.font.body", Int]
comptime g_font_small = named_global["chip.font.small", Int]

comptime CMD_QUIT = 1


# ── CoreAudio ───────────────────────────────────────────────────────────────
# Four-character codes, as the headers spell them.

comptime kAudioUnitType_Output = 0x61756F75            # 'auou'
comptime kAudioUnitSubType_DefaultOutput = 0x64656620  # 'def '
comptime kAudioUnitManufacturer_Apple = 0x6170706C     # 'appl'
comptime kAudioFormatLinearPCM = 0x6C70636D            # 'lpcm'
comptime kAudioFormatFlagIsFloat = 1
comptime kAudioFormatFlagIsPacked = 8
comptime kAudioUnitProperty_StreamFormat = 8
comptime kAudioUnitProperty_SetRenderCallback = 23
comptime kAudioUnitScope_Input = 1

# The callback's type. An AURenderCallback is a C function pointer, and `fn`
# in a type position is exactly that -- the same aliasing the Objective-C
# bindings use for an IMP.
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

    Everything this touches was allocated before the unit started. There is no
    lock here and there must not be one: the main thread reads the same chip
    state to draw the meters, and a torn read costs a wrong pixel for one
    frame, where a held lock would cost a click in the speaker.

    An AudioBufferList is {UInt32 mNumberBuffers; AudioBuffer mBuffers[]} and
    an AudioBuffer is {UInt32 mNumberChannels; UInt32 mDataByteSize; void*
    mData}; the pointer is 8-aligned, so the first buffer's data sits at
    offset 16 and its size at 12.
    """
    let base = io_data.unsafe_bitcast[UInt32]()
    let byte_size = Int(base[unsafe_offset=3])
    let data_slot = io_data.unsafe_bitcast[Int]()[unsafe_offset=2]
    if data_slot == 0:
        return 0
    let dest = Pointer[Float32, MutUntrackedOrigin](
        unsafe_from_address=data_slot
    )
    let n = byte_size // 4
    let st = ref_con

    if get(st, PLAYER_BASE + UI_PAUSE) != 0:
        for i in range(n):
            dest[unsafe_offset=i] = Float32(0.0)
        return 0

    chip_render(st, dest, n, player_tick)

    # Hand the drawing side something to show. A plain ring buffer with no
    # synchronisation: the reader may catch a half-written sweep and draw one
    # frame with a seam in it, which is the correct trade for a scope.
    let scope_addr = get(st, PLAYER_BASE + UI_SCOPE)
    if scope_addr != 0:
        let scope = Pointer[Float32, MutUntrackedOrigin](
            unsafe_from_address=scope_addr
        )
        var pos = get(st, PLAYER_BASE + UI_SCOPE_POS)
        for i in range(n):
            scope[unsafe_offset=pos] = dest[unsafe_offset=i]
            pos += 1
            if pos >= SCOPE_LEN:
                pos = 0
        put(st, PLAYER_BASE + UI_SCOPE_POS, pos)
    return 0


def start_audio(st: P) raises -> Int:
    """Open the default output and install the Mojo callback. Returns the unit."""
    if not load_framework["AudioToolbox"]():
        raise Error("could not load AudioToolbox")

    var desc = external_call["calloc", P](Int(5), Int(4))
    let d = desc.unsafe_bitcast[UInt32]()
    d[unsafe_offset=0] = UInt32(kAudioUnitType_Output)
    d[unsafe_offset=1] = UInt32(kAudioUnitSubType_DefaultOutput)
    d[unsafe_offset=2] = UInt32(kAudioUnitManufacturer_Apple)

    var nil_addr = 0
    let comp = external_call["AudioComponentFindNext", P](
        P(unsafe_from_address=nil_addr), desc
    )
    if Int(comp) == 0:
        raise Error("no default output audio component")

    var unit_slot = external_call["calloc", P](Int(1), Int(8))
    var rc = external_call["AudioComponentInstanceNew", Int32](comp, unit_slot)
    if rc != 0:
        raise Error("could not instantiate the output unit")
    let unit = P(
        unsafe_from_address=unit_slot.unsafe_bitcast[Int]()[unsafe_offset=0]
    )

    # AudioStreamBasicDescription: a Float64 sample rate then eight UInt32s.
    # Mono float, which is what the chip produces and what a 6581 had.
    var asbd = external_call["calloc", P](Int(40), Int(1))
    asbd.unsafe_bitcast[Float64]()[unsafe_offset=0] = Float64(SAMPLE_RATE)
    let a = asbd.unsafe_bitcast[UInt32]()
    a[unsafe_offset=2] = UInt32(kAudioFormatLinearPCM)
    a[unsafe_offset=3] = UInt32(
        kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
    )
    a[unsafe_offset=4] = UInt32(4)   # bytes per packet
    a[unsafe_offset=5] = UInt32(1)   # frames per packet
    a[unsafe_offset=6] = UInt32(4)   # bytes per frame
    a[unsafe_offset=7] = UInt32(1)   # channels
    a[unsafe_offset=8] = UInt32(32)  # bits per channel
    rc = external_call["AudioUnitSetProperty", Int32](
        unit, UInt32(kAudioUnitProperty_StreamFormat),
        UInt32(kAudioUnitScope_Input), UInt32(0), asbd, UInt32(40),
    )
    if rc != 0:
        raise Error("could not set the stream format")

    # AURenderCallbackStruct { AURenderCallback proc; void* refCon; }.
    # The function's address is read out of a slot holding it: `fn` here is a
    # C function pointer, so the slot's eight bytes are exactly what CoreAudio
    # wants, and the chip goes in beside it as the refCon.
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


# ── The screen ──────────────────────────────────────────────────────────────
# The VIC-II's sixteen colours. Only a few are needed, but the blue-on-blue
# is the whole look and the light green is what a monitor's phosphor did to
# a bright line.

comptime WIN_W = 760.0
comptime WIN_H = 470.0
comptime FRAME = 22.0


fn rgb(r: Int, g: Int, b: Int) -> ObjCObject:
    return Cls["NSColor"]().colorWithSRGBRed_green_blue_alpha(
        Float64(r) / 255.0, Float64(g) / 255.0, Float64(b) / 255.0, 1.0
    )


fn c64_blue() -> ObjCObject:
    return rgb(64, 49, 141)


fn c64_light_blue() -> ObjCObject:
    return rgb(120, 105, 196)


fn c64_light_green() -> ObjCObject:
    return rgb(148, 224, 137)


fn c64_yellow() -> ObjCObject:
    return rgb(191, 206, 114)


fn c64_light_red() -> ObjCObject:
    return rgb(184, 105, 98)


fn c64_black() -> ObjCObject:
    return rgb(0, 0, 0)


fn rect(x: Float64, y: Float64, w: Float64, h: Float64) -> CGRect:
    return CGRect(CGPoint(x, y), CGSize(w, h))


fn fill_rect(r: CGRect, colour: ObjCObject):
    Obj["NSColor"](colour.addr()).setFill()
    _ = external_call["NSRectFill", NoneType](r)


fn make_font(size: Float64) -> Int:
    """A retained monospaced font, or the system font if that is unavailable.

    Returns a bare address: an ObjCObject cannot live in a global, and this
    outlives every pool anyway because it is retained.
    """
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
        # A nil font is not a reason to bring the process down: draw the text
        # in whatever AppKit defaults to and let the layout look wrong.
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


fn wave_name(wave: Int) -> String:
    """The waveform bits, spelled the way the register reads."""
    if wave == 0:
        return String("---- ")
    var s = String("")
    s += "T" if (wave & WAVE_TRI) != 0 else "."
    s += "S" if (wave & WAVE_SAW) != 0 else "."
    s += "P" if (wave & WAVE_PULSE) != 0 else "."
    s += "N" if (wave & WAVE_NOISE) != 0 else "."
    return s + " "


fn note_name(step: Int) -> String:
    """Turn a voice's frequency back into a note name, for the display.

    The chip has no idea what note it is playing -- it has a step size. Going
    backwards is a logarithm, and this is a display, so it counts instead:
    multiply up from A0 until it passes.
    """
    if step <= 0:
        return String("--- ")
    # step = freq_reg * CLOCK * 256 / SR, and freq_reg = hz * 2^24 / CLOCK,
    # so hz = step * SR / (2^24 * 256).
    let hz = Float64(step) * Float64(SAMPLE_RATE) / 4294967296.0
    if hz < 20.0:
        return String("--- ")
    var midi = 0
    var probe = 8.1757989156  # C-1
    while probe * 1.0293022366 < hz and midi < 127:
        probe *= 1.0594630943592953
        midi += 1
    let names = String("C C#D D#E F F#G G#A A#B ")
    let pc = midi % 12
    let octave = midi // 12 - 1
    return names[byte = pc * 2 : pc * 2 + 2] + String(octave) + String(" ")


fn draw_screen():
    let st = P(unsafe_from_address=g_chip()[])
    with autoreleasepool():
        # The border, and the screen inside it.
        fill_rect(rect(0.0, 0.0, WIN_W, WIN_H), c64_light_blue())
        fill_rect(
            rect(FRAME, FRAME, WIN_W - 2.0 * FRAME, WIN_H - 2.0 * FRAME),
            c64_blue(),
        )

        let left = FRAME + 18.0
        var y = WIN_H - FRAME - 34.0

        draw_text(
            String("**** MOJO CHIP SYNTHESISER ****"),
            left, y, g_font_title()[], c64_light_blue(),
        )
        y -= 22.0
        let paused = get(st, PLAYER_BASE + UI_PAUSE) != 0
        let frame_no = get(st, S_FRAME)
        draw_text(
            String("3 VOICES  48 KHZ  FRAME ") + String(frame_no)
            + (String("  [PAUSED]") if paused else String("")),
            left, y, g_font_body()[], c64_light_blue(),
        )

        # ── The scope ───────────────────────────────────────────────────────
        let scope_x = left
        let scope_y = 224.0
        let scope_w = WIN_W - 2.0 * FRAME - 36.0
        let scope_h = 130.0
        fill_rect(rect(scope_x, scope_y, scope_w, scope_h), c64_black())

        let mid = scope_y + scope_h / 2.0
        # The zero line, so a silent scope still reads as a scope.
        fill_rect(rect(scope_x, mid, scope_w, 1.0), rgb(40, 60, 40))

        let scope_addr = get(st, PLAYER_BASE + UI_SCOPE)
        if scope_addr != 0:
            let scope = Pointer[Float32, MutUntrackedOrigin](
                unsafe_from_address=scope_addr
            )
            let ink = c64_light_green()
            Obj["NSColor"](ink.addr()).setFill()
            let points = Int(scope_w) // 2
            for i in range(points):
                let s = Float64(
                    scope[unsafe_offset=(i * SCOPE_LEN) // points]
                )
                let h = s * (scope_h / 2.0 - 4.0)
                # Draw from the centre outwards so the trace has body, the
                # way a phosphor scope does at low sweep speeds.
                var top = mid
                var height = h
                if h < 0.0:
                    top = mid + h
                    height = -h
                if height < 1.5:
                    height = 1.5
                _ = external_call["NSRectFill", NoneType](
                    rect(scope_x + Float64(i * 2), top, 2.0, height)
                )

        # ── The voices ──────────────────────────────────────────────────────
        y = 182.0
        draw_text(
            String("VOICE  WAVE  NOTE   ENVELOPE"),
            left, y, g_font_body()[], c64_light_blue(),
        )
        y -= 8.0
        for v in range(3):
            y -= 30.0
            let muted = get(st, PLAYER_BASE + UI_MUTE + v) != 0
            let ink = c64_light_red() if muted else c64_yellow()
            let env = vget(st, v, V_ENV) >> 16
            var line = String(" ") + String(v + 1) + String("     ")
            line += wave_name(vget(st, v, V_WAVE))
            line += String(" ") + note_name(vget(st, v, V_STEP))
            draw_text(line, left, y, g_font_body()[], ink)

            # The envelope, as a bar. This is read while the audio thread is
            # writing it; the worst case is one frame of a stale number.
            let bar_x = left + 232.0
            let bar_w = 180.0
            fill_rect(rect(bar_x, y + 2.0, bar_w, 12.0), rgb(30, 24, 80))
            if env > 0:
                let filled = bar_w * Float64(env) / 255.0
                fill_rect(
                    rect(bar_x, y + 2.0, filled, 12.0),
                    c64_light_red() if muted else c64_light_green(),
                )
            if muted:
                draw_text(String("MUTE"), bar_x + bar_w + 12.0, y, g_font_body()[],
                          c64_light_red())

        # ── The filter ──────────────────────────────────────────────────────
        y -= 34.0
        let mode = get(st, S_FMODE)
        var mode_name = String("OFF")
        if mode == FILT_LP:
            mode_name = String("LOW")
        elif mode == FILT_BP:
            mode_name = String("BAND")
        elif mode == FILT_HP:
            mode_name = String("HIGH")
        draw_text(
            String("FILTER ") + mode_name
            + String("  CUTOFF ") + String(get(st, S_CUTOFF))
            + String("  RES ") + String(get(st, S_RES)),
            left, y, g_font_body()[], c64_light_blue(),
        )

        draw_text(
            String("SPACE PAUSE  1 2 3 MUTE  < > CUTOFF  - + RES  F FILTER  Q QUIT"),
            left, FRAME + 12.0, g_font_small()[], c64_light_blue(),
        )


# ── The view ────────────────────────────────────────────────────────────────


class SidView(NSView):
    def drawRect_(self, dirty: CGRect):
        draw_screen()

    def acceptsFirstResponder(self) -> Bool:
        return True

    def keyDown_(self, event: ObjCObject):
        # The handler only edits chip registers, which is the same thing the
        # player routine does -- so there is nothing here the audio thread is
        # not already prepared for.
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

        if c == 113 or c == 81 or c == 27:        # q, Q, escape
            g_cmd()[] = g_cmd()[] | CMD_QUIT
        elif c == 32:                             # space
            let was = get(st, PLAYER_BASE + UI_PAUSE)
            put(st, PLAYER_BASE + UI_PAUSE, 0 if was != 0 else 1)
        elif c >= 49 and c <= 51:                 # 1, 2, 3
            let v = c - 49
            let slot = PLAYER_BASE + UI_MUTE + v
            if get(st, slot) != 0:
                put(st, slot, 0)
                vput(st, v, V_WAVE, get(st, PLAYER_BASE + UI_SAVED_WAVE + v))
            else:
                put(st, slot, 1)
                put(st, PLAYER_BASE + UI_SAVED_WAVE + v, vget(st, v, V_WAVE))
                # Silence is no waveform selected, which is what the register
                # means -- not a volume of zero, which the chip does not have
                # per voice.
                vput(st, v, V_WAVE, 0)
        elif c == 44 or c == 60:                  # , or <
            set_filter(st, get(st, S_CUTOFF) - 64, get(st, S_RES),
                       get(st, S_FMODE))
        elif c == 46 or c == 62:                  # . or >
            set_filter(st, get(st, S_CUTOFF) + 64, get(st, S_RES),
                       get(st, S_FMODE))
        elif c == 45:                             # -
            var r = get(st, S_RES) - 1
            if r < 0:
                r = 0
            set_filter(st, get(st, S_CUTOFF), r, get(st, S_FMODE))
        elif c == 61 or c == 43:                  # = or +
            var r = get(st, S_RES) + 1
            if r > 15:
                r = 15
            set_filter(st, get(st, S_CUTOFF), r, get(st, S_FMODE))
        elif c == 102 or c == 70:                 # f, F
            let mode = get(st, S_FMODE)
            var next = FILT_LP
            if mode == FILT_LP:
                next = FILT_BP
            elif mode == FILT_BP:
                next = FILT_HP
            set_filter(st, get(st, S_CUTOFF), get(st, S_RES), next)


fn redraw():
    if g_view()[] != 0:
        Obj["NSView"](ObjCObject(g_view()[]).addr()).setNeedsDisplay(True)


def main() raises:
    if not load_framework["AppKit"]():
        raise Error("could not load AppKit")

    let st = chip_new()
    g_chip()[] = Int(st)

    # A named .abc file replaces the built-in tune. The parse happens here,
    # before the audio unit exists: it allocates and it can raise, and the
    # render callback may do neither.
    var loaded = String("")
    let args = argv()
    if len(args) > 1:
        var path = String(args[1])
        var text = String("")
        try:
            with open(path, "r") as f:
                text = f.read()
        except:
            raise Error("could not read " + path)
        let tune = parse_abc(text)
        let score = install_abc(st, tune)
        if score == 0:
            raise Error("no notes found in " + path)
        # An ABC tune says nothing about timbre, so the voices get the
        # standing arrangement: melody, bass, and anything left over.
        instrument_lead(st, 0)
        instrument_bass(st, 1)
        instrument_lead(st, 2)
        set_filter(st, 1200, 8, FILT_LP)
        player_attach(st, score, True)
        loaded = tune.title if len(tune.title.as_bytes()) > 0 else path
        print("playing:", loaded)
    else:
        _ = build_demo(st)

    # The scope buffer, allocated once, before a single sample is rendered.
    put(
        st, PLAYER_BASE + UI_SCOPE,
        Int(external_call["calloc", P](Int(SCOPE_LEN), Int(4))),
    )

    g_font_title()[] = make_font(15.0)
    g_font_body()[] = make_font(13.0)
    g_font_small()[] = make_font(11.0)

    let unit = start_audio(st)
    print("CHIP.  SPACE pause · 1 2 3 mute · < > cutoff · - + resonance · F filter · Q quit")

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
            win,
            CGRect(CGPoint(200.0, 200.0), CGSize(WIN_W, WIN_H)),
            Int(15),
            Int(2),
            Bool(False),
        )
        _ = msg_send[ObjCObject, "NSWindow", "setTitle:"](
            win, nsstring(String("CHIP")).ptr()
        )

        let view = ObjCObject(SidView().__objc_id)
        _ = msg_send[ObjCObject, "NSView", "setFrame:"](
            view, rect(0.0, 0.0, WIN_W, WIN_H)
        )
        # The retain is not optional. The Mojo wrapper owns the only reference
        # until this line, and it releases at the end of the statement that
        # made it -- after which AppKit is holding a freed object and the
        # first drawRect: traps somewhere inside _NSViewDrawRect, with a stack
        # that says nothing about ownership.
        _ = external_call["objc_retain", P](view.ptr())
        g_view()[] = view.addr()
        _ = msg_send[ObjCObject, "NSWindow", "setContentView:"](
            win, view.ptr()
        )
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

        # The loop is hand-rolled rather than [NSApp run] for the same reason
        # the other examples give: the thing that owns the resource has to be
        # the thing that drives the app. Here it owns the audio unit, and it
        # has to stop it before the process exits or CoreAudio keeps pulling
        # from a callback whose chip has been freed.
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
                running = False
                break
            redraw()
            # Thirty frames a second of drawing. The audio is not on this
            # clock and does not care what this loop does.
            sleep(0.033)

    stop_audio(unit)
    print("stopped.")
