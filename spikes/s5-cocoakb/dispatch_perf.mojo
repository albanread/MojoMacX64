# std.objc dispatch is materialized to C speed by code generation:
#  - the objc_msgSend stub is a link-time symbol reference (a relocation), and
#  - the selector is cached in a per-selector persistent global slot (one load).
# After warmup a fully-checked, database-driven message send costs about as
# much as a hand-written objc_msgSend -- with none of the selector typos, ABI
# stub mistakes, arg-count or register-file bugs a hand binding can have.
from std.objc import ObjCClass, ObjCObject, msg_send
from std.time import perf_counter_ns


def main():
    var NSString = ObjCClass.lookup["NSString"]()
    var hi = String("perf")
    var s = msg_send[
        ObjCObject, "NSString", "stringWithUTF8String:", is_class=True
    ](NSString.as_object(), hi.as_c_string_slice())

    # warm the selector slot
    _ = msg_send[Int, "NSString", "length"](s)

    comptime iters = 50_000_000
    var t0 = perf_counter_ns()
    var total = 0
    for _ in range(iters):
        total += msg_send[Int, "NSString", "length"](s)
    var t1 = perf_counter_ns()

    var ns = Float64(t1 - t0) / Float64(iters)
    print("length sum:", total)
    print("ns per fully-checked msg_send:", ns)
    print("DISPATCH-PERF: PASS" if total == iters * 4 and ns < 20.0 else "DISPATCH-PERF: FAIL")
