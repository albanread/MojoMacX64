# A persistent rope: the text structure Roast is built on.
#
# A B-tree over UTF-8 leaves. Every node caches the bytes and newlines beneath
# it, so line->offset and offset->line are O(log n) walks rather than scans, and
# a 250,000-line file is a small case rather than the ceiling.
#
# The important property is that nodes are immutable and shared. An edit copies
# only the path from the touched leaf to the root -- four nodes at this depth --
# and returns a new root; every other node is shared with the previous version.
# That single property pays three times over, and the editor is designed around
# it:
#
#   * Undo is a stack of old roots. Structural sharing makes a thousand-entry
#     history cost kilobytes, so there are no command objects and no inverse
#     operations to get wrong.
#   * A snapshot is one pointer copy, so background work -- LSP sync, search,
#     saving -- reads a consistent tree on another queue with no lock while the
#     main thread keeps editing.
#   * A save cannot tear, because the tree it serialises cannot change.
#
# Byte offsets throughout. Mojo makes the choice explicit at every slice
# (`s[byte=a:b]` versus `s[codepoint=a:b]`), which is the right pressure for a
# text editor: the rope indexes bytes, and only the view layer thinks in
# characters.
from std.memory import ArcPointer

# Leaves are split near this size. Small enough that copying one on each
# keystroke is free, large enough that a big file is thousands of nodes rather
# than millions.
comptime LEAF_TARGET = 4096

# Interior fanout. At 32 a 100 MB file is four levels deep.
comptime FANOUT = 32


def _utf16_of(s: String) -> Int:
    """UTF-16 units in a string, counted from bytes without decoding.

    A 1-, 2- or 3-byte sequence is one unit; a 4-byte sequence is a surrogate
    pair, two. So the count is every non-continuation byte, plus one more for
    each 4-byte lead (0xF0 and up). One pass, no allocation.
    """
    let bytes = s.as_bytes()
    var u = 0
    for i in range(len(bytes)):
        let b = Int(bytes[i])
        if (b & 0xC0) != 0x80:
            u += 1
            if b >= 0xF0:
                u += 1
    return u


struct Node(Movable, Deinitable):
    """One rope node: either a run of text, or a list of children."""

    var is_leaf: Bool
    var text: String
    var kids: List[ArcPointer[Node]]
    var nbytes: Int
    var nlines: Int  # newline characters beneath this node, not line count
    var nutf16: Int  # UTF-16 units beneath this node -- what Cocoa counts in

    def __init__(out self, var text: String):
        """A leaf."""
        self.is_leaf = True
        self.nbytes = text.byte_length()
        self.nlines = text.count("\n")
        self.nutf16 = _utf16_of(text)
        self.text = text^
        self.kids = []

    def __init__(out self, var kids: List[ArcPointer[Node]]):
        """An interior node, summing its children."""
        var b = 0
        var l = 0
        var u = 0
        for k in kids:
            b += k[].nbytes
            l += k[].nlines
            u += k[].nutf16
        self.is_leaf = False
        self.text = String()
        self.kids = kids^
        self.nbytes = b
        self.nlines = l
        self.nutf16 = u


def _leaf(var text: String) -> ArcPointer[Node]:
    return ArcPointer(Node(text^))


def _branch(var kids: List[ArcPointer[Node]]) -> ArcPointer[Node]:
    return ArcPointer(Node(kids^))


