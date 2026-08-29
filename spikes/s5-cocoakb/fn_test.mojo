# The revived `fn`: foreign-callable, C ABI, callable from Mojo too.
from std.memory import OpaquePointer


fn add_one(x: Int) -> Int:
    return x + 1


fn no_args() -> Int:
    return 42


# fn in TYPE position: sugar for `def(...) thin abi("C") -> ...`.
comptime IntFn = fn(Int) -> Int


def apply(f: IntFn, x: Int) -> Int:
    return f(x)


def main() raises:
    if add_one(1) != 2:
        raise Error("FAIL: fn direct call")
    if no_args() != 42:
        raise Error("FAIL: fn no-arg call")
    if apply(add_one, 41) != 42:
        raise Error("FAIL: fn through fn-typed value")
    print("FN: PASS")
