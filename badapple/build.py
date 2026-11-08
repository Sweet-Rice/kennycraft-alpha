#!/usr/bin/env python3
"""Build the Bad Apple loader passes and the player for the current bitstream.

    build.py <video> <out_dir>

1. ffmpeg scales the video to 160 x 120 gray; ba_tool (host C, the chip's
   codec) codes it, writes the reference frames and checks a full decode.
2. The DDR3 image is the header chunk plus the stream, zero-padded to whole
   4 KB chunks (badapple/ba_chip.h).
3. The image is cut into passes that fill a loader's free data memory and
   all of texture memory. Each pass and the player get a directory with
   kc_imem.hex, kc_dmem.hex and textures.hex in the formats rtl/top.sv reads
   and fpga/patch_bit.sh patches (data memory 0x6000-0x7FFF stays 0, like
   the bitstream's).
"""

import os
import shutil
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
GCC = "/home/tai/AMD/2026.1/gnu/riscv/lin/bin/riscv64-unknown-elf-"
CFLAGS = ["-march=rv32i_zmmul", "-mabi=ilp32", "-O2", "-ffreestanding", "-nostdlib", "-fno-builtin",
          "-msmall-data-limit=0", "-Wall", "-Wextra", "-Werror", "-DKC_CHIP", f"-I{HERE}"]
LDFLAGS = ["-T", f"{ROOT}/sw/kc.ld", "-nostdlib", "-Wl,--build-id=none"]
CHUNK = 4096
TEX_BYTES = 16384 // 2          # 16 K four-bit cells, two per byte
DMEM_DATA = 0x5F00              # sw/kc.ld DMEM: 0x1000_0100 .. 0x1000_5FFF
MAGIC, VERSION, MAX_CHUNKS = 0x4C504142, 1, (CHUNK - 32) // 4


def run(*cmd, **kw):
    subprocess.run(cmd, check=True, **kw)


def chunk_sum(data):
    a, b = 1, 0
    for v in data:
        a = (a + v) & 0xFFFFFFFF
        b = (b + a) & 0xFFFFFFFF
    return (a ^ (b << 16) ^ (b >> 16)) & 0xFFFFFFFF


def link(out, sources):
    """Compile and link a chip program; write its imem/dmem hex into out."""
    os.makedirs(out, exist_ok=True)
    elf = f"{out}/kc.elf"
    run(f"{GCC}gcc", *CFLAGS, *LDFLAGS, f"-Wl,-Map,{out}/kc.map", f"{ROOT}/sw/crt0.S", *sources, "-lgcc", "-o", elf)
    run(f"{GCC}objcopy", "-O", "binary", "-j", ".text", elf, f"{out}/imem.bin")
    run(f"{GCC}objcopy", "-O", "binary", "-j", ".rodata", "-j", ".data", elf, f"{out}/dmem.bin")
    run(sys.executable, f"{ROOT}/scripts/elf2hex.py", f"{out}/imem.bin", f"{out}/kc_imem.hex",
        "--offset-bytes", "0", "--words", "8192", "--nonempty")
    run(sys.executable, f"{ROOT}/scripts/elf2hex.py", f"{out}/dmem.bin", f"{out}/kc_dmem.hex",
        "--offset-bytes", "0x100", "--words", "8192")
    for f in ("imem.bin", "dmem.bin"):
        os.remove(f"{out}/{f}")
    return elf


def dmem_end(elf):
    """First byte past .rodata/.data/.bss, relative to 0x1000_0100."""
    out = subprocess.run([f"{GCC}nm", elf], check=True, capture_output=True, text=True).stdout
    syms = {l.split()[2]: int(l.split()[0], 16) for l in out.splitlines() if len(l.split()) == 3}
    return syms["__bss_end"] - 0x10000100


def write_tex(path, payload):
    cells = []
    for v in payload:
        cells += [v & 15, v >> 4]
    cells += [0] * (2 * TEX_BYTES - len(cells))
    with open(path, "w") as f:
        f.write("".join(f"{c:x}\n" for c in cells))


