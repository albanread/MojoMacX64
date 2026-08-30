# JSON, because the language server speaks it.
#
# IDE-DESIGN.md lists std.json as a stdlib gap; this is that gap, filled to the
# shape LSP actually needs. Strict rather than forgiving: a language server is a
# program we ship, so malformed input is a bug to surface, not a stream to
# guess at.
#
# Children hang off ArcPointer for the same reason the rope's do -- a struct
# cannot contain a List of itself, since the type is not complete while it is
# being defined, and a pointer is a fixed size.
from std.memory import ArcPointer

comptime NULL = 0
comptime BOOL = 1
comptime NUMBER = 2
comptime STRING = 3
comptime ARRAY = 4
comptime OBJECT = 5


struct JSON(Movable, Deinitable):
    var kind: Int
    var b: Bool
    var num: Float64
    var text: String
    var items: List[ArcPointer[JSON]]
    var keys: List[String]  # parallel to items when kind == OBJECT

    def __init__(out self):
        self.kind = NULL
        self.b = False
        self.num = 0.0
        self.text = String()
        self.items = []
        self.keys = []

    # Each constructor fills every field itself rather than assigning a fresh
    # Self over `out self`. Assigning to an uninitialised out-parameter runs the
    # destructor on whatever bytes were there, and this struct owns two Lists
    # and a String -- the same hazard that put the editor's buffer in a global
    # List instead of a raw slot.
    def __init__(out self, b: Bool):
        self.kind = BOOL
        self.b = b
        self.num = 0.0
        self.text = String()
        self.items = []
        self.keys = []

    def __init__(out self, n: Int):
        self.kind = NUMBER
        self.b = False
        self.num = Float64(n)
        self.text = String()
        self.items = []
        self.keys = []

    def __init__(out self, var s: String):
        self.kind = STRING
        self.b = False
        self.num = 0.0
        self.text = s^
        self.items = []
        self.keys = []

    def __init__(out self, *, number: Float64):
        self.kind = NUMBER
        self.b = False
        self.num = number
        self.text = String()
        self.items = []
        self.keys = []

    def __init__(out self, *, kind: Int):
        self.kind = kind
        self.b = False
        self.num = 0.0
        self.text = String()
        self.items = []
        self.keys = []

    @staticmethod
    def number(n: Float64) -> Self:
        return Self(number=n)

    @staticmethod
    def object() -> Self:
        return Self(kind=OBJECT)

    @staticmethod
    def array() -> Self:
        return Self(kind=ARRAY)

    def set(mut self, var key: String, var value: JSON):
        """Set a member, replacing an existing key rather than duplicating."""
        var i = 0
        while i < len(self.keys):
            if self.keys[i] == key:
                self.items[i] = ArcPointer(value^)
                return
            i += 1
        self.keys.append(key^)
        self.items.append(ArcPointer(value^))

    def push(mut self, var value: JSON):
        self.items.append(ArcPointer(value^))

    def has(self, key: String) -> Bool:
        for k in self.keys:
            if k == key:
                return True
        return False

    def get(self, key: String) -> ArcPointer[JSON]:
        """A member, or null if absent -- so a chain of gets never needs a
        guard at every step."""
        var i = 0
        while i < len(self.keys):
            if self.keys[i] == key:
                return self.items[i]
            i += 1
        return ArcPointer(JSON())

    def at(self, index: Int) -> ArcPointer[JSON]:
        if index < 0 or index >= len(self.items):
            return ArcPointer(JSON())
        return self.items[index]

    def count(self) -> Int:
        return len(self.items)

    def as_string(self) -> String:
        return self.text if self.kind == STRING else String()

    def as_int(self) -> Int:
        return Int(self.num) if self.kind == NUMBER else 0

    def as_bool(self) -> Bool:
        return self.b if self.kind == BOOL else False

    def is_null(self) -> Bool:
        return self.kind == NULL

    def serialize(self) -> String:
        var out = String()
        _write(self, out)
        return out^


def _ch(code: Int) -> String:
    return String(Codepoint(unsafe_unchecked_codepoint=UInt32(code)))


