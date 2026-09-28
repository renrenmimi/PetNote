#!/usr/bin/env python3
"""Colour statistics for a region of a device screenshot.

Exists because "it looks right" is not evidence and neither is a screenshot on
its own. The two defects this is built to catch, both real:

  - a black band where the keyboard's surroundings should be — caught by
    `darkest`, i.e. max(r,g,b) < 12 over a run of rows;
  - a permanently grey block where an image should be — caught by `colours`
    (a loaded photo has hundreds of distinct colours, a placeholder has one).

    python3 sample-pixels.py shot.png                 # whole image
    python3 sample-pixels.py shot.png 0 800 1206 200  # x y w h
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from pngread import read_png, px  # noqa: E402


def stats(path, box=None):
    w, h, nch, data = read_png(path)
    x0, y0, bw, bh = box or (0, 0, w, h)
    x1, y1 = min(x0 + bw, w), min(y0 + bh, h)
    colours = set()
    total = 0
    dark_rows = 0
    sum_l = 0.0
    sum_l2 = 0.0
    for y in range(y0, y1):
        row_dark = True
        for x in range(x0, x1):
            r, g, b = px(w, nch, data, x, y)
            colours.add((r, g, b))
            lum = 0.299 * r + 0.587 * g + 0.114 * b
            sum_l += lum
            sum_l2 += lum * lum
            total += 1
            if max(r, g, b) >= 12:
                row_dark = False
        if row_dark:
            dark_rows += 1
    mean = sum_l / total if total else 0
    var = (sum_l2 / total - mean * mean) if total else 0
    return {
        "image": f"{w}x{h}",
        "region": f"{x0},{y0} {x1 - x0}x{y1 - y0}",
        "pixels": total,
        "colours": len(colours),
        "mean_luma": round(mean, 1),
        "variance": round(var, 1),
        "fully_dark_rows": dark_rows,
    }


if __name__ == "__main__":
    if len(sys.argv) not in (2, 6):
        print(__doc__)
        raise SystemExit(2)
    box = tuple(int(v) for v in sys.argv[2:6]) if len(sys.argv) == 6 else None
    for key, value in stats(sys.argv[1], box).items():
        print(f"{key:18s} {value}")
