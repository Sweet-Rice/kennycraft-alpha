#!/usr/bin/env python3
"""Run approved replay shots, or explicitly replace a named golden frame."""
import argparse
from pathlib import Path
import re
import shutil
import subprocess
import sys
from pngdiff import compare


def run(binary, keys, frames, output):
    output.mkdir(parents=True, exist_ok=True)
    command = [str(binary), '--headless', '--keys', str(keys), '--frames', str(frames),
               '--png-dir', str(output)]
    subprocess.run(command, check=True)
    shot = output / f'frame_{frames:05d}.png'
    if not shot.is_file():
        raise FileNotFoundError(f'kcvl did not produce expected frame: {shot}')
    return shot


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('check', 'update'))
    parser.add_argument('--binary', type=Path, default=Path('out/vl/kcvl'))
    parser.add_argument('--golden-dir', type=Path, default=Path('sw/golden'))
    parser.add_argument('--name')
    parser.add_argument('--frames', type=int)
    parser.add_argument('--keys', type=Path)
    args = parser.parse_args()
    try:
        if args.action == 'check':
            shots = sorted(args.golden_dir.glob('*_f*.png')) if args.golden_dir.exists() else []
            if not shots:
                print('golden: no approved shots')
                return 0
        binary = args.binary.resolve(strict=True)
        if args.action == 'update':
            if not args.name or not re.fullmatch(r'[A-Za-z0-9_-]+', args.name):
                parser.error('update needs --name with letters, digits, _ or -')
            if not args.frames or args.frames < 1 or args.keys is None:
                parser.error('update needs positive --frames and --keys')
            keys = args.keys.resolve(strict=True)
            shot = run(binary, keys, args.frames, Path('out/golden') / args.name / 'update')
            args.golden_dir.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(shot, args.golden_dir / f'{args.name}_f{args.frames}.png')
            destination = args.golden_dir / f'{args.name}.keys'
            try:
                if not destination.exists() or destination.resolve() != keys:
                    shutil.copyfile(keys, destination)
            except shutil.SameFileError:
                pass
            print(f'golden: updated {args.name} frame {args.frames}; review before committing')
            return 0
        for golden in shots:
            match = re.fullmatch(r'(.+)_f([1-9][0-9]*)\.png', golden.name)
            if not match:
                raise ValueError(f'bad golden filename: {golden}')
            name, frame = match.group(1), int(match.group(2))
            keys = (args.golden_dir / f'{name}.keys').resolve(strict=True)
            shot = run(binary, keys, frame, Path('out/golden') / name / f'f{frame}')
            if compare(golden, shot, Path('out/golden') / f'{name}_diff.png'):
                return 1
            print(f'golden: {name} frame {frame} PASS')
        return 0
    except subprocess.CalledProcessError as error:
        return error.returncode if 1 <= error.returncode <= 5 else 5
    except (OSError, ValueError) as error:
        print(f'golden: {error}', file=sys.stderr)
        return 5


if __name__ == '__main__':
    sys.exit(main())