def pass_source(path, index, count, start, dmem_len, tex_len, bin_path):
    with open(path, "w") as f:
        f.write(f"""    .section .rodata
    .balign 4
    .globl ba_pass_index, ba_pass_count, ba_pass_start, ba_pass_dmem_len, ba_pass_tex_len, ba_pass_dmem
ba_pass_index:    .word {index}
ba_pass_count:    .word {count}
ba_pass_start:    .word {start}
ba_pass_dmem_len: .word {dmem_len}
ba_pass_tex_len:  .word {tex_len}
ba_pass_dmem:
""" + (f'    .incbin "{bin_path}"\n' if dmem_len else ""))


def main():
    video, out = sys.argv[1], os.path.abspath(sys.argv[2])
    os.makedirs(out, exist_ok=True)

    tool = f"{out}/ba_tool"
    run("zig", "cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", f"{HERE}/ba_tool.c", "-o", tool)
    run("ffmpeg", "-v", "error", "-y", "-i", video, "-vf", "scale=160:120:flags=area,format=gray",
        "-f", "rawvideo", f"{out}/frames.gray")
    run(tool, "enc", f"{out}/frames.gray", f"{out}/stream.bin", f"{out}/ref.bin")
    run(tool, "check", f"{out}/stream.bin", f"{out}/ref.bin")
    os.remove(f"{out}/frames.gray")

    stream = open(f"{out}/stream.bin", "rb").read()
    frames = os.path.getsize(f"{out}/ref.bin") // (160 * 120 // 8)
    data = stream + bytes(-len(stream) % CHUNK)
    chunks = len(data) // CHUNK
    if chunks > MAX_CHUNKS:
        sys.exit(f"build.py: {chunks} chunks do not fit one header ({MAX_CHUNKS})")
    sums = [chunk_sum(data[i * CHUNK:(i + 1) * CHUNK]) for i in range(chunks)]

    # Player first: its data memory use bounds nothing, but a failure here is cheap.
    link(f"{out}/player", [f"{HERE}/player.c"])
    write_tex(f"{out}/player/textures.hex", b"")

    # Measure the loader's own data memory with an empty slice, then size the slices.
    probe = f"{out}/probe"
    os.makedirs(probe, exist_ok=True)
    pass_source(f"{probe}/pass.S", 0, 1, 0, 0, 0, "")
    used = dmem_end(link(probe, [f"{HERE}/loader.c", f"{probe}/pass.S"]))
    shutil.rmtree(probe)
    dmem_cap = (DMEM_DATA - used - 64) & ~3
    per_pass = dmem_cap + TEX_BYTES

    header = struct.pack("<8I", MAGIC, VERSION, frames, len(stream), chunks, 0, 0, 0)
    image = bytearray(header + struct.pack(f"<{chunks}I", *sums))
    image += bytes(CHUNK - len(image))
    image += data
    passes = (len(image) + per_pass - 1) // per_pass
    struct.pack_into("<I", image, 20, passes)

    for k in range(passes):
        d = f"{out}/pass_{k + 1:02d}"
        os.makedirs(d, exist_ok=True)
        part = image[k * per_pass:(k + 1) * per_pass]
        dm, tx = part[:dmem_cap], part[dmem_cap:]
        open(f"{d}/payload.bin", "wb").write(dm)
        pass_source(f"{d}/pass.S", k, passes, k * per_pass, len(dm), len(tx), f"{d}/payload.bin")
        elf = link(d, [f"{HERE}/loader.c", f"{d}/pass.S"])
        if dmem_end(elf) > DMEM_DATA:
            sys.exit(f"build.py: pass {k + 1} overflows data memory")
        write_tex(f"{d}/textures.hex", tx)

    open(f"{out}/image.bin", "wb").write(image)
    print(f"frames {frames}, stream {len(stream)} B, {chunks} data chunks, image {len(image)} B")
    print(f"loader data memory {used} B, slice {dmem_cap} B dmem + {TEX_BYTES} B tex = {per_pass} B")
    print(f"{passes} loader passes in {out}/pass_NN, player in {out}/player")


if __name__ == "__main__":
    main()
