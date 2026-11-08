#!/usr/bin/env python3
"""Compare the retirement traces of a multi-cycle (A) and a pipelined (B)
build of the same tb/core testbench, ignoring cycle numbers (P8).

Both binaries run with +trace through tb/core/tracediff.py's run(), which
fails on a non-zero exit or a FAIL line. Every `trace` line soc_harness.svh
prints is compared with its cycle number removed: PC, instruction, active
mask, lane 0's rd write, every other lane's rd write, and the halt line
(ERR_PC and the ERR bits). What depends on the CPI is handled explicitly,
per test, and everything it hides is printed:

  * a run of consecutive retirements of the same `jal x0, 0` (a spin that
    waits for the testbench) counts as one line, since its length is the
    time the testbench waits;
  * --poll ADDR[:NAME] (repeatable): poll loops on a load address, such as
    an MMIO status register or a flag the testbench writes. A poll loop is
    the pc range from a backward conditional branch's target to the branch,
    found after a load from ADDR (in any active lane; the address comes
    from the register values the trace shows) within the next few
    retirements. Each visit to the loop becomes one line in both traces;
    the visits must match, and every loop is printed with its iteration
    count on each side. --poll LO-HI[:NAME] names the pc range directly;
  * --mask ADDR[:NAME] (repeatable): rd values loaded from ADDR (CYCLES)
    and every value computed from them (register taint, per lane) are
    replaced by a token in both traces. Each masked write is printed with
    both values and B - A;
  * --tail N: A may end with up to N lines that B lacks (instructions still
    in B's pipeline when the testbench calls $finish). They are printed,
    and a halt line is never excused. B may end with the testbench's final
    spin when A had not reached it yet (B is faster); it is printed.

Anything else is a mismatch: a poll loop, a masked value or a spin may hide
nothing but its own timing.

usage: tracediff_pipe.py [--tail N] [--poll SPEC]... [--mask SPEC]...
                         NAME BIN_A BIN_B [plusargs...]
"""
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "core"))
from tracediff import run  # noqa: E402

MAIN = re.compile(r"^trace \d+ pc=([0-9a-f]{8}) inst=([0-9a-f]{8}) m=([0-9a-f]+)(?: x(\d+)=([0-9a-f]{8}))?$")
LANE = re.compile(r"^trace \d+   lane(\d+) x(\d+)=([0-9a-f]{8})$")
CYCLE = re.compile(r"^trace \d+ ")
SPIN = 0x0000006F            # jal x0, 0
POLL_LOOKAHEAD = 8           # retirements from the polled load to the loop branch
MASKED = "<timing>"


def sext(v, bits):
    return v - (1 << bits) if v & (1 << (bits - 1)) else v


def b_offset(inst):
    imm = (((inst >> 31) & 1) << 12) | (((inst >> 7) & 1) << 11) | \
          (((inst >> 25) & 0x3F) << 5) | (((inst >> 8) & 0xF) << 1)
    return sext(imm, 13)


def sources(inst):
    """Registers an instruction reads (enough for taint): rs1 except for
    LUI, AUIPC and JAL; rs2 for R-type, stores, branches and custom ops."""
    op = inst & 0x7F
    rs1, rs2 = (inst >> 15) & 31, (inst >> 20) & 31
    if op in (0x37, 0x17, 0x6F):
        return ()
    if op in (0x33, 0x23, 0x63, 0x0B, 0x2B, 0x5B):
        return (rs1, rs2)
    return (rs1,)


class Retire:
    """One retired instruction: its main line and lane lines, or a halt."""

    def __init__(self, text, pc=None, inst=None, mask=0, writes=None):
        self.text, self.pc, self.inst, self.mask = text, pc, inst, mask
        self.writes = writes or {}   # lane -> (rd, value)
        self.addrs = {}              # lane -> load address (loads only)
        self.tainted = set()         # lanes whose rd value is masked


