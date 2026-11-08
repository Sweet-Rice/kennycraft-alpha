#!/usr/bin/env python3
"""Compare the retirement traces of a multi-cycle (A) and a pipelined (B)
build of the same tb/core testbench, ignoring cycle numbers (P8).

Both binaries run with +trace through tb/core/tracediff.py's run(), which
fails on a non-zero exit or a FAIL line. Every `trace` line soc_harness.svh
prints is compared with its cycle number removed: PC, instruction, active
mask, lane 0's rd write, every other lane's rd write, and the halt line
(ERR_PC and the ERR bits). Two things are timing, not architecture, and are
handled explicitly:

  * a run of consecutive retirements of the same `jal x0, 0` (a spin that
    waits for the testbench) counts as one line, since its length is the
    time the testbench waits;
  * with --tail N, A may end with up to N lines that B lacks (instructions
    still in B's pipeline when the testbench calls $finish). They are
    printed, and a halt line is never excused.

Anything else, including every CYCLES or polling difference, is a mismatch.

usage: tracediff_pipe.py [--tail N] NAME BIN_A BIN_B [plusargs...]
"""
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "core"))
from tracediff import run  # noqa: E402

CYCLE = re.compile(r"^trace \d+ ")
SPIN = re.compile(r"^trace pc=[0-9a-f]{8} inst=0000006f ")


def normalize(lines):
    out = []
    for l in lines:
        l = CYCLE.sub("trace ", l, count=1)
        if SPIN.match(l) and out and out[-1] == l:
            continue
        out.append(l)
    return out


def compare(name, a, b, tail):
    """Return (ok, message) for normalized traces a (reference) and b."""
    if not a:
        return False, f"tracediff {name}: empty trace"
    for i, (la, lb) in enumerate(zip(a, b)):
        if la != lb:
            ctx = "".join(f"    {a[j]}\n" for j in range(max(0, i - 3), i))
            return False, (f"tracediff {name}: first difference at trace line {i + 1}\n"
                           f"{ctx}  A {la}\n  B {lb}")
    if len(b) > len(a):
        return False, (f"tracediff {name}: B retires {len(b) - len(a)} more line(s), "
                       f"first: {b[len(a)]}")
    extra = a[len(b):]
    if len(extra) > tail or any(" halt " in l for l in extra):
        return False, (f"tracediff {name}: lengths differ, {len(a)} vs {len(b)} lines, "
                       f"first missing in B: {extra[0]}")
    msg = f"tracediff {name}: PASS, {len(b)} trace lines identical (cycles ignored)"
    for l in extra:
        msg += f"\n  not retired by B at $finish: {l}"
    return True, msg


def main():
    args = sys.argv[1:]
    tail = 0
    if args[:1] == ["--tail"]:
        tail, args = int(args[1]), args[2:]
    if len(args) < 3:
        sys.exit(__doc__)
    name, bin_a, bin_b, plusargs = args[0], args[1], args[2], args[3:]
    a = normalize(run(bin_a, plusargs))
    b = normalize(run(bin_b, plusargs))
    ok, msg = compare(name, a, b, tail)
    print(msg)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
