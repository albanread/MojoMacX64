# GridView — the editor surface. A custom NSView that draws the rope.
#
# The whole speed argument lives here, and it is an argument about what the view
# refuses to do. A fixed-pitch font makes layout arithmetic:
#
#     x = column * advance          y = line * line_height
#     document height = line_count * line_height
#
# so there is no layout pass to run, ever, and no text storage to keep in sync.
# The view borrows the current rope root and draws the lines the scroll view is
# actually showing -- sixty of them, not two hundred and fifty thousand.
#
# A browser editor pays DOM mutation, style recalculation, layout, paint and
# composite on every keystroke, plus a JS heap and its collector. This pays a
# rope edit (measured: 2.4 us) and one line redrawn.
from rope import Rope
import session
from dap import (
    breakpoint_at as dap_breakpoint_at,
    verified_line as dap_verified_line,
    is_verified as dap_is_verified,
    breakpoint_count as dap_breakpoint_count,
    breakpoint_file as dap_breakpoint_file,
    toggle_breakpoint as dap_toggle_breakpoint,
    is_stopped as dap_is_stopped,
    stop_line as dap_stop_line,
    stop_file as dap_stop_file,
)
from lsp import (
    diag_visible,
    completion_count,
    clear_completions,
    g_comp_label,
    g_comp_detail,
    g_comp_insert,
    diagnostic_count,
    g_diag_line,
    g_diag_col,
    g_diag_end,
    g_diag_sev,
    g_diag_msg,
)
from std.objc import (
    ObjCClass,
    ObjCObject,
    msg_send,
    nsstring,
    autoreleasepool,
    extern_object,
    ns_to_string,
    named_global,
    box_ref,
    Obj,
    Cls,
    sel,
    CGPoint,
    CGSize,
    CGRect,
    NSRange,
)
from std.memory import OpaquePointer
from std.os import getenv
from std.ffi import external_call, c_char

comptime P = OpaquePointer[MutUntrackedOrigin]


# The geometry comes from std.objc now, declared TrivialRegisterPassable there
# because that is what the C ABI says these are -- and what lets a `class`
# method return one (COCOA_CLASS_DESIGN.md, struct returns).
def rect(x: Float64, y: Float64, w: Float64, h: Float64) -> CGRect:
    return CGRect(CGPoint(x, y), CGSize(w, h))


# ── State the draw callback can reach ────────────────────────────────────────
# drawRect: is a C-ABI fn with no closure, so the buffer it draws lives at a
# known address. The rope itself is heap-allocated once and replaced wholesale
# on edit -- which is cheap, because replacing it is a pointer swap.
# The buffer lives in a one-element global list rather than a raw heap slot.
# A zero-initialised global of any type is all zeros, and assigning a value
# with a destructor over zeros would run that destructor on garbage. A List is
# the exception worth using: zero-initialised it *is* a valid empty list, so
# the first buffer is appended and every later one replaces element zero --
# destroying a real Rope, which is correct.
comptime g_buffer = named_global["roast.buffer", List[Rope]]
comptime g_font = named_global["roast.font", Int]
comptime g_attrs = named_global["roast.attrs", Int]
comptime g_gutter_attrs = named_global["roast.gutter.attrs", Int]

# Metrics, measured once from the font and then treated as arithmetic.
comptime g_advance_x1000 = named_global["roast.advance", Int]
comptime g_line_h_x1000 = named_global["roast.lineh", Int]

comptime GUTTER_W = 62.0
comptime TEXT_PAD = 8.0

# Which file the view is showing, as a plain path. The breakpoint list is
# keyed by path and the view draws one document at a time, so it has to know
# which markers are its own -- and lsp's shown_uri is a uri, which is the
# same fact wearing a scheme.
comptime g_shown_path = named_global["roast.shown.path", List[String]]


def shown_path() -> String:
    let slot = g_shown_path()
    return slot[][0] if len(slot[]) > 0 else String()


def set_shown_path(var path: String):
    let slot = g_shown_path()
    if len(slot[]) == 0:
        slot[].append(path^)
    else:
        slot[][0] = path^


def gutter_line_at(y: Float64) -> Int:
    """Which line a click in the gutter is on, zero-based."""
    let lh = line_height()
    if lh <= 0.0:
        return -1
    return Int(y / lh)


def in_gutter(x: Float64) -> Bool:
    """A click left of the text is a gutter click. The line numbers are
    right-aligned against TEXT_PAD, so the whole strip is fair game -- there
    is nothing else there to hit."""
    return x < GUTTER_W


def advance() -> Float64:
    return Float64(g_advance_x1000()[]) / 1000.0


def line_height() -> Float64:
    return Float64(g_line_h_x1000()[]) / 1000.0


def set_rope(var r: Rope):
    """Install a new buffer. The old one is dropped, and any snapshot another
    queue is holding stays alive on its own -- which is the point of the rope."""
    let buf = g_buffer()
    if len(buf[]) == 0:
        buf[].append(r^)
    else:
        buf[][0] = r^
    g_revision()[] += 1


def has_rope() -> Bool:
    return len(g_buffer()[]) > 0


# ── Drawing ─────────────────────────────────────────────────────────────────
# ── Completion popup ────────────────────────────────────────────────────────
def ensure_popup():
    """Build the popup window once."""
    if g_popup()[] != 0:
        return
    let NSWindow = ObjCClass.lookup["NSWindow"]()
    var win = Cls["NSWindow"]().alloc()
    # Borderless, non-activating: showing candidates must not take focus away
    # from the text being typed.
    win = Obj["NSWindow"](win.addr()).initWithContentRect_styleMask_backing_defer(
        rect(0.0, 0.0, POPUP_W, POPUP_ROW_H),
        Int(0),
        Int(2),
        Bool(False),
    )
    Obj["NSWindow"](win.addr()).setLevel(Int(101))
    Obj["NSWindow"](win.addr()).setOpaque(False)
    Obj["NSWindow"](win.addr()).setHasShadow(True)

    var view = ObjCObject(RoastCompletionView().__objc_id)
    Obj["NSView"](view.addr()).setFrame(rect(0.0, 0.0, POPUP_W, POPUP_ROW_H))
    Obj["NSWindow"](win.addr()).setContentView(view.ptr())
    _ = external_call["objc_retain", P](win.ptr())
    g_popup()[] = win.addr()
    g_popup_view()[] = view.addr()


def word_start(at: Int) -> Int:
    """Where the identifier under the caret begins.

    A completion replaces the word being typed, not the empty space after it;
    getting this wrong appends to a prefix and produces `setTitsetTitle:`.
    """
    if not has_rope():
        return at
    let text = g_buffer()[][0].slice(max(0, at - 128), at)
    let bytes = text.as_bytes()
    var back = 0
    while back < len(bytes):
        let c = Int(bytes[len(bytes) - 1 - back])
        let alnum = (
            (c >= 0x30 and c <= 0x39)
            or (c >= 0x41 and c <= 0x5A)
            or (c >= 0x61 and c <= 0x7A)
            or c == 0x5F
        )
        if not alnum:
            break
        back += 1
    return at - back


def show_popup(anchor_view: ObjCObject):
    """Put the list under the word being completed."""
    if completion_count() == 0:
        hide_popup()
        return
    ensure_popup()
    with autoreleasepool():
        let rows = min(completion_count(), POPUP_MAX_ROWS)
        let h = Float64(rows) * POPUP_ROW_H
        g_popup_from()[] = word_start(g_caret()[])
        let pos = caret_position(g_popup_from()[])

        # The caret is in view coordinates; the window wants screen ones.
        let local = rect(pos.x, pos.y + line_height(), POPUP_W, h)
        let in_window = Obj["NSView"](anchor_view.addr()).convertRect_toView(
            local, ObjCObject(0).ptr()
        )
        let host = Obj["NSView"](anchor_view.addr()).window()
        if host.addr() == 0:
            return
        var screen = Obj["NSWindow"](host.addr()).convertRectToScreen(in_window)
        # The window's y is its bottom edge, and the list hangs below the
        # caret, so the origin moves down by the height.
        screen.origin.y -= h

        let win = ObjCObject(g_popup()[])
        Obj["NSWindow"](win.addr()).setFrame_display(screen, True)
        Obj["NSView"](ObjCObject(g_popup_view()[]).addr()).setFrameSize(
            CGSize(POPUP_W, h)
        )
        Obj["NSView"](ObjCObject(g_popup_view()[]).addr()).setNeedsDisplay(True)
        # orderFront, never makeKey: the text keeps the keyboard.
        Obj["NSWindow"](win.addr()).orderFront(win.ptr())
        g_popup_open()[] = 1
        g_popup_sel()[] = 0


def hide_popup():
    if g_popup()[] == 0 or g_popup_open()[] == 0:
        return
    with autoreleasepool():
        Obj["NSWindow"](ObjCObject(g_popup()[]).addr()).orderOut(
            ObjCObject(g_popup()[]).ptr()
        )
    g_popup_open()[] = 0
    clear_completions()


def popup_open() -> Bool:
    return g_popup_open()[] != 0


def popup_move(delta: Int):
    let n = min(completion_count(), POPUP_MAX_ROWS)
    if n == 0:
        return
    var sel = g_popup_sel()[] + delta
    if sel < 0:
        sel = n - 1
    elif sel >= n:
        sel = 0
    g_popup_sel()[] = sel
    with autoreleasepool():
        Obj["NSView"](ObjCObject(g_popup_view()[]).addr()).setNeedsDisplay(True)


def popup_accept() -> Bool:
    """Insert the selected candidate over the word being completed."""
    if not popup_open() or completion_count() == 0:
        return False
    let sel = min(g_popup_sel()[], completion_count() - 1)
    # `var`, not `let`. The revived `let` binds to the list slot, and
    # hide_popup() clears that list -- so the insert below read a String
    # whose storage had been freed. It printed the right text anyway,
    # because freed heap memory usually still holds its bytes, which is the
    # worst kind of working. The checker cannot see it: named_global routes
    # through an untracked origin, exactly where invalidated-reference
    # analysis goes blind. `var` copies while the slot is still alive.
    var text = g_comp_insert()[][sel]
    let from_ = g_popup_from()[]
    hide_popup()
    if not has_rope():
        return False
    push_undo()
    set_rope(g_buffer()[][0].replace(from_, g_caret()[], text))
    set_caret(from_ + text.byte_length())
    return True


