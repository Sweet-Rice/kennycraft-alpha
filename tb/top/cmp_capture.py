#!/usr/bin/env python3
"""Compare a board video capture with the Verilator frame, pixel for pixel.

    cmp_capture.py <sim.ppm> <capture.png> [--box X0,Y0,X1,Y1] [--out DIR]

sim.ppm is the 160x120 frame written by tb/top/t_top_frame.sv (8-bit channels,
each 17 x a 4-bit VGA level). capture.png is a capture-card frame of the VGA
output (any size; the 640x480 picture is scaled, maybe pillarboxed). Each of
the 160x120 logical pixels is read as the mean of the middle half of its cell
inside the picture box X0,Y0 (inclusive) .. X1,Y1 (exclusive).

The capture path (VGA -> HDMI converter -> MJPEG capture card) changes colours
(gain, gamma, compression), so a capture pixel is not compared with the RGB444
value itself. Every colour of the Verilator frame gets a reference point: the
mean capture value over all cells where Verilator shows that colour. A cell
matches when its nearest reference point is the colour Verilator shows there.
One wrong pixel moves its colour's mean by only 1/n, so it still lands on the
wrong reference. The raw nearest-RGB444 count is printed too.

Without --box the picture box starts as the bounding box of non-black rows and
columns and each edge is then moved by up to 6 capture pixels, keeping the box
with the fewest mismatches (the converter's scaling is not exactly known).

Writes board.ppm (the classified board frame) and diff.ppm (mismatches in
magenta, matches dimmed) to --out and prints:
    cmp_capture: <n> of 19200 pixels differ, box=..., ...
Exit status 0 only when every pixel matches.
"""

import argparse
import sys
from pathlib import Path

from PIL import Image

W, H = 160, 120


class Integral:
    """Summed-area table per channel, for O(1) rectangle means."""

    def __init__(self, img):
        self.w, self.h = img.size
        px = list(img.getdata())
        w1 = self.w + 1
        self.s = [[0] * (w1 * (self.h + 1)) for _ in range(3)]
        for ch in range(3):
            s = self.s[ch]
            for y in range(self.h):
                run = 0
                row, prev, cur = y * self.w, y * w1, (y + 1) * w1
                for x in range(self.w):
                    run += px[row + x][ch]
                    s[cur + x + 1] = s[prev + x + 1] + run

    def mean(self, x0, y0, x1, y1):
        w1 = self.w + 1
        n = (x1 - x0) * (y1 - y0)
        return tuple((s[y1 * w1 + x1] - s[y0 * w1 + x1] - s[y1 * w1 + x0] + s[y0 * w1 + x0]) / n
                     for s in self.s)


def bbox(img, thresh=24):
    w, h = img.size
    px = img.load()

    def lit(x, y):
        return max(px[x, y]) > thresh
    cols = [x for x in range(w) if sum(lit(x, y) for y in range(0, h, 4)) > h // 16]
    rows = [y for y in range(h) if sum(lit(x, y) for x in range(0, w, 4)) > w // 16]
    if not cols or not rows:
        sys.exit("cmp_capture: capture is black")
    return [cols[0], rows[0], cols[-1] + 1, rows[-1] + 1]


def dist(a, b):
    return (a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2


def classify(ii, sim, colours, box):
    """Return (mismatches, cell means, reference points) for one picture box."""
    x0, y0, x1, y1 = box
    sx, sy = (x1 - x0) / W, (y1 - y0) / H
    means = {}
    for y in range(H):
        cy0 = int(y0 + (y + 0.25) * sy)
        cy1 = max(int(y0 + (y + 0.75) * sy), cy0 + 1)
        for x in range(W):
            cx0 = int(x0 + (x + 0.25) * sx)
            cx1 = max(int(x0 + (x + 0.75) * sx), cx0 + 1)
            means[x, y] = ii.mean(cx0, cy0, cx1, cy1)
    acc = {c: [0.0, 0.0, 0.0, 0] for c in colours}
    for k, m in means.items():
        a = acc[sim[k]]
        a[0] += m[0]; a[1] += m[1]; a[2] += m[2]; a[3] += 1
    ref = {c: (a[0] / a[3], a[1] / a[3], a[2] / a[3]) for c, a in acc.items()}
    near = {k: min(colours, key=lambda c: dist(ref[c], m)) for k, m in means.items()}
    bad = sum(near[k] != sim[k] for k in means)
    return bad, means, near


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sim")
    ap.add_argument("capture")
    ap.add_argument("--box")
    ap.add_argument("--out", default=".")
    a = ap.parse_args()

    simg = Image.open(a.sim).convert("RGB")
    if simg.size != (W, H):
        sys.exit(f"cmp_capture: {a.sim} is {simg.size}, expected {W}x{H}")
    cap = Image.open(a.capture).convert("RGB")
    sp = simg.load()
    sim = {(x, y): sp[x, y] for y in range(H) for x in range(W)}
    colours = sorted(set(sim.values()))
    ii = Integral(cap)

    if a.box:
        box = [int(v) for v in a.box.split(",")]
        bad = classify(ii, sim, colours, box)[0]
    else:
        box = bbox(cap)
        bad = classify(ii, sim, colours, box)[0]
        limits = [(0, cap.size[0]), (0, cap.size[1])] * 2
        improved = True
        while improved and bad:
            improved = False
            for edge in range(4):
                for d in range(-6, 7):
                    trial = list(box)
                    trial[edge] += d
                    lo, hi = limits[edge]
                    if not lo <= trial[edge] <= hi or trial[2] - trial[0] < W or trial[3] - trial[1] < H:
                        continue
                    b = classify(ii, sim, colours, trial)[0]
                    if b < bad:
                        bad, box, improved = b, trial, True

    bad, means, near = classify(ii, sim, colours, box)
    raw_bad = sum(min(colours, key=lambda c: dist(c, m)) != sim[k] for k, m in means.items())
    err = sum(sum(abs(sim[k][i] - m[i]) for i in range(3)) / 3 for k, m in means.items())

    board = Image.new("RGB", (W, H))
    diff = Image.new("RGB", (W, H))
    bp, dp = board.load(), diff.load()
    for (x, y), c in near.items():
        bp[x, y] = c
        s = sim[x, y]
        dp[x, y] = (255, 0, 255) if c != s else (s[0] // 3, s[1] // 3, s[2] // 3)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    board.save(out / "board.ppm")
    diff.save(out / "diff.ppm")
    print(f"cmp_capture: {bad} of {W * H} pixels differ, box={','.join(map(str, box))} "
          f"({len(colours)} colours; raw nearest-RGB444 differs on {raw_bad}), "
          f"mean |capture - RGB444|={err / (W * H):.1f}/255")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
