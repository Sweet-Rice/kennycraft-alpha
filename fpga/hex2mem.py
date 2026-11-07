#!/usr/bin/env python3
"""Turn a $readmemh image (one word per line) into an updatemem MEM file.

    hex2mem.py <in.hex> <out.mem> <width_bits>

Each input line is one memory word of width_bits (kc_imem.hex / kc_dmem.hex:
32, textures.hex: 4). The MEM file starts at address 0 and
holds one word per entry, written with ceil(width / 4) hex digits, which is
how updatemem reads words of an address space whose bit lanes add up to
width bits (fpga/kc_mmi.tcl).
"""

import sys


def main():
    src, dst, width = sys.argv[1], sys.argv[2], int(sys.argv[3])
    digits = (width + 3) // 4
    words = []
    with open(src, encoding="ascii") as f:
        for line in f:
            line = line.split("//")[0].strip()
            if not line:
                continue
            if line.startswith("@"):
                sys.exit(f"hex2mem: {src}: address records are not supported")
            v = int(line, 16)
            if v >> width:
                sys.exit(f"hex2mem: {src}: {line} does not fit in {width} bits")
            words.append(v)
    with open(dst, "w", encoding="ascii", newline="\n") as out:
        out.write("@00000000\n")
        for i in range(0, len(words), 8):
            out.write(" ".join(f"{w:0{digits}X}" for w in words[i:i + 8]) + "\n")


if __name__ == "__main__":
    main()
