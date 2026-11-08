#!/usr/bin/env python3
"""Send the Doom DDR3 image to the board's bootloader over the UART.

Reads out/doom/ddr.manifest (`<hex DDR3 addr> <path>` per line), zero-fills the
gaps between 0x0010_0000 and the image end (the boot checksum covers them),
writes every file except the header, then the header last, then asks the
bootloader to check and boot ('G'). Protocol: doom/boot/boot.c, doom/README.md.
"""
import argparse
import struct
import sys
from pathlib import Path

import serial

IMG_START = 0x0010_0000
CHUNK = 4096


def ack(port, what):
    r = port.read(1)
    if r != b'A':
        raise RuntimeError(f'{what}: bootloader answered {r!r}')


def write(port, addr, blob):
    for off in range(0, len(blob), CHUNK):
        part = blob[off:off + CHUNK]
        for _ in range(3):
            port.write(b'W' + struct.pack('<II', addr + off, len(part)) + part
                       + struct.pack('<I', sum(part) & 0xFFFF_FFFF))
            if port.read(1) == b'A':
                break
        else:
            raise RuntimeError(f'write at {addr + off:#x} failed')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--manifest', type=Path, default=Path('out/doom/ddr.manifest'))
    p.add_argument('--port', default='/dev/ttyUSB1')
    p.add_argument('--baud', type=int, default=1_000_000)
    a = p.parse_args()

    files = []
    for line in a.manifest.read_text().splitlines():
        if line.strip():
            addr, path = line.split(None, 1)
            files.append((int(addr, 16), Path(path).read_bytes()))
    files.sort()
    header = [f for f in files if f[0] == 0]
    body = [f for f in files if f[0] != 0]
    if len(header) != 1:
        print('doom_load: manifest needs exactly one file at address 0', file=sys.stderr)
        return 1
    end = struct.unpack('<4I', header[0][1][:16])[2]

    with serial.Serial(a.port, a.baud, timeout=10) as port:
        port.reset_input_buffer()      # the bootloader's start-up log
        pos = IMG_START
        for addr, blob in body + [(end, b'')]:
            if addr > pos:
                gap = (addr - pos + 3) // 4 * 4
                print(f'doom_load: zero {pos:#010x}+{gap:#x}')
                port.write(b'Z' + struct.pack('<II', pos, gap))
                ack(port, 'zero')
            if blob:
                print(f'doom_load: write {addr:#010x}+{len(blob):#x}')
                write(port, addr, blob)
            pos = max(pos, addr + len(blob))
        write(port, 0, header[0][1])
        port.write(b'G')
        while (r := port.read(1)) not in (b'A', b'N'):   # the check logs lowercase text first
            if not r:
                raise RuntimeError('boot: no answer')
            sys.stdout.write(r.decode(errors='replace'))
        if r != b'A':
            raise RuntimeError('boot: image check failed')
        print('doom_load: booted')
    return 0


if __name__ == '__main__':
    sys.exit(main())
