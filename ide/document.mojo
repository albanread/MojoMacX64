# Documents: what a tab is.
#
# The editor's live state -- the rope, the caret, the undo stack, the revision
# -- lives in process globals, because a Cocoa callback gets no closure and has
# to find it somewhere. That was right for one buffer and is exactly wrong for
# several.
#
# Rather than thread a document handle through forty call sites, the globals
# stay as the *working set* and a Document is a saved state. Switching tabs
# stashes the working set into the document being left and loads the one being
# entered. Two functions, one place, and every existing call site keeps working
# unchanged -- which matters because those call sites are draw loops and input
# handlers where a wrong lookup is a bug nobody sees until it corrupts a buffer.
#
# The rope makes the stash cheap: saving a document's text is one pointer copy,
# and so is its whole undo history, because the entries share structure.
from rope import Rope
from gridview import (
    g_buffer,
    g_caret,
    g_anchor,
    g_revision,
    g_undo,
    g_redo,
    g_undo_caret,
    g_redo_caret,
    g_coalesce_at,
    g_marked_at,
    g_marked_len,
    set_rope,
    reset_line_cols,
)
from std.objc import named_global
from std.memory import Pointer


struct Document(Movable, Deinitable):
    """One open file: its text, where the caret is, and how to take back what
    was done to it."""

    var uri: String
    var rope: Rope
    var caret: Int
    var anchor: Int
    var revision: Int
    var saved_revision: Int   # the revision the file on disk matches
    var sent_revision: Int    # the revision the language server was told about
    var undo: List[Rope]
    var undo_caret: List[Int]
    var redo: List[Rope]
    var redo_caret: List[Int]

    def __init__(out self, var uri: String, var rope: Rope):
        self.uri = uri^
        self.rope = rope^
        self.caret = 0
        self.anchor = 0
        self.revision = 0
        self.saved_revision = 0
        self.sent_revision = -1
        self.undo = []
        self.undo_caret = []
        self.redo = []
        self.redo_caret = []

    def name(self) -> String:
        """The tab's label: the file name, or a placeholder."""
        if self.uri == "":
            return String("untitled")
        # Sliced out of a separate binding: `path = String(path[...])` reads
        # and writes the same value in one expression, which the compiler
        # rightly refuses.
        let full = self.uri
        var path = full
        if full.startswith("file://"):
            path = String(full[byte=7 : full.byte_length()])
        let cut = path.rfind(String("/"))
        if cut < 0:
            return path
        return String(path[byte = cut + 1 : path.byte_length()])

    def path(self) -> String:
        let full = self.uri
        if not full.startswith("file://"):
            return String()
        return String(full[byte=7 : full.byte_length()])

    def is_dirty(self) -> Bool:
        return self.revision != self.saved_revision


comptime g_docs = named_global["roast.docs", List[Document]]
comptime g_current = named_global["roast.current", Int]


def count() -> Int:
    return len(g_docs()[])


def current_index() -> Int:
    return min(g_current()[], max(0, count() - 1))


def name_at(index: Int) -> String:
    if index < 0 or index >= count():
        return String()
    return g_docs()[][index].name()


def dirty_at(index: Int) -> Bool:
    if index < 0 or index >= count():
        return False
    # The document being edited is the working set, not the stored copy.
    if index == current_index():
        return g_revision()[] != g_docs()[][index].saved_revision
    return g_docs()[][index].is_dirty()


def uri_at(index: Int) -> String:
    if index < 0 or index >= count():
        return String()
    return g_docs()[][index].uri


def path_at(index: Int) -> String:
    if index < 0 or index >= count():
        return String()
    return g_docs()[][index].path()


def _copy_ropes(src: List[Rope]) -> List[Rope]:
    var out = List[Rope]()
    for r in src:
        out.append(r.copy())
    return out^


def _copy_ints(src: List[Int]) -> List[Int]:
    var out = List[Int]()
    for v in src:
        out.append(v)
    return out^


def _clear_ropes(slot: Pointer[List[Rope], MutUntrackedOrigin]):
    while len(slot[]) > 0:
        _ = slot[].pop()


def _clear_ints(slot: Pointer[List[Int], MutUntrackedOrigin]):
    while len(slot[]) > 0:
        _ = slot[].pop()


def _stash(index: Int):
    """Copy the working set into the document being left."""
    if index < 0 or index >= count():
        return
    let docs = g_docs()
    if len(g_buffer()[]) > 0:
        docs[][index].rope = g_buffer()[][0].copy()
    docs[][index].caret = g_caret()[]
    docs[][index].anchor = g_anchor()[]
    docs[][index].revision = g_revision()[]
    # The stacks move rather than copy: the document is taking ownership of a
    # history the working set is about to replace.
    # Copied rather than moved: a global's contents have no origin to move
    # out of. The copy is cheap because an undo entry is a rope root -- one
    # pointer, sharing every node with its neighbours.
    docs[][index].undo = _copy_ropes(g_undo()[])
    docs[][index].undo_caret = _copy_ints(g_undo_caret()[])
    docs[][index].redo = _copy_ropes(g_redo()[])
    docs[][index].redo_caret = _copy_ints(g_redo_caret()[])
    _clear_ropes(g_undo())
    _clear_ints(g_undo_caret())
    _clear_ropes(g_redo())
    _clear_ints(g_redo_caret())


