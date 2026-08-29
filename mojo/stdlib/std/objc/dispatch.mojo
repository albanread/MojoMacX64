# ===----------------------------------------------------------------------=== #
# Grand Central Dispatch, for the revived `fn`.
#
# GCD is the concurrency story for a Cocoa app: UI work belongs to the main
# queue, and everything else hops between queues. It is a C API in libSystem
# (nothing to link), and every operation this module needs exists in two
# forms: a block form, and an `_f` form taking a bare C function pointer plus
# a context word.
#
# The `_f` forms are exactly the revived `fn` contract -- thin, non-raising,
# C ABI -- so the core of this module is direct calls with no adaptation
# layer at all. The block story rides on top: a capture-less block is a
# 32-byte literal whose invoke pointer IS an `fn`, built on the stack in
# `_stack_block` and copied by the runtime if the call escapes (dispatch's
# own Block_copy path; with no captures there are no copy/dispose helpers to
# synthesize, the copy is a memmove). That gives block-only Cocoa APIs a
# working path today, with heap blocks for capturing closures deferred to the
# design's later phase.
#
# The main queue is not a function but a GLOBAL (`_dispatch_main_q`; the C
# macro dispatch_get_main_queue() takes its address), referenced here the
# same way the msg_send stubs are.
# ===----------------------------------------------------------------------=== #

from std.ffi import external_call
from .classes import named_global
from std.memory import OpaquePointer, Pointer
from std.collections.string.string_span import _get_kgen_string

comptime _RawPtr = OpaquePointer[MutUntrackedOrigin]
comptime DispatchFn = fn(_RawPtr) -> None
comptime _BlockInvokeFn = fn(_RawPtr) -> None


def _main_queue() -> _RawPtr:
    """&_dispatch_main_q -- the address of the global, as the C macro takes it."""
    return _RawPtr(
        _mlir_value=__mlir_op.`pop.extern_ptr_symbol`[
            name = _get_kgen_string["_dispatch_main_q"](),
            alignment = Int(8).__mlir_index__(),
            _type = _RawPtr._mlir_type,
        ]()
    )


def global_queue() -> _RawPtr:
    """The default-QoS concurrent queue."""
    return external_call["dispatch_get_global_queue", _RawPtr](Int(0), Int(0))


def main_queue() -> _RawPtr:
    return _main_queue()


def async_f(queue: _RawPtr, context: _RawPtr, work: DispatchFn):
    """dispatch_async_f: enqueue `work(context)` on `queue`. The `fn` contract
    is the whole safety story -- no captures to outlive the caller, no Mojo
    error to cross the C boundary."""
    external_call["dispatch_async_f", NoneType](queue, context, work)


def sync_f(queue: _RawPtr, context: _RawPtr, work: DispatchFn):
    """dispatch_sync_f: run `work(context)` on `queue`, returning after it."""
    external_call["dispatch_sync_f", NoneType](queue, context, work)


struct Semaphore(Movable):
    """dispatch_semaphore_t. The test-and-rendezvous primitive of the C API,
    and how a caller waits for async work without a runloop."""

    var _sem: Int

    def __init__(out self, value: Int = 0):
        self._sem = Int(
            external_call["dispatch_semaphore_create", _RawPtr](value)
        )

    def wait(self):
        """Block until signalled (DISPATCH_TIME_FOREVER)."""
        _ = external_call["dispatch_semaphore_wait", Int](
            _RawPtr(unsafe_from_address=self._sem), Int(-1)
        )

    def signal(self):
        _ = external_call["dispatch_semaphore_signal", Int](
            _RawPtr(unsafe_from_address=self._sem)
        )

    def __deinit__(deinit self):
        # dispatch objects are ObjC objects under ARC's rules on modern
        # macOS: release through the objc entry point.
        external_call["objc_release", NoneType](
            _RawPtr(unsafe_from_address=self._sem)
        )


# ── Capture-less blocks over `fn` ────────────────────────────────────────────
#
# Block literal layout (ABI, 32 bytes on arm64/x86-64):
#   +0  isa          -- class pointer; _NSConcreteStackBlock for a stack block
#   +8  flags: i32   -- 0: no copy/dispose helpers, not global, no signature
#   +12 reserved:i32
#   +16 invoke       -- the C function called with the BLOCK as argument 0
#   +24 descriptor   -- pointer to { reserved: u64 = 0, size: u64 = 32 }
#
# Two lifetime facts carry the whole design:
#
#   * The LITERAL may live on this frame. dispatch_sync finishes before we
#     return; dispatch_async runs Block_copy BEFORE returning, and with no
#     captures there are no copy/dispose helpers -- the copy is a 32-byte
#     memmove plus refcounting. Either way the stack literal only has to
#     survive the call itself.
#
#   * The DESCRIPTOR may NOT live on this frame: the heap copy keeps pointing
#     at it, and the runtime reads `size` from it on release, long after this
#     frame is gone. Clang emits descriptors as statics; ours is a
#     `named_global` -- one immortal 16-byte record serves every capture-less
#     block in the process, because their descriptors are all identical.


def with_block[work: fn() -> None](queue: _RawPtr, *, wait: Bool):
    """Run `work` on `queue` as a real Objective-C BLOCK (the dispatch_sync /
    dispatch_async block forms), proving the `fn`-as-block correspondence.

    `work` is a comptime parameter, not a capture: the invoke trampoline
    below is itself a thin `fn`, as the block ABI requires.
    """

    fn _invoke(block: _RawPtr) -> None:
        work()

    # The immortal shared descriptor. The store is idempotent (always 32),
    # so concurrent first calls cannot disagree.
    var desc = named_global["dispatch.blockdesc", Array[Int, 2]]()
    desc[][1] = 32

    var storage = Array[Int, 4](fill=0)
    storage[0] = Int(
        _RawPtr(
            _mlir_value=__mlir_op.`pop.extern_ptr_symbol`[
                name = _get_kgen_string["_NSConcreteStackBlock"](),
                alignment = Int(8).__mlir_index__(),
                _type = _RawPtr._mlir_type,
            ]()
        )
    )
    # storage[1] is flags:0 / reserved:0.
    storage[2] = Pointer(to=_invoke).unsafe_bitcast[Int]()[]
    storage[3] = Int(desc)

    if wait:
        external_call["dispatch_sync", NoneType](queue, Pointer(to=storage))
    else:
        external_call["dispatch_async", NoneType](queue, Pointer(to=storage))
