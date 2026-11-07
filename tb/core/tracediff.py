#!/usr/bin/env python3
"""Run two Verilated tb/core testbenches with +trace and compare their
retirement traces (the `trace ...` lines soc_harness.svh prints from the
core's retire_* wires: cycle, PC, instruction, mask, lane 0's rd write, other
lanes' rd writes, halts).

Both runs must exit 0 without a FAIL line. With --lane0, lines for lanes 1
and up are checked and then dropped before the comparison: with only lane 0
active they may only come from BALLOT and MASKGET, which write rd in every
lane (Tai_2 section 2), and nothing else may write lanes 1 and up.

usage: tracediff.py [--lane0] NAME BIN_A BIN_B [plusargs...]
"""
import re
import subprocess
import sys

UNIFORM_F3 = (3, 5)   # BALLOT, MASKGET


def run(binary, plusargs):
    p = subprocess.run([binary, "+trace", *plusargs], capture_output=True, text=True)
    out = p.stdout + p.stderr
    if p.returncode != 0 or re.search(r"^\s*FAIL", out, re.M):
        sys.stdout.write(out)
        sys.exit(f"tracediff: {binary} failed (exit {p.returncode})")
    return [l for l in out.splitlines() if l.startswith("trace ")]


def strip_lanes(name, lines):
    kept, last_inst = [], None
    for l in lines:
        m = re.match(r"trace \d+   lane(\d+) ", l)
        if m:
            f3 = (last_inst >> 12) & 7 if last_inst is not None else -1
            if last_inst is None or (last_inst & 0x7F) != 0x0B or f3 not in UNIFORM_F3:
                sys.exit(f"tracediff {name}: lane {m.group(1)} written by a "
                         f"non-uniform instruction: {l}")
            continue
        m = re.search(r"inst=([0-9a-f]{8})", l)
        if m:
            last_inst = int(m.group(1), 16)
        kept.append(l)
    return kept


def main():
    args = sys.argv[1:]
    lane0 = args and args[0] == "--lane0"
    if lane0:
        args = args[1:]
    if len(args) < 3:
        sys.exit(__doc__)
    name, bin_a, bin_b, plusargs = args[0], args[1], args[2], args[3:]
    a, b = run(bin_a, plusargs), run(bin_b, plusargs)
    if lane0:
        b = strip_lanes(name, b)
    if not a:
        sys.exit(f"tracediff {name}: empty trace")
    for i, (la, lb) in enumerate(zip(a, b)):
        if la != lb:
            ctx = max(0, i - 3)
            print(f"tracediff {name}: first difference at trace line {i + 1}")
            for j in range(ctx, i):
                print(f"    {a[j]}")
            print(f"  A {la}\n  B {lb}")
            sys.exit(1)
    if len(a) != len(b):
        sys.exit(f"tracediff {name}: lengths differ, {len(a)} vs {len(b)} lines")
    print(f"tracediff {name}: PASS, {len(a)} trace lines identical")


if __name__ == "__main__":
    main()