def _load(index: Int):
    """Make a document the working set."""
    if index < 0 or index >= count():
        return
    let docs = g_docs()
    set_rope(docs[][index].rope.copy())
    # set_rope bumps the revision; the document's own count is what counts.
    g_revision()[] = docs[][index].revision
    g_caret()[] = docs[][index].caret
    g_anchor()[] = docs[][index].anchor
    g_marked_at()[] = 0
    g_marked_len()[] = 0
    g_coalesce_at()[] = -1
    # The widest-line record belongs to the outgoing document.
    reset_line_cols()
    _clear_ropes(g_undo())
    _clear_ints(g_undo_caret())
    _clear_ropes(g_redo())
    _clear_ints(g_redo_caret())
    for r in docs[][index].undo:
        g_undo()[].append(r.copy())
    for c in docs[][index].undo_caret:
        g_undo_caret()[].append(c)
    for r in docs[][index].redo:
        g_redo()[].append(r.copy())
    for c in docs[][index].redo_caret:
        g_redo_caret()[].append(c)


def switch_to(index: Int) -> Bool:
    """Show a different document. Nothing happens if it is already showing."""
    if index < 0 or index >= count() or index == current_index():
        return False
    _stash(current_index())
    g_current()[] = index
    _load(index)
    return True


def index_of(uri: String) -> Int:
    """Which tab holds this file, or -1. Opening a file already open should
    select its tab rather than opening it twice."""
    var i = 0
    while i < count():
        if g_docs()[][i].uri == uri:
            return i
        i += 1
    return -1


def open_document(var uri: String, var rope: Rope) -> Int:
    """Add a document and make it current. An already-open file is selected."""
    let existing = index_of(uri)
    if existing >= 0:
        _ = switch_to(existing)
        return existing
    if count() > 0:
        _stash(current_index())
    g_docs()[].append(Document(uri^, rope^))
    g_current()[] = count() - 1
    _load(current_index())
    return current_index()


def close_at(index: Int) -> Bool:
    """Close a tab by index. The last one stays: an editor with no document is
    a window with nothing in it, and every editor keeps one open.

    Closing a tab that is not the current one must not disturb what is on
    screen, so the current document is stashed first and the index is adjusted
    rather than reloaded -- reloading would swap the buffer out from under an
    edit in progress.
    """
    if index < 0 or index >= count() or count() <= 1:
        return False
    let docs = g_docs()
    let at = current_index()
    _stash(at)
    var i = index
    while i < count() - 1:
        docs[].swap_elements(i, i + 1)
        i += 1
    _ = docs[].pop()
    if index == at:
        g_current()[] = min(index, count() - 1)
        _load(current_index())
    elif index < at:
        # Everything after the hole shifted down, so the current tab did too.
        g_current()[] = at - 1
    return True


def close_current() -> Bool:
    """Close the current tab. The last one stays: an editor with no document is
    a window with nothing in it, and every editor keeps one open."""
    if count() <= 1:
        return False
    let docs = g_docs()
    let at = current_index()
    # Shift the tail down. Documents are moved one slot at a time rather than
    # rebuilt, so the ropes are never copied.
    var i = at
    while i < count() - 1:
        docs[].swap_elements(i, i + 1)
        i += 1
    _ = docs[].pop()
    g_current()[] = min(at, count() - 1)
    _load(current_index())
    return True


def mark_saved():
    let docs = g_docs()
    let at = current_index()
    if at < count():
        docs[][at].saved_revision = g_revision()[]


def set_sent_revision(rev: Int):
    let docs = g_docs()
    let at = current_index()
    if at < count():
        docs[][at].sent_revision = rev


def sent_revision() -> Int:
    let at = current_index()
    if at >= count():
        return -1
    return g_docs()[][at].sent_revision


def current_uri() -> String:
    return uri_at(current_index())


def set_current_uri(var uri: String):
    let docs = g_docs()
    let at = current_index()
    if at < count():
        docs[][at].uri = uri^


def text_at(index: Int) -> String:
    """A document's full text: the working set for the current tab, the
    stored rope for a background one."""
    if index < 0 or index >= count():
        return String()
    if index == current_index() and len(g_buffer()[]) > 0:
        return g_buffer()[][0].to_string()
    return g_docs()[][index].rope.to_string()


def mark_announced(index: Int):
    """The server was just told this document's current text."""
    if index < 0 or index >= count():
        return
    let docs = g_docs()
    if index == current_index():
        docs[][index].sent_revision = g_revision()[]
    else:
        docs[][index].sent_revision = docs[][index].revision


def dirty_count() -> Int:
    var n = 0
    var i = 0
    while i < count():
        if dirty_at(i):
            n += 1
        i += 1
    return n
