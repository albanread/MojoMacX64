# The payoff: idiomatic, leak-safe Cocoa in Mojo. No selector, ABI stub, or
# retain/release is written by hand -- the compiler supplies them from the SDK
# database, and NSString owns its object via ObjCRef.
from std.objc import NSString


def main():
    var hello = NSString("Hello, ")
    var world = NSString("Cocoa from Mojo")

    print("length of first string:", hello.length())

    var greeting = hello.appending(world)
    print("joined:", greeting.to_string())
    print("joined length:", greeting.length())

    var same = NSString("Hello, Cocoa from Mojo")
    print("equal to a fresh copy:", greeting.equals(same))
    print("equal to 'hello':", greeting.equals(hello))

    # Stress the ownership path: many bridged strings, released each iteration.
    var total = 0
    for i in range(200000):
        var s = NSString("iteration")
        total += s.length()
    print("cycled 2e5 NSStrings, total length units:", total)

    var ok = (
        greeting.to_string() == "Hello, Cocoa from Mojo"
        and greeting.equals(same)
        and not greeting.equals(hello)
        and total == 200000 * 9
    )
    print("FOUNDATION-DEMO: PASS" if ok else "FOUNDATION-DEMO: FAIL")
