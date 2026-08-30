#!/usr/bin/env python3
"""Ask the language server to complete at one position and print the labels.

    tools/lsp-probe/complete.py <lsp-binary> <file.mojo> <line> <character>

Line and character are zero-based, as LSP counts them. Used by check-dist.sh to
verify Cocoa completion, and useful on its own when a completion is missing and
the question is whether the server or the editor is at fault.
"""
import json, os, subprocess, sys

if len(sys.argv) != 5:
    sys.exit(__doc__)
exe, doc, line, char = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
text = open(doc).read()
uri = "file://" + os.path.abspath(doc)

def frame(m):
    b = json.dumps(m).encode()
    return b"Content-Length: %d\r\n\r\n" % len(b) + b

stdin = b"".join([
    frame({"jsonrpc": "2.0", "id": 1, "method": "initialize",
           "params": {"processId": None, "rootUri": None, "capabilities": {}}}),
    frame({"jsonrpc": "2.0", "method": "initialized", "params": {}}),
    frame({"jsonrpc": "2.0", "method": "textDocument/didOpen",
           "params": {"textDocument": {"uri": uri, "languageId": "mojo",
                                       "version": 1, "text": text}}}),
    frame({"jsonrpc": "2.0", "id": 2, "method": "textDocument/completion",
           "params": {"textDocument": {"uri": uri},
                      "position": {"line": line, "character": char}}}),
    frame({"jsonrpc": "2.0", "id": 3, "method": "shutdown", "params": None}),
])

proc = subprocess.run([exe], input=stdin, capture_output=True, timeout=180)
raw = proc.stdout.decode(errors="replace")

# Responses arrive framed and interleaved with notifications; find id 2.
for chunk in raw.split("Content-Length: "):
    if '"id":2' not in chunk:
        continue
    body = chunk[chunk.index("{"):]
    try:
        result = json.loads(body[:body.rindex("}") + 1])
    except ValueError:
        continue
    for item in result.get("result", {}).get("items", []):
        print(f"{item.get('label','')}\t{item.get('detail','') or ''}")
    sys.exit(0)

sys.stderr.write(proc.stderr.decode(errors="replace")[:600])
sys.exit(1)
