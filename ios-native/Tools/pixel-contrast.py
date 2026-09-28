#!/usr/bin/env python3
"""Measure contrast from the pixels that were actually drawn.

    pixel-contrast.py <screenshot.png> <walk.txt> [--screen "feed"] [--min-ratio 4.5]

Why this exists alongside `PaletteContrastTests`: that test measures a *token*
against a *surface*, which is a statement about two constants. It cannot see an
`.opacity()` modifier, a material, a gradient behind a label, or a colour that
a view got from somewhere other than the palette. This reads the rendered
frame, which is what a person looks at.

Method, and its honest limits:

  For each element's rectangle, take the darkest and the lightest pixel inside
  it and treat them as foreground and background. For a text label on a solid
  ground this is exactly right: the glyph core reaches the full text colour and
  the gaps between glyphs are the full background.

  It is *not* right for a label over a photo or a gradient — the extremes then
  come from the image, not the text — so those must be excluded by hand, and a
  measurement over such a rectangle is reported with a warning rather than as a
  ratio to be trusted.

  Anti-aliased edge pixels sit between the two extremes and are ignored by
  construction, which is the conservative direction: the ratio reported is the
  best case, so a failure here is a real failure.

There is no PIL on this machine (checked), so the PNG is decoded here with
zlib and struct. Only the 8-bit RGB/RGBA non-interlaced case is handled, which
is what `XCUIScreen.screenshot().pngRepresentation` produces.
"""

import struct
import sys
import zlib


