#!/usr/bin/env python3
"""Draw Roast's icon: three roasted cocoa beans, and write tools/roast.icns.

    ./tools/make-icon.py

The name is the joke and the joke is the icon -- roasting is what you do to
cocoa beans, and this is the IDE for cocoa-mojo. Three beans on a warm dark
ground, lit from the upper left, each with the crease down its face that
makes a cocoa bean read as one at any size.

Drawn here rather than pasted in as a binary for the same reason the rest of
this repository builds what it ships: an .icns nobody can regenerate is a
file that rots. There is no image library in the environment, so this is
arithmetic into a pixel buffer, 4x supersampled and box-filtered down, with
a small pure-Python PNG writer at the end (zlib does the compressing, which
is all a PNG really is).
"""

import math
import os
import shutil
import struct
import subprocess
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

SS = 4  # supersampling factor; the whole anti-aliasing story
MASTER = 1024
SIZES = [16, 32, 64, 128, 256, 512, 1024]

# macOS icons are a rounded square inset from the canvas, not a full bleed.
INSET = 0.085
CORNER = 0.225  # of the square's side


def srgb(c):
    return max(0, min(255, int(round(c * 255))))


def lerp(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def superellipse_inside(x, y, cx, cy, half, n):
    """macOS's corner is closer to a superellipse than to a circular arc."""
    dx = abs(x - cx) / half
    dy = abs(y - cy) / half
    return (dx ** n + dy ** n) <= 1.0


def bean_field(x, y, bean):
    """Signed-ish coordinates inside one bean.

    Returns (inside, u, v) where u runs across the bean and v along it, both
    in -1..1, so the shading and the crease can be written in the bean's own
    frame rather than the canvas's.
    """
    cx, cy, rx, ry, ang = bean
    ca, sa = math.cos(ang), math.sin(ang)
    dx, dy = x - cx, y - cy
    u = (dx * ca + dy * sa) / rx
    v = (-dx * sa + dy * ca) / ry
    # A cocoa bean is an ellipse with one end a little fuller than the other.
    taper = 1.0 + 0.13 * v
    u /= taper
    return (u * u + v * v) <= 1.0, u, v


def render(size):
    """The icon at `size`, supersampled. Returns rows of RGBA bytes."""
    n = size * SS
    px = bytearray(n * n * 4)

    # Ground: a warm dark roast, lighter at the top left where the light is.
    # The ground is pulled well away from the beans in both value and hue --
    # a near-black espresso rather than a mid brown. Beans and background in
    # the same register is what made the first pass read as one brown blob at
    # small sizes, which is the only size that really matters.
    GROUND_HI = (0.157, 0.106, 0.086)  # #281b16
    GROUND_LO = (0.063, 0.039, 0.031)  # #100a08
    # Bean body, and the crease that splits it.
    BEAN_HI = (0.812, 0.522, 0.267)   # lit face, a warm roasted amber
    BEAN_LO = (0.361, 0.184, 0.086)   # shadowed face
    CREASE = (0.157, 0.075, 0.039)
    SHEEN = (0.949, 0.796, 0.573)     # the oil on a roasted bean

    half = n * (0.5 - INSET)
    cx = cy = n * 0.5
    corner_n = 2.0 / CORNER * 0.55 + 2.0  # ~5, the squircle exponent

    # Three beans: two forward, one behind and above, so the group reads as a
    # heap rather than a row. Coordinates are fractions of the canvas.
    beans = [
        (0.50, 0.335, 0.150, 0.245, math.radians(6)),
        (0.355, 0.610, 0.155, 0.255, math.radians(-24)),
        (0.650, 0.615, 0.155, 0.255, math.radians(22)),
    ]
    beans = [
        (bx * n, by * n, brx * n, bry * n, ang) for bx, by, brx, bry, ang in beans
    ]

    for y in range(n):
        row = y * n * 4
        for x in range(n):
            i = row + x * 4
            if not superellipse_inside(x, y, cx, cy, half, corner_n):
                continue  # transparent outside the rounded square

            # Ground gradient along the top-left to bottom-right diagonal.
            t = ((x / n) + (y / n)) * 0.5
            r, g, b = lerp(GROUND_HI, GROUND_LO, min(1.0, t * 1.25))

            # A soft vignette so the beans sit in something.
            d = math.hypot(x - cx, y - cy) / half
            r, g, b = (c * (1.0 - 0.28 * d * d) for c in (r, g, b))

            for bean in beans:
                inside, u, v = bean_field(x, y, bean)
                if not inside:
                    # A contact shadow just outside each bean, which is what
                    # stops three flat shapes looking like stickers.
                    rr = u * u + v * v
                    if rr < 1.45:
                        k = (1.45 - rr) / 0.45
                        k = max(0.0, min(1.0, k)) * 0.55
                        r, g, b = (c * (1.0 - k * 0.55) for c in (r, g, b))
                    continue

                # Lambert-ish: light from the upper left in the bean's frame.
                lit = 0.5 - 0.5 * (u * 0.72 + v * 0.62)
                lit = max(0.0, min(1.0, lit))
                br, bg, bb = lerp(BEAN_LO, BEAN_HI, lit ** 0.85)

                # The crease: a groove down the long axis, deepest at the
                # middle and fading at the ends, which is the single feature
                # that says "cocoa bean" at sixteen pixels.
                groove = math.exp(-((u / 0.20) ** 2)) * (1.0 - 0.55 * v * v)
                br, bg, bb = lerp((br, bg, bb), CREASE, min(0.92, groove))

                # Rim light along the lit edge, and a small specular.
                rim = max(0.0, (u * u + v * v) - 0.62) / 0.38
                if lit > 0.55:
                    br, bg, bb = lerp((br, bg, bb), SHEEN, rim * 0.30 * (lit - 0.55) * 2.2)
                spec = math.exp(-(((u + 0.42) ** 2 + (v + 0.46) ** 2) / 0.055))
                br, bg, bb = lerp((br, bg, bb), SHEEN, min(0.55, spec * 0.55))

                r, g, b = br, bg, bb

            px[i] = srgb(r)
            px[i + 1] = srgb(g)
            px[i + 2] = srgb(b)
            px[i + 3] = 255

    return downsample(px, n, size)


def downsample(px, n, size):
    """Box filter SS x SS back to `size`, averaging alpha honestly so the
    rounded corners come out soft rather than stepped."""
    out = bytearray(size * size * 4)
    for y in range(size):
        for x in range(size):
            r = g = b = a = 0
            for dy in range(SS):
                base = ((y * SS + dy) * n + x * SS) * 4
                for dx in range(SS):
                    i = base + dx * 4
                    al = px[i + 3]
                    r += px[i] * al
                    g += px[i + 1] * al
                    b += px[i + 2] * al
                    a += al
            o = (y * size + x) * 4
            if a:
                out[o] = min(255, r // a)
                out[o + 1] = min(255, g // a)
                out[o + 2] = min(255, b // a)
            out[o + 3] = a // (SS * SS)
    return out


def write_png(path, size, rgba):
    raw = bytearray()
    for y in range(size):
        raw.append(0)  # filter: none
        raw += rgba[y * size * 4:(y + 1) * size * 4]

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def main():
    iconset = os.path.join(HERE, "roast.iconset")
    shutil.rmtree(iconset, ignore_errors=True)
    os.makedirs(iconset)

    # iconutil wants exactly these names; a 1024 is icon_512x512@2x.
    names = {
        16: ["icon_16x16.png"],
        32: ["icon_16x16@2x.png", "icon_32x32.png"],
        64: ["icon_32x32@2x.png"],
        128: ["icon_128x128.png"],
        256: ["icon_128x128@2x.png", "icon_256x256.png"],
        512: ["icon_256x256@2x.png", "icon_512x512.png"],
        1024: ["icon_512x512@2x.png"],
    }
    for size in SIZES:
        print("   %4d" % size, end="", flush=True)
        rgba = render(size)
        first = os.path.join(iconset, names[size][0])
        write_png(first, size, rgba)
        for extra in names[size][1:]:
            shutil.copyfile(first, os.path.join(iconset, extra))
        print(" ok", end="", flush=True)
    print()

    icns = os.path.join(HERE, "roast.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
    shutil.rmtree(iconset, ignore_errors=True)
    print("wrote %s (%d KB)" % (icns, os.path.getsize(icns) // 1024))


if __name__ == "__main__":
    sys.exit(main())
