# A small Mojo tokenizer for syntax highlighting.
#
# Deliberately lexical and dependency-free: the LSP's semantic tokens are
# better and arrive in P3, but they need a round trip to another process. This
# runs on every keystroke over one paragraph, so it must be immediate and
# never wrong in a way that flickers.

from std.collections.string.string_span import StringSlice


comptime TOK_PLAIN = 0
comptime TOK_KEYWORD = 1
comptime TOK_STRING = 2
comptime TOK_COMMENT = 3
comptime TOK_NUMBER = 4
comptime TOK_DECORATOR = 5
comptime TOK_TYPE = 6


@fieldwise_init
struct TokenSpan(ImplicitlyCopyable, Movable):
    """A [start, end) byte range of one kind."""

    var start: Int
    var end: Int
    var kind: Int


def _is_ident_byte(c: UInt8) -> Bool:
    return (
        (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
        or (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
        or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
        or c == UInt8(ord("_"))
    )


def _is_digit(c: UInt8) -> Bool:
    return c >= UInt8(ord("0")) and c <= UInt8(ord("9"))


def _keyword_kind(word: String) -> Int:
    """Mojo keywords, plus the builtin type names worth colouring apart."""
    if (
        word == "def"
        or word == "fn"
        or word == "struct"
        or word == "trait"
        or word == "var"
        or word == "comptime"
        or word == "if"
        or word == "elif"
        or word == "else"
        or word == "for"
        or word == "while"
        or word == "in"
        or word == "return"
        or word == "yield"
        or word == "raise"
        or word == "raises"
        or word == "try"
        or word == "except"
        or word == "finally"
        or word == "with"
        or word == "as"
        or word == "import"
        or word == "from"
        or word == "pass"
        or word == "break"
        or word == "continue"
        or word == "and"
        or word == "or"
        or word == "not"
        or word == "is"
        or word == "None"
        or word == "True"
        or word == "False"
        or word == "self"
        or word == "Self"
        or word == "mut"
        or word == "out"
        or word == "deinit"
        or word == "ref"
        or word == "owned"
        or word == "inout"
        or word == "borrowed"
        or word == "alias"
        or word == "assert"
        or word == "print"
    ):
        return TOK_KEYWORD
    if (
        word == "Int"
        or word == "UInt"
        or word == "Float64"
        or word == "Float32"
        or word == "Float16"
        or word == "Bool"
        or word == "String"
        or word == "StaticString"
        or word == "List"
        or word == "Pointer"
        or word == "UnsafePointer"
        or word == "SIMD"
        or word == "DType"
        or word == "Int8"
        or word == "Int16"
        or word == "Int32"
        or word == "Int64"
        or word == "UInt8"
        or word == "UInt16"
        or word == "UInt32"
        or word == "UInt64"
    ):
        return TOK_TYPE
    return TOK_PLAIN


def tokenize(source: StringSlice) -> List[TokenSpan]:
    """Classify `source` into non-overlapping spans. Only non-plain spans are
    returned; the caller paints everything else with the default colour."""
    var spans = List[TokenSpan]()
    var b = source.as_bytes()
    var n = len(b)
    var i = 0

    while i < n:
        var c = b[i]

        # Comment to end of line.
        if c == UInt8(ord("#")):
            var start = i
            while i < n and b[i] != UInt8(ord("\n")):
                i += 1
            spans.append(TokenSpan(start, i, TOK_COMMENT))
            continue

        # String literal, single or double quoted, with escapes. Triple quotes
        # fall out of the same loop because the closing quote of the opening
        # pair immediately ends an empty string, then the third starts a new
        # one -- ugly but stable, and docstrings still read as string-coloured.
        if c == UInt8(ord('"')) or c == UInt8(ord("'")):
            var quote = c
            var start = i
            i += 1
            while i < n:
                if b[i] == UInt8(ord("\\")):
                    i += 2
                    continue
                if b[i] == quote:
                    i += 1
                    break
                if b[i] == UInt8(ord("\n")):
                    break
                i += 1
            spans.append(TokenSpan(start, i, TOK_STRING))
            continue

        # Decorator.
        if c == UInt8(ord("@")):
            var start = i
            i += 1
            while i < n and _is_ident_byte(b[i]):
                i += 1
            spans.append(TokenSpan(start, i, TOK_DECORATOR))
            continue

        # Number (leading digit only: 1, 1.5, 0x1f, 1e9 -- close enough).
        if _is_digit(c):
            var start = i
            while i < n and (
                _is_ident_byte(b[i]) or b[i] == UInt8(ord("."))
            ):
                i += 1
            spans.append(TokenSpan(start, i, TOK_NUMBER))
            continue

        # Identifier or keyword.
        if _is_ident_byte(c):
            var start = i
            while i < n and _is_ident_byte(b[i]):
                i += 1
            var word = String(StringSlice(unsafe_from_utf8=b[start:i]))
            var kind = _keyword_kind(word)
            if kind != TOK_PLAIN:
                spans.append(TokenSpan(start, i, kind))
            continue

        i += 1

    return spans^
