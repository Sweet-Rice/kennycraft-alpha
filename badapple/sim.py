#!/usr/bin/env python3
"""Run the Bad Apple loader passes and the player in Verilator (kcvl).

    sim.py <img_dir> <run_dir> <video_frames> [--player-only]

kcvl must be built from this checkout with STAGE=2 PIPELINED=1
TEX_HEX=<run_dir>/textures.hex VL_MDIR=out/vl-ba (the top_s2p configuration).
DDR3 carries from one run to the next through the bench-only +ddr_load /
+ddr_save plusargs of tb/harness/stubs/mig_ddr3.sv, which stands in for DDR3
keeping its contents while the board is reprogrammed.

Every loader pass must report "ok". The player's first frame is its chunk
check screen; the next <video_frames> frames are compared pixel for pixel
with the encoder's reference frames.
"""

import os
import shutil
import subprocess
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KCVL = f"{ROOT}/out/vl-ba/kcvl"


def stage(img, run_dir):
    os.makedirs(f"{run_dir}/out", exist_ok=True)
    for f in ("kc_imem.hex", "kc_dmem.hex"):
        shutil.copy(f"{img}/{f}", f"{run_dir}/out/{f}")
    shutil.copy(f"{img}/textures.hex", f"{run_dir}/textures.hex")


def kcvl(run_dir, png_dir, args):
    os.makedirs(png_dir, exist_ok=True)
    p = subprocess.Popen([KCVL, "--headless", "--png-dir", png_dir, *args], cwd=run_dir,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    lines = []
    for line in p.stdout:
        lines.append(line)
        if line.startswith(("ba-", "halt", "ERR", "timeout", "kcvl")):
            print("  " + line.rstrip(), flush=True)
    return p.wait(), "".join(lines)


def ref_frame(ref, f):
    base = f * 2400
    bits = []
    for y in range(120):
        for j in range(5):
            w = int.from_bytes(ref[base + (y * 5 + j) * 4:base + (y * 5 + j) * 4 + 4], "little")
            bits += [(w >> i) & 1 for i in range(32)]
    return bits


def main():
    img, run_dir, frames = sys.argv[1], os.path.abspath(sys.argv[2]), int(sys.argv[3])
    player_only = "--player-only" in sys.argv[4:]
    os.makedirs(run_dir, exist_ok=True)
    passes = sorted(d for d in os.listdir(img) if d.startswith("pass_"))
    ddr = f"{run_dir}/ddr_{passes[-1]}.hex"

    if not player_only:
        prev = None
        for d in passes:
            stage(f"{img}/{d}", run_dir)
            save = f"{run_dir}/ddr_{d}.hex"
            args = ["--max-cycles", "40000000", f"+ddr_save={save}"]
            if prev:
                args.append(f"+ddr_load={prev}")
            print(f"{d}:", flush=True)
            rc, out = kcvl(run_dir, f"{run_dir}/png_{d}", args)
            if rc != 4 or " ok\n" not in out:
                sys.exit(f"sim.py: {d} failed (exit {rc})")
            prev = save

    stage(f"{img}/player", run_dir)
    print("player:", flush=True)
    png = f"{run_dir}/png_player"
    rc, out = kcvl(run_dir, png, ["--frames", str(frames + 1), f"+ddr_load={ddr}"])
    open(f"{run_dir}/player.log", "w").write(out)
    if rc != 0:
        sys.exit(f"sim.py: player exit {rc}")

    ref = open(f"{img}/ref.bin", "rb").read()
    bad = 0
    for f in range(frames):
        im = Image.open(f"{png}/frame_{f + 2:05d}.png").convert("RGB")
        got = [1 if r > 127 else 0 for r, _, _ in im.getdata()]
        if got != ref_frame(ref, f):
            bad += 1
            if bad <= 5:
                print(f"  frame {f}: {sum(a != b for a, b in zip(got, ref_frame(ref, f)))} pixels differ")
    print(f"player: {frames - bad} of {frames} video frames match the reference")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
