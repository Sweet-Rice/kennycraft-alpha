#!/usr/bin/env python3
"""Report the first retired-instruction trace mismatch with five lines of context."""
import argparse
from collections import deque
from itertools import zip_longest
import sys


def compare(a, b):
    previous = deque(maxlen=5)
    with open(a, 'r', encoding='utf-8', errors='replace') as left, \
         open(b, 'r', encoding='utf-8', errors='replace') as right:
        for n, (x, y) in enumerate(zip_longest(left, right), 1):
            if x is None or y is None:
                print(f'trace {a if x is None else b} ends at line {n}')
                return 1
            if x.rstrip('\r\n') != y.rstrip('\r\n'):
                print(f'trace differs at line {n}')
                for line, text in previous:
                    print(f'  {line}: {text.rstrip("\r\n")}')
                print(f'A: {x.rstrip("\r\n")}')
                print(f'B: {y.rstrip("\r\n")}')
                return 1
            previous.append((n, x))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('a')
    parser.add_argument('b')
    args = parser.parse_args()
    try:
        return compare(args.a, args.b)
    except OSError as error:
        print(f'tracediff: {error}', file=sys.stderr)
        return 5


if __name__ == '__main__':
    sys.exit(main())
