# Barnsley's fern.
#
# Three files: this one, ifs.mojo, and png.mojo, all beside each other. Roast
# finds main.mojo and hands it to cocoamojo, which follows the imports from
# there -- which is why a project's files live in the project's folder.
#
# Build with cmd-B, run with cmd-R. It writes fern.png next to wherever it
# was run from, and prints a rough copy to the terminal on the way past.

from std.math import log
from std.pathlib import cwd

from ifs import Affine, barnsley, Rng
from png import write_rgb_png

comptime W = 720
comptime H = 960
comptime POINTS = 2_000_000
comptime SETTLE = 20  # iterations before the point is really on the attractor

# The fern lives in roughly x in [-2.2, 2.7], y in [0, 10].
comptime X0 = -2.20
comptime X1 = 2.70
comptime Y0 = 0.0
comptime Y1 = 10.0


def main() raises:
    var maps = barnsley()
    var rng = Rng(0x2545F4914F6CDD1D)

    # Count how many points land in each pixel. Chaos-game pictures are all
    # about density -- plotting hit-or-miss throws away most of the picture,
    # which is exactly what the old text version was doing.
    var hits = List[UInt32](length=W * H, fill=0)
    var peak: UInt32 = 0

    var x = 0.0
    var y = 0.0

    for n in range(POINTS):
        # Pick a map by its probability.
        var r = rng.next()
        var acc = 0.0
        var k = len(maps) - 1
        for i in range(len(maps)):
            acc += maps[i].p
            if r <= acc:
                k = i
                break

        var m = maps[k]
        var nx = m.a * x + m.b * y + m.e
        var ny = m.c * x + m.d * y + m.f
        x = nx
        y = ny

        if n < SETTLE:
            continue

        var col = Int((x - X0) / (X1 - X0) * Float64(W - 1) + 0.5)
        var row = Int((Y1 - y) / (Y1 - Y0) * Float64(H - 1) + 0.5)
        if col < 0 or col >= W or row < 0 or row >= H:
            continue
        var idx = row * W + col
        hits[idx] += 1
        if hits[idx] > peak:
            peak = hits[idx]

    print("plotted", POINTS, "points into", W, "x", H, "-- busiest pixel:", peak)

    # Density to colour, on a log scale: linear brightness would leave the
    # fronds invisible next to the stem.
    var scale = 1.0 / log(Float64(peak) + 1.0)
    var rgb = List[UInt8](capacity=W * H * 3)
    for i in range(W * H):
        var h = hits[i]
        if h == 0:
            rgb.append(9)
            rgb.append(12)
            rgb.append(14)
            continue
        var t = log(Float64(h) + 1.0) * scale
        rgb.append(UInt8(24.0 + 200.0 * t * t))
        rgb.append(UInt8(70.0 + 175.0 * t))
        rgb.append(UInt8(38.0 + 150.0 * t * t * t))

    var path = String(cwd()) + "/fern.png"
    write_rgb_png(path, W, H, rgb)
    print("wrote", path)

    _preview(hits, peak)


def _preview(hits: List[UInt32], peak: UInt32):
    """A rough copy for the terminal, in case nobody opens the png.

    Each cell takes the *busiest* pixel in its block, not the average -- a
    frond is one pixel wide against a lot of empty space, and averaging washes
    it straight out. Terminal cells are about twice as tall as they are wide,
    so the grid is wider than the image's proportions to compensate."""
    comptime RAMP = " .:-=+*#%@"
    comptime CW = 54
    comptime CH = 36

    var scale = 1.0 / log(Float64(peak) + 1.0)
    for cy in range(CH):
        var line = String()
        for cx in range(CW):
            var best: UInt32 = 0
            for py in range(cy * H // CH, (cy + 1) * H // CH):
                for px in range(cx * W // CW, (cx + 1) * W // CW):
                    var h = hits[py * W + px]
                    if h > best:
                        best = h
            var t = log(Float64(best) + 1.0) * scale
            var step = Int(t * Float64(RAMP.byte_length() - 1) + 0.5)
            if step < 0:
                step = 0
            if step >= RAMP.byte_length():
                step = RAMP.byte_length() - 1
            line += RAMP[byte=step : step + 1]
        print(line)