# ── Construction ────────────────────────────────────────────────────────────
class RoastGridView(NSView, NSTextInputClient):
    """The editor surface, and the whole NSTextInputClient.

    Twenty-one selectors that were an ObjCClassBuilder, eight encoding
    strings, and seven `add_method_unchecked` escapes -- the escapes existed
    because the checked overloads could not describe NSRange and CGRect
    crossing by value. The compiler takes every encoding from the SDK now,
    and the struct shapes cross the trampoline in registers both ways
    (struct_arg_test, struct_ret_test).

    Conformance is declared in the base list: implementing the selectors is
    not conforming, and AppKit asks `conformsToProtocol:` before it will
    speak NSTextInputClient to a view.
    """

    # The view's own state, in its box rather than in process globals beside
    # it. Every one of these is per editor view by nature -- a second view
    # would need its own caret, not a share of this one -- and the accessors
    # below keep the 149 existing call sites spelled exactly as they were.
    var caret: Int
    """the insertion point, in bytes from the start of the rope"""
    var anchor: Int
    """the other end of the selection; equal to the caret when there is none"""
    var marked_at: Int
    """IME marked text: where it starts"""
    var marked_len: Int
    """IME marked text: how long it is"""
    var blink_on: Int
    """whether the caret is currently drawn"""
    var focused: Int
    """whether this view is first responder"""
    var max_cols: Int
    """the widest line seen, for the document width"""

    def isFlipped(self) -> Bool:
        # Origin at the top-left. Text goes down the page; the arithmetic should
        # not have to apologise for Cocoa's y-axis.
        return True

    def acceptsFirstResponder(self) -> Bool:
        return True

    def drawRect_(self, dirty: CGRect):
        """Paint the visible lines.

        The dirty rect that AppKit passes is ignored in favour of `visibleRect`,
        which is what the design actually wants: draw the viewport, not the
        document. Declaring the IMP without the CGRect argument is ABI-safe on
        arm64 -- the caller passes it in registers the callee simply never reads.
        """
        try:
            with autoreleasepool():
                let view = ObjCObject(self.__objc_id)
                # The dirty rect, not the viewport. For a keystroke they are
                # the same thing; for the caret blink the dirty rect is a
                # four-point sliver, and drawing the viewport instead meant
                # re-lexing every visible line twice a second to blink a
                # cursor. AppKit clips to the dirty region anyway -- honouring
                # it just stops paying for paint that was never shown.
                var vis = dirty
                if vis.size.height <= 0.0 or vis.size.width <= 0.0:
                    vis = Obj["NSView"](view.addr()).visibleRect()

                # Background.
                let NSColor = ObjCClass.lookup["NSColor"]()
                let bg = theme_color(ROLE_BG)
                Obj["NSColor"](bg.addr()).setFill()
                _ = external_call["NSRectFill", NoneType](vis)

                # The gutter is a margin, not more page: its own quiet
                # background and a hairline where it meets the text. Drawn
                # only when the damage reaches it.
                if vis.origin.x < GUTTER_W:
                    let full = Obj["NSView"](view.addr()).bounds()
                    let margin = theme_color(ROLE_GUTTER_BG)
                    Obj["NSColor"](margin.addr()).setFill()
                    _ = external_call["NSRectFill", NoneType](
                        rect(0.0, vis.origin.y, GUTTER_W - 8.0,
                             vis.size.height)
                    )
                    let hair = theme_color(ROLE_HAIRLINE)
                    Obj["NSColor"](hair.addr()).setFill()
                    _ = external_call["NSRectFill", NoneType](
                        rect(GUTTER_W - 8.0, vis.origin.y, 1.0,
                             vis.size.height)
                    )
                    _ = full

                let lh = line_height()
                if lh <= 0.0:
                    return

                if not has_rope():
                    return
                _update_lncol()
                let buf = g_buffer()
                let total = buf[][0].line_count()

                # Exactly the lines the damage covers, with one either side so
                # a partially scrolled line is not clipped away.
                var first = Int(vis.origin.y / lh) - 1
                if first < 0:
                    first = 0
                var last = Int((vis.origin.y + vis.size.height) / lh) + 1
                if last > total:
                    last = total

                let gutter_attrs = ObjCObject(g_gutter_attrs()[])

                # Every match on screen, faintly. Only the visible byte range is
                # searched, because only the visible range can be seen -- the whole
                # buffer would be scanned on every frame for nothing.
                let q = query()
                if q.byte_length() > 0:
                    let vis_a = buf[][0].line_start(first)
                    let vis_b = buf[][0].line_start(min(last, total - 1)) + buf[][
                        0
                    ].line(min(last, total - 1)).byte_length()
                    let NSColorM = ObjCClass.lookup["NSColor"]()
                    let found_bg = Cls["NSColor"]().systemYellowColor()
                    let faded = Obj["NSColor"](found_bg.addr()).colorWithAlphaComponent(
                        Float64(0.35),
                    )
                    Obj["NSColor"](faded.addr()).setFill()
                    for m in buf[][0].find_all_in(q, vis_a, vis_b):
                        let a = caret_position(m)
                        let b = caret_position(m + q.byte_length())
                        if b.y == a.y:
                            _ = external_call["NSRectFill", NoneType](
                                rect(a.x, a.y, max(b.x - a.x, 2.0), lh)
                            )

                # Selection, painted under the text.
                let sel_a = sel_start()
                let sel_b = sel_end()
                if sel_a != sel_b:
                    let NSColor2 = ObjCClass.lookup["NSColor"]()
                    let hl = theme_color(ROLE_SELECTION)
                    Obj["NSColor"](hl.addr()).setFill()
                    let l0 = buf[][0].line_of_offset(sel_a)
                    let l1 = buf[][0].line_of_offset(sel_b)
                    var ln = max(l0, first)
                    while ln <= min(l1, last - 1):
                        let ls = buf[][0].line_start(ln)
                        let le = ls + buf[][0].line(ln).byte_length()
                        let from_ = max(sel_a, ls)
                        let to_ = min(sel_b, le)
                        let x0 = caret_position(from_).x
                        var x1 = caret_position(to_).x
                        # A selected newline shows as a sliver, the way a text view
                        # signals that the line break itself is included.
                        if sel_b > le and ln < l1:
                            x1 += advance() * 0.5
                        _ = external_call["NSRectFill", NoneType](
                            rect(x0, Float64(ln) * lh, max(x1 - x0, 1.0), lh)
                        )
                        ln += 1

                # The stopped line, painted before the text so the glyphs sit
                # on it rather than under it. Only for the file being shown:
                # a program stops in ONE place, and highlighting that line
                # number in every open file would be a lie in all but one.
                let here = shown_path()
                if dap_is_stopped() and here != "" and dap_stop_file() == here:
                    let sl = dap_stop_line() - 1  # DAP counts from one
                    if sl >= first and sl < last:
                        let NSColorS = ObjCClass.lookup["NSColor"]()
                        let band = Obj["NSColor"](
                            msg_send[
                                ObjCObject, "NSColor", "systemYellowColor",
                                is_class=True,
                            ](NSColorS.as_object()).addr()
                        ).colorWithAlphaComponent(Float64(0.22))
                        _ = msg_send[ObjCObject, "NSColor", "setFill"](band)
                        _ = external_call["NSRectFill", NoneType](
                            rect(0.0, Float64(sl) * lh, vis.size.width
                                 + vis.origin.x, lh)
                        )

                # Whether line `first` begins inside a docstring: replay
                # the lines above it through the state scanner once per
                # draw. A byte walk over the prefix, and honest: the same
                # rule the per-line colouring itself uses.
                var in_triple = False
                var pre = 0
                while pre < first:
                    in_triple = triple_state_after(
                        buf[][0].line(pre), in_triple
                    )
                    pre += 1
                var i = first
                var widest = 0
                while i < last:
                    let y = Float64(i) * lh
                    # A breakpoint marker, if this line has one. Drawn at the
                    # line it BOUND to rather than the line that was clicked:
                    # the adapter slides a breakpoint to the next line with
                    # code, and a dot on a line the program never reaches is
                    # a promise nobody keeps.
                    if here != "":
                        var bp = 0
                        while bp < dap_breakpoint_count():
                            if (
                                dap_breakpoint_file(bp) == here
                                and dap_verified_line(bp) == i + 1
                            ):
                                let NSColorB = ObjCClass.lookup["NSColor"]()
                                # Solid once the adapter has confirmed it,
                                # hollow while it is only an intention -- the
                                # difference between "the debugger knows" and
                                # "you have asked".
                                let ink = msg_send[
                                    ObjCObject, "NSColor", "systemRedColor",
                                    is_class=True,
                                ](NSColorB.as_object())
                                let shade = ink if dap_is_verified(bp) else (
                                    Obj["NSColor"](ink.addr())
                                    .colorWithAlphaComponent(Float64(0.35))
                                )
                                _ = msg_send[ObjCObject, "NSColor", "setFill"](
                                    shade
                                )
                                let d = lh * 0.55
                                _ = external_call["NSRectFill", NoneType](
                                    rect(6.0, y + (lh - d) * 0.5, d, d)
                                )
                                break
                            bp += 1
                    # Line number, right-aligned in the gutter.
                    let num = String(i + 1)
                    let num_w = Float64(num.byte_length()) * advance()
                    Obj["NSString"](nsstring(num).addr()).drawAtPoint_withAttributes(
                        CGPoint(GUTTER_W - num_w - TEXT_PAD, y),
                        gutter_attrs.ptr(),
                    )
                    # The line, in runs of one colour each. Monospaced means a
                    # run's x is just its column times the advance, so drawing
                    # in pieces costs a few more calls and no layout at all.
                    # The runs come straight from the lexer; each is one slice
                    # of the line, not a character-by-character rebuild.
                    let text = buf[][0].line(i)
                    # Colour with the state the line STARTS in; advance the
                    # state after. Not a `let` snapshot of the flag: in this
                    # dialect `let` binds by reference (see popup_accept
                    # above, which learned the same lesson), so a "copy"
                    # taken before the update would read the updated value
                    # and hand every docstring opener its own closing state.
                    if text.byte_length() > 0:
                        let runs = highlight_runs(text, in_triple)
                        for r in runs:
                            Obj["NSString"](nsstring(
                                    String(
                                        text[
                                            byte = r.byte_start : r.byte_start
                                            + r.byte_len
                                        ]
                                    )
                                ).addr()).drawAtPoint_withAttributes(CGPoint(
                                    GUTTER_W
                                    + TEXT_PAD
                                    + Float64(r.col) * advance(),
                                    y,
                                ), _attrs_for(r.kind).ptr())
                        if len(runs) > 0:
                            let lastr = runs[len(runs) - 1]
                            if lastr.col + lastr.cols > widest:
                                widest = lastr.col + lastr.cols
                    # Advance the docstring state AFTER colouring -- and for
                    # every line, including empty ones inside a docstring.
                    in_triple = triple_state_after(text, in_triple)
                    i += 1

                # A longer line than any seen before means the document is
                # wider than the view thought. Growing the frame here, from
                # the draw, is safe because it only ever grows.
                if note_line_cols(widest):
                    let frame = Obj["NSView"](view.addr()).frame()
                    let want = document_size(frame.size.width)
                    if want.width > frame.size.width:
                        Obj["NSView"](view.addr()).setFrameSize(want)

                # Diagnostics from the language server. Drawn after the text so
                # the underline sits under the glyphs it is about, and before the
                # caret so the caret stays on top of everything.
                let dn = diagnostic_count()
                if dn > 0:
                    let NSColorD = ObjCClass.lookup["NSColor"]()
                    var di = 0
                    while di < dn:
                        # The store holds every open document's diagnostics;
                        # only this one's belong on this buffer.
                        if not diag_visible(di):
                            di += 1
                            continue
                        let dline = g_diag_line()[][di]
                        if dline < first or dline >= last:
                            di += 1
                            continue
                        # 1 error, 2 warning, anything else advisory.
                        let sev = g_diag_sev()[][di]
                        var ink = Cls["NSColor"]().systemRedColor()
                        if sev == 2:
                            ink = Cls["NSColor"]().systemOrangeColor()
                        elif sev > 2:
                            ink = Cls["NSColor"]().systemBlueColor()
                        Obj["NSColor"](ink.addr()).setFill()

                        let y = Float64(dline) * lh
                        # The gutter mark: a bar at the left edge, which reads at a
                        # glance and does not need the line to be on screen wide.
                        _ = external_call["NSRectFill", NoneType](
                            rect(2.0, y + 3.0, 4.0, lh - 6.0)
                        )

                        # The underline, under the range the server gave.
                        let lstart = buf[][0].line_start(dline)
                        let a = caret_position(lstart + g_diag_col()[][di])
                        var end_col = g_diag_end()[][di]
                        if end_col <= g_diag_col()[][di]:
                            end_col = g_diag_col()[][di] + 1
                        let b = caret_position(lstart + end_col)
                        _ = external_call["NSRectFill", NoneType](
                            rect(a.x, y + lh - 2.0, max(b.x - a.x, advance()), 2.0)
                        )
                        di += 1

                # The caret: drawn only with focus, and only on the blink's on
                # phase, because a caret that never blinks reads as a rendering
                # artefact rather than a cursor.
                if g_focused()[] != 0 and g_blink_on()[] != 0 and sel_a == sel_b:
                    let NSColor3 = ObjCClass.lookup["NSColor"]()
                    # The caret is text, not chrome: on a dark theme a
                    # system-coloured one is invisible against the page.
                    let ink = theme_color(ROLE_TEXT)
                    Obj["NSColor"](ink.addr()).setFill()
                    let pos = caret_position(g_caret()[])
                    _ = external_call["NSRectFill", NoneType](
                        rect(pos.x, pos.y, 2.0, lh)
                    )

                # Composing text is underlined, which is how a person knows it is
                # not committed yet.
                if g_marked_len()[] > 0:
                    let a = caret_position(g_marked_at()[])
                    let b = caret_position(g_marked_at()[] + g_marked_len()[])
                    let NSColor4 = ObjCClass.lookup["NSColor"]()
                    let mark = Cls["NSColor"]().textColor()
                    Obj["NSColor"](mark.addr()).setFill()
                    _ = external_call["NSRectFill", NoneType](
                        rect(a.x, a.y + lh - 2.0, max(b.x - a.x, advance()), 1.0)
                    )
        except:
            pass

    def mouseDown_(self, event: ObjCObject):
        """Click to place the caret; drag to select."""
        try:
            with autoreleasepool():
                let view = ObjCObject(self.__objc_id)
                let win_pt = Obj["NSEvent"](event.addr()).locationInWindow()
                let local = Obj["NSView"](view.addr()).convertPoint_fromView(
                    win_pt, ObjCObject(0).ptr()
                )
                if in_gutter(local.x):
                    # The gutter is the debugger's margin, not the text's:
                    # a click here toggles a breakpoint and leaves the caret
                    # where it was.
                    let line = gutter_line_at(local.y)
                    let path = shown_path()
                    if line >= 0 and path != "":
                        _ = dap_toggle_breakpoint(path, line + 1)
                        _refresh(P(unsafe_from_address=self.__objc_id))
                    return
                let at = offset_at_point(local.x, local.y)
                let clicks = Obj["NSEvent"](event.addr()).clickCount()
                if clicks >= 3:
                    select_line_at(at)
                elif clicks == 2:
                    select_word_at(at)
                else:
                    set_caret(at)
                g_coalesce_at()[] = -1
                _ = Obj["NSWindow"](Obj["NSView"](view.addr()).window().addr()).makeFirstResponder(
                    view.ptr(),
                )
                _refresh(P(unsafe_from_address=self.__objc_id))
        except:
            pass

    def menuForEvent_(self, event: ObjCObject) -> ObjCObject:
        """The right-click menu over the selection.

        A click outside the current selection selects the word under the
        pointer first -- the convention every Mac editor follows -- so the
        menu always applies to what is highlighted. Items reuse the SAME
        selectors as the menu bar: nil-targeted, resolved down the responder
        chain, so enabling and behaviour cannot drift from Edit and
        Navigate.
        """
        try:
            with autoreleasepool():
                let view = ObjCObject(self.__objc_id)
                let win_pt = Obj["NSEvent"](event.addr()).locationInWindow()
                let local = Obj["NSView"](view.addr()).convertPoint_fromView(
                    win_pt, ObjCObject(0).ptr()
                )
                if not in_gutter(local.x):
                    let at = offset_at_point(local.x, local.y)
                    let lo = min(g_anchor()[], g_caret()[])
                    let hi = max(g_anchor()[], g_caret()[])
                    if at < lo or at > hi or lo == hi:
                        select_word_at(at)
                        _refresh(P(unsafe_from_address=self.__objc_id))
                var menu = Cls["NSMenu"]().alloc()
                menu = Obj["NSMenu"](menu.addr()).initWithTitle(
                    nsstring(String("Edit")).ptr()
                )
                _ = Obj["NSMenu"](menu.addr()).addItemWithTitle_action_keyEquivalent(
                    nsstring(String("Cut")).ptr(),
                    sel["cut:"]().ptr(),
                    nsstring(String("")).ptr(),
                )
                _ = Obj["NSMenu"](menu.addr()).addItemWithTitle_action_keyEquivalent(
                    nsstring(String("Copy")).ptr(),
                    sel["copy:"]().ptr(),
                    nsstring(String("")).ptr(),
                )
                _ = Obj["NSMenu"](menu.addr()).addItemWithTitle_action_keyEquivalent(
                    nsstring(String("Paste")).ptr(),
                    sel["paste:"]().ptr(),
                    nsstring(String("")).ptr(),
                )
                Obj["NSMenu"](menu.addr()).addItem(
                    Cls["NSMenuItem"]().separatorItem().ptr()
                )
                _ = Obj["NSMenu"](menu.addr()).addItemWithTitle_action_keyEquivalent(
                    nsstring(String("Go to Definition")).ptr(),
                    sel["roastGoToDefinition:"]().ptr(),
                    nsstring(String("")).ptr(),
                )
                _ = Obj["NSMenu"](menu.addr()).addItemWithTitle_action_keyEquivalent(
                    nsstring(String("Find All References")).ptr(),
                    sel["roastFindReferences:"]().ptr(),
                    nsstring(String("")).ptr(),
                )
                _ = Obj["NSMenu"](menu.addr()).addItemWithTitle_action_keyEquivalent(
                    nsstring(String("Rename…")).ptr(),
                    sel["roastRename:"]().ptr(),
                    nsstring(String("")).ptr(),
                )
                if dap_is_stopped():
                    Obj["NSMenu"](menu.addr()).addItem(
                        Cls["NSMenuItem"]().separatorItem().ptr()
                    )
                    _ = Obj["NSMenu"](menu.addr()).addItemWithTitle_action_keyEquivalent(
                        nsstring(String("Evaluate Selection")).ptr(),
                        sel["roastEvaluate:"]().ptr(),
                        nsstring(String("")).ptr(),
                    )
                return menu
        except:
            return ObjCObject(0)

    # ── Dropping files ──────────────────────────────────────────────
    # A folder becomes the project, a file becomes a tab -- the same rule
    # the Finder's open already follows, so a drag and a double-click land
    # in the same place.

    def draggingEntered_(self, sender: ObjCObject) -> Int:
        # NSDragOperationCopy. Answered for anything carrying file URLs;
        # what they point at is judged when they land, because refusing a
        # folder here would just make the cursor lie.
        return 1 if _dragged_paths().__len__() > 0 else 0

    def draggingUpdated_(self, sender: ObjCObject) -> Int:
        return 1 if _dragged_paths().__len__() > 0 else 0

    def prepareForDragOperation_(self, sender: ObjCObject) -> Bool:
        return _dragged_paths().__len__() > 0

    def performDragOperation_(self, sender: ObjCObject) -> Bool:
        let paths = _dragged_paths()
        if len(paths) == 0:
            return False
        for path in paths:
            g_dropped()[].append(path)
        return True

    def mouseDragged_(self, event: ObjCObject):
        try:
            with autoreleasepool():
                let view = ObjCObject(self.__objc_id)
                let win_pt = Obj["NSEvent"](event.addr()).locationInWindow()
                let local = Obj["NSView"](view.addr()).convertPoint_fromView(
                    win_pt, ObjCObject(0).ptr()
                )
                # Move the caret, leave the anchor: that is a selection.
                g_caret()[] = offset_at_point(local.x, local.y)
                _refresh(P(unsafe_from_address=self.__objc_id))
        except:
            pass

    def becomeFirstResponder(self) -> Bool:
        g_focused()[] = 1
        g_blink_on()[] = 1
        return True

    def resignFirstResponder(self) -> Bool:
        g_focused()[] = 0
        return True

    def roastBlink_(self, timer: ObjCObject):
        """Toggle the caret and redraw just the line it is on."""
        try:
            g_blink_on()[] = 0 if g_blink_on()[] != 0 else 1
            if g_focused()[] == 0:
                return
            with autoreleasepool():
                let view = ObjCObject(self.__objc_id)
                let pos = caret_position(g_caret()[])
                Obj["NSView"](view.addr()).setNeedsDisplayInRect(
                    rect(pos.x - 1.0, pos.y, 4.0, line_height())
                )
        except:
            pass

    def acceptsFirstMouse_(self, event: ObjCObject) -> Bool:
        return True

    def keyDown_(self, event: ObjCObject):
        """Every key goes to the input context, never straight to the buffer.

        Interpreting the event ourselves would work for ASCII and break every
        input method: it is `interpretKeyEvents:` that turns a keystroke into
        `insertText:`, a command selector, or marked text mid-composition.
        """
        try:
            with autoreleasepool():
                let view = ObjCObject(self.__objc_id)
                let NSArray = ObjCClass.lookup["NSArray"]()
                let one = Cls["NSArray"]().arrayWithObject(event)
                Obj["NSView"](view.addr()).interpretKeyEvents(one.ptr())
        except:
            pass

    def insertText_replacementRange_(self, text: ObjCObject, replacement: NSRange):
        """Committed text: a character, a pasted run, or a finished composition."""
        try:
            with autoreleasepool():
                let obj = text
                # Either an NSString or an NSAttributedString; ask for the string.
                var s = obj
                if Obj["NSObject"](obj.addr()).isKindOfClass(ObjCClass.lookup["NSAttributedString"]().as_object().ptr()):
                    s = Obj["NSAttributedString"](obj.addr()).string().object()
                # A composition being committed replaces what it was composing.
                if g_marked_len()[] > 0:
                    g_anchor()[] = g_marked_at()[]
                    g_caret()[] = g_marked_at()[] + g_marked_len()[]
                replace_selection(ns_to_string(s))
                # A word character continues a completion; anything else ends one.
                let typed = ns_to_string(s)
                if popup_open():
                    if typed.byte_length() != 1:
                        hide_popup()
                # No signature-help trigger here on purpose. `(` and `,`
                # are where every editor asks -- but measured against this
                # server, a request anywhere inside `combine(10, 20)` answers
                # `__init__` of whatever literal the caret is near, and at one
                # column a wall of mangled MLIR. Firing that on every open
                # paren would replace the status bar with a wrong answer while
                # someone is typing. Signature help stays on demand until the
                # server resolves the enclosing call.
                _refresh(P(unsafe_from_address=self.__objc_id))
        except:
            pass

    def setMarkedText_selectedRange_replacementRange_(self, text: ObjCObject, selected: NSRange, replacement: NSRange):
        """Text mid-composition: shown, not committed. Replacing the previous
        marked run is what keeps a CJK candidate window from duplicating input."""
        try:
            with autoreleasepool():
                let obj = text
                var s = obj
                if Obj["NSObject"](obj.addr()).isKindOfClass(ObjCClass.lookup["NSAttributedString"]().as_object().ptr()):
                    s = Obj["NSAttributedString"](obj.addr()).string().object()
                let str = ns_to_string(s)

                # Replace whatever was marked before, or the selection if nothing.
                let at = g_marked_at()[] if g_marked_len()[] > 0 else sel_start()
                let upto = (
                    g_marked_at()[] + g_marked_len()[]
                    if g_marked_len()[] > 0
                    else sel_end()
                )
                if has_rope():
                    set_rope(g_buffer()[][0].replace(at, upto, str))
                g_marked_at()[] = at
                g_marked_len()[] = str.byte_length()
                set_caret(at + str.byte_length())
                _refresh(P(unsafe_from_address=self.__objc_id))
        except:
            pass

    def unmarkText(self):
        g_marked_at()[] = 0
        g_marked_len()[] = 0

    def hasMarkedText(self) -> Bool:
        return g_marked_len()[] > 0

    def markedRange(self) -> NSRange:
        try:
            if g_marked_len()[] == 0:
                return NSRange(NOT_FOUND, 0)
            let a = byte_to_utf16(g_marked_at()[])
            let b = byte_to_utf16(g_marked_at()[] + g_marked_len()[])
            return NSRange(a, b - a)
        except:
            return NSRange(NOT_FOUND, 0)

    def selectedRange(self) -> NSRange:
        try:
            let a = byte_to_utf16(sel_start())
            let b = byte_to_utf16(sel_end())
            return NSRange(a, b - a)
        except:
            return NSRange(0, 0)

    def validAttributesForMarkedText(self) -> ObjCObject:
        """No marked-text styling is honoured, so the list is empty -- which is a
        legitimate answer, and an empty array rather than nil."""
        try:
            with autoreleasepool():
                let NSArray = ObjCClass.lookup["NSArray"]()
                return Cls["NSArray"]().array().object()
        except:
            return ObjCObject(0)

    def attributedSubstringForProposedRange_actualRange_(self, range: NSRange, actual: P) -> ObjCObject:
        """The text an input method wants to reconsider -- used by dictionary
        lookup and by some candidate windows."""
        try:
            with autoreleasepool():
                if not has_rope():
                    return ObjCObject(0)
                let a = utf16_to_byte(range.location)
                let b = utf16_to_byte(range.location + range.length)
                let s = g_buffer()[][0].slice(a, b)
                let NSAttributedString = ObjCClass.lookup["NSAttributedString"]()
                var att = Cls["NSAttributedString"]().alloc()
                # Named for the concrete class, not the facade. NSAttributedString
                # is a class cluster: `[NSAttributedString alloc]` hands back an
                # NSConcreteAttributedString, and the database is a runtime dump,
                # so initWithString: is recorded on the concrete member and not on
                # the public name. The class parameter only chooses which metadata
                # to read -- dispatch happens on the receiver either way -- so this
                # names where the selector actually lives.
                # A new binding rather than an assignment: `Obj` has no
                # variance, so an Obj["NSConcreteAttributedString"] is not an
                # Obj["NSAttributedString"] even though the object is both.
                # That is the honest consequence of the class living in the
                # type, and `.object()` is the way out of it.
                let made = Obj["NSConcreteAttributedString"](
                    att.addr()
                ).initWithString(nsstring(s).ptr())
                return made.object()
        except:
            return ObjCObject(0)

    def firstRectForCharacterRange_actualRange_(self, range: NSRange, actual: P) -> CGRect:
        """Where to put the candidate window: screen coordinates of the composing
        text. Getting this wrong parks the CJK candidate list in a corner."""
        try:
            with autoreleasepool():
                let view = ObjCObject(self.__objc_id)
                let at = utf16_to_byte(range.location)
                let line = g_buffer()[][0].line_of_offset(at) if has_rope() else 0
                let col = at - (
                    g_buffer()[][0].line_start(line) if has_rope() else 0
                )
                let local = rect(
                    GUTTER_W + TEXT_PAD + Float64(col) * advance(),
                    Float64(line) * line_height(),
                    advance(),
                    line_height(),
                )
                # View -> window -> screen. `convertRect:toView:` with a nil view
                # means "to the window", which is the conversion wanted here.
                let in_window = Obj["NSView"](view.addr()).convertRect_toView(
                    local, ObjCObject(0).ptr()
                )
                let w = Obj["NSView"](view.addr()).window()
                if w.addr() == 0:
                    return in_window
                return Obj["NSWindow"](w.addr()).convertRectToScreen(in_window)
        except:
            return rect(0.0, 0.0, 0.0, 0.0)

    def characterIndexForPoint_(self, point: CGPoint) -> Int:
        """Hit testing, for click-to-place-caret from the input system."""
        try:
            if not has_rope():
                return 0
            let line = max(0, Int(point.y / line_height()))
            let col = max(0, Int((point.x - GUTTER_W - TEXT_PAD) / advance()))
            let start = g_buffer()[][0].line_start(line)
            return byte_to_utf16(start + col)
        except:
            return 0

    def doCommandBySelector_(self, selector: P):
        """Movement and deletion arrive as selectors, not characters."""
        try:
            let raw = external_call["sel_getName", P](selector)
            if Int(raw) == 0:
                return
            let name = String(unsafe_from_utf8_ptr=raw.unsafe_bitcast[c_char]())
            let view = ObjCObject(self.__objc_id)
            # A page is however many lines the viewport actually shows.
            var page = 40
            with autoreleasepool():
                let vis = Obj["NSView"](view.addr()).visibleRect()
                if line_height() > 0.0:
                    page = max(1, Int(vis.size.height / line_height()) - 1)
            apply_command(name, page)
            _refresh(P(unsafe_from_address=self.__objc_id))
            # Movement must be watchable: an arrow key that puts the caret
            # somewhere the viewport is not reads as a dead key.
            reveal_caret(view)
        except:
            pass

    # ── Edit menu actions ───────────────────────────────────────────────────
    # The menu wires cut:, copy:, paste:, undo:, redo: and selectAll: to the
    # responder chain, and the chain ends at whoever implements them. Until
    # these existed it ended nowhere: every one of those items -- and its key
    # equivalent -- did nothing in the editor, because a menu action never
    # goes through doCommandBySelector:. A code editor without paste.

    def copy_(self, sender: ObjCObject):
        try:
            _ = copy_selection()
        except:
            pass

    def cut_(self, sender: ObjCObject):
        try:
            if cut_selection():
                _refresh(P(unsafe_from_address=self.__objc_id))
        except:
            pass

    def paste_(self, sender: ObjCObject):
        try:
            if paste_clipboard():
                let view = ObjCObject(self.__objc_id)
                _refresh(P(unsafe_from_address=self.__objc_id))
                reveal_caret(view)
        except:
            pass

    def undo_(self, sender: ObjCObject):
        try:
            if undo():
                let view = ObjCObject(self.__objc_id)
                _refresh(P(unsafe_from_address=self.__objc_id))
                reveal_caret(view)
        except:
            pass

    def redo_(self, sender: ObjCObject):
        try:
            if redo():
                let view = ObjCObject(self.__objc_id)
                _refresh(P(unsafe_from_address=self.__objc_id))
                reveal_caret(view)
        except:
            pass

    def selectAll_(self, sender: ObjCObject):
        try:
            if has_rope():
                g_anchor()[] = 0
                g_caret()[] = g_buffer()[][0].byte_length()
                _refresh(P(unsafe_from_address=self.__objc_id))
        except:
            pass


