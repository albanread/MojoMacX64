# Cocoa on MacVegaFork — the database-backed compiler design

How this fork makes Mojo *great* at Cocoa on the 2019 Intel Mac Pro: the
compiler reads `cocoa.sqlite` during elaboration, so bindings state a **name**
and the compiler supplies — and *checks* — everything else: struct layouts,
enum values, selector existence, type encodings, and (the x86-64 crown jewel)
**which `objc_msgSend` variant each call must go through**.

Expands PORT_DESIGN.md §10 into the buildable design. The mechanism is the
sister port's `winkb` (proven on Windows x64), re-aimed at a richer database.

## 1. The assets

### 1.1 The database (regenerated for x86-64)

[`CocoaBaseMCP`](https://github.com/albanread/CocoaBaseMCP) maintains
`cocoa.sqlite`, ingested from the **live** runtime/SDK on this machine.
Verified contents as of today:

| table | rows | what it answers |
|---|---|---|
| `rt_classes` | 24,125 | every class + superclass (inheritance chain) |
| `rt_methods` | 422,683 | every selector, verbatim `@encode` signature |
| `method_abi_x64` | 422,683 | **per-method SysV classification + `msgsend` variant** |
| `structs` / `struct_fields` | 2,355 | name, size, align, per-field offsets (x86-64) |
| `bs_enums` / `bs_constants` | — | enum values; extern-symbol constants + types |
| `posix_functions` / `posix_function_abi_x64` | 299 | libc signatures + SysV classes |

Spot-checked x86-64 truth: `CGRect` = 32/8 with `origin@0`, `size@16`;
`NSString.length` = `Q16@0:8`; real `objc_msgSend_stret` rows exist (SysV
MEMORY returns — a class that **does not exist on arm64** and that upstream
Mojo therefore has no concept of).

The ABI token vocabulary (`v g f gg gf fg ff x s m ?`) is documented in
`abi_sysv.py` and is the contract between the database and any caller.

### 1.2 The mechanism (proven in the sister port)

One generic comptime param-expr, evaluated during elaboration:

```
#kgen.param.expr<cocoakb_query, "<query>", "<arg>"...> : index | string
```

The compiler owns a **query table** (name → SQL); Mojo wrappers pass query
names, never SQL. Adding a capability = one row in that table. Failures are
**compile errors at the asking source location** — a name the database does
not know can never become a wrong answer (the sister port's origin story:
34 of 35 hand-transcribed constants right; the 35th cost hours).

## 2. Design decisions

**D1 — system sqlite, no new deps.** `sqlite3.h` + `libsqlite3.tbd` ship in
the pinned MacOSX26.sdk. The Elaborator links `-lsqlite3`. (The sister port
carried a bazel archive; this fork is one machine, and the SDK is pinned.)

**D2 — path resolution.** `MODULAR_MOJO_MAX_COCOAKB_PATH` env override, else
config default `lib/cocoa.sqlite` next to the toolchain; `vega-sdk/bin/mojo`
sets the env to `/Volumes/S/CocoaBaseMCP/cocoa.sqlite`. Opened read-only,
once per process, mutex-guarded; **never created if missing** — a missing
database is a configuration error, not an empty one that answers wrongly.

**D3 — inheritance is resolved in SQL, not in Mojo.** The runtime ingest
records methods on the class that *defines* them. Lookups walk the
superclass chain with a recursive CTE over `rt_classes` (verified:
`NSMutableString / length` resolves to `NSString`, `objc_msgSend`). Mojo
asks about the class it has; the database answers from wherever the method
actually lives. Category/inherited resolution is a *query*, not codegen.

**D4 — the `?` rows are compile errors.** `method_abi_x64.msgsend = '?'`
means the encoding was unmodelable. A call through such a method fails to
compile with the reason, rather than guessing an ABI.

**D5 — reproducibility pin.** `cocoakb_query<"db_hash">` returns the SHA-256
of the database file (lazily computed, cached), so a binary can record which
metadata revision it was built against.

**D6 — enum values read signed-first.** `CAST(value AS INTEGER)` from
`bs_enums` (BridgeSupport `value64`). Extern-symbol constants
(`NSFontAttributeName`…) are **runtime addresses, not comptime values** —
for those the database supplies the *type* (`constant_type`), and the
binding dlsyms at runtime. The two kinds are not conflated.

## 3. The query table (phase 1)

| query | args | source | returns |
|---|---|---|---|
| `db_hash` | — | file | string |
| `struct_size` / `struct_align` | name | `structs` | index |
| `field_offset` | struct, field | `struct_fields` | index |
| `enum_value` | name | `bs_enums` | index |
| `constant_type` | name | `bs_constants` | string (type64) |
| `superclass` | class | `rt_classes` | string |
| `method_encoding` | class, sel, kind | CTE→`rt_methods` | string |
| `msgsend_variant` | class, sel, kind | CTE→`method_abi_x64` | string |
| `method_ret_class` / `method_arg_classes` | class, sel, kind | CTE→`method_abi_x64` | string |
| `posix_sig` | name | `posix_functions` | string (qualtype) |
| `posix_ret_class` / `posix_arg_classes` | name | `posix_function_abi_x64` | string |

(`kind` = `"0"` instance / `"1"` class method; CAST in SQL.)

## 4. The Mojo programming model

### 4.1 Layer 1 — `std/sys/_cocoakb.mojo` (raw, phase 1)

Mirrors `_winkb.mojo`: one comptime function per query, `StaticString`
parameters, `Int`/`StaticString` results. Immediately usable for **checked
declarations**:

```mojo
struct NSRect:
    var origin: CGPoint
    var size: CGSize

comptime assert size_of[NSRect]() == cocoakb_struct_size["CGRect"]()
comptime assert offset_of[NSRect, "size"]() == cocoakb_field_offset["CGRect", "size"]()
```

A struct that drifts from the SDK **fails to build**.

### 4.2 Layer 2 — `std/objc` (the dispatch model, phase 2)

The x86-64-specific value: on arm64 every send is `objc_msgSend`; on x86-64
a MEMORY-class return **must** go through `objc_msgSend_stret` (hidden
buffer pointer in `rdi`, `self` shifted to `rsi`) and `long double` through
`_fpret` — get it wrong and the stack corrupts silently. No human should
pick the stub; the database + `comptime if` does:

```mojo
def msg_send[
    R: AnyType, cls: StaticString, sel: StaticString, *Ts: AnyType
](obj: ObjCPtr, args: *Ts) -> R:
    comptime variant = cocoakb_msgsend_variant[cls, sel, "0"]()  # compile error if unknown selector
    comptime if variant == "objc_msgSend_stret":
        # external_call["objc_msgSend_stret"] with sret slot
    comptime elif variant == "objc_msgSend_fpret":
        ...
    comptime else:
        # plain objc_msgSend, cast to fn type
```

- **Selector typos are compile errors** (the query fails).
- Selector registration (`sel_registerName`) happens at runtime, cached in a
  per-selector global; class lookup (`objc_getClass`) likewise.
- Encoding verification (phase 4): comptime-parse `method_encoding` and
  check it against `@encode`-of-`R`/`Ts` computed from Mojo types — argument
  type mismatches become compile errors too.

### 4.3 Layer 3 — memory management (phase 3)

`ObjCRef`: owning wrapper; `__copyinit__` retains, `__del__` releases, move
transfers. `autoreleasepool()` context manager over
`objc_autoreleasePoolPush/Pop`. Convention-aware constructors (`alloc/init`
chains return +1; `new`… returns +1; everything else autoreleased) —
encoded once in `ObjCRef.adopt`/`ObjCRef.borrow`, not at every call site.
Weak refs via `objc_loadWeak` deferred until needed. **No-leak is the
default**: you must opt *out* of ownership, not into it.

### 4.4 The POSIX layer

Same database, same discipline: `posix_sig` documents, `posix_*_class`
checks a hand declaration's ABI expectation, and existing `external_call`
does the call. Phase 1 ships the queries; a `std.posix` sugar layer is
optional later.

## 5. Phases

- **P1 (now):** compiler hook (`cocoakb_query` end to end) + `_cocoakb.mojo`
  + spike `spikes/s5-cocoakb/`: checked CGRect/CGPoint layout, an enum
  value, a msgsend variant (incl. one `_stret` case), a posix sig — all
  resolved at comptime, plus one deliberate failure demonstrating the
  compile-error path.
- **P2:** `std.objc` dispatch — `msg_send` with variant selection; smoke:
  NSString round-trip (UTF8String / length / isEqualToString:) on the host.
- **P3:** ownership (`ObjCRef`, autoreleasepool); smoke: build/tear down
  10⁶ objects under `leaks` with zero growth. Then an AppKit hello-window.
- **P4:** encoding verification (comptime `@encode` parser + Mojo-type
  encoder) — argument-level type checking.

## 6. Risks / notes

- Elaboration is concurrent → the DB handle is mutex-guarded (sister-proven).
- `msg_send` with comptime string dispatch relies on `comptime if` over
  string equality — used elsewhere in the stdlib (`_accelerator_arch()`
  comparisons), so proven in-tree.
- JIT runs must resolve `objc_msgSend*`: libobjc is loaded in every macOS
  process that links Foundation; for `mojo build`, the vega-sdk wrapper
  adds `-lobjc`. Verified in P2's smoke, not assumed.
- The database is rebuildable in ~2 s on this machine (`build.py`) after
  any macOS update; `db_hash` makes drift visible.
