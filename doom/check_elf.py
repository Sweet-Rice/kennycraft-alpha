#!/usr/bin/env python3
"""Static checks on the Doom ELF for the KennyCraft core.

1. Every instruction in .text is one the core executes: 32-bit only (no
   compressed), RV32I + Zmmul (MUL/MULH/MULHSU/MULHU), FENCE (a no-op), and the
   custom-0/1/2 opcodes; no SYSTEM (ECALL/EBREAK/CSR*), no DIV/REM, no A/F/D
   (rtl/kc_isa_pkg.sv, rtl/core decoder, wiki Tai_2).
2. Memory layout: .text inside --code (fetch-only for Doom: loads there read 0)
   and every other allocated section inside --data; with --min-heap, the heap
   between _end and __stack_limit holds at least that many bytes.
"""
import argparse
import re
import subprocess
import sys


LEGAL_OPC = {0x03, 0x0F, 0x13, 0x17, 0x23, 0x33, 0x37, 0x63, 0x67, 0x6F, 0x0B, 0x2B, 0x5B}
BAD_MNEMONIC = re.compile(
    r'^(ecall|ebreak|uret|sret|mret|wfi|csr\w*|fence\.i|div\w*|rem\w*|lr\.\w+|sc\.\w+|amo\w+|'
    r'f(l|s)[whd]|f\w+\.[sdq]|c\.\w+|unimp)$')


def check_insn(w):
    """Reason the core rejects instruction word w, or None."""
    opc = w & 0x7F
    f3 = (w >> 12) & 7
    f7 = w >> 25
    if w & 3 != 3:
        return 'compressed'
    if opc not in LEGAL_OPC:
        return f'opcode {opc:#04x}'
    if opc == 0x03 and f3 in (3, 6, 7):
        return 'load width'
    if opc == 0x23 and f3 > 2:
        return 'store width'
    if opc == 0x13 and f3 == 1 and f7 != 0:
        return 'slli funct7'
    if opc == 0x13 and f3 == 5 and f7 not in (0x00, 0x20):
        return 'srli/srai funct7'
    if opc == 0x33:
        if f7 == 0x01:
            return 'div/rem' if f3 >= 4 else None
        if f7 == 0x20 and f3 not in (0, 5):
            return 'op funct7'
        if f7 not in (0x00, 0x20):
            return 'op funct7'
    if opc == 0x0F and f3 == 1:
        return 'fence.i'
    if opc in (0x63,) and f3 in (2, 3):
        return 'branch funct3'
    if opc == 0x67 and f3 != 0:
        return 'jalr funct3'
    return None


def sections(objdump, elf):
    out = subprocess.run([objdump, '-h', '-w', elf], check=True, capture_output=True, text=True).stdout
    res = []
    for line in out.splitlines():
        m = re.match(r'\s*\d+\s+(\S+)\s+([0-9a-f]+)\s+([0-9a-f]+)\s+[0-9a-f]+\s+[0-9a-f]+\s+\S+\s+(.*)', line)
        if m:
            res.append((m.group(1), int(m.group(2), 16), int(m.group(3), 16), m.group(4)))
    return res


def symbols(nm, elf):
    out = subprocess.run([nm, elf], check=True, capture_output=True, text=True).stdout
    syms = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 3:
            syms[parts[2]] = int(parts[0], 16)
    return syms


def main():
    p = argparse.ArgumentParser()
    p.add_argument('elf')
    p.add_argument('--objdump', required=True)
    p.add_argument('--nm', required=True)
    p.add_argument('--code', required=True, help='lo:len of the .text region')
    p.add_argument('--data', required=True, help='lo:len of the data region')
    p.add_argument('--min-heap', type=lambda s: int(s, 0), default=None)
    a = p.parse_args()
    errors = []
    code, data = ([int(x, 0) for x in r.split(':')] for r in (a.code, a.data))

    # ---- instructions ----
    dis = subprocess.run([a.objdump, '-d', '-M', 'no-aliases', '-j', '.text', a.elf],
                         check=True, capture_output=True, text=True).stdout
    n = 0
    bad = []
    mnemonics = {}
    for line in dis.splitlines():
        m = re.match(r'\s*([0-9a-f]+):\s+([0-9a-f]+)\s+(\S+)', line)
        if not m:
            continue
        n += 1
        addr, enc, mn = int(m.group(1), 16), m.group(2), m.group(3)
        mnemonics[mn] = mnemonics.get(mn, 0) + 1
        why = 'compressed' if len(enc) != 8 else check_insn(int(enc, 16))
        if why is None and BAD_MNEMONIC.match(mn):
            why = f'mnemonic {mn}'
        if why:
            bad.append(f'{addr:#010x}: {enc} {mn} ({why})')
    print(f'check_elf: {n} instructions in .text, {len(mnemonics)} distinct mnemonics')
    print('check_elf: illegal-instruction scan: ' + (f'{len(bad)} FOUND' if bad else 'none'))
    for b in bad[:50]:
        print('  ' + b)
    if bad:
        errors.append('illegal instructions')

    # ---- layout ----
    for name, size, vma, flags in sections(a.objdump, a.elf):
        if 'ALLOC' not in flags or size == 0:
            continue
        lo, ln = code if name == '.text' else data
        ok = lo <= vma and vma + size <= lo + ln
        print(f'check_elf: {name:10s} {vma:#010x} {size:9d} bytes {"" if ok else "OUT OF RANGE"}')
        if not ok:
            errors.append(f'{name} outside its memory')
    syms = symbols(a.nm, a.elf)
    if a.min_heap is not None:
        heap = syms['__stack_limit'] - syms['_end']
        stack = syms['__stack_top'] - syms['__stack_limit']
        print(f'check_elf: heap {heap} bytes ({heap / (1 << 20):.2f} MiB), stack {stack} bytes')
        if heap < a.min_heap:
            errors.append(f'heap {heap} < {a.min_heap}')

    for e in errors:
        print(f'check_elf: FAIL: {e}', file=sys.stderr)
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
