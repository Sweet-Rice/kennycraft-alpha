#!/usr/bin/env python3
"""Build a git reference in out/ref and compare two real chip retire traces."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
from tracediff import compare


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ref', required=True)
    parser.add_argument('--frames', type=int, default=5)
    parser.add_argument('--keys', type=Path)
    parser.add_argument('--palette-hex', type=Path)
    parser.add_argument('--texture-hex', type=Path)
    args = parser.parse_args()
    if args.frames < 1:
        parser.error('--frames must be positive')
    root = Path.cwd()
    reference = root / 'out/ref'
    traces = root / 'out/traces'
    created = False
    try:
        if reference.exists():
            raise ValueError('out/ref already exists; remove its git worktree before comparing')
        binary = (root / 'out/vl/kcvl').resolve(strict=True)
        images = [(root / 'out' / name).resolve(strict=True)
                  for name in ('kc_imem.hex', 'kc_dmem.hex')]
        keys = args.keys.resolve(strict=True) if args.keys else None
        palette = args.palette_hex.resolve(strict=True) if args.palette_hex else None
        texture = args.texture_hex.resolve(strict=True) if args.texture_hex else None
        subprocess.run(['git', 'worktree', 'add', '--detach', str(reference), args.ref], check=True)
        created = True
        build = ['make', 'vl-build']
        if palette is not None:
            build.append(f'PAL_HEX={palette}')
        if texture is not None:
            build.append(f'TEX_HEX={texture}')
        subprocess.run(build, cwd=reference, check=True)
        # Build first: reference make rules may rebuild their default program.
        (reference / 'out').mkdir(parents=True, exist_ok=True)
        for image in images:
            shutil.copyfile(image, reference / 'out' / image.name)
        traces.mkdir(parents=True, exist_ok=True)
        for label, executable, cwd in (
                ('current', binary, root), ('reference', reference / 'out/vl/kcvl', reference)):
            command = [str(executable), '--headless', '--frames', str(args.frames),
                       '--trace', str(traces / f'{label}.trace'),
                       '--png-dir', str(traces / f'{label}-frames')]
            if keys:
                command += ['--keys', str(keys)]
            subprocess.run(command, cwd=cwd, check=True)
        return compare(traces / 'reference.trace', traces / 'current.trace')
    except subprocess.CalledProcessError as error:
        print(f'tracediff: command failed ({error.returncode}): {error.cmd}', file=sys.stderr)
        return error.returncode if 1 <= error.returncode <= 5 else 5
    except (OSError, ValueError) as error:
        print(f'tracediff: {error}', file=sys.stderr)
        return 5
    finally:
        if created:
            cleanup = subprocess.run(['git', 'worktree', 'remove', str(reference)],
                                     capture_output=True, text=True)
            if cleanup.returncode:
                print(f'tracediff: reference worktree retained: {cleanup.stderr.strip()}', file=sys.stderr)
                return 5


if __name__ == '__main__':
    sys.exit(main())
