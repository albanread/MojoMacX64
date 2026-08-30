# JSON tests. The language server is on the other end of this, so the cases
# that matter are the ones a real server sends: nested objects, arrays of
# objects, escapes, non-ASCII, and numbers that must not grow a decimal point.
from json import JSON, parse


def check(name: String, got: String, want: String) -> Int:
    if got == want:
        print("  OK  ", name)
        return 0
    print("  FAIL", name, "-- got", repr(got), "want", repr(want))
    return 1


def check_int(name: String, got: Int, want: Int) -> Int:
    if got == want:
        print("  OK  ", name, "=", got)
        return 0
    print("  FAIL", name, "-- got", got, "want", want)
    return 1


def main() raises:
    var failures = 0

    print("json: writing")
    var o = JSON.object()
    o.set(String("jsonrpc"), JSON(String("2.0")))
    o.set(String("id"), JSON(1))
    failures += check(
        "object", o.serialize(), String('{"jsonrpc":"2.0","id":1}')
    )

    # Whole numbers must not gain a decimal point: LSP counts lines and
    # characters, and a server reading 3.0 where 3 was meant is a bug report.
    var n = JSON.object()
    n.set(String("line"), JSON(3))
    failures += check("integer stays integral", n.serialize(), String('{"line":3}'))

    var arr = JSON.array()
    arr.push(JSON(1))
    arr.push(JSON(String("two")))
    arr.push(JSON(True))
    failures += check("array", arr.serialize(), String('[1,"two",true]'))

    var esc = JSON.object()
    esc.set(String("k"), JSON(String("a\"b\\c\nd")))
    failures += check(
        "escapes", esc.serialize(), String('{"k":"a\\"b\\\\c\\nd"}')
    )

    var uni = JSON(String("héllo 日本"))
    failures += check("utf-8 passes through", uni.serialize(), String('"héllo 日本"'))

    print("json: replacing a key does not duplicate it")
    var dup = JSON.object()
    dup.set(String("a"), JSON(1))
    dup.set(String("a"), JSON(2))
    failures += check("replaced", dup.serialize(), String('{"a":2}'))

    print("json: reading")
    let doc = parse(
        String(
            '{"jsonrpc":"2.0","id":7,"result":{"capabilities":'
            '{"hoverProvider":true,"completionProvider":{"triggerCharacters":'
            '["."]}}}}'
        )
    )
    failures += check("version", doc.get("jsonrpc")[].as_string(), String("2.0"))
    failures += check_int("id", doc.get("id")[].as_int(), 7)
    failures += check_int(
        "nested bool",
        Int(doc.get("result")[].get("capabilities")[].get("hoverProvider")[].as_bool()),
        1,
    )
    failures += check(
        "trigger character",
        doc.get("result")[]
        .get("capabilities")[]
        .get("completionProvider")[]
        .get("triggerCharacters")[]
        .at(0)[]
        .as_string(),
        String("."),
    )

    print("json: a missing key is null, not a crash")
    failures += check_int("absent", Int(doc.get("nope")[].is_null()), 1)
    failures += check_int(
        "absent chains", Int(doc.get("nope")[].get("deeper")[].is_null()), 1
    )
    failures += check_int("index out of range", Int(doc.at(99)[].is_null()), 1)

    print("json: escapes and unicode come back")
    let esc2 = parse(String('{"s":"a\\"b\\\\c\\nd\\tE"}'))
    failures += check(
        "unescaped", esc2.get("s")[].as_string(), String("a\"b\\c\nd\tE")
    )
    let u = parse(String('{"s":"caf\\u00e9 \\u65e5"}'))
    failures += check("\\u escape", u.get("s")[].as_string(), String("café 日"))
    # Outside the BMP arrives as a surrogate pair.
    let emoji = parse(String('{"s":"\\ud83d\\ude80"}'))
    failures += check("surrogate pair", emoji.get("s")[].as_string(), String("🚀"))

    print("json: round trip")
    let original = String(
        '{"a":[1,2,{"b":"x"}],"c":{"d":null,"e":false},"f":"héllo"}'
    )
    failures += check("round trip", parse(original).serialize(), original)

    print("json: a real diagnostic notification")
    let diag = parse(
        String(
            '{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics",'
            '"params":{"uri":"file:///t.mojo","diagnostics":[{"range":'
            '{"start":{"line":2,"character":4},"end":{"line":2,"character":9}},'
            '"severity":1,"message":"use of unknown declaration"}]}}'
        )
    )
    failures += check(
        "method", diag.get("method")[].as_string(),
        String("textDocument/publishDiagnostics"),
    )
    let list = diag.get("params")[].get("diagnostics")[]
    failures += check_int("one diagnostic", list.count(), 1)
    let d0 = list.at(0)[]
    failures += check_int("severity", d0.get("severity")[].as_int(), 1)
    failures += check_int(
        "start line", d0.get("range")[].get("start")[].get("line")[].as_int(), 2
    )
    failures += check(
        "message", d0.get("message")[].as_string(),
        String("use of unknown declaration"),
    )

    print("json: malformed input yields null rather than raising")
    # A truncated object keeps whatever it managed to read; what matters is
    # that parsing returns rather than crashing.
    failures += check_int(
        "truncated returns", Int(parse(String("{\"a\":")).count() >= 0), 1
    )
    failures += check_int("garbage", Int(parse(String("<html>")).is_null()), 1)
    failures += check_int("empty", Int(parse(String("")).is_null()), 1)

    print()
    if failures == 0:
        print("json OK")
    else:
        print("json FAILED:", failures)
        raise Error("json tests failed")
