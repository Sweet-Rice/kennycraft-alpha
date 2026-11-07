#!/usr/bin/env python3
"""Golden camera shots: Kennedy's plain C reference against Verilator frames.

The reference is game/'s host renderer (make -C game shots), which writes each
shot's raw 320x240 back buffer to <ref-dir>/<name>.fb. For every shot in SHOTS
this builds tb/harness/shots/shot.c with the game sources for the chip, runs it
on kcvl and compares the first frame it swaps, pixel for pixel in RGB, with the
.fb shown through the game's palette (Bennett.md, Shared.md Verification).

Exit codes: 0 every shot matches, 1 a mismatch, 2-4 kcvl's own failure codes,
5 nothing could be compared (no shots, missing reference) or a tool failed.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
from PIL import Image
from pngdiff import compare

# Poses from game/host/main_host.c cmd_shots. Only the first host shot starts
# from a fresh boot, so it is the one the chip reproduces exactly.
SHOTS = {
    'g0_spawn': dict(w=160, dx=0, dy=0, dz=0, yaw=128, pitch=-40),
}


def game_variable(game, name):
    """A variable from game/Makefile, so the chip flags have one source."""
    result = subprocess.run(
        ['make', '-s', '--no-print-directory', '-C', str(game), '-f', 'Makefile', '-f', '-',
         'kc-print-variable'],
        input=f'kc-print-variable:\n\t@echo $({name})\n', text=True, capture_output=True, check=True)
    return result.stdout.split()


def load_palette(path):
    entries = [int(line.split('//')[0], 16) for line in path.read_text().splitlines()
               if line.split('//')[0].strip()]
    if len(entries) != 256:
        raise ValueError(f'{path}: expected 256 palette entries, found {len(entries)}')
    return [((c >> 8 & 15) * 17, (c >> 4 & 15) * 17, (c & 15) * 17) for c in entries]


def reference_png(fb, palette, width, output):
    data = fb.read_bytes()
    if len(data) != 320 * 240:
        raise ValueError(f'{fb}: expected 76800 bytes, found {len(data)}')
    height = width * 3 // 4
    pixels = bytearray()
    for y in range(height):
        for index in data[y * 320:y * 320 + width]:
            pixels.extend(palette[index])
    Image.frombytes('RGB', (width, height), bytes(pixels)).save(output)
    return output


def build_shot(args, name, pose, work):
    game = args.game_dir
    flags = game_variable(game, 'CHIP_FLAGS')
    sources = [game / s for s in game_variable(game, 'SRC')]
    loop = [s for s in sources if s.name == 'kc_main.c']
    if len(loop) != 1:
        raise ValueError('game SRC has no src/kc_main.c')
    defines = [f'-DKC_LANES={args.lanes}', f'-DKC_SHOT_W={pose["w"]}',
               f'-DKC_SHOT_DX={pose["dx"]}', f'-DKC_SHOT_DY={pose["dy"]}',
               f'-DKC_SHOT_DZ={pose["dz"]}', f'-DKC_SHOT_YAW={pose["yaw"]}',
               f'-DKC_SHOT_PITCH={pose["pitch"]}']
    cc = args.cc.split()
    # Compile from game/ like game/Makefile, whose flags use -Isrc -Igen.
    main_obj = (work / 'kc_main.o').resolve()
    subprocess.run([*cc, *flags, *defines, '-Dmain=kc_game_main', '-c', str(loop[0].resolve()),
                    '-o', str(main_obj)], cwd=game, check=True)
    elf = (work / 'kc.elf').resolve()
    rest = [str(s.resolve()) for s in sources if s not in loop]
    subprocess.run([*cc, *flags, *defines, '-T', str(Path('sw/kc.ld').resolve()),
                    str(Path('sw/crt0.S').resolve()), str(Path('tb/harness/shots/shot.c').resolve()),
                    *rest, str(main_obj), '-o', str(elf)], cwd=game, check=True)
    images = work / 'out'
    images.mkdir(exist_ok=True)
    for memory, sections, offset in (('imem', ['.text'], '0'), ('dmem', ['.rodata', '.data'], '0x100')):
        binary = images / f'kc_{memory}.bin'
        command = [args.objcopy, '-O', 'binary']
        for section in sections:
            command += ['-j', section]
        subprocess.run([*command, str(elf), str(binary)], check=True)
        subprocess.run([sys.executable, 'scripts/elf2hex.py', str(binary), str(images / f'kc_{memory}.hex'),
                        '--offset-bytes', offset, '--words', '8192'], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--binary', type=Path, required=True,
                        help='kcvl built with the game palette and textures (PAL_HEX, TEX_HEX)')
    parser.add_argument('--game-dir', type=Path, default=Path('game'))
    parser.add_argument('--ref-dir', type=Path, default=Path('game/out/shots'))
    parser.add_argument('--palette-hex', type=Path, default=Path('game/gen/palette.hex'))
    parser.add_argument('--cc', default='clang', help="game/Makefile's CHIP_CC")
    parser.add_argument('--objcopy', required=True)
    parser.add_argument('--lanes', type=int, default=1)
    parser.add_argument('--max-cycles', type=int, default=2_000_000_000)
    parser.add_argument('--work', type=Path, default=Path('out/golden'))
    args = parser.parse_args()
    try:
        if not SHOTS:
            print('golden: FAIL, no shots wired; nothing was compared', file=sys.stderr)
            return 5
        binary = args.binary.resolve(strict=True)
        palette = load_palette(args.palette_hex)
        for name, pose in SHOTS.items():
            reference = args.ref_dir / f'{name}.fb'
            if not reference.is_file():
                raise FileNotFoundError(f'no plain C reference {reference} (make -C game shots)')
            work = args.work / name
            if work.exists():
                shutil.rmtree(work)
            work.mkdir(parents=True)
            build_shot(args, name, pose, work)
            subprocess.run([str(binary), '--headless', '--frames', '1', '--max-cycles', str(args.max_cycles),
                            '--png-dir', 'frames'], cwd=work, check=True)
            expected = reference_png(reference, palette, pose['w'], work / 'reference.png')
            if compare(expected, work / 'frames' / 'frame_00001.png', work / 'diff.png'):
                print(f'golden: {name} FAIL (plain C {expected}, Verilator {work}/frames/frame_00001.png)')
                return 1
            print(f'golden: {name} PASS')
        return 0
    except subprocess.CalledProcessError as error:
        print(f'golden: command failed ({error.returncode}): {error.cmd}', file=sys.stderr)
        return error.returncode if 2 <= error.returncode <= 5 else 5
    except (OSError, ValueError) as error:
        print(f'golden: {error}', file=sys.stderr)
        return 5


if __name__ == '__main__':
    sys.exit(main())
