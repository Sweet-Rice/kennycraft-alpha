#!/usr/bin/env python3
"""Convert a little-endian binary into a fixed-size readmemh image."""
import argparse
from pathlib import Path
import sys


def main():
    p = argparse.ArgumentParser()
    p.add_argument('input', type=Path)
    p.add_argument('output', type=Path)
    p.add_argument('--offset-bytes', type=lambda s: int(s, 0), required=True)
    p.add_argument('--words', type=int, default=8192)
    p.add_argument('--mem', action='store_true')
    a = p.parse_args()
    if a.offset_bytes < 0 or a.words < 0:
        p.error('offset and words must be nonnegative')
    try:
        data = a.input.read_bytes()
        size = (a.offset_bytes + len(data) + 3) // 4
        if size > a.words:
            print(f'elf2hex: image too large ({size} words > {a.words})', file=sys.stderr)
            return 1
        data = bytes(a.offset_bytes) + data
        data += bytes(a.words * 4 - len(data))
        with a.output.open('w') as f:
            if a.mem:
                f.write('@00000000\n')
            for i in range(0, len(data), 4):
                f.write(f'{int.from_bytes(data[i:i+4], "little"):08x}\n')
    except OSError as e:
        print(f'elf2hex: {e}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