class RoastCompletionView(NSView):
    """The completion popup's content view."""

    def drawRect_(self, dirty: CGRect):
        """The candidate list: label on the left, detail greyed on the right."""
        try:
            with autoreleasepool():
                let view = ObjCObject(self.__objc_id)
                let bounds = Obj["NSView"](view.addr()).bounds()
                let NSColorP = ObjCClass.lookup["NSColor"]()

                # Background and a hairline border, so it reads as a panel rather
                # than text that has escaped.
                let bg = Cls["NSColor"]().controlBackgroundColor()
                Obj["NSColor"](bg.addr()).setFill()
                _ = external_call["NSRectFill", NoneType](bounds)

                let n = min(completion_count(), POPUP_MAX_ROWS)
                let attrs = ObjCObject(g_attrs()[])
                let dim = ObjCObject(g_gutter_attrs()[])
                var row = 0
                while row < n:
                    let y = Float64(row) * POPUP_ROW_H
                    if row == g_popup_sel()[]:
                        let hl = Cls["NSColor"]().selectedContentBackgroundColor()
                        Obj["NSColor"](hl.addr()).setFill()
                        _ = external_call["NSRectFill", NoneType](
                            rect(0.0, y, bounds.size.width, POPUP_ROW_H)
                        )
                    Obj["NSString"](nsstring(g_comp_label()[][row]).addr()).drawAtPoint_withAttributes(
                        CGPoint(8.0, y + 2.0),
                        attrs.ptr(),
                    )
                    let detail = g_comp_detail()[][row]
                    if detail.byte_length() > 0:
                        # Right-aligned, so the eye can run down the signatures.
                        var chars = 0
                        for _ in detail.codepoints():
                            chars += 1
                        let dx = bounds.size.width - 8.0 - Float64(chars) * advance()
                        Obj["NSString"](nsstring(detail).addr()).drawAtPoint_withAttributes(
                            CGPoint(max(dx, 180.0), y + 2.0),
                            dim.ptr(),
                        )
                    row += 1
        except:
            pass

    def isFlipped(self) -> Bool:
        return True


