# An iterated function system, kept apart from the example that draws it so
# there is a project here with more than one file in it.
@fieldwise_init
struct Affine(ImplicitlyCopyable, Movable):
    """x' = a x + b y + e,  y' = c x + d y + f, chosen with probability p."""

    var a: Float64
    var b: Float64
    var c: Float64
    var d: Float64
    var e: Float64
    var f: Float64
    var p: Float64


def barnsley() -> List[Affine]:
    """Barnsley's fern: four maps, and the shape is in the numbers."""
    var maps = List[Affine]()
    maps.append(Affine(0.00, 0.00, 0.00, 0.16, 0.0, 0.00, 0.01))
    maps.append(Affine(0.85, 0.04, -0.04, 0.85, 0.0, 1.60, 0.85))
    maps.append(Affine(0.20, -0.26, 0.23, 0.22, 0.0, 1.60, 0.07))
    maps.append(Affine(-0.15, 0.28, 0.26, 0.24, 0.0, 0.44, 0.07))
    return maps^


struct Rng(Movable):
    """A small deterministic generator, so the picture is the same every run --
    an example that draws something different each time is hard to check."""

    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed

    def next(mut self) -> Float64:
        # xorshift64*
        self.state ^= self.state >> 12
        self.state ^= self.state << 25
        self.state ^= self.state >> 27
        let x = self.state * 2685821657736338717
        return Float64(x >> 11) / Float64(1 << 53)
