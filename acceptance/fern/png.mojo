# A PNG writer, small enough to read in one sitting.
#
# Truecolour, eight bits a channel, no filtering, and deflate's "stored" mode
# -- which compresses nothing but is a legal deflate stream, so every decoder
# accepts it. The whole format is four chunks and two checksums.

comptime _CRC_POLY: UInt32 = 0xEDB88320


fn _crc32(data: List[UInt8]) -> UInt32:
    """The CRC PNG puts at the end of every chunk. Bit at a time; the table
    version is faster but this one fits on the screen."""
    var c: UInt32 = 0xFFFFFFFF
    for i in range(len(data)):
        c ^= UInt32(data[i])
        for _ in range(8):
            if (c & 1) != 0:
                c = (c >> 1) ^ _CRC_POLY
            else:
                c = c >> 1
    return c ^ 0xFFFFFFFF


fn _adler32(data: List[UInt8]) -> UInt32:
    """zlib's checksum, which rides at the end of the compressed stream."""
    var a: UInt32 = 1
    var b: UInt32 = 0
    for i in range(len(data)):
        a = (a + UInt32(data[i])) % 65521
        b = (b + a) % 65521
    return (b << 16) | a


fn _be32(mut out: List[UInt8], v: UInt32):
    """PNG is big-endian throughout."""
    out.append(UInt8((v >> 24) & 0xFF))
    out.append(UInt8((v >> 16) & 0xFF))
    out.append(UInt8((v >> 8) & 0xFF))
    out.append(UInt8(v & 0xFF))


fn _chunk(mut out: List[UInt8], tag: StringSlice, body: List[UInt8]):
    """length, type, data, CRC-of-type-and-data."""
    _be32(out, UInt32(len(body)))
    var covered = List[UInt8]()
    var tb = tag.as_bytes()
    for i in range(len(tb)):
        covered.append(tb[i])
    for i in range(len(body)):
        covered.append(body[i])
    for i in range(len(covered)):
        out.append(covered[i])
    _be32(out, _crc32(covered))


fn _deflate_stored(raw: List[UInt8]) -> List[UInt8]:
    """A zlib stream of uncompressed blocks: header, then up to 65535 bytes at
    a time, each announced by its length and that length's complement."""
    var z = List[UInt8]()
    z.append(0x78)  # deflate, 32K window
    z.append(0x01)  # no preset dictionary, and 0x7801 is divisible by 31

    var n = len(raw)
    var pos = 0
    while True:
        var take = n - pos
        if take > 65535:
            take = 65535
        var last = pos + take >= n
        z.append(UInt8(1) if last else UInt8(0))  # BFINAL, BTYPE=00 (stored)
        z.append(UInt8(take & 0xFF))
        z.append(UInt8((take >> 8) & 0xFF))
        var nlen = 65535 - take
        z.append(UInt8(nlen & 0xFF))
        z.append(UInt8((nlen >> 8) & 0xFF))
        for i in range(take):
            z.append(raw[pos + i])
        pos += take
        if last:
            break

    _be32(z, _adler32(raw))
    return z^


def write_rgb_png(path: StringSlice, width: Int, height: Int, rgb: List[UInt8]) raises:
    """Save `width * height * 3` bytes of RGB as a PNG."""
    if len(rgb) != width * height * 3:
        raise Error("write_rgb_png: expected " + String(width * height * 3) +
                    " bytes, got " + String(len(rgb)))

    # Each row is preceded by its filter byte. Zero means "no filter", which
    # costs size and saves us writing four predictors.
    var raw = List[UInt8]()
    for y in range(height):
        raw.append(0)
        var base = y * width * 3
        for i in range(width * 3):
            raw.append(rgb[base + i])

    var out = List[UInt8]()
    out.append(137)
    out.append(80)
    out.append(78)
    out.append(71)
    out.append(13)
    out.append(10)
    out.append(26)
    out.append(10)

    var ihdr = List[UInt8]()
    _be32(ihdr, UInt32(width))
    _be32(ihdr, UInt32(height))
    ihdr.append(8)  # bits per channel
    ihdr.append(2)  # colour type 2: truecolour
    ihdr.append(0)  # compression: deflate
    ihdr.append(0)  # filter method 0
    ihdr.append(0)  # not interlaced
    _chunk(out, "IHDR", ihdr)
    _chunk(out, "IDAT", _deflate_stored(raw))
    _chunk(out, "IEND", List[UInt8]())

    var f = open(path, "w")
    f.write_all(Span(out))
    f.close()