# Editor font size in tenths of a point; zero means the 13.0 default, which
# is what a zero-initialised process global has to mean.
comptime g_font_pts_x10 = named_global["roast.font.pts", Int]


def font_size() -> Float64:
    let v = g_font_pts_x10()[]
    return Float64(v) / 10.0 if v != 0 else 13.0


def set_font_size(pts: Float64):
    """Change the editor's type size and rebuild everything derived from it.
    Clamped to what remains legible on either end."""
    var want = pts
    if want < 8.0:
        want = 8.0
    elif want > 36.0:
        want = 36.0
    g_font_pts_x10()[] = Int(want * 10.0)
    build_type()


def _drop_retained(addr: Int):
    if addr != 0:
        _ = external_call["objc_release", P](ObjCObject(addr).ptr())


def build_type():
    """The font at the current size, and every dictionary derived from it.

    Separated from make_grid_view so ⌘+ and ⌘− can re-run it: the size was a
    literal 13.0 buried in view construction, which is why the editor had no
    zoom at all. Old dictionaries are released; the previous font goes with
    them, since they were its only owners.
    """
    with autoreleasepool():
        let NSFont = ObjCClass.lookup["NSFont"]()
        let font = Cls["NSFont"]().monospacedSystemFontOfSize_weight(
            font_size(), Float64(0.0)
        )
        _ = external_call["objc_retain", P](font.ptr())
        _drop_retained(g_font()[])
        g_font()[] = font.addr()

        let NSMutableDictionary = ObjCClass.lookup["NSMutableDictionary"]()
        var attrs = Cls["NSMutableDictionary"]().dictionary()
        Obj["NSMutableDictionary"](attrs.addr()).setObject_forKey(
            font.ptr(), extern_object["NSFontAttributeName"]().ptr()
        )
        let NSColor = ObjCClass.lookup["NSColor"]()
        let fg = theme_color(ROLE_TEXT)
        Obj["NSMutableDictionary"](attrs.addr()).setObject_forKey(
            fg.ptr(), extern_object["NSForegroundColorAttributeName"]().ptr()
        )
        _ = external_call["objc_retain", P](attrs.ptr())
        _drop_retained(g_attrs()[])
        g_attrs()[] = attrs.addr()

        # The gutter, dimmer.
        var gattrs = Cls["NSMutableDictionary"]().dictionary()
        Obj["NSMutableDictionary"](gattrs.addr()).setObject_forKey(
            font.ptr(), extern_object["NSFontAttributeName"]().ptr()
        )
        let dim = theme_color(ROLE_GUTTER_TEXT)
        Obj["NSMutableDictionary"](gattrs.addr()).setObject_forKey(
            dim.ptr(), extern_object["NSForegroundColorAttributeName"]().ptr()
        )
        _ = external_call["objc_retain", P](gattrs.ptr())
        _drop_retained(g_gutter_attrs()[])
        g_gutter_attrs()[] = gattrs.addr()

        # Syntax colours. System colours rather than chosen ones, so the
        # editor follows the appearance the rest of the machine is using.
        # Comments get secondaryLabel, not a hue: they are the most common
        # token in a file, and the most common token must recede -- a colour
        # that shouts turns the whole window that colour. The named colours
        # carry meaning where it is rare enough to read: keywords, strings,
        # numbers.
        let comment_c = theme_color(ROLE_COMMENT)
        let string_c = theme_color(ROLE_STRING)
        let keyword_c = theme_color(ROLE_KEYWORD)
        let number_c = theme_color(ROLE_NUMBER)
        _drop_retained(g_attr_comment()[])
        _drop_retained(g_attr_string()[])
        _drop_retained(g_attr_keyword()[])
        _drop_retained(g_attr_number()[])
        g_attr_comment()[] = _make_attrs(comment_c)
        g_attr_string()[] = _make_attrs(string_c)
        g_attr_keyword()[] = _make_attrs(keyword_c)
        g_attr_number()[] = _make_attrs(number_c)

        # Advance: the width of one character in a face where they are all
        # the same width. Measured, not assumed.
        let probe = nsstring(String("0000000000"))
        let probe_size = Obj["NSString"](probe.addr()).sizeWithAttributes(
            attrs.ptr()
        )
        g_advance_x1000()[] = Int(probe_size.width / 10.0 * 1000.0)

        # Line height from the font's own metrics, so descenders are not
        # clipped.
        let ascender = Obj["NSFont"](font.addr()).ascender()
        let descender = Obj["NSFont"](font.addr()).descender()
        let leading = Obj["NSFont"](font.addr()).leading()
        g_line_h_x1000()[] = Int((ascender - descender + leading + 2.0) * 1000.0)


def _dragged_paths() -> List[String]:
    """The file paths a drag is carrying, or empty.

    Read as NSURLs rather than the legacy filenames property list: the
    modern type is what a Finder drag actually puts on the pasteboard, and
    asking for URLs means a security-scoped one arrives intact.
    """
    var out = List[String]()
    with autoreleasepool():
        # The drag pasteboard by name, not through the sender. NSDraggingInfo
        # is a protocol rather than a class, so it is not in the SDK database
        # the compiler resolves selectors against -- and the drag pasteboard
        # is a documented named one, which is the same object the sender
        # would have handed back.
        let pb = Cls["NSPasteboard"]().pasteboardWithName(
            nsstring(String("Apple CFPasteboard drag")).ptr()
        )
        if pb.addr() == 0:
            return out^
        let url_class = ObjCClass.lookup["NSURL"]().as_object()
        let classes = Cls["NSArray"]().arrayWithObject(url_class.ptr())
        let urls = Obj["NSPasteboard"](pb.addr()).readObjectsForClasses_options(
            classes.ptr(), ObjCObject(0).ptr()
        )
        if urls.addr() == 0:
            return out^
        let n = Obj["NSArray"](urls.addr()).count()
        for i in range(n):
            let url = Obj["NSArray"](urls.addr()).objectAtIndex(i)
            let path = ns_to_string(Obj["NSURL"](url.addr()).path())
            if path != "":
                out.append(path)
    return out^


def make_grid_view(frame: CGRect) -> ObjCObject:
    """Register the view class, measure the font, and return an instance."""
    build_type()

    # Instantiating the class registers it -- methods, protocol and all. The
    # conformance report the smoke test asserts stays: it now checks what the
    # declaration claims rather than what a builder was told.
    var view = ObjCObject(RoastGridView().__objc_id)
    # Parked immediately, not by the caller later: the accessors above read it
    # to find their box, so any gap between making the view and recording it
    # is a window where the view's own state goes somewhere else.
    g_grid()[] = view.addr()

    # Accept file drags. Registered here rather than in the window so the
    # drop lands on the text, which is where a person aims it.
    with autoreleasepool():
        let types = Cls["NSMutableArray"]().array()
        Obj["NSMutableArray"](types.addr()).addObject(
            nsstring(String("public.file-url")).ptr()
        )
        Obj["NSView"](view.addr()).registerForDraggedTypes(types.ptr())
    var proto = external_call["objc_getProtocol", P](
        "NSTextInputClient".ptr()
    )
    if not Obj["NSObject"](view.addr()).conformsToProtocol(proto):
        print("roast: NSTextInputClient protocol not registered")
    Obj["NSView"](view.addr()).setFrame(frame)

    # The blink. 0.53 s is what Cocoa uses, and matching it means the caret
    # keeps time with every other text field on screen.
    g_blink_on()[] = 1
    let NSTimer = ObjCClass.lookup["NSTimer"]()
    _ = Cls["NSTimer"]().scheduledTimerWithTimeInterval_target_selector_userInfo_repeats(
        Float64(0.53),
        view.ptr(),
        sel["roastBlink:"]().ptr(),
        view.ptr(),
        Bool(True),
    )
    return view


# The widest line the draw loop has seen in the current document, in columns.
# Grow-only, reset when the document changes: measuring every line of a big
# file up front would cost a full scan on open, and the width only matters
# once a long line has actually been on screen. Until then there is nothing
# past the right edge to scroll to.
comptime _pre_max_cols = named_global["roast.max.cols", Int]