def _split_points(s: String) -> List[Int]:
    """Byte offsets to cut a string into leaf-sized pieces.

    Cuts land after a newline where one is near the target, which keeps most
    lines inside a single leaf and makes line extraction a single slice. A cut
    never lands inside a UTF-8 sequence: continuation bytes are 0b10xxxxxx, so
    the offset walks forward off one.
    """
    var out = List[Int]()
    let n = s.byte_length()
    let bytes = s.as_bytes()
    var at = 0
    while n - at > LEAF_TARGET:
        var cut = at + LEAF_TARGET
        # Prefer a newline in the last eighth of the window.
        var probe = cut
        let floor = cut - (LEAF_TARGET // 8)
        var found = -1
        while probe > floor:
            if bytes[probe - 1] == 10:
                found = probe
                break
            probe -= 1
        if found > 0:
            cut = found
        else:
            # No newline nearby: step off any continuation byte.
            while cut < n and (Int(bytes[cut]) & 0xC0) == 0x80:
                cut += 1
        out.append(cut)
        at = cut
    return out^


def _build(var leaves: List[ArcPointer[Node]]) -> ArcPointer[Node]:
    """A balanced tree over ready-made leaves, built bottom-up."""
    if len(leaves) == 0:
        return _leaf(String())
    var level = leaves^
    while len(level) > 1:
        var up = List[ArcPointer[Node]]()
        var i = 0
        while i < len(level):
            var group = List[ArcPointer[Node]]()
            var j = 0
            while j < FANOUT and i < len(level):
                group.append(level[i])
                i += 1
                j += 1
            up.append(_branch(group^))
        level = up^
    return level[0]


struct Rope(Movable, Copyable):
    """An immutable text buffer. Every mutating operation returns a new Rope
    sharing all untouched structure with this one."""

    var root: ArcPointer[Node]

    def __init__(out self, var text: String):
        let cuts = _split_points(text)
        var leaves = List[ArcPointer[Node]]()
        var at = 0
        for c in cuts:
            # A byte slice is a StringSpan view; a leaf owns its text.
            leaves.append(_leaf(String(text[byte=at:c])))
            at = c
        leaves.append(_leaf(String(text[byte=at : text.byte_length()])))
        self.root = _build(leaves^)

    def __init__(out self, var root: ArcPointer[Node]):
        self.root = root^

    def copy(self) -> Self:
        # A snapshot: one retain, no text copied. This is what background work
        # takes while the main thread carries on editing.
        return Self(root=self.root)

    def byte_length(self) -> Int:
        return self.root[].nbytes

    def line_count(self) -> Int:
        """Lines, counting the last one even without a trailing newline."""
        return self.root[].nlines + 1

    # ── Reading ─────────────────────────────────────────────────────────────
    def slice(self, start: Int, end: Int) -> String:
        """Bytes [start, end). Walks only the nodes the range touches."""
        var out = String()
        _collect(self.root, 0, max(0, start), min(end, self.byte_length()), out)
        return out^

    def to_string(self) -> String:
        return self.slice(0, self.byte_length())

    def line_start(self, line: Int) -> Int:
        """Byte offset where `line` begins. O(log n) on the newline counts."""
        if line <= 0:
            return 0
        return _offset_of_newline(self.root, line - 1) + 1

    def line(self, index: Int) -> String:
        """One line, without its terminator."""
        let start = self.line_start(index)
        let n = self.byte_length()
        if start >= n:
            return String()
        var end = self.line_start(index + 1)
        if end > start and end <= n:
            end -= 1  # drop the newline
        else:
            end = n
        return self.slice(start, end)

    def line_of_offset(self, offset: Int) -> Int:
        """Which line a byte offset falls on."""
        return _count_newlines_before(self.root, min(offset, self.byte_length()))

    def utf16_length(self) -> Int:
        return self.root[].nutf16

    def byte_to_utf16(self, offset: Int) -> Int:
        """A byte offset as a UTF-16 offset, the unit Cocoa's text system
        counts in. O(log n) on the cached per-node counts plus one leaf scan;
        this used to be a copy of the whole prefix, which put a multi-megabyte
        walk inside selectedRange -- called on essentially every keystroke."""
        return _u16_before(
            self.root, max(0, min(offset, self.byte_length()))
        )

    def utf16_to_byte(self, u16: Int) -> Int:
        """The inverse, same cost. An offset landing inside a surrogate pair
        snaps to the start of the character -- Cocoa can ask for one when a
        range splits an astral-plane glyph, and half a pair is not a place."""
        if u16 <= 0:
            return 0
        if u16 >= self.root[].nutf16:
            return self.byte_length()
        return _byte_of_u16(self.root, u16)

    # ── Editing ─────────────────────────────────────────────────────────────
    def replace(self, start: Int, end: Int, var text: String) -> Self:
        """Replace bytes [start, end) with `text`, returning a new Rope.

        The common case -- an edit falling inside one leaf, which is every
        keystroke -- copies the path from that leaf to the root and shares
        everything else, so it costs O(log n) regardless of file size. Anything
        wider falls back to rebuilding, which is correct and rare.
        """
        let n = self.byte_length()
        let a = max(0, min(start, n))
        let b = max(a, min(end, n))

        # A leaf grown far past target would degrade lookup, so an edit that
        # would do that rebuilds instead and gets re-split.
        if b - a + text.byte_length() < LEAF_TARGET:
            let touched = _edit_leaf(self.root, 0, a, b, text)
            if touched:
                return Self(root=touched.value())

        var out = self.slice(0, a)
        out += text
        out += self.slice(b, n)
        return Self(out^)

    def insert(self, at: Int, var text: String) -> Self:
        return self.replace(at, at, text^)

    def delete(self, start: Int, end: Int) -> Self:
        return self.replace(start, end, String())

    # ── Searching ───────────────────────────────────────────────────────────
    def find(self, needle: String, from_offset: Int = 0) -> Int:
        """First occurrence at or after `from_offset`, or -1.

        Walks leaves rather than flattening. Flattening would copy the whole
        buffer on every find-next -- 14 MB per keypress while someone holds
        cmd-G -- and the point of a rope is that the text is already in
        memory in pieces worth scanning in place.

        A match straddling a leaf boundary is found because each leaf is
        searched together with the last `len(needle) - 1` bytes of the one
        before it, which is the only place a split match can hide.
        """
        if needle.byte_length() == 0:
            return -1
        var st = _Scan(needle, from_offset)
        _scan(self.root, 0, st)
        return st.found

    def find_last(self, needle: String, before: Int) -> Int:
        """Last occurrence starting strictly before `before`, or -1.

        Backwards search by repeated forward search: the buffer is scanned once
        and the last qualifying hit kept. Bounded and simple; a reverse walk
        would be faster on a huge file and is not worth the second code path
        until someone is searching backwards through 100 MB.
        """
        if needle.byte_length() == 0:
            return -1
        var best = -1
        var at = 0
        while True:
            let hit = self.find(needle, at)
            if hit < 0 or hit >= before:
                break
            best = hit
            at = hit + 1
        return best

    def find_all_in(
        self, needle: String, start: Int, end: Int
    ) -> List[Int]:
        """Every match beginning within [start, end), in one pass.

        This used to call find() once per match, and find() walks from the
        root -- O(matches x buffer), which match_count() then ran on every
        keystroke in the search field. Searching a big file for a common
        letter was seconds of copying. One walk collects them all.
        """
        var out = List[Int]()
        if needle.byte_length() == 0:
            return out^
        var st = _ScanAll(needle, start, min(end, self.byte_length()))
        _scan_all(self.root, 0, st)
        # Element copy rather than a move: a field cannot be moved out of a
        # value that still has a destructor to run.
        for h in st.hits:
            out.append(h)
        return out^


def _edit_leaf(
    node: ArcPointer[Node], base: Int, start: Int, end: Int, text: String
) -> Optional[ArcPointer[Node]]:
    """A new tree with [start, end) replaced, if the range lies inside a single
    leaf; nothing if it straddles more than one.

    This is the path copy. Only the nodes between the touched leaf and the root
    are rebuilt -- four of them at this depth on a 100 MB file -- and every
    other node is shared with the tree we were given, which is what makes undo
    a stack of roots rather than a log of inverse operations.
    """
    if node[].is_leaf:
        let lo = start - base
        let hi = end - base
        if lo < 0 or hi > node[].nbytes:
            return None
        var t = String(node[].text[byte=0:lo])
        t += text
        t += node[].text[byte=hi : node[].nbytes]
        return _leaf(t^)

    var at = base
    var index = -1
    var i = 0
    for k in node[].kids:
        # Contained, and not merely starting here: an edit crossing a child
        # boundary has to take the rebuild path.
        if start >= at and end <= at + k[].nbytes:
            index = i
            break
        at += k[].nbytes
        i += 1
    if index < 0:
        return None

    let rebuilt = _edit_leaf(node[].kids[index], at, start, end, text)
    if not rebuilt:
        return None

    var kids = List[ArcPointer[Node]]()
    var j = 0
    for k in node[].kids:
        if j == index:
            kids.append(rebuilt.value())
        else:
            kids.append(k)  # shared, not copied
        j += 1
    return _branch(kids^)


struct _Scan(Movable):
    """State carried across leaves while searching.

    `carry` is the tail of the previous leaf: without it a needle lying across
    a leaf boundary is invisible, which is the one bug every rope search has
    until it is written down.
    """

    var needle: String
    var from_offset: Int
    var carry: String
    var carry_at: Int
    var found: Int

    def __init__(out self, var needle: String, from_offset: Int):
        self.needle = needle^
        self.from_offset = from_offset
        self.carry = String()
        self.carry_at = 0
        self.found = -1


def _scan(node: ArcPointer[Node], base: Int, mut st: _Scan):
    if st.found >= 0:
        return
    # A whole subtree before the search start contributes nothing: a match
    # STARTS at or after from_offset, so bytes wholly before it are never part
    # of one, and the carry only matters between leaves actually scanned.
    # Without this, find-next from the middle of a big file still walked -- and
    # copied -- everything before the caret.
    if base + node[].nbytes <= st.from_offset:
        return
    if node[].is_leaf:
        # Everything before the search start is not worth looking at, but the
        # carry still has to be maintained across it.
        let m = st.needle.byte_length()
        var window = st.carry
        window += node[].text
        let window_at = st.carry_at if st.carry.byte_length() > 0 else base
        let rel = max(0, st.from_offset - window_at)
        let hit = window.find(st.needle, start=rel)
        if hit >= 0:
            st.found = window_at + hit
            return
        # Keep the last m-1 bytes for the next leaf, on a codepoint boundary so
        # the carry is always valid UTF-8.
        let keep = min(m - 1, window.byte_length())
        var cut = window.byte_length() - keep
        let bytes = window.as_bytes()
        while cut < window.byte_length() and (Int(bytes[cut]) & 0xC0) == 0x80:
            cut += 1
        st.carry = String(window[byte=cut : window.byte_length()])
        st.carry_at = window_at + cut
        return
    var at = base
    for k in node[].kids:
        _scan(k, at, st)
        if st.found >= 0:
            return
        at += k[].nbytes


struct _ScanAll(Movable):
    """Like _Scan, but keeps every hit in [start, end) instead of the first."""

    var needle: String
    var start: Int
    var end: Int
    var carry: String
    var carry_at: Int
    var hits: List[Int]
    var done: Bool

    def __init__(out self, var needle: String, start: Int, end: Int):
        self.needle = needle^
        self.start = start
        self.end = end
        self.carry = String()
        self.carry_at = 0
        self.hits = []
        self.done = False


def _scan_all(node: ArcPointer[Node], base: Int, mut st: _ScanAll):
    if st.done:
        return
    # Before the range: nothing here can start a match (same argument as
    # _scan). Past it: a match starting at or after `end` is not wanted, and
    # everything from here on starts later still.
    if base + node[].nbytes <= st.start:
        return
    if base >= st.end:
        st.done = True
        return
    if node[].is_leaf:
        let m = st.needle.byte_length()
        var window = st.carry
        window += node[].text
        let window_at = st.carry_at if st.carry.byte_length() > 0 else base
        var rel = max(0, st.start - window_at)
        while True:
            let hit = window.find(st.needle, start=rel)
            if hit < 0:
                break
            let pos = window_at + hit
            if pos >= st.end:
                st.done = True
                return
            st.hits.append(pos)
            rel = hit + 1
        # A match entirely inside the carry was found in the previous window
        # (it is shorter than the needle is long), so carrying the tail cannot
        # double-count -- the same argument _scan rests on.
        let keep = min(m - 1, window.byte_length())
        var cut = window.byte_length() - keep
        let bytes = window.as_bytes()
        while cut < window.byte_length() and (Int(bytes[cut]) & 0xC0) == 0x80:
            cut += 1
        st.carry = String(window[byte=cut : window.byte_length()])
        st.carry_at = window_at + cut
        return
    var at = base
    for k in node[].kids:
        _scan_all(k, at, st)
        if st.done:
            return
        at += k[].nbytes


# ── Tree walks ──────────────────────────────────────────────────────────────
def _collect(
    node: ArcPointer[Node], base: Int, start: Int, end: Int, mut out: String
):
    """Append the part of `node` covered by [start, end)."""
    let n = node[].nbytes
    if end <= base or start >= base + n:
        return
    if node[].is_leaf:
        let lo = max(0, start - base)
        let hi = min(n, end - base)
        if hi > lo:
            out += node[].text[byte=lo:hi]
        return
    var at = base
    for k in node[].kids:
        _collect(k, at, start, end, out)
        at += k[].nbytes


def _offset_of_newline(node: ArcPointer[Node], index: Int) -> Int:
    """Byte offset of the `index`-th newline (0-based)."""
    if node[].is_leaf:
        var seen = 0
        let bytes = node[].text.as_bytes()
        var i = 0
        while i < len(bytes):
            if bytes[i] == 10:
                if seen == index:
                    return i
                seen += 1
            i += 1
        return node[].nbytes
    var at = 0
    var remaining = index
    for k in node[].kids:
        if remaining < k[].nlines:
            return at + _offset_of_newline(k, remaining)
        remaining -= k[].nlines
        at += k[].nbytes
    return node[].nbytes


def _u16_before(node: ArcPointer[Node], offset: Int) -> Int:
    """UTF-16 units in the first `offset` bytes."""
    if node[].is_leaf:
        let bytes = node[].text.as_bytes()
        var u = 0
        var i = 0
        while i < len(bytes) and i < offset:
            let b = Int(bytes[i])
            if (b & 0xC0) != 0x80:
                u += 1
                if b >= 0xF0:
                    u += 1
            i += 1
        return u
    var at = 0
    var u = 0
    for k in node[].kids:
        if offset <= at:
            break
        if offset >= at + k[].nbytes:
            u += k[].nutf16
        else:
            u += _u16_before(k, offset - at)
            break
        at += k[].nbytes
    return u


def _byte_of_u16(node: ArcPointer[Node], u16: Int) -> Int:
    """The byte offset where the `u16`-th UTF-16 unit begins."""
    if node[].is_leaf:
        let bytes = node[].text.as_bytes()
        var u = 0
        var i = 0
        while i < len(bytes):
            let b = Int(bytes[i])
            if (b & 0xC0) != 0x80:
                var w = 1
                if b >= 0xF0:
                    w = 2
                if u + w > u16:
                    return i
                u += w
            i += 1
        return node[].nbytes
    var at = 0
    var remaining = u16
    for k in node[].kids:
        if remaining < k[].nutf16:
            return at + _byte_of_u16(k, remaining)
        remaining -= k[].nutf16
        at += k[].nbytes
    return node[].nbytes


def _count_newlines_before(node: ArcPointer[Node], offset: Int) -> Int:
    """How many newlines sit strictly before `offset`."""
    if node[].is_leaf:
        var seen = 0
        let bytes = node[].text.as_bytes()
        var i = 0
        while i < len(bytes) and i < offset:
            if bytes[i] == 10:
                seen += 1
            i += 1
        return seen
    var at = 0
    var seen = 0
    for k in node[].kids:
        if offset <= at:
            break
        if offset >= at + k[].nbytes:
            seen += k[].nlines
        else:
            seen += _count_newlines_before(k, offset - at)
            break
        at += k[].nbytes
    return seen
