# ===----------------------------------------------------------------------=== #
# The Cocoa geometry types, declared the way the ABI sees them.
#
# Every one of these is a homogeneous aggregate the C ABI keeps in registers:
# CGPoint and CGSize are two doubles (v0-v1), CGRect is four (v0-v3), NSRange
# is two 64-bit words (x0/x1). Declaring them TrivialRegisterPassable makes
# Mojo agree -- which is not a micro-optimisation but what lets a `class`
# method RETURN one. A memory-only result becomes a by-ref slot, which is not
# how Objective-C returns a struct, so `selectedRange` was impossible to
# implement until these types stopped being memory-only.
#
# Thirteen files used to redeclare CGRect locally, each as `Copyable, Movable`
# and therefore each subtly wrong for that purpose. This is the one copy.
# ===----------------------------------------------------------------------=== #
from std.sys.info import TrivialRegisterPassable


@fieldwise_init
struct CGPoint(TrivialRegisterPassable):
    var x: Float64
    var y: Float64


@fieldwise_init
struct CGSize(TrivialRegisterPassable):
    var width: Float64
    var height: Float64


@fieldwise_init
struct CGRect(TrivialRegisterPassable):
    var origin: CGPoint
    var size: CGSize


@fieldwise_init
struct NSRange(TrivialRegisterPassable):
    """`{_NSRange=QQ}`: location and length, in x0/x1. `NSNotFound` for a
    range that does not exist is `location == NOT_FOUND`."""

    var location: Int
    var length: Int

    comptime NOT_FOUND = 0x7FFFFFFFFFFFFFFF
