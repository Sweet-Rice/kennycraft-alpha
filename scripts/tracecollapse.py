#!/usr/bin/env python3
"""Compare two kcvl retire traces, collapsing MMIO poll loops that ran a different count.

Two cores with different CPI retire the same instructions except where the program
polls a timing-dependent MMIO register (DDR_STATUS, FB_SWAP, CHUNK_DONE, UART_STATUS,
CYCLES, ...) in a loop: there the iteration counts, and the values the loop loaded,
differ. At a mismatch this checks whether both traces sit in the same loop whose
body loads from MMIO; if so it skips both traces to the loop exit and records the
region (PC range, MMIO registers read, iterations on each side) instead of failing.
Anything else, including an MMIO read outside a loop, is a real mismatch and is
reported with five lines of context and the MMIO register, if any.

Lane 0's registers are rebuilt from the trace's own rd writes (lane:xN=value) to
compute each load's address. Every collapsed region is listed, so nothing is
hidden; exit 0 means the traces match apart from the listed regions.
"""
import argparse
from collections import deque
import sys

MMIO_BASE = 0x5000_0000
MMIO_END = 0x5000_1000
MMIO_NAMES = {0x00: 'FB_SWAP', 0x04: 'FRAME_COUNT', 0x08: 'VSYNC', 0x0C: 'CYCLES',
              0x10: 'UART_RX', 0x14: 'UART_STATUS', 0x18: 'UART_TX', 0x1C: 'ERR',
              0x20: 'ERR_PC', 0x24: 'LEDS', 0x28: 'FB_MODE', 0x2C: 'DDR_STATUS',
              0x30: 'CHUNK_CMD', 0x34: 'CHUNK_DONE', 0x38: 'SLOT_VALID', 0x3C: 'WIN_ORIGIN'}
HISTORY = 4096        # lines of common history kept to find a loop body
MAX_BODY = 64         # longest loop body (lines) treated as a poll loop


def mmio_name(address):
    offset = address - MMIO_BASE
    return MMIO_NAMES.get(offset, f'0x{address:08x}')


class Trace:
    """One trace: lines with their lane-0 MMIO load address (or None)."""

    def __init__(self, lines, name):
        self.lines = lines
        self.name = name
        self.regs = [0] * 32
        self.n = 0
        self.ahead = deque()

    def _parse(self, text):
        line = text.rstrip('\r\n')
        pc = int(line[0:8], 16)
        instr = int(line[9:17], 16)
        address = None
        if instr & 0x7F == 0x03:                                   # load
            imm = instr >> 20
            imm -= (imm & 0x800) << 1
            address = (self.regs[(instr >> 15) & 31] + imm) & 0xFFFF_FFFF
            if not MMIO_BASE <= address < MMIO_END:
                address = None
        at = line.find(' 0:x')
        if at >= 0:
            end = line.find(' ', at + 1)
            reg, value = line[at + 4:end if end >= 0 else None].split('=')
            self.regs[int(reg)] = int(value, 16)
        return line, pc, address

    def peek(self, k=0):
        """The k-th line from here (0: the next one), or None past the end."""
        while len(self.ahead) <= k:
            text = next(self.lines, None)
            if text is None:
                return None
            self.ahead.append(self._parse(text))
        return self.ahead[k]

    def take(self):
        record = self.peek()
        if record is not None:
            self.ahead.popleft()
            self.n += 1
        return record


def find_loop(history, head):
    """The loop around `head`: the lines since its previous occurrence.

    A PC recurs only through a backward jump, so any recurrence within MAX_BODY lines
    is a loop, wherever `head` sits in it (the caller still requires an MMIO read).
    The loop's own head may come before the MMIO load, as in `li t4, MMIO; lw; bnez`.
    """
    body = []
    for line, pc, address in reversed(history):
        body.append((pc, address))
        if pc == head:
            return body if len(body) > 1 else None
        if len(body) > MAX_BODY:
            return None
    return None


def find_loop_ahead(trace, head):
    """The loop through `head` in trace's next lines: up to its next occurrence."""
    body = []
    for k in range(MAX_BODY):
        record = trace.peek(k)
        if record is None:
            return None
        if k and record[1] == head:
            return body
        body.append((record[1], record[2]))
    return None


def compare_collapsed(left, right, a, b, out=sys.stdout):
    ta, tb = Trace(iter(left), a), Trace(iter(right), b)
    history = deque(maxlen=HISTORY)
    regions = []
    status = 0
    while True:
        ra, rb = ta.peek(), tb.peek()
        if ra is None or rb is None:
            if ra is not rb:
                print(f'trace {a if ra is None else b} ends at line {(ta if ra is None else tb).n + 1}', file=out)
                status = 1
            break
        if ra[0] == rb[0]:
            history.append(ta.take())
            tb.take()
            continue
        # Loop head: the PC both are at, or (they left the loop at different times) the
        # last common one.
        head = ra[1] if ra[1] == rb[1] else (history[-1][1] if history else None)
        body = None
        if head is not None:
            # A loop seen in the common history, or else one that a trace is about to
            # repeat (the other side ran it fewer times, possibly once).
            body = find_loop(list(history)[:-1] if ra[1] != rb[1] else history, head)
            if not body and ra[1] == rb[1]:
                body = find_loop_ahead(ta, head) or find_loop_ahead(tb, head)
        if body and any(address is not None for _, address in body):
            pcs = {pc for pc, _ in body}
            prior = 0
            for line, pc, _ in reversed(history):
                if pc not in pcs:
                    break
                prior += pc == head
            counts, reads = [], set()
            for trace in (ta, tb):
                count = prior
                while (record := trace.peek()) is not None and record[1] in pcs:
                    count += record[1] == head
                    if record[2] is not None:
                        reads.add(record[2])
                    trace.take()
                counts.append(count)
            reads |= {address for _, address in body if address is not None}
            regions.append((min(pcs), max(pcs), sorted(reads), counts[0], counts[1], ta.n, tb.n))
            history.clear()
            continue
        print(f'trace differs at line {ta.n + 1} of A, {tb.n + 1} of B (A {a}, B {b})', file=out)
        for line, _, _ in list(history)[-5:]:
            print(f'  {line}', file=out)
        for label, record in (('A', ra), ('B', rb)):
            note = f'   <- MMIO {mmio_name(record[2])} read' if record[2] is not None else ''
            print(f'{label}: {record[0]}{note}', file=out)
        status = 1
        break
    for lo, hi, reads, ca, cb, la, lb in regions:
        print(f'collapsed poll loop pc 0x{lo:08x}-0x{hi:08x} reading '
              f'{", ".join(mmio_name(r) for r in reads)}: {ca} iteration(s) in A, {cb} in B '
              f'(resumes at line {la + 1} of A, {lb + 1} of B)', file=out)
    print(f'tracecollapse: {len(regions)} poll loop(s) collapsed, '
          + ('traces otherwise identical' if status == 0 else 'mismatch above'), file=out)
    return status


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('a')
    parser.add_argument('b')
    args = parser.parse_args()
    try:
        with open(args.a, encoding='utf-8', errors='replace') as left, \
             open(args.b, encoding='utf-8', errors='replace') as right:
            return compare_collapsed(left, right, args.a, args.b)
    except (OSError, ValueError) as error:
        print(f'tracecollapse: {error}', file=sys.stderr)
        return 5


if __name__ == '__main__':
    sys.exit(main())