def g_max_cols() -> Pointer[Int, MutUntrackedOrigin]:
    """`max_cols`, on the view. Spelled as it always was, so no call site moved.

    Two storages, and which one is live is decided by whether there is a view
    to hold one -- which is the same question as whether `box_ref` answers.
    That is not a transition artefact: `edit_test` drives the whole editor
    without ever making a view -- deliberately, since the risk there is the
    arithmetic and not the Objective-C -- and writes through this accessor
    constantly. So the fallback is a real, used path, not a start-up nicety.

    They cannot disagree. The field carries no initializer, so both read zero
    until a view exists, and `make_grid_view` records `g_grid` in the same
    breath as it makes the view, leaving no window in which one is written
    and the other read."""
    var box = box_ref[RoastGridView](g_grid()[])
    if not box:
        return _pre_max_cols()
    return Pointer(to=box.value()[].max_cols)


def note_line_cols(cols: Int) -> Bool:
    """Remember the widest line drawn so far; True when the record moved."""
    if cols > g_max_cols()[]:
        g_max_cols()[] = cols
        return True
    return False


def reset_line_cols():
    g_max_cols()[] = 0


def document_size(width: Float64) -> CGSize:
    """How big the view must be for the scroll view to scroll it.

    The height is exact -- lines times line height. The width used to be
    pinned to the viewport, which meant NO horizontal scrolling: any line
    wider than the window was clipped at the edge with no way to reach it.
    It now covers the widest line the draw loop has seen.
    """
    if not has_rope():
        return CGSize(width, 1.0)
    let h = Float64(g_buffer()[][0].line_count()) * line_height()
    let widest = (
        GUTTER_W + TEXT_PAD * 2.0 + Float64(g_max_cols()[]) * advance()
    )
    return CGSize(max(max(width, GUTTER_W + 400.0), widest), max(h, 1.0))


# ── Text input ───────────────────────────────────────────────────────────────
# NSTextInputClient, implemented in full rather than in part.
#
# This is the protocol that decides whether an editor is real. Typing ASCII
# works with almost any half of it; dead keys, option-e composition and every
# CJK input method go through marked text, and a client that answers
# `hasMarkedText` without maintaining a marked range corrupts the buffer in a
# way that only shows up for people using those input methods. So all eleven
# methods are here, and the class declares conformance rather than merely
# responding to the selectors -- AppKit asks `conformsToProtocol:`.
#
# Offsets are UTF-16 at this boundary, because that is what Cocoa counts in,
# and bytes inside the rope. The two conversions live in one place each.


# NSRange comes from std.objc (TrivialRegisterPassable, x0/x1); location and
# length are counted in UTF-16 units here, as everywhere in Cocoa text.
comptime NOT_FOUND = NSRange.NOT_FOUND

# Caret and selection, in byte offsets. anchor == caret means no selection.
comptime g_grid = named_global["roast.grid", Int]
"""The one editor view's id. Declared here rather than in roast.mojo because
the accessors below need it to find their box, and roast.mojo imports from
this module rather than the other way round."""

comptime _pre_caret = named_global["roast.caret", Int]


def g_caret() -> Pointer[Int, MutUntrackedOrigin]:
    """`caret`, on the view. Spelled as it always was, so no call site moved.

    Two storages, and which one is live is decided by whether there is a view
    to hold one -- which is the same question as whether `box_ref` answers.
    That is not a transition artefact: `edit_test` drives the whole editor
    without ever making a view -- deliberately, since the risk there is the
    arithmetic and not the Objective-C -- and writes through this accessor
    constantly. So the fallback is a real, used path, not a start-up nicety.

    They cannot disagree. The field carries no initializer, so both read zero
    until a view exists, and `make_grid_view` records `g_grid` in the same
    breath as it makes the view, leaving no window in which one is written
    and the other read."""
    var box = box_ref[RoastGridView](g_grid()[])
    if not box:
        return _pre_caret()
    return Pointer(to=box.value()[].caret)
comptime _pre_anchor = named_global["roast.anchor", Int]


def g_anchor() -> Pointer[Int, MutUntrackedOrigin]:
    """`anchor`, on the view. Spelled as it always was, so no call site moved.

    Two storages, and which one is live is decided by whether there is a view
    to hold one -- which is the same question as whether `box_ref` answers.
    That is not a transition artefact: `edit_test` drives the whole editor
    without ever making a view -- deliberately, since the risk there is the
    arithmetic and not the Objective-C -- and writes through this accessor
    constantly. So the fallback is a real, used path, not a start-up nicety.

    They cannot disagree. The field carries no initializer, so both read zero
    until a view exists, and `make_grid_view` records `g_grid` in the same
    breath as it makes the view, leaving no window in which one is written
    and the other read."""
    var box = box_ref[RoastGridView](g_grid()[])
    if not box:
        return _pre_anchor()
    return Pointer(to=box.value()[].anchor)
# The composing region, in bytes; length 0 means nothing is being composed.
comptime _pre_marked_at = named_global["roast.marked.at", Int]


def g_marked_at() -> Pointer[Int, MutUntrackedOrigin]:
    """`marked_at`, on the view. Spelled as it always was, so no call site moved.

    Two storages, and which one is live is decided by whether there is a view
    to hold one -- which is the same question as whether `box_ref` answers.
    That is not a transition artefact: `edit_test` drives the whole editor
    without ever making a view -- deliberately, since the risk there is the
    arithmetic and not the Objective-C -- and writes through this accessor
    constantly. So the fallback is a real, used path, not a start-up nicety.

    They cannot disagree. The field carries no initializer, so both read zero
    until a view exists, and `make_grid_view` records `g_grid` in the same
    breath as it makes the view, leaving no window in which one is written
    and the other read."""
    var box = box_ref[RoastGridView](g_grid()[])
    if not box:
        return _pre_marked_at()
    return Pointer(to=box.value()[].marked_at)
comptime _pre_marked_len = named_global["roast.marked.len", Int]


def g_marked_len() -> Pointer[Int, MutUntrackedOrigin]:
    """`marked_len`, on the view. Spelled as it always was, so no call site moved.

    Two storages, and which one is live is decided by whether there is a view
    to hold one -- which is the same question as whether `box_ref` answers.
    That is not a transition artefact: `edit_test` drives the whole editor
    without ever making a view -- deliberately, since the risk there is the
    arithmetic and not the Objective-C -- and writes through this accessor
    constantly. So the fallback is a real, used path, not a start-up nicety.

    They cannot disagree. The field carries no initializer, so both read zero
    until a view exists, and `make_grid_view` records `g_grid` in the same
    breath as it makes the view, leaving no window in which one is written
    and the other read."""
    var box = box_ref[RoastGridView](g_grid()[])
    if not box:
        return _pre_marked_len()
    return Pointer(to=box.value()[].marked_len)

# Undo is a stack of whole buffers, which is only sane because they share
# structure: a thousand entries of a 14 MB file cost kilobytes, not gigabytes.
# There are no command objects and no inverse operations, so there is nothing
# to get wrong when a new kind of edit is added later.
comptime g_undo = named_global["roast.undo", List[Rope]]
comptime g_redo = named_global["roast.redo", List[Rope]]
comptime g_undo_caret = named_global["roast.undo.caret", List[Int]]
comptime g_redo_caret = named_global["roast.redo.caret", List[Int]]

# Typing should undo in words, not letters. An insert that continues the
# previous one -- single character, immediately after it -- joins the entry
# already on the stack instead of pushing a new one.
comptime g_coalesce_at = named_global["roast.coalesce.at", Int]

# The caret blinks, and is drawn only while the view has focus.
# What is being searched for, and where the last match was. The query is a
# one-element list for the same reason the buffer is: a zero-initialised global
# List is valid, and a zero-initialised String is not.
comptime g_query = named_global["roast.query", List[String]]
comptime g_match_at = named_global["roast.match.at", Int]

# Bumped on every edit. The app watches it to decide when to tell the server,
# rather than sending a document on every keystroke.
comptime g_revision = named_global["roast.revision", Int]

# The completion popup: a borderless window floating above everything, drawing
# its own list. A floating window rather than something inside the editor so it
# is not clipped by the scroll view, and a self-drawn list rather than an
# NSTableView so there is no data source to keep in step with the model.
comptime g_popup = named_global["roast.popup", Int]
comptime g_popup_view = named_global["roast.popup.view", Int]
comptime g_popup_open = named_global["roast.popup.open", Int]
comptime g_popup_sel = named_global["roast.popup.sel", Int]
# Where the word being completed starts, so accepting replaces the prefix
# rather than appending to it.
comptime g_popup_from = named_global["roast.popup.from", Int]

comptime POPUP_ROW_H = 20.0
comptime POPUP_MAX_ROWS = 12
comptime POPUP_W = 460.0

# Text colours, made once and kept: NSColor lookups in a draw loop are the
# easy way to make a fast renderer slow.
comptime g_col_plain = named_global["roast.col.plain", Int]
comptime g_col_comment = named_global["roast.col.comment", Int]
comptime g_col_string = named_global["roast.col.string", Int]
comptime g_col_keyword = named_global["roast.col.keyword", Int]
comptime g_col_number = named_global["roast.col.number", Int]

# One attribute dictionary per colour, for the same reason.
comptime g_attr_comment = named_global["roast.attr.comment", Int]
comptime g_attr_string = named_global["roast.attr.string", Int]
comptime g_attr_keyword = named_global["roast.attr.keyword", Int]
comptime g_attr_number = named_global["roast.attr.number", Int]

comptime KIND_PLAIN = 0
comptime KIND_COMMENT = 1
comptime KIND_STRING = 2
comptime KIND_KEYWORD = 3
comptime KIND_NUMBER = 4


def _is_keyword(w: String) -> Bool:
    """cocoa-mojo's keywords, `let`, `fn` and `class` among them -- this fork
    revived the first two and made the third declare a real Objective-C
    class, and an editor that greys any of them out would be quietly wrong
    about the language it is for. The argument conventions (`imm`, `mut`,
    `out`, `deinit`, `where`) are contextual soft identifiers, coloured here
    on the same terms as each other."""
    return (
        w == "def" or w == "fn" or w == "let" or w == "var" or w == "class"
        or w == "struct"
        or w == "trait" or w == "comptime" or w == "alias" or w == "import"
        or w == "from" or w == "as" or w == "if" or w == "elif" or w == "else"
        or w == "while" or w == "for" or w == "in" or w == "return"
        or w == "raise" or w == "raises" or w == "try" or w == "except"
        or w == "with" or w == "yield" or w == "pass" or w == "break"
        or w == "continue" or w == "and" or w == "or" or w == "not"
        or w == "is" or w == "True" or w == "False" or w == "None"
        or w == "self" or w == "Self" or w == "imm" or w == "mut"
        or w == "out" or w == "deinit" or w == "ref" or w == "where"
    )


@fieldwise_init
struct Run(ImplicitlyCopyable, Movable):
    """One same-coloured stretch of a line: where it starts in columns and
    bytes, how far it runs in each, and its kind."""

    var col: Int
    var byte_start: Int
    var byte_len: Int
    var cols: Int
    var kind: Int


def _push_run(
    mut runs: List[Run],
    col: Int,
    byte_start: Int,
    byte_len: Int,
    cols: Int,
    kind: Int,
):
    """Append, merging with the previous run when the colour is the same."""
    let n = len(runs)
    if n > 0 and runs[n - 1].kind == kind:
        runs[n - 1].byte_len += byte_len
        runs[n - 1].cols += cols
        return
    runs.append(Run(col, byte_start, byte_len, cols, kind))


def _char_width(b: Int) -> Int:
    """Bytes in the UTF-8 sequence this lead byte starts."""
    if b >= 0xF0:
        return 4
    if b >= 0xE0:
        return 3
    if b >= 0xC0:
        return 2
    return 1


def triple_state_after(line: String, start_inside: Bool) -> Bool:
    """Whether the NEXT line starts inside a triple-quoted string.

    The lexer is per-line by design; this is the one bit of state a
    docstring needs carried across lines. Both quote styles count, and a
    backslash escapes inside a string the way the lexer already honours.
    """
    let bytes = line.as_bytes()
    let n = len(bytes)
    var inside = start_inside
    var quote = 0x22  # the delimiter of the string we are inside
    var i = 0
    while i < n:
        let b = Int(bytes[i])
        if inside:
            if b == 0x5C:
                i += 2
                continue
            if (
                b == quote
                and i + 2 < n
                and Int(bytes[i + 1]) == quote
                and Int(bytes[i + 2]) == quote
            ):
                inside = False
                i += 3
                continue
            i += 1
            continue
        if (b == 0x22 or b == 0x27) and i + 2 < n:
            if Int(bytes[i + 1]) == b and Int(bytes[i + 2]) == b:
                inside = True
                quote = b
                i += 3
                continue
        if b == 0x22 or b == 0x27:
            # An ordinary string: skip it whole so its contents cannot fake
            # a triple delimiter.
            let q = b
            var esc = False
            i += 1
            while i < n:
                let c = Int(bytes[i])
                i += 1
                if esc:
                    esc = False
                elif c == 0x5C:
                    esc = True
                elif c == q:
                    break
            continue
        if b == 0x23:
            return inside  # comment: nothing after it counts
        i += 1
    return inside


