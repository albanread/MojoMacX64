# Patches to the standard library

Every change this fork makes to Modular's standard library, so that a future
sync knows what to carry forward and why. A patch that only exists as a diff
is a patch someone re-applies blindly or drops silently.

**Write an entry when you change anything under `mojo/stdlib/`.** Say what
was wrong, not just what changed — the reasoning is the part a merge conflict
destroys.

The staged copies are downstream of this tree and are not edited by hand:

    mojo/stdlib/std/…                      the source of truth
    dist/CocoaMojo/lib/mojo/stdlib/…       staged by tools/make-dist.sh
    ~/Library/Application Support/Roast/…  the editable copy Roast installs

Changing one of the copies and not this tree means the next `make-dist.sh`
throws the change away.

---

## 2026-08-30 — `String._realloc_mutable` asked the allocator for zero bytes

**File:** `std/collections/string/string.mojo`

**Symptom.** A trap with a message that names the wrong culprit:

    alloc: `Layout.count()` must be > 0

**Cause.** The growth arithmetic was

```mojo
var new_capacity = (max(capacity, self.capacity_bytes() * 2) + 7) >> 3
var new_ptr = self._alloc(new_capacity << 3)
```

An empty inline `String` has `capacity_bytes() == 0`, so growing one by
nothing computes `(0 + 7) >> 3 == 0` and asks `alloc` for a zero-sized
layout. The allocator refuses — correctly — but the message describes the
allocator rather than the `String` that asked it for nothing.

**Patch.** Two changes, and deliberately not one:

- `new_capacity` is clamped to at least one unit, so the benign zero case
  allocates the smallest thing worth owning instead of trapping.
- A capacity that cannot hold the live length still aborts, now with a
  message that says the caller passed something that is not a size.

The second half is why this is not a blind clamp. Clamping a bad size would
allocate something small and then `memcpy` the old length into it, turning a
loud trap into silent heap corruption. A benign zero deserves a buffer; a
nonsense size deserves an abort that names itself.

**Carry forward:** yes. Neither half depends on anything else in this fork.

---

## Prior stdlib work, from the history

Most changes under `mojo/stdlib/` in this fork are not bug patches against
Modular's code — they are this fork's own surface (`std.objc`, `class`
support, the Cocoa database bridge) which happens to live in the stdlib tree.
They are listed here so an entry is never mistaken for a missing one, and
they are indexed rather than described: their reasoning is in the commits.

| Commit | What it is |
|---|---|
| `d3ce7c8a` | `std.objc.typed`: calling Cocoa as calls |
| `9c606281`, `1ffa4ce8` | `box_ref`: reaching a class's fields; nil as a state |
| `8666a03a`, `5d599de4`, `1e1217a0` | a returned class parameterises a type; the SDK chooses it |
| `bc422335`, `43121d47`, `ec26184f`, `ef6a68a6` | class fields live in the box |
| `fc991d41`, `3dfe3e02` | `class B(A)`; `@staticmethod` |
| `320832b2` | struct returns, and the IDE becomes entirely `class` |
| `e22ab603` | every `msg_send` in the IDE becomes a call |
| `5390d3b3` | fix-list entries 1–5, 7, 9 |
| `e8dd6790` | the stdlib README's fork notice |

This table was seeded from `git log -- mojo/stdlib` and is an index, not an
audit: nobody has gone back through those commits to separate a fix to
Modular's code from an addition of our own. If you touch one of them, write
it a proper entry above and delete its row here.