def read_png(path):
    with open(path, "rb") as handle:
        data = handle.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, idat, meta = 8, b"", None
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", body)
            meta = (width, height, depth, colour, interlace)
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
        pos += 12 + length

    width, height, depth, colour, interlace = meta
    if depth != 8 or interlace != 0 or colour not in (2, 6):
        raise ValueError(f"unsupported PNG: depth={depth} colour={colour} interlace={interlace}")
    channels = 3 if colour == 2 else 4
    raw = zlib.decompress(idat)
    stride = width * channels

    rows, previous, offset = [], bytearray(stride), 0
    for _ in range(height):
        filter_type = raw[offset]
        offset += 1
        line = bytearray(raw[offset:offset + stride])
        offset += stride
        if filter_type == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif filter_type == 2:
            for i in range(stride):
                line[i] = (line[i] + previous[i]) & 0xFF
        elif filter_type == 3:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 0xFF
        elif filter_type == 4:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = previous[i]
                c = previous[i - channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 0xFF
        elif filter_type != 0:
            raise ValueError(f"unknown PNG filter {filter_type}")
        rows.append(bytes(line))
        previous = line
    return width, height, channels, rows


def luminance(rgb):
    def lin(v):
        v /= 255.0
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    return 0.2126 * lin(rgb[0]) + 0.7152 * lin(rgb[1]) + 0.0722 * lin(rgb[2])


def ratio(a, b):
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def extremes(rows, channels, x0, y0, x1, y1, width, height):
    """Darkest and lightest pixel in the rectangle, plus how varied it is."""
    x0, y0 = max(0, int(x0)), max(0, int(y0))
    x1, y1 = min(width, int(x1)), min(height, int(y1))
    if x1 <= x0 or y1 <= y0:
        return None
    darkest = lightest = None
    dl, ll = 2.0, -1.0
    distinct = set()
    for y in range(y0, y1):
        row = rows[y]
        for x in range(x0, x1):
            i = x * channels
            pixel = (row[i], row[i + 1], row[i + 2])
            distinct.add(pixel)
            lum = luminance(pixel)
            if lum < dl:
                dl, darkest = lum, pixel
            if lum > ll:
                ll, lightest = lum, pixel
    return darkest, lightest, len(distinct)


def parse_frame(text):
    """`frame={{x, y}, {w, h}}` as XCUIElement prints it."""
    digits = []
    number = ""
    for ch in text:
        if ch.isdigit() or ch in ".-":
            number += ch
        elif number:
            digits.append(float(number))
            number = ""
    if number:
        digits.append(float(number))
    return digits[:4] if len(digits) >= 4 else None


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    png, walk = sys.argv[1], sys.argv[2]
    want_screen = None
    min_ratio = 4.5
    if "--screen" in sys.argv:
        want_screen = sys.argv[sys.argv.index("--screen") + 1]
    if "--min-ratio" in sys.argv:
        min_ratio = float(sys.argv[sys.argv.index("--min-ratio") + 1])

    width, height, channels, rows = read_png(png)

    entries = []
    window_width = None
    for line in open(walk, encoding="utf-8", errors="replace"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) < 5:
            continue
        screen, _kind, ident, label, frame = parts[0], parts[1], parts[2], parts[3], parts[4]
        if want_screen and screen != want_screen:
            continue
        box = parse_frame(frame)
        if not box:
            continue
        entries.append((ident[3:], label[6:], box))
        window_width = max(window_width or 0, box[0] + box[2])

    if not entries:
        print("no elements parsed from the walk file — nothing to measure")
        return 1

    # The screenshot is in pixels, the frames are in points.
    #
    # Inferring the point width from the elements does not work and the first
    # version of this script got it wrong: the feed's photo is laid out wider
    # than the window (aspect-fill, then clipped), so its frame runs from
    # x=-176 to x=578 on a 402pt screen. Taking the maximum extent gave 578,
    # a scale of 2 instead of 3, and every sampled rectangle landed somewhere
    # other than the element — which showed up as "contrast 1.00:1, one colour"
    # for the navigation bar and as "photo/gradient" for plain labels.
    #
    # So the width is passed in. `--window-width 402` is the iPhone 17 Pro's,
    # the same constant SnapshotTests pins.
    if "--window-width" in sys.argv:
        window_width = float(sys.argv[sys.argv.index("--window-width") + 1])
    scale = width / window_width if window_width else 1
    if abs(scale - round(scale)) > 0.01:
        print(f"WARNING: png width {width} is not an integer multiple of "
              f"{window_width}pt (scale={scale:.3f}). Pass --window-width.")
    scale = round(scale)
    print(f"png={width}x{height}px  scale={scale}x  elements={len(entries)}  "
          f"threshold={min_ratio}:1")
    print()

    failures = 0
    unmeasured = 0
    for ident, label, (x, y, w, h) in entries:
        if w < 2 or h < 2:
            continue
        found = extremes(rows, channels,
                         x * scale, y * scale, (x + w) * scale, (y + h) * scale,
                         width, height)
        if not found:
            continue
        dark, light, distinct = found
        value = ratio(dark, light)
        # A rectangle with hundreds of distinct colours is a photo, not text on
        # a flat ground; the extremes there are the image's, and reporting a
        # ratio for it would be measuring the photo.
        photo = distinct > 400
        # A rectangle containing one or two colours did not land on the element.
        # Text is anti-aliased: even a two-character label puts dozens of
        # intermediate greys inside its own box. One colour means the frame and
        # the screenshot came from different layout states — which happened on
        # the detail screen in this project's first run, where the comment list
        # arrived between `shoot()` and the frame dump and every comment row
        # measured "1.00:1, one colour".
        #
        # Reporting that as a contrast failure would have been a fabricated
        # defect. Reporting it as "unmeasured" is the truth.
        landed = distinct >= 8
        flag = ""
        if not landed:
            flag = ("  <-- RECT DID NOT LAND ON THE ELEMENT "
                    f"({distinct} colour(s)); screenshot and frames disagree — not a measurement")
            unmeasured += 1
        elif photo:
            flag = "  (photo/gradient — extremes are not text vs ground, ignore)"
        elif value < min_ratio:
            flag = "  <-- UNDER THRESHOLD"
            failures += 1
        name = ident if ident and ident != "-" else label[:30]
        print(f"  {value:6.2f}:1  {name[:38]:38s} dark={dark} light={light} "
              f"colours={distinct}{flag}")

    print()
    if unmeasured:
        print(f"{unmeasured} element(s) could not be measured: the rectangle held")
        print("fewer than 8 colours, so it did not land on the element. Re-take the")
        print("screenshot and the frame dump in the same settled state; do NOT read")
        print("these as contrast failures.")
    if failures:
        print(f"{failures} element(s) below {min_ratio}:1 in the rendered frame.")
    else:
        print(f"no measurable element below {min_ratio}:1 in the rendered frame.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