def highlight_runs(line: String, in_triple: Bool = False) -> List[Run]:
    """The line as same-coloured runs.

    A lexer rather than a parser, and deliberately: this is on the draw path
    and has to be right about comments, strings and keywords without knowing
    anything else. It walks bytes and allocates one Run per colour change --
    the old shape built a String PER CHARACTER and a kind per character, and
    the draw loop then rebuilt those characters into runs with another String
    append each. Sixty lines of that per frame, twice a second at idle for
    the caret blink, was the editor lexing the world to blink a cursor.
    """
    var runs = List[Run]()
    let bytes = line.as_bytes()
    let n = len(bytes)
    var i = 0
    var col = 0
    # A line that STARTS inside a docstring is string-coloured up to the
    # closing delimiter, or wholly, and the lexer resumes after it. This is
    # the fix for continuation lines rendering as code: the lexer was
    # per-line and nothing told it the line began mid-string.
    if in_triple:
        var j = 0
        var cols = 0
        var closed = False
        while j < n:
            let c = Int(bytes[j])
            if c == 0x5C:
                var w = 1
                if j + 1 < n:
                    w = 2
                var k = j
                while k < j + w:
                    if (Int(bytes[k]) & 0xC0) != 0x80:
                        cols += 1
                    k += 1
                j += w
                continue
            if (
                c == 0x22
                and j + 2 < n
                and Int(bytes[j + 1]) == 0x22
                and Int(bytes[j + 2]) == 0x22
            ):
                cols += 3
                j += 3
                closed = True
                break
            if (Int(bytes[j]) & 0xC0) != 0x80:
                cols += 1
            j += 1
        if not closed and j >= n and n >= 3:
            # The delimiter may sit at the very end of the line.
            if (
                Int(bytes[n - 3]) == 0x22
                and Int(bytes[n - 2]) == 0x22
                and Int(bytes[n - 1]) == 0x22
            ):
                closed = True
        _push_run(runs, col, 0, j, cols, KIND_STRING)
        col += cols
        i = j
    while i < n:
        let b = Int(bytes[i])
        if b == 0x23:  # '#' -- comment to end of line, nothing else after
            var cols = 0
            var j = i
            while j < n:
                if (Int(bytes[j]) & 0xC0) != 0x80:
                    cols += 1
                j += 1
            _push_run(runs, col, i, n - i, cols, KIND_COMMENT)
            break
        if (
            (b == 0x22 or b == 0x27)
            and i + 2 < n
            and Int(bytes[i + 1]) == b
            and Int(bytes[i + 2]) == b
        ):
            # A triple-quoted string opening here. Colour to its close on
            # this line, or to the end -- the carried state (threaded by the
            # draw loop through triple_state_after) covers the lines after.
            let q3 = b
            var j = i + 3
            var cols = 3
            while j < n:
                let c = Int(bytes[j])
                if c == 0x5C and j + 1 < n:
                    if (Int(bytes[j]) & 0xC0) != 0x80:
                        cols += 1
                    if (Int(bytes[j + 1]) & 0xC0) != 0x80:
                        cols += 1
                    j += 2
                    continue
                if (
                    c == q3
                    and j + 2 < n
                    and Int(bytes[j + 1]) == q3
                    and Int(bytes[j + 2]) == q3
                ):
                    cols += 3
                    j += 3
                    break
                if (c & 0xC0) != 0x80:
                    cols += 1
                j += 1
            _push_run(runs, col, i, j - i, cols, KIND_STRING)
            col += cols
            i = j
            continue
        if b == 0x22 or b == 0x27:  # a string, escapes included
            let quote = b
            var j = i + 1
            var cols = 1
            var escaped = False
            while j < n:
                let c = Int(bytes[j])
                if (c & 0xC0) != 0x80:
                    cols += 1
                j += 1
                if escaped:
                    escaped = False
                elif c == 0x5C:
                    escaped = True
                elif c == quote:
                    break
            _push_run(runs, col, i, j - i, cols, KIND_STRING)
            col += cols
            i = j
            continue
        if b >= 0x30 and b <= 0x39:  # a number, with . _ and suffix letters
            var j = i
            var cols = 0
            while j < n:
                let c = Int(bytes[j])
                if not (
                    (c >= 0x30 and c <= 0x39)
                    or c == 0x2E
                    or c == 0x5F
                    or (c >= 0x61 and c <= 0x7A)
                    or (c >= 0x41 and c <= 0x5A)
                ):
                    break
                cols += 1
                j += 1
            _push_run(runs, col, i, j - i, cols, KIND_NUMBER)
            col += cols
            i = j
            continue
        let ident = (
            (b >= 0x41 and b <= 0x5A) or (b >= 0x61 and b <= 0x7A) or b == 0x5F
        )
        if ident:
            var j = i
            while j < n:
                let c = Int(bytes[j])
                if not (
                    (c >= 0x41 and c <= 0x5A)
                    or (c >= 0x61 and c <= 0x7A)
                    or (c >= 0x30 and c <= 0x39)
                    or c == 0x5F
                ):
                    break
                j += 1
            let word = String(line[byte=i:j])
            let kind = KIND_KEYWORD if _is_keyword(word) else KIND_PLAIN
            _push_run(runs, col, i, j - i, j - i, kind)
            col += j - i
            i = j
            continue
        # Anything else is one plain character, however many bytes wide.
        let w = _char_width(b)
        _push_run(runs, col, i, min(w, n - i), 1, KIND_PLAIN)
        col += 1
        i += w
    return runs^


def highlight(line: String) -> List[Int]:
    """One kind per character -- the runs, expanded. The draw loop reads the
    runs directly; this shape remains for the tests, which assert per-character
    and would hide an off-by-one if they asserted runs."""
    var kinds = List[Int]()
    for r in highlight_runs(line):
        for _ in range(r.cols):
            kinds.append(r.kind)
    return kinds^


def _attrs_for(kind: Int) -> ObjCObject:
    if kind == KIND_COMMENT:
        return ObjCObject(g_attr_comment()[])
    if kind == KIND_STRING:
        return ObjCObject(g_attr_string()[])
    if kind == KIND_KEYWORD:
        return ObjCObject(g_attr_keyword()[])
    if kind == KIND_NUMBER:
        return ObjCObject(g_attr_number()[])
    return ObjCObject(g_attrs()[])


def _make_attrs(colour: ObjCObject) -> Int:
    """An attribute dictionary for one colour, retained for the process."""
    let NSMutableDictionary = ObjCClass.lookup["NSMutableDictionary"]()
    var d = Cls["NSMutableDictionary"]().dictionary()
    Obj["NSMutableDictionary"](d.addr()).setObject_forKey(
        ObjCObject(g_font()[]).ptr(),
        extern_object["NSFontAttributeName"]().ptr(),
    )
    Obj["NSMutableDictionary"](d.addr()).setObject_forKey(
        colour.ptr(), extern_object["NSForegroundColorAttributeName"]().ptr()
    )
    _ = external_call["objc_retain", P](d.ptr())
    return d.addr()

comptime _pre_blink_on = named_global["roast.blink", Int]


def g_blink_on() -> Pointer[Int, MutUntrackedOrigin]:
    """`blink_on`, on the view. Spelled as it always was, so no call site moved.

    Two storages, and which one is live is decided by whether there is a view
    to hold one -- which is the same question as whether `box_ref` answers.
    That is not a transition artefact: `edit_test` drives the whole editor
    without ever making a view -- deliberately, since the risk there is the
    arithmetic and not the Objective-C -- and writes through this accessor
    constantly. So the fallback is a real, used path, not a start-up nicety.

    They cannot disagree. The field carries no initializer, so both read zero
    until a view exists, and `make_grid_view` records `g_grid` in the same
    breath as it makes the view, leaving no window in which one is written
    and the other read."""
    var box = box_ref[RoastGridView](g_grid()[])
    if not box:
        return _pre_blink_on()
    return Pointer(to=box.value()[].blink_on)
comptime _pre_focused = named_global["roast.focused", Int]


def g_focused() -> Pointer[Int, MutUntrackedOrigin]:
    """`focused`, on the view. Spelled as it always was, so no call site moved.

    Two storages, and which one is live is decided by whether there is a view
    to hold one -- which is the same question as whether `box_ref` answers.
    That is not a transition artefact: `edit_test` drives the whole editor
    without ever making a view -- deliberately, since the risk there is the
    arithmetic and not the Objective-C -- and writes through this accessor
    constantly. So the fallback is a real, used path, not a start-up nicety.

    They cannot disagree. The field carries no initializer, so both read zero
    until a view exists, and `make_grid_view` records `g_grid` in the same
    breath as it makes the view, leaving no window in which one is written
    and the other read."""
    var box = box_ref[RoastGridView](g_grid()[])
    if not box:
        return _pre_focused()
    return Pointer(to=box.value()[].focused)


def sel_start() -> Int:
    return min(g_caret()[], g_anchor()[])


def sel_end() -> Int:
    return max(g_caret()[], g_anchor()[])


# Paths dropped on the editor, waiting for the timer to open them. A queue
# and not a direct call: this module is imported BY roast, so it cannot
# reach open_path, and a drop must not run a project open from inside
# AppKit's drag machinery anyway.
comptime g_dropped = named_global["roast.dropped", List[String]]


def take_dropped() -> List[String]:
    """Everything dropped since the last call, and clears the queue."""
    var out = List[String]()
    for path in g_dropped()[]:
        out.append(path)
    g_dropped()[] = List[String]()
    return out^


comptime g_lncol_field = named_global["roast.lncol.field", Int]
comptime g_lncol_last = named_global["roast.lncol.last", Int]


def set_lncol_field(addr: Int):
    """The status bar's Ln/Col label, handed over by the window builder.
    The caret lives here, so keeping the label true lives here too."""
    g_lncol_field()[] = addr
    _update_lncol()


def _update_lncol():
    if g_lncol_field()[] == 0 or not has_rope():
        return
    let buf = g_buffer()
    let caret = g_caret()[]
    # Free when nothing moved: draw also runs for scrolls and edits.
    if caret == g_lncol_last()[] - 1:
        return
    g_lncol_last()[] = caret + 1
    let line = buf[][0].line_of_offset(caret)
    let col = caret - buf[][0].line_start(line)
    with autoreleasepool():
        _ = msg_send[ObjCObject, "NSTextField", "setStringValue:"](
            ObjCObject(g_lncol_field()[]),
            nsstring(
                String("Ln ") + String(line + 1)
                + String(", Col ") + String(col + 1)
            ).ptr(),
        )


def set_caret(at: Int):
    g_caret()[] = at
    g_anchor()[] = at


def byte_to_utf16(offset: Int) -> Int:
    """A byte offset in the buffer as a UTF-16 offset, for Cocoa.

    The rope answers from cached per-node counts. The old version here sliced
    the whole prefix into a fresh String -- and selectedRange calls this on
    essentially every keystroke, so on a big file every keypress paid a
    multi-megabyte copy before the character landed."""
    if not has_rope():
        return 0
    return g_buffer()[][0].byte_to_utf16(offset)


def utf16_to_byte(u16: Int) -> Int:
    """The inverse. This one flattened the ENTIRE buffer with to_string()."""
    if not has_rope():
        return 0
    return g_buffer()[][0].utf16_to_byte(u16)


# Undo entries kept. An entry is a rope root -- pointer-cheap -- but each
# root pins every leaf it references, so an unbounded stack turns a long
# session's memory into a museum of every state the buffer has ever had.
comptime UNDO_CAP = 1000


def push_undo(coalescing: Bool = False):
    """Record the current buffer so an edit can be taken back.

    `coalescing` is the typing case: a run of single characters becomes one
    undo entry rather than one per keystroke.
    """
    if not has_rope():
        return
    if coalescing and g_coalesce_at()[] == g_caret()[] and len(g_undo()[]) > 0:
        return  # continues the run already recorded
    g_undo()[].append(g_buffer()[][0].copy())
    g_undo_caret()[].append(g_caret()[])
    # The oldest history goes first, which is the end nobody misses.
    while len(g_undo()[]) > UNDO_CAP:
        _ = g_undo()[].pop(0)
        _ = g_undo_caret()[].pop(0)
    # Any new edit invalidates the redo branch, as it must.
    while len(g_redo()[]) > 0:
        _ = g_redo()[].pop()
    while len(g_redo_caret()[]) > 0:
        _ = g_redo_caret()[].pop()


