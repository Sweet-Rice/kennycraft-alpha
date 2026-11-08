#!/usr/bin/env python3
"""Doom DDR3 image: boot header and the simulation preload manifest.

DDR3 layout (doom/README.md): header @0, .text @0x0010_0000, WAD @0x0040_0000,
.rodata/.data @0x0100_0000. Header = u32 magic 'KCDM', entry PC, image end,
checksum = sum of the u32 words from 0x0010_0000 to end, skipping the WAD area
0x0040_0000..0x00FF_FFFF (boot time; gaps read as 0: the
model's unwritten memory is 0 and doom_load.py zero-fills them on the board).
"""
import argparse
import struct
import sys
from pathlib import Path

MAGIC = 0x4D44434B
TEXT, WAD, DATA, LIMIT = 0x0010_0000, 0x0040_0000, 0x0100_0000, 0x0F00_0000


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--text', type=Path, required=True)
    p.add_argument('--data', type=Path, required=True)
    p.add_argument('--wad', type=Path, required=True)
    p.add_argument('--entry', type=lambda s: int(s, 0), required=True)
    p.add_argument('--header', type=Path, required=True)
    p.add_argument('--manifest', type=Path, required=True)
    a = p.parse_args()
    text, data, wad = a.text.read_bytes(), a.data.read_bytes(), a.wad.read_bytes()
    parts = [(TEXT, text, WAD), (WAD, wad, DATA), (DATA, data, LIMIT)]
    s = 0
    for base, blob, limit in parts:
        if base + len(blob) > limit:
            print(f'mkimage: {len(blob)} bytes at {base:#x} overrun {limit:#x}', file=sys.stderr)
            return 1
        blob += bytes(-len(blob) % 4)
        if base != WAD:                 # the WAD area is not summed (boot time)
            s += sum(struct.unpack(f'<{len(blob) // 4}I', blob))
    end = DATA + (len(data) + 3) // 4 * 4
    a.header.write_bytes(struct.pack('<4I', MAGIC, a.entry, end, s & 0xFFFF_FFFF))
    a.manifest.write_text(f'{0:08x} {a.header.resolve()}\n'
                          f'{TEXT:08x} {a.text.resolve()}\n'
                          f'{WAD:08x} {a.wad.resolve()}\n'
                          f'{DATA:08x} {a.data.resolve()}\n')
    print(f'mkimage: entry {a.entry:#x}, end {end:#x}, checksum {s & 0xFFFF_FFFF:#010x}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
