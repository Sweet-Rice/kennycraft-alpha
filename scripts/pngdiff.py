#!/usr/bin/env python3
"""Compare two PNGs exactly in RGB and save differing pixels on failure."""
import argparse
from pathlib import Path
import sys
from PIL import Image


def compare(a, b, diff):
    with Image.open(a) as source:
        left = source.convert('RGB')
    with Image.open(b) as source:
        right = source.convert('RGB')
    if left.size == right.size and left.tobytes() == right.tobytes():
        return 0
    width, height = max(left.width, right.width), max(left.height, right.height)
    output = Image.new('RGB', (width, height))
    lp, rp, op = left.load(), right.load(), output.load()
    count = 0
    for y in range(height):
        for x in range(width):
            in_left = x < left.width and y < left.height
            in_right = x < right.width and y < right.height
            if not in_left and not in_right:
                continue
            if not in_left or not in_right:
                op[x, y] = (255, 0, 255)
                count += 1
            elif lp[x, y] != rp[x, y]:
                op[x, y] = tuple(abs(i - j) for i, j in zip(lp[x, y], rp[x, y]))
                count += 1
    if count:
        diff = Path(diff)
        diff.parent.mkdir(parents=True, exist_ok=True)
        output.save(diff)
        print(f'pngdiff: {count} differing pixels; diff {diff}')
        return 1
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('a')
    parser.add_argument('b')
    parser.add_argument('diff')
    args = parser.parse_args()
    try:
        return compare(args.a, args.b, args.diff)
    except (OSError, ValueError) as error:
        print(f'pngdiff: {error}', file=sys.stderr)
        return 5


if __name__ == '__main__':
    sys.exit(main())