def _write_string(s: String, mut out: String):
    """A JSON string literal.

    Only what the grammar requires is escaped. Non-ASCII goes out as UTF-8
    rather than \\u escapes: the transport is bytes with a Content-Length and
    every LSP implementation reads UTF-8.
    """
    comptime HEX = "0123456789abcdef"
    out += _ch(0x22)
    for c in s.codepoints():
        let n = Int(c)
        if n == 0x22:
            out += "\\" + _ch(0x22)
        elif n == 0x5C:
            out += "\\\\"
        elif n == 0x0A:
            out += "\\n"
        elif n == 0x0D:
            out += "\\r"
        elif n == 0x09:
            out += "\\t"
        elif n < 0x20:
            # Control characters have no literal form in JSON.
            out += "\\u00"
            out += HEX[byte = (n >> 4) : (n >> 4) + 1]
            out += HEX[byte = (n & 15) : (n & 15) + 1]
        else:
            out += String(c)
    out += _ch(0x22)


def _write(v: JSON, mut out: String):
    if v.kind == NULL:
        out += "null"
    elif v.kind == BOOL:
        out += "true" if v.b else "false"
    elif v.kind == NUMBER:
        # Whole numbers lose the decimal point: LSP counts lines and characters,
        # and 3.0 where 3 is meant reads as a mistake.
        let i = Int(v.num)
        if Float64(i) == v.num:
            out += String(i)
        else:
            out += String(v.num)
    elif v.kind == STRING:
        _write_string(v.text, out)
    elif v.kind == ARRAY:
        out += "["
        var first = True
        for it in v.items:
            if not first:
                out += ","
            first = False
            _write(it[], out)
        out += "]"
    else:
        out += "{"
        var i = 0
        while i < len(v.keys):
            if i > 0:
                out += ","
            _write_string(v.keys[i], out)
            out += ":"
            _write(v.items[i][], out)
            i += 1
        out += "}"


struct _Parser(Movable):
    var src: String
    var at: Int
    var failed: Bool

    def __init__(out self, var src: String):
        self.src = src^
        self.at = 0
        self.failed = False

    def peek(self) -> Int:
        if self.at >= self.src.byte_length():
            return -1
        return Int(self.src.as_bytes()[self.at])

    def skip_space(mut self):
        while True:
            let c = self.peek()
            if c == 32 or c == 9 or c == 10 or c == 13:
                self.at += 1
            else:
                return

    def expect(mut self, byte: Int) -> Bool:
        if self.peek() != byte:
            self.failed = True
            return False
        self.at += 1
        return True


def parse(var text: String) -> JSON:
    """Parse a document. Malformed input yields null rather than raising: the
    caller checks the shape it wanted anyway, and a server sending nonsense
    should not take the editor down with it."""
    var p = _Parser(text^)
    var v = _parse_value(p)
    return v^


def _parse_value(mut p: _Parser) -> JSON:
    p.skip_space()
    let c = p.peek()
    if c == 0x7B:
        return _parse_object(p)
    if c == 0x5B:
        return _parse_array(p)
    if c == 0x22:
        return JSON(_parse_string(p))
    if c == 0x74:
        p.at += 4
        return JSON(True)
    if c == 0x66:
        p.at += 5
        return JSON(False)
    if c == 0x6E:
        p.at += 4
        return JSON()
    if c == 0x2D or (c >= 0x30 and c <= 0x39):
        return JSON.number(_parse_number(p))
    p.failed = True
    return JSON()


def _parse_object(mut p: _Parser) -> JSON:
    var v = JSON.object()
    _ = p.expect(0x7B)
    p.skip_space()
    if p.peek() == 0x7D:
        p.at += 1
        return v^
    while not p.failed:
        p.skip_space()
        var key = _parse_string(p)
        p.skip_space()
        if not p.expect(0x3A):
            break
        var val = _parse_value(p)
        v.set(key^, val^)
        p.skip_space()
        if p.peek() == 0x2C:
            p.at += 1
            continue
        _ = p.expect(0x7D)
        break
    return v^


