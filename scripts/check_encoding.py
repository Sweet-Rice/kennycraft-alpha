#!/usr/bin/env python3
"""Check the assembler encodings of every KennyCraft custom instruction.

Assembles sw/tests/encoding.S with the RISC-V GCC toolchain, disassembles the
object with objdump, and compares each instruction word against the Example
hex column of the Tai_2 section 1 encoding table (in table order).

With --wiki PATH (the wiki checkout's Tai_2.md), the table is also parsed from
the wiki and must match the copy below exactly, so drift between the wiki and
this repo is caught.

Exits 0 only if every word matches.
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile

# Tai_2 section 1, "Custom instruction formats": (name, Example hex).
TABLE = [
    ("LANEID", 0x0000050B),
    ("LMASK", 0x0005900B),
    ("QRCP", 0x0005A50B),
    ("BALLOT", 0x0005B50B),
    ("MASKGET", 0x0000550B),
    ("MASKSET", 0x0005E00B),
    ("MASKALL", 0x0000700B),
    ("VSET", 0x0605802B),
    ("VTRACE", 0x0005952B),
    ("VGET", 0x0200252B),
    ("DIF", 0x0005885B),
    ("DELSE", 0x0000145B),
    ("DENDIF", 0x0000205B),
]
# Words after the table in encoding.S: the DELSE and DIF branch targets.
TRAILER = [("nop", 0x00000013), ("nop", 0x00000013)]

DEFAULT_PREFIX = "/home/tai/AMD/2026.1/gnu/riscv/lin/bin/riscv64-unknown-elf-"
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def parse_wiki(path):
    """Return [(name, hex)] from the Tai_2 custom instruction table."""
    rows = []
    in_section = False
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("### "):
                in_section = line.startswith("### Custom instruction formats")
                continue
            if not in_section or not line.startswith("|"):
                continue
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            m = re.search(r"`0x([0-9A-Fa-f]{8})`", cells[-1])
            if not m:
                continue  # header or separator
            rows.append((cells[0].split()[0], int(m.group(1), 16)))
    return rows


def objdump_words(prefix, src, workdir):
    # .insn b leaves R_RISCV_BRANCH relocations in the object, so link at
    # address 0 and disassemble the linked image, where they are resolved.
    obj = os.path.join(workdir, "encoding.o")
    elf = os.path.join(workdir, "encoding.elf")
    subprocess.run(
        [prefix + "gcc", "-march=rv32i_zmmul", "-mabi=ilp32", "-mno-relax",
         "-c", src, "-o", obj],
        check=True)
    subprocess.run(
        [prefix + "ld", "-m", "elf32lriscv", "--no-relax", "-Ttext=0",
         "-e", "encoding_table", obj, "-o", elf],
        check=True)
    dis = subprocess.run([prefix + "objdump", "-d", elf], check=True,
                         capture_output=True, text=True).stdout
    words = []
    for line in dis.splitlines():
        m = re.match(r"^\s*([0-9a-f]+):\s+([0-9a-f]{8})\s+(.*)$", line)
        if m:
            words.append((int(m.group(1), 16), int(m.group(2), 16), m.group(3).strip()))
    return words


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--prefix", default=os.environ.get("RISCV_PREFIX", DEFAULT_PREFIX),
                    help="toolchain prefix (default: $RISCV_PREFIX or the AMD bundle)")
    ap.add_argument("--src", default=os.path.join(REPO, "sw", "tests", "encoding.S"))
    ap.add_argument("--wiki", help="path to the wiki's Tai_2.md for a cross-check")
    args = ap.parse_args()

    fail = 0
    if args.wiki:
        wiki = parse_wiki(args.wiki)
        if wiki != TABLE:
            fail += 1
            print("FAIL wiki table differs from scripts/check_encoding.py TABLE")
            print("  wiki:  " + ", ".join(f"{n}=0x{h:08X}" for n, h in wiki))
        else:
            print(f"wiki table matches ({len(wiki)} rows from {args.wiki})")

    with tempfile.TemporaryDirectory() as tmp:
        words = objdump_words(args.prefix, args.src, tmp)

    expected = TABLE + TRAILER
    if len(words) != len(expected):
        print(f"FAIL objdump shows {len(words)} words, expected {len(expected)}")
        fail += 1
    for i, ((name, want), (addr, got, text)) in enumerate(zip(expected, words)):
        ok = got == want and addr == 4 * i
        print(f"{'ok  ' if ok else 'FAIL'} {name:8s} @{addr:02x} objdump 0x{got:08X}"
              f" table 0x{want:08X}  {text}")
        fail += not ok

    if fail:
        print(f"check_encoding: FAIL ({fail} mismatches)")
        return 1
    print(f"check_encoding: PASS ({len(TABLE)} custom instructions match Tai_2)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
