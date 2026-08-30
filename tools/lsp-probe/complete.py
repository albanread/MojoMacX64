#!/usr/bin/env python3
"""Ask the language server to complete at one position and print the labels.

    tools/lsp-probe/complete.py <lsp-binary> <file.mojo> <line> <character>

Line and character are zero-based, as LSP counts them. Used by check-dist.sh to
verify Cocoa completion, and useful on its own when a completion is missing and
the question is whether the server or the editor is at fault.
"""
import json, os, subprocess, sys

if len(sys.argv) < 5:
    sys.exit(__doc__)
# Anything after the four is handed to the server verbatim -- import roots,
# mostly. A server launched bare has no -I, fails the parse with "unable to
# locate module 'std'", and answers every completion with nothing: a missing
# flag that reads exactly like a broken feature.
exe, doc, line, char = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
server_args = sys.argv[5:]
text = open(doc).read()
uri = "file://" + os.path.abspath(doc)

def frame(m):
    b = json.dumps(m).encode()
    return b"Content-Length: %d\r\n\r\n" % len(b) + b


# Driven turn by turn rather than piped in as one blob, and that is not style.
# The server parses didOpen asynchronously and cancels any request that arrives
# against a document still in flight:
#
#     {"error":{"code":-32801,"message":"outdated request"},"id":2}
#
# Piped all at once, the completion always lost that race and came back empty --
# indistinguishable from a server that knows no candidates. So: wait for the
# open to settle (its diagnostics are the signal), then ask.
proc = subprocess.Popen([exe] + server_args, stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def send(m):
    proc.stdin.write(frame(m))
    proc.stdin.flush()


def read_message(timeout=180):
    hdr = b""
    while b"\r\n\r\n" not in hdr:
        c = proc.stdout.read(1)
        if not c:
            return None
        hdr += c
    n = int([l for l in hdr.decode().split("\r\n")
             if l.lower().startswith("content-length")][0].split(":")[1])
    return json.loads(proc.stdout.read(n))


def wait_for(pred, limit=400):
    for _ in range(limit):
        m = read_message()
        if m is None:
            return None
        if pred(m):
            return m
    return None


send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"processId": None, "rootUri": None, "capabilities": {}}})
wait_for(lambda m: m.get("id") == 1)
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": uri, "languageId": "mojo",
                                  "version": 1, "text": text}}})
wait_for(lambda m: m.get("method") == "textDocument/publishDiagnostics"
         and m.get("params", {}).get("uri") == uri)
send({"jsonrpc": "2.0", "id": 2, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": uri},
                 "position": {"line": line, "character": char}}})
reply = wait_for(lambda m: m.get("id") == 2)
proc.kill()

if reply is None:
    sys.stderr.write("no completion reply\n")
    sys.exit(1)
if "error" in reply:
    sys.stderr.write("server error: %s\n" % json.dumps(reply["error"]))
    sys.exit(1)
result = reply.get("result") or {}
items = result.get("items", result if isinstance(result, list) else [])
for item in items:
    print(f"{item.get('label','')}\t{item.get('detail','') or ''}")