def parse(lines):
    out = []
    for raw in lines:
        l = CYCLE.sub("trace ", raw, count=1)
        m = MAIN.match(raw)
        if m:
            r = Retire(l, int(m.group(1), 16), int(m.group(2), 16), int(m.group(3), 16))
            if m.group(4) is not None:
                r.writes[0] = (int(m.group(4)), int(m.group(5), 16))
            out.append(r)
            continue
        m = LANE.match(raw)
        if m and out and out[-1].pc is not None:
            out[-1].writes[int(m.group(1))] = (int(m.group(2)), int(m.group(3), 16))
            continue
        out.append(Retire(l))        # halt line
    return out


def model(trace, mask_addrs):
    """Replay register writes per lane: load addresses and CYCLES taint."""
    regs, taint = {}, {}
    for r in trace:
        if r.pc is None:
            continue
        op = r.inst & 0x7F
        lanes = [l for l in range(32) if (r.mask >> l) & 1] or [0]
        if op == 0x03:
            imm = sext(r.inst >> 20, 12)
            rs1 = (r.inst >> 15) & 31
            for l in lanes:
                base = 0 if rs1 == 0 else regs.get((l, rs1))
                if base is not None:
                    r.addrs[l] = (base + imm) & 0xFFFFFFFF
        src = sources(r.inst)
        any_t = any(taint.get((l, s)) for l in lanes for s in src if s)
        for l, (rd, v) in r.writes.items():
            if op == 0x03:
                t = r.addrs.get(l) in mask_addrs
            elif op in (0x0B, 0x2B, 0x5B):
                t = any_t
            else:
                t = any(taint.get((l, s)) for s in src if s)
            if rd:
                regs[(l, rd)] = v
                taint[(l, rd)] = t
            if t:
                r.tainted.add(l)


def find_polls(trace, poll_addrs):
    """pc ranges (lo, hi) of loops around loads from a polled address."""
    found = {}
    for i, r in enumerate(trace):
        hit = [a for a in r.addrs.values() if a in poll_addrs]
        if not hit:
            continue
        for b in trace[i + 1:i + 1 + POLL_LOOKAHEAD]:
            if b.pc is not None and b.inst & 0x7F == 0x63 and b_offset(b.inst) < 0:
                lo = (b.pc + b_offset(b.inst)) & 0xFFFFFFFF
                if lo <= r.pc:
                    found[(lo, b.pc)] = hit[0]
                    break
    return found


def normalize(trace, polls):
    """Lines to compare (text) with what each hides (info)."""
    out = []
    for r in trace:
        if r.pc is not None:
            region = next((k for k in polls if k[0] <= r.pc <= k[1]), None)
            if region:
                if out and out[-1][1] and out[-1][1][0] == "poll" and out[-1][1][1] == region:
                    out[-1][1][2] += r.pc == region[1]
                    out[-1][1][3].append(r)
                    continue
                out.append([f"poll {region[0]:08x}-{region[1]:08x}",
                            ["poll", region, int(r.pc == region[1]), [r]]])
                continue
            if r.inst == SPIN and out and out[-1][0] == r.text:
                continue
        text, vals = r.text, {}
        for l, (rd, v) in sorted(r.writes.items()):
            if l in r.tainted:
                vals[l] = (rd, v)
                if l == 0:
                    text = re.sub(r"=[0-9a-f]{8}$", "=" + MASKED, text)
                else:
                    text += f" / lane{l} x{rd}={MASKED}"
            elif l:
                text += f" / lane{l} x{rd}={v:08x}"
        out.append([text, ["mask", r, vals] if vals else None])
    return out