def _parse_array(mut p: _Parser) -> JSON:
    var v = JSON.array()
    _ = p.expect(0x5B)
    p.skip_space()
    if p.peek() == 0x5D:
        p.at += 1
        return v^
    while not p.failed:
        var item = _parse_value(p)
        v.push(item^)
        p.skip_space()
        if p.peek() == 0x2C:
            p.at += 1
            continue
        _ = p.expect(0x5D)
        break
    return v^


def _parse_string(mut p: _Parser) -> String:
    var out = String()
    if not p.expect(0x22):
        return out^
    while True:
        let c = p.peek()
        if c < 0:
            p.failed = True
            return out^
        if c == 0x22:
            p.at += 1
            return out^
        if c == 0x5C:
            p.at += 1
            let e = p.peek()
            p.at += 1
            if e == 0x6E:
                out += _ch(10)
            elif e == 0x74:
                out += _ch(9)
            elif e == 0x72:
                out += _ch(13)
            elif e == 0x62:
                out += _ch(8)
            elif e == 0x66:
                out += _ch(12)
            elif e == 0x75:
                var code = 0
                for _ in range(4):
                    code = code * 16 + _hex(p.peek())
                    p.at += 1
                # A surrogate pair is two escapes and one character. Servers
                # send them for anything outside the BMP, emoji included.
                if code >= 0xD800 and code <= 0xDBFF and p.peek() == 0x5C:
                    p.at += 2
                    var lo = 0
                    for _ in range(4):
                        lo = lo * 16 + _hex(p.peek())
                        p.at += 1
                    code = 0x10000 + ((code - 0xD800) << 10) + (lo - 0xDC00)
                out += _ch(code)
            else:
                # Any other escape stands for itself, "/" among them.
                out += _ch(e)
            continue
        # An ordinary character. Copy the whole UTF-8 sequence, not one byte:
        # the lead byte says how long it is, and slicing through the middle of
        # one is rejected -- rightly -- as not a codepoint boundary.
        var width = 1
        if c >= 0xF0:
            width = 4
        elif c >= 0xE0:
            width = 3
        elif c >= 0xC0:
            width = 2
        let stop = min(p.at + width, p.src.byte_length())
        out += p.src[byte = p.at : stop]
        p.at = stop


def _hex(c: Int) -> Int:
    if c >= 0x30 and c <= 0x39:
        return c - 0x30
    if c >= 0x61 and c <= 0x66:
        return c - 0x61 + 10
    if c >= 0x41 and c <= 0x46:
        return c - 0x41 + 10
    return 0


def _parse_number(mut p: _Parser) -> Float64:
    """Accumulate the value digit by digit.

    The obvious version -- slice the token and convert -- returned zero for
    every number, and silently, because the conversion sits inside a try that
    was written to keep malformed input from raising. Reading the digits
    directly has no failure to swallow and no slice of a struct field to get
    wrong, which is worth more here than brevity.
    """
    var negative = False
    if p.peek() == 0x2D:
        negative = True
        p.at += 1

    var value = 0.0
    while True:
        let c = p.peek()
        if c < 0x30 or c > 0x39:
            break
        value = value * 10.0 + Float64(c - 0x30)
        p.at += 1

    if p.peek() == 0x2E:  # fraction
        p.at += 1
        var scale = 0.1
        while True:
            let c = p.peek()
            if c < 0x30 or c > 0x39:
                break
            value += Float64(c - 0x30) * scale
            scale *= 0.1
            p.at += 1

    let e = p.peek()
    if e == 0x65 or e == 0x45:  # exponent
        p.at += 1
        var neg_exp = False
        if p.peek() == 0x2D:
            neg_exp = True
            p.at += 1
        elif p.peek() == 0x2B:
            p.at += 1
        var exp = 0
        while True:
            let c = p.peek()
            if c < 0x30 or c > 0x39:
                break
            exp = exp * 10 + (c - 0x30)
            p.at += 1
        var factor = 1.0
        for _ in range(exp):
            factor *= 10.0
        if neg_exp:
            value /= factor
        else:
            value *= factor

    return -value if negative else value