def undo() -> Bool:
    if len(g_undo()[]) == 0 or not has_rope():
        return False
    g_redo()[].append(g_buffer()[][0].copy())
    g_redo_caret()[].append(g_caret()[])
    set_rope(g_undo()[].pop())
    set_caret(g_undo_caret()[].pop())
    g_coalesce_at()[] = -1
    return True


def redo() -> Bool:
    if len(g_redo()[]) == 0 or not has_rope():
        return False
    g_undo()[].append(g_buffer()[][0].copy())
    g_undo_caret()[].append(g_caret()[])
    set_rope(g_redo()[].pop())
    set_caret(g_redo_caret()[].pop())
    g_coalesce_at()[] = -1
    return True


def query() -> String:
    if len(g_query()[]) == 0:
        return String()
    return g_query()[][0]


def set_query(var q: String):
    let slot = g_query()
    if len(slot[]) == 0:
        slot[].append(q^)
    else:
        slot[][0] = q^


def find_next(wrap: Bool = True) -> Bool:
    """Move the selection to the next match after the caret."""
    let q = query()
    if q.byte_length() == 0 or not has_rope():
        return False
    let buf = g_buffer()[][0]
    var hit = buf.find(q, g_caret()[])
    if hit < 0 and wrap:
        hit = buf.find(q, 0)          # wrap, the way every editor does
    if hit < 0:
        return False
    g_anchor()[] = hit
    g_caret()[] = hit + q.byte_length()
    g_match_at()[] = hit
    return True


def find_previous() -> Bool:
    let q = query()
    if q.byte_length() == 0 or not has_rope():
        return False
    let buf = g_buffer()[][0]
    var hit = buf.find_last(q, sel_start())
    if hit < 0:
        hit = buf.find_last(q, buf.byte_length())
    if hit < 0:
        return False
    g_anchor()[] = hit
    g_caret()[] = hit + q.byte_length()
    g_match_at()[] = hit
    return True


def match_count() -> Int:
    if query().byte_length() == 0 or not has_rope():
        return 0
    let buf = g_buffer()[][0]
    return len(buf.find_all_in(query(), 0, buf.byte_length()))


def display_column(offset: Int) -> Int:
    """The column an offset sits at, counted in characters rather than bytes.

    Fixed-pitch means one character is one cell, so this is what multiplies by
    the advance. East Asian double-width characters occupy two cells and are
    not handled here -- the design lists a width table as a stdlib gap, and
    until it exists a CJK line's caret drifts. Latin and code are exact.
    """
    if not has_rope():
        return 0
    let buf = g_buffer()[][0]
    let line = buf.line_of_offset(offset)
    let start = buf.line_start(line)
    var n = 0
    for _ in buf.slice(start, offset).codepoints():
        n += 1
    return n


def caret_position(offset: Int) -> CGPoint:
    """Where a byte offset lands on screen, in view coordinates."""
    if not has_rope():
        return CGPoint(GUTTER_W + TEXT_PAD, 0.0)
    let line = g_buffer()[][0].line_of_offset(offset)
    return CGPoint(
        GUTTER_W + TEXT_PAD + Float64(display_column(offset)) * advance(),
        Float64(line) * line_height(),
    )


def offset_at_point(x: Float64, y: Float64) -> Int:
    """The reverse: a click becomes a caret position."""
    if not has_rope():
        return 0
    let buf = g_buffer()[][0]
    let line = max(0, min(buf.line_count() - 1, Int(y / line_height())))
    let col = max(0, Int((x - GUTTER_W - TEXT_PAD) / advance() + 0.5))
    let text = buf.line(line)
    # Walk codepoints so a click past a multi-byte character lands after it,
    # never inside it.
    var seen = 0
    var at = buf.line_start(line)
    for c in text.codepoints():
        if seen >= col:
            break
        at += len(String(c).as_bytes())
        seen += 1
    return at


def replace_selection(text: String):
    """The one place the buffer changes. Everything else routes through here so
    the caret, the marked range and the view are updated together."""
    if not has_rope():
        return
    let a = sel_start()
    let b = sel_end()
    # A one-character insert with nothing selected is typing; anything else is
    # an edit worth its own undo entry.
    let typing = a == b and text.byte_length() == 1 and text != "\n"
    push_undo(coalescing=typing)
    set_rope(g_buffer()[][0].replace(a, b, text))
    set_caret(a + text.byte_length())
    g_coalesce_at()[] = g_caret()[] if typing else -1
    g_marked_at()[] = 0
    g_marked_len()[] = 0


def selected_text() -> String:
    if not has_rope():
        return String()
    return g_buffer()[][0].slice(sel_start(), sel_end())


def clipboard_write(text: String) -> Bool:
    """Put a string on the general pasteboard, replacing what was there."""
    with autoreleasepool():
        let NSPasteboard = ObjCClass.lookup["NSPasteboard"]()
        let pb = Cls["NSPasteboard"]().generalPasteboard()
        _ = Obj["NSPasteboard"](pb.addr()).clearContents()
        return Obj["NSPasteboard"](pb.addr()).setString_forType(
            nsstring(text).ptr(),
            extern_object["NSPasteboardTypeString"]().ptr(),
        )


def clipboard_read() -> String:
    """The pasteboard's string, or empty -- an image on the clipboard is not
    something a text editor can paste."""
    with autoreleasepool():
        let NSPasteboard = ObjCClass.lookup["NSPasteboard"]()
        let pb = Cls["NSPasteboard"]().generalPasteboard()
        let s = Obj["NSPasteboard"](pb.addr()).stringForType(
            extern_object["NSPasteboardTypeString"]().ptr()
        )
        if s.addr() == 0:
            return String()
        return ns_to_string(s.object())


def copy_selection() -> Bool:
    """Copy the selection. Nothing selected copies nothing -- clearing the
    clipboard because the caret was collapsed would surprise, and surprise at
    paste time is data loss at copy time."""
    let text = selected_text()
    if text.byte_length() == 0:
        return False
    return clipboard_write(text)


def cut_selection() -> Bool:
    if not copy_selection():
        return False
    replace_selection(String())
    return True


def paste_clipboard() -> Bool:
    let text = clipboard_read()
    if text.byte_length() == 0:
        return False
    replace_selection(text)
    return True


def reveal_caret(view: ObjCObject):
    """Scroll the caret into view. A paste or an undo can land it anywhere."""
    with autoreleasepool():
        let pos = caret_position(g_caret()[])
        let lh = line_height()
        _ = Obj["NSView"](view.addr()).scrollRectToVisible(
            rect(pos.x - 40.0, pos.y - lh, 160.0, lh * 3.0)
        )


def _prev_codepoint(buf: Rope, at: Int) -> Int:
    """One character left of `at`, never landing inside a UTF-8 sequence.

    A windowed slice rather than to_string(): stepping the caret must not
    cost a copy of the buffer, and a UTF-8 sequence is at most four bytes.
    """
    if at <= 0:
        return 0
    let window_at = max(0, at - 8)
    let bytes = buf.slice(window_at, at).as_bytes()
    var back = at - 1
    while back > window_at and (Int(bytes[back - window_at]) & 0xC0) == 0x80:
        back -= 1
    return back


def _next_codepoint(buf: Rope, at: Int) -> Int:
    """One character right, same terms."""
    let n = buf.byte_length()
    if at >= n:
        return n
    let bytes = buf.slice(at, min(n, at + 8)).as_bytes()
    var fwd = at + 1
    while fwd < n and fwd - at < len(bytes) and (
        Int(bytes[fwd - at]) & 0xC0
    ) == 0x80:
        fwd += 1
    return fwd


def select_word_at(at: Int):
    """Select the identifier under `at`, or the single non-word character
    there -- the double-click rule every Mac text view follows.

    The rope has no whole-buffer byte view; like the ⌥-arrow movement
    above, this reads a small window around the point, which is also the
    only part a word can occupy."""
    if not has_rope():
        return
    let buf = g_buffer()[][0]
    let total = buf.byte_length()
    var a = at
    if a > total:
        a = total
    let w0 = max(0, a - 512)
    let w1 = min(total, a + 512)
    let bytes = buf.slice(w0, w1).as_bytes()
    let n = len(bytes)
    var rel = a - w0
    if rel < n and _is_word_byte(Int(bytes[rel])):
        var lo = rel
        while lo > 0 and _is_word_byte(Int(bytes[lo - 1])):
            lo -= 1
        var hi = rel
        while hi < n and _is_word_byte(Int(bytes[hi])):
            hi += 1
        g_anchor()[] = w0 + lo
        g_caret()[] = w0 + hi
        return
    # Off a word: behind one? (a click lands between characters)
    if rel > 0 and _is_word_byte(Int(bytes[rel - 1])):
        var lo2 = rel - 1
        while lo2 > 0 and _is_word_byte(Int(bytes[lo2 - 1])):
            lo2 -= 1
        var hi2 = rel
        while hi2 < n and _is_word_byte(Int(bytes[hi2])):
            hi2 += 1
        g_anchor()[] = w0 + lo2
        g_caret()[] = w0 + hi2
        return
    if rel < n:
        g_anchor()[] = w0 + rel
        g_caret()[] = w0 + rel + 1


def select_line_at(at: Int):
    """Select the whole line under `at`, newline included -- triple-click."""
    if not has_rope():
        return
    let buf = g_buffer()[][0]
    let ln = buf.line_of_offset(at)
    g_anchor()[] = buf.line_start(ln)
    if ln + 1 < buf.line_count():
        g_caret()[] = buf.line_start(ln + 1)
    else:
        g_caret()[] = buf.byte_length()


def _is_word_byte(b: Int) -> Bool:
    """What ⌥-arrow jumps over: identifier characters, and any non-ASCII
    byte -- multibyte text is words, not punctuation."""
    return (
        (b >= 0x30 and b <= 0x39)
        or (b >= 0x41 and b <= 0x5A)
        or (b >= 0x61 and b <= 0x7A)
        or b == 0x5F
        or b >= 0x80
    )


def _word_left(buf: Rope, at: Int) -> Int:
    """⌥←: over the separators, then over the word they end. Newlines are
    separators, so this crosses lines the way every editor does."""
    let window_at = max(0, at - 512)
    let bytes = buf.slice(window_at, at).as_bytes()
    var i = len(bytes)
    while i > 0 and not _is_word_byte(Int(bytes[i - 1])):
        i -= 1
    while i > 0 and _is_word_byte(Int(bytes[i - 1])):
        i -= 1
    return window_at + i


def _word_right(buf: Rope, at: Int) -> Int:
    let n = buf.byte_length()
    let bytes = buf.slice(at, min(n, at + 512)).as_bytes()
    var i = 0
    while i < len(bytes) and not _is_word_byte(Int(bytes[i])):
        i += 1
    while i < len(bytes) and _is_word_byte(Int(bytes[i])):
        i += 1
    return at + i


def _vertical(buf: Rope, from_: Int, lines: Int) -> Int:
    """The offset `lines` lines away, keeping the column.

    Off the top lands at the start, off the bottom at the end -- which is what
    an arrow key at the edge of the document does everywhere. The column is
    walked in codepoints on the target line, so arriving beside a multibyte
    character cannot land inside it.
    """
    let line = buf.line_of_offset(from_)
    let col = from_ - buf.line_start(line)
    let target = line + lines
    if target < 0:
        return 0
    if target >= buf.line_count():
        return buf.byte_length()
    let ls = buf.line_start(target)
    let text = buf.line(target)
    var seen = 0
    for c in text.codepoints():
        let w = len(String(c).as_bytes())
        if seen + w > col:
            break
        seen += w
    return ls + seen


