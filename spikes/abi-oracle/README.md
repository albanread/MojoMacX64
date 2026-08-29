# The ABI oracle — clang on the other side

Every other Cocoa test in this tree has Mojo at both ends, and proves only that
we agree with ourselves. This one puts the compiler that built AppKit on the
far side, so whatever it does with a struct by value *is* the ABI.

Ported in shape from the sister fork; the **cases are ours**, because the
x86-64 System V cases differ from AAPCS64 in kind, not in register names:

| | AAPCS64 (their port) | x86-64 System V (here) |
|---|---|---|
| struct > 16B argument | caller-owned copy behind a pointer | passed **on the stack** |
| struct > 16B return | hidden `x8` register, same entry point | **`objc_msgSend_stret`** — a different function |
| `long double` return | n/a | **`objc_msgSend_fpret`** — a different function |

The last two are why this exists. A binding correct on Apple silicon can be
silently wrong here, because the arm64 path never has to *choose* an entry
point.

## Build and run

```bash
clang -dynamiclib -fobjc-arc -o /tmp/libabioracle.dylib \
    spikes/abi-oracle/abi_oracle.m -framework Foundation -framework AppKit
vega-sdk/bin/mojo build -o /tmp/abio spikes/abi-oracle/abi_oracle_test.mojo
/tmp/abio
```

The Mojo binary links nothing from the dylib. `dlopen` registers the class with
the Objective-C runtime and Mojo finds it by name — so the test exercises the
real dynamic path rather than a link-time shortcut.

The oracle's methods are named after **real SDK selectors** chosen for their
ABI shapes (`setFrameSize:` NSSize/16B, `setFrame:` NSRect/32B, `frame` NSRect
return). Our bindings verify every selector against `cocoa.sqlite`, so an
invented name would not resolve — this is a constraint worth knowing before
writing any such test.

## Status

**Direction A — Mojo sends, clang receives.** PASS.

| case | shape | result |
|---|---|---|
| `setFrameSize:` | 16B struct arg, SSE registers | 31.0 ✓ |
| `setFrame:` | 32B struct arg, MEMORY/stack | 12.0 ✓ |
| `frame` | 32B struct **return** | **skipped** |

The database independently agrees with clang on the entry point: it answers
`objc_msgSend_stret` for `frame` and plain `objc_msgSend` for the setters,
and clang's own dylib references exactly those two symbols.

The struct return is **refused at compile time**, by design —
`runtime.mojo:116` defers the sret slot to P2.1. That refusal is correct
behaviour and much better than the silent stack corruption the alternative
would be, but it means **no NSRect-returning API is reachable today**
(`frame`, `bounds`, `visibleRect`, …). P2.1 is therefore on phase 1's critical
path, not a nicety: a `class` method returning a struct needs the same slot on
the receiving side.

**Direction B — clang sends, Mojo receives.** Not yet. The `poke_*` functions
in the `.m` are written and waiting; they target a class registered *from
Mojo*, which is what phase 1's trampolines add. When they pass, the receiving
half of the ABI is verified by the only authority that counts.
