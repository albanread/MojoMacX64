# GCD through the revived fn: the _f path, and real blocks built over fn.
from std.ffi import external_call
from std.memory import OpaquePointer
from std.objc.classes import named_global
from std.objc.dispatch import (
    Semaphore,
    async_f,
    global_queue,
    sync_f,
    with_block,
)

comptime P = OpaquePointer[MutUntrackedOrigin]


fn add_and_signal(ctx: P) -> None:
    # ctx is the semaphore; the counter is app state reached the Cocoa way
    # (named_global), since an fn has no closure.
    var n = named_global["disp.count", Int]()
    n[] = n[] + 1
    _ = external_call["dispatch_semaphore_signal", Int](ctx)


fn set_flag_sync(ctx: P) -> None:
    named_global["disp.sync_flag", Int]()[] = 42


fn block_work() -> None:
    var n = named_global["disp.block_count", Int]()
    n[] = n[] + 1


def main() raises:
    var q = global_queue()

    # 1. dispatch_sync_f: runs before returning.
    # Context unused by set_flag_sync; Pointer is non-nullable, so hand it a
    # real (arbitrary) address rather than null.
    sync_f(q, P(unsafe_from_address=Int(named_global["disp.sync_flag", Int]())), set_flag_sync)
    if named_global["disp.sync_flag", Int]()[] != 42:
        raise Error("FAIL: sync_f did not run")

    # 2. dispatch_async_f x3, rendezvous through a semaphore.
    var sem = Semaphore()
    var ctx = P(unsafe_from_address=sem._sem)
    async_f(q, ctx, add_and_signal)
    async_f(q, ctx, add_and_signal)
    async_f(q, ctx, add_and_signal)
    sem.wait()
    sem.wait()
    sem.wait()
    if named_global["disp.count", Int]()[] != 3:
        raise Error("FAIL: async_f count wrong")

    # 3. A real ObjC block over fn: sync (no copy) ...
    with_block[block_work](q, wait=True)
    if named_global["disp.block_count", Int]()[] != 1:
        raise Error("FAIL: sync block did not run")

    # 4. ... and async (Block_copy path: 32-byte literal copied off our
    # frame, immortal shared descriptor read at release).
    with_block[block_work](q, wait=False)
    var deadline = external_call["dispatch_time", Int](Int(0), Int(2_000_000_000))
    var spin = 0
    while named_global["disp.block_count", Int]()[] < 2 and spin < 2000:
        _ = external_call["usleep", Int](Int(1000))
        spin += 1
    if named_global["disp.block_count", Int]()[] != 2:
        raise Error("FAIL: async block did not run (Block_copy path)")
    _ = deadline
    print("DISPATCH: PASS")