def apply_command(name: String, page_lines: Int = 40):
    """Movement and deletion, separated from the plumbing that delivers it.

    Everything here is buffer arithmetic, which is where the bugs live -- a
    backspace that eats half a UTF-8 sequence, an up-arrow that forgets which
    column it started in. ide/edit_test.mojo drives this directly, with no
    window and no event loop.

    Selection is not a separate mode: every movement selector has an
    AndModifySelection: twin that AppKit sends for the shifted key, and the
    twin is the same motion leaving the anchor where it was. Resolving the
    suffix once means a motion added later is selectable for free.
    """
    try:
        if not has_rope():
            return
        let buf = g_buffer()[][0]
        let n = buf.byte_length()

        # While candidates are showing, the arrows and Enter belong to the
        # list, not the buffer. Escape puts it away; anything else that is not
        # a movement dismisses it, because a list that survives an edit is
        # answering a question nobody is asking any more.
        if popup_open():
            if name == "moveDown:":
                popup_move(1)
                return
            if name == "moveUp:":
                popup_move(-1)
                return
            if name == "insertNewline:" or name == "insertTab:":
                _ = popup_accept()
                return
            if name == "cancelOperation:":
                hide_popup()
                return
            hide_popup()

        if name == "undo:":
            _ = undo()
            return
        elif name == "redo:":
            _ = redo()
            return
        elif name == "selectAll:":
            g_anchor()[] = 0
            g_caret()[] = buf.byte_length()
            return

        if name == "insertNewline:":
            # Auto-indent: the new line opens where the old one was
            # indented, one level deeper after a trailing colon. Two rules,
            # and they cover nearly all Mojo typing.
            var indent = String("\n")
            if has_rope():
                let ln = buf.line_of_offset(sel_start())
                let cur = buf.line(ln)
                let cb = cur.as_bytes()
                var pad = 0
                while pad < len(cb) and Int(cb[pad]) == 0x20:
                    pad += 1
                # Only the indent BEFORE the caret carries: pressing Return
                # at column 0 of an indented line starts a fresh line, it
                # does not clone indentation from text the caret sits above.
                let col_b = sel_start() - buf.line_start(ln)
                if pad > col_b:
                    pad = col_b
                for _ in range(pad):
                    indent += String(" ")
                # A colon at the end of what precedes the caret opens a
                # block. Trailing spaces after it count as after it.
                var last = col_b - 1
                while last >= 0 and Int(cb[last]) == 0x20:
                    last -= 1
                if last >= 0 and Int(cb[last]) == 0x3A:
                    indent += String("    ")
            replace_selection(indent)
            return
        elif name == "insertTab:":
            replace_selection(String("    "))
            return
        elif name == "deleteBackward:":
            if sel_start() != sel_end():
                replace_selection(String())
            elif g_caret()[] > 0:
                # One codepoint, not one byte: deleting half a character is
                # how a buffer stops being valid UTF-8.
                push_undo()
                let back = _prev_codepoint(buf, g_caret()[])
                set_rope(buf.replace(back, g_caret()[], String()))
                set_caret(back)
            return
        elif name == "deleteForward:":
            if sel_start() != sel_end():
                replace_selection(String())
            elif g_caret()[] < n:
                push_undo()
                set_rope(
                    buf.replace(
                        g_caret()[], _next_codepoint(buf, g_caret()[]), String()
                    )
                )
            return
        elif name == "deleteWordBackward:":
            # ⌥⌫. With a selection it is just delete; the word rule is for a
            # collapsed caret.
            if sel_start() != sel_end():
                replace_selection(String())
            elif g_caret()[] > 0:
                g_anchor()[] = _word_left(buf, g_caret()[])
                replace_selection(String())
            return
        elif name == "deleteWordForward:":
            if sel_start() != sel_end():
                replace_selection(String())
            elif g_caret()[] < n:
                g_anchor()[] = _word_right(buf, g_caret()[])
                replace_selection(String())
            return
        elif name == "deleteToBeginningOfLine:":
            # ⌘⌫, the whole line behind the caret.
            if sel_start() != sel_end():
                replace_selection(String())
            else:
                let ls = buf.line_start(buf.line_of_offset(g_caret()[]))
                if g_caret()[] > ls:
                    g_anchor()[] = ls
                    replace_selection(String())
            return

        # Movement. The shifted key sends the same name with a suffix; strip
        # it once and every motion below gains its selecting twin.
        var motion = name
        var select = False
        if name.endswith("AndModifySelection:"):
            select = True
            motion = String(
                name[byte = 0 : name.byte_length() - 19]
            ) + String(":")

        var to = -1
        if motion == "moveLeft:":
            # An unshifted arrow with a selection collapses to its edge
            # rather than moving -- the Mac rule, and what makes shift-select
            # then tap-arrow land where the eye expects.
            if not select and sel_start() != sel_end():
                to = sel_start()
            else:
                to = _prev_codepoint(buf, g_caret()[])
        elif motion == "moveRight:":
            if not select and sel_start() != sel_end():
                to = sel_end()
            else:
                to = _next_codepoint(buf, g_caret()[])
        elif motion == "moveUp:":
            to = _vertical(buf, g_caret()[], -1)
        elif motion == "moveDown:":
            to = _vertical(buf, g_caret()[], 1)
        elif motion == "moveWordLeft:" or motion == "moveWordBackward:":
            to = _word_left(buf, g_caret()[])
        elif motion == "moveWordRight:" or motion == "moveWordForward:":
            to = _word_right(buf, g_caret()[])
        elif (
            motion == "moveToBeginningOfLine:"
            or motion == "moveToLeftEndOfLine:"
        ):
            to = buf.line_start(buf.line_of_offset(g_caret()[]))
        elif (
            motion == "moveToEndOfLine:"
            or motion == "moveToRightEndOfLine:"
        ):
            let line = buf.line_of_offset(g_caret()[])
            to = buf.line_start(line) + buf.line(line).byte_length()
        elif motion == "moveToBeginningOfDocument:":
            to = 0
        elif motion == "moveToEndOfDocument:":
            to = n
        elif motion == "pageUp:" or motion == "scrollPageUp:":
            to = _vertical(buf, g_caret()[], -max(1, page_lines))
        elif motion == "pageDown:" or motion == "scrollPageDown:":
            to = _vertical(buf, g_caret()[], max(1, page_lines))
        if to >= 0:
            g_caret()[] = to
            if not select:
                g_anchor()[] = to
    except:
        pass


def _refresh(view_ptr: P):
    """Redraw, and keep the document tall enough for the buffer."""
    try:
        with autoreleasepool():
            let view = ObjCObject(Int(view_ptr))
            let frame = Obj["NSView"](view.addr()).frame()
            let want = document_size(frame.size.width)
            if want.height != frame.size.height:
                Obj["NSView"](view.addr()).setFrameSize(want)
            Obj["NSView"](view.addr()).setNeedsDisplay(True)
    except:
        pass




# ── Themes ──────────────────────────────────────────────────────────────────
# Every colour in the editor came from the system palette, which is correct
# and, on a machine set to light, relentless. A theme is a small table of
# roles, and `System` keeps the old behaviour: it follows whatever the rest
# of the machine is doing.
#
# The colours are sRGB triples rather than named system colours because that
# is the point -- a theme that defers to the system is not a theme.

comptime ROLE_BG = 0
comptime ROLE_TEXT = 1
comptime ROLE_GUTTER_BG = 2
comptime ROLE_GUTTER_TEXT = 3
comptime ROLE_SELECTION = 4
comptime ROLE_KEYWORD = 5
comptime ROLE_STRING = 6
comptime ROLE_NUMBER = 7
comptime ROLE_COMMENT = 8
comptime ROLE_HAIRLINE = 9
comptime ROLE_SIDEBAR_BG = 10
comptime ROLE_SIDEBAR_TEXT = 11


def theme_names() -> List[String]:
    """The themes on offer, in menu order."""
    var out = List[String]()
    out.append(String("System"))
    out.append(String("Ink"))
    out.append(String("Dusk"))
    out.append(String("Paper"))
    out.append(String("Contrast"))
    return out^


def current_theme() -> String:
    let chosen = session.setting(String("view.theme"))
    return String("System") if chosen == "" else chosen^


def theme_is_dark(name: String) -> Bool:
    return name == "Ink" or name == "Dusk" or name == "Contrast"


def _rgb(r: Int, g: Int, b: Int) -> ObjCObject:
    """A colour from 0-255 components, which is how they are written down."""
    return Cls["NSColor"]().colorWithSRGBRed_green_blue_alpha(
        Float64(r) / 255.0, Float64(g) / 255.0, Float64(b) / 255.0, 1.0
    )


def _system_color(role: Int) -> ObjCObject:
    """What the editor used before there were themes."""
    if role == ROLE_BG:
        return Cls["NSColor"]().textBackgroundColor()
    if role == ROLE_TEXT:
        return Cls["NSColor"]().textColor()
    if role == ROLE_GUTTER_BG:
        return Cls["NSColor"]().windowBackgroundColor()
    if role == ROLE_GUTTER_TEXT:
        return Cls["NSColor"]().tertiaryLabelColor()
    if role == ROLE_SELECTION:
        return Cls["NSColor"]().selectedTextBackgroundColor()
    if role == ROLE_KEYWORD:
        return Cls["NSColor"]().systemPurpleColor()
    if role == ROLE_STRING:
        return Cls["NSColor"]().systemRedColor()
    if role == ROLE_NUMBER:
        return Cls["NSColor"]().systemBlueColor()
    if role == ROLE_COMMENT:
        return Cls["NSColor"]().secondaryLabelColor()
    if role == ROLE_SIDEBAR_BG:
        return Cls["NSColor"]().controlBackgroundColor()
    if role == ROLE_SIDEBAR_TEXT:
        return Cls["NSColor"]().labelColor()
    return Cls["NSColor"]().separatorColor()


def theme_color(role: Int) -> ObjCObject:
    """The colour for one role under the current theme."""
    let name = current_theme()

    if name == "Ink":
        # Near-black, warm ink. The background is not pure black: a page
        # that dark makes every glyph glare.
        if role == ROLE_BG: return _rgb(20, 22, 26)
        if role == ROLE_TEXT: return _rgb(230, 225, 216)
        if role == ROLE_GUTTER_BG: return _rgb(26, 29, 34)
        if role == ROLE_GUTTER_TEXT: return _rgb(95, 103, 115)
        if role == ROLE_SELECTION: return _rgb(52, 62, 78)
        if role == ROLE_KEYWORD: return _rgb(199, 146, 234)
        if role == ROLE_STRING: return _rgb(224, 148, 116)
        if role == ROLE_NUMBER: return _rgb(130, 170, 255)
        if role == ROLE_COMMENT: return _rgb(107, 114, 128)
        if role == ROLE_SIDEBAR_BG: return _rgb(15, 17, 20)
        if role == ROLE_SIDEBAR_TEXT: return _rgb(198, 194, 186)
        return _rgb(44, 48, 56)

    if name == "Dusk":
        # Slate blue, lower contrast than Ink, for long sittings.
        if role == ROLE_BG: return _rgb(27, 32, 40)
        if role == ROLE_TEXT: return _rgb(215, 220, 227)
        if role == ROLE_GUTTER_BG: return _rgb(33, 39, 48)
        if role == ROLE_GUTTER_TEXT: return _rgb(93, 107, 125)
        if role == ROLE_SELECTION: return _rgb(56, 70, 90)
        if role == ROLE_KEYWORD: return _rgb(154, 184, 255)
        if role == ROLE_STRING: return _rgb(240, 168, 104)
        if role == ROLE_NUMBER: return _rgb(127, 209, 185)
        if role == ROLE_COMMENT: return _rgb(103, 118, 138)
        if role == ROLE_SIDEBAR_BG: return _rgb(22, 26, 33)
        if role == ROLE_SIDEBAR_TEXT: return _rgb(190, 198, 208)
        return _rgb(48, 57, 70)

    if name == "Paper":
        # Warm light: the antidote to a white page, without leaving daylight.
        if role == ROLE_BG: return _rgb(246, 241, 231)
        if role == ROLE_TEXT: return _rgb(46, 42, 37)
        if role == ROLE_GUTTER_BG: return _rgb(238, 232, 219)
        if role == ROLE_GUTTER_TEXT: return _rgb(150, 142, 128)
        if role == ROLE_SELECTION: return _rgb(219, 208, 184)
        if role == ROLE_KEYWORD: return _rgb(122, 62, 157)
        if role == ROLE_STRING: return _rgb(163, 59, 32)
        if role == ROLE_NUMBER: return _rgb(31, 111, 178)
        if role == ROLE_COMMENT: return _rgb(138, 131, 120)
        if role == ROLE_SIDEBAR_BG: return _rgb(233, 226, 211)
        if role == ROLE_SIDEBAR_TEXT: return _rgb(62, 56, 48)
        return _rgb(220, 212, 197)

    if name == "Contrast":
        # For a bright room or eyes that have had enough of subtlety.
        if role == ROLE_BG: return _rgb(0, 0, 0)
        if role == ROLE_TEXT: return _rgb(255, 255, 255)
        if role == ROLE_GUTTER_BG: return _rgb(16, 16, 16)
        if role == ROLE_GUTTER_TEXT: return _rgb(160, 160, 160)
        if role == ROLE_SELECTION: return _rgb(0, 90, 160)
        if role == ROLE_KEYWORD: return _rgb(255, 212, 0)
        if role == ROLE_STRING: return _rgb(124, 255, 124)
        if role == ROLE_NUMBER: return _rgb(124, 215, 255)
        if role == ROLE_COMMENT: return _rgb(160, 160, 160)
        if role == ROLE_SIDEBAR_BG: return _rgb(12, 12, 12)
        if role == ROLE_SIDEBAR_TEXT: return _rgb(235, 235, 235)
        return _rgb(64, 64, 64)

    return _system_color(role)


def rebuild_theme():
    """Re-derive every cached colour after the theme changes.

    The attributes are built once at startup and cached, which is why the
    editor does not pay for them per line. A theme change is the one moment
    that cache is wrong, so it is thrown away and built again -- the same
    path startup uses, rather than a second one that could drift from it.
    """
    build_type()
    if g_grid()[] != 0:
        Obj["NSView"](ObjCObject(g_grid()[]).addr()).setNeedsDisplay(True)