def compare(name, a, b, tail, labels):
    """Return (ok, message) for normalized traces a (reference) and b."""
    if not a:
        return False, f"tracediff {name}: empty trace"
    for i, (la, lb) in enumerate(zip(a, b)):
        if la[0] != lb[0]:
            ctx = "".join(f"    {a[j][0]}\n" for j in range(max(0, i - 3), i))
            return False, (f"tracediff {name}: first difference at trace line {i + 1}\n"
                           f"{ctx}  A {la[0]}\n  B {lb[0]}")
    # B may also end with the testbench's spin (jal x0, 0) that A had not
    # reached yet when the testbench called $finish: B is faster.
    spin = f"inst={SPIN:08x} "
    if len(b) > len(a) and not all(spin in l[0] for l in b[len(a):]):
        return False, (f"tracediff {name}: B retires {len(b) - len(a)} more line(s), "
                       f"first: {b[len(a)][0]}")
    extra = a[len(b):]
    if len(extra) > tail or any(" halt " in l[0] for l in extra):
        return False, (f"tracediff {name}: lengths differ, {len(a)} vs {len(b)} lines, "
                       f"first missing in B: {extra[0][0]}")
    msg = [f"tracediff {name}: PASS, {min(len(a), len(b))} trace lines identical (cycles ignored)"]
    for l in b[len(a):]:
        msg.append(f"  B only, the final spin (A had not reached it): {l[0]}")

    visits = {}
    for la, lb in zip(a, b):
        if la[1] and la[1][0] == "poll":
            visits.setdefault(la[1][1], []).append((la[1][2], lb[1][2]))
    for (lo, hi), v in sorted(visits.items()):
        it_a, it_b = sum(x for x, _ in v), sum(y for _, y in v)
        per = " ".join(f"{x}/{y}" for x, y in v)
        msg.append(f"  poll loop pc {lo:08x}-{hi:08x} on {labels.get((lo, hi), '?')}: "
                   f"{len(v)} visit(s), iterations A/B {it_a}/{it_b}: {per}")
    for la, lb in zip(a, b):
        if la[1] and la[1][0] == "mask":
            ra, va, vb = la[1][1], la[1][2], lb[1][2]
            for l in sorted(va):
                rd, x = va[l]
                y = vb[l][1]
                d = sext((y - x) & 0xFFFFFFFF, 32)
                src = "".join(f" from {labels.get(ad, f'{ad:08x}')}"
                              for ad in [ra.addrs.get(l)] if ad in labels) or " derived"
                msg.append(f"  masked pc {ra.pc:08x} lane {l} x{rd}{src}: "
                           f"A {x:08x} B {y:08x} (B - A = {d})")
    for l in extra:
        msg.append(f"  not retired by B at $finish: {l[0]}")
    return True, "\n".join(msg)


def spec(s):
    """ADDR[:NAME] -> (addr, name); LO-HI[:NAME] -> ((lo, hi), name)"""
    v, _, label = s.partition(":")
    if "-" in v:
        lo, hi = (int(x, 0) for x in v.split("-"))
        return (lo, hi), label or f"pc {lo:08x}-{hi:08x}"
    a = int(v, 0)
    return a, label or f"{a:08x}"


def main():
    args, tail, polls, masks = sys.argv[1:], 0, {}, {}
    while args and args[0] in ("--tail", "--poll", "--mask"):
        opt, val, args = args[0], args[1], args[2:]
        if opt == "--tail":
            tail = int(val)
        else:
            k, label = spec(val)
            (polls if opt == "--poll" else masks)[k] = label
    if len(args) < 3:
        sys.exit(__doc__)
    name, bin_a, bin_b, plusargs = args[0], args[1], args[2], args[3:]
    ta, tb = parse(run(bin_a, plusargs)), parse(run(bin_b, plusargs))
    model(ta, masks)
    model(tb, masks)

    poll_addrs = {k: v for k, v in polls.items() if isinstance(k, int)}
    labels = {**poll_addrs, **masks}
    ranges = {k: v for k, v in polls.items() if isinstance(k, tuple)}
    for t in (ta, tb):
        for rng, addr in find_polls(t, poll_addrs).items():
            ranges.setdefault(rng, poll_addrs[addr] + f" @{addr:08x}")
    labels.update(ranges)
    ok, msg = compare(name, normalize(ta, ranges), normalize(tb, ranges), tail, labels)
    print(msg)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
