#!/usr/bin/env python3
"""Drive lldb-dap the way the IDE will: does a breakpoint bind, does the
program stop on it, and does the stopped frame answer with named Mojo locals.

A STAND-IN, and it should be deleted when its replacement arrives. The sister
fork checks this with `ide/dap_test.mojo` driven from `tools/check-ide.sh`, and
that is the version to have -- but it is written in the IDE, which is the next
arc and not yet ported. Rather than port the IDE early to get a test, or leave
the debugger with no acceptance at all, this drives the same protocol from
Python. When the IDE lands, prefer theirs and remove this.

It earned its place immediately: it is what showed that the tcmalloc abort on
`quit` is confined to the lldb CLI and does not touch the DAP path, which is
the only reason the allocator was left alone (see DEBUGGER_SPRINT.md).

Sequencing is the whole difficulty, and getting it wrong looks exactly like a
broken debugger: lldb-dap only accepts breakpoints after it has answered
`initialize` AND emitted the `initialized` event, which it does in response to
`launch`. Send setBreakpoints before that and it verifies nothing, binds
nothing, and never stops -- with no error anywhere.

  ./dap-probe.py <lldb-dap> <program> <source.mojo> <line> <libMojoLLDB.dylib>
"""
import json, subprocess, sys, os, threading, queue

dap, prog, src, line, plugin = sys.argv[1:6]
p = subprocess.Popen([dap], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.PIPE, cwd=os.path.dirname(os.path.abspath(prog)))
q, seq = queue.Queue(), [0]

def reader():
    while True:
        hdr = b""
        while b"\r\n\r\n" not in hdr:
            c = p.stdout.read(1)
            if not c: q.put(None); return
            hdr += c
        n = int([l for l in hdr.decode().split("\r\n")
                 if l.lower().startswith("content-length")][0].split(":")[1])
        q.put(json.loads(p.stdout.read(n)))
threading.Thread(target=reader, daemon=True).start()

def send(cmd, **args):
    seq[0] += 1
    body = json.dumps({"seq": seq[0], "type": "request", "command": cmd, "arguments": args})
    p.stdin.write(f"Content-Length: {len(body)}\r\n\r\n{body}".encode()); p.stdin.flush()
    return seq[0]

def wait_for(pred, timeout=90):
    import time; end = time.time() + timeout
    while time.time() < end:
        try: m = q.get(timeout=max(0.1, end - time.time()))
        except Exception: return None
        if m is None: return None
        if pred(m): return m
    return None

send("initialize", adapterID="lldb-dap", linesStartAt1=True, columnsStartAt1=True,
     pathFormat="path", supportsConfigurationDoneRequest=True)
wait_for(lambda m: m.get("type")=="response" and m.get("command")=="initialize")
send("launch", program=os.path.abspath(prog), stopOnEntry=False,
     initCommands=[f"plugin load {plugin}"])
wait_for(lambda m: m.get("type")=="event" and m.get("event")=="initialized", timeout=60)
s = send("setBreakpoints", source={"path": os.path.abspath(src), "name": os.path.basename(src)},
         breakpoints=[{"line": int(line)}], lines=[int(line)])
r = wait_for(lambda m: m.get("request_seq")==s)
bps = (r or {}).get("body", {}).get("breakpoints", [])
bound = bool(bps) and bps[0].get("verified", False)
send("configurationDone")
ev = wait_for(lambda m: m.get("type")=="event" and m.get("event")=="stopped", timeout=90)
tid = (ev or {}).get("body", {}).get("threadId")

locals_seen = []
if tid is not None:
    s = send("stackTrace", threadId=tid)
    r = wait_for(lambda m: m.get("request_seq")==s)
    fr = (r or {}).get("body", {}).get("stackFrames", [])
    if fr:
        s = send("scopes", frameId=fr[0]["id"])
        r = wait_for(lambda m: m.get("request_seq")==s)
        for sc in (r or {}).get("body", {}).get("scopes", []):
            s = send("variables", variablesReference=sc["variablesReference"])
            r = wait_for(lambda m: m.get("request_seq")==s)
            locals_seen += [(v["name"], v.get("value","")) for v in (r or {}).get("body",{}).get("variables",[])]
            if locals_seen: break

print(f"  breakpoint verified : {bound}")
print(f"  stopped at bp       : {tid is not None}")
print(f"  locals              : {locals_seen}")
send("disconnect", terminateDebuggee=True)
try: p.stdin.close()
except Exception: pass
try:
    rc = p.wait(timeout=30); print(f"  lldb-dap exit code  : {rc}")
except Exception:
    p.kill(); print(f"  lldb-dap exit code  : DID NOT EXIT (killed)")
err = b""
try: err = p.stderr.read()
except Exception: pass
print("  tcmalloc abort      : " + ("YES" if b"invalid pointer" in err else "no"))
