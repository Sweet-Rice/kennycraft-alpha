#!/usr/bin/env python3
"""Compare the real chip retire trace of this tree's kcvl with a reference build.

The reference is a git ref (checked out as a detached worktree in out/ref and
removed afterwards) or an existing checkout directory, built in place. It is
built with `make vl-build` and the --make-var settings (the caller's chip
configuration), never with this make's MAKEFLAGS, so a PIPELINED=1 tree can
compare against the multi-cycle core of the same configuration.

Both kcvl runs get the same memory images (kc_imem.hex and kc_dmem.hex from
--images), keys and frame count, each in its own run directory under
out/traces, and run side by side. Their traces stream through pipes into the
comparison, which stops both runs at the first difference; frames and each
run's stdout (with its per-frame cycle counts) stay in out/traces.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
from tracediff import compare_lines

MAKE_ENV_DROP = ('MAKEFLAGS', 'MFLAGS', 'MAKELEVEL', 'MAKEOVERRIDES')


def build_reference(directory, make_vars, palette, texture):
    command = ['make', 'vl-build', 'VL_MDIR=out/vl-tracediff', *make_vars]
    if palette is not None:
        command.append(f'PAL_HEX={palette}')
    if texture is not None:
        command.append(f'TEX_HEX={texture}')
    env = {key: value for key, value in os.environ.items() if key not in MAKE_ENV_DROP}
    subprocess.run(command, cwd=directory, env=env, check=True)
    return (directory / 'out/vl-tracediff/kcvl').resolve(strict=True)


def start(label, executable, images, traces, frames, keys):
    """Start one kcvl in out/traces/<label>; return (process, trace pipe, log)."""
    run = traces / label
    if run.exists():
        shutil.rmtree(run)
    (run / 'out').mkdir(parents=True)
    for image in images:
        shutil.copyfile(image, run / 'out' / image.name)
    read_end, write_end = os.pipe()
    command = [str(executable), '--headless', '--frames', str(frames),
               '--trace', f'/dev/fd/{write_end}', '--png-dir', 'frames']
    if keys:
        command += ['--keys', str(keys)]
    log = open(run / 'kcvl.log', 'w')
    try:
        process = subprocess.Popen(command, cwd=run, stdout=log, stderr=subprocess.STDOUT,
                                   pass_fds=(write_end,))
    finally:
        os.close(write_end)
    return process, os.fdopen(read_end, 'r', encoding='utf-8', errors='replace', buffering=1 << 20), log


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--ref', required=True, help='git ref, or a checkout directory built in place')
    parser.add_argument('--frames', type=int, default=5)
    parser.add_argument('--keys', type=Path)
    parser.add_argument('--binary', type=Path, default=Path('out/vl/kcvl'), help="this tree's kcvl")
    parser.add_argument('--images', type=Path, default=Path('out'),
                        help='directory with kc_imem.hex and kc_dmem.hex for both runs')
    parser.add_argument('--make-var', action='append', default=[], metavar='NAME=VALUE',
                        help='setting for the reference make vl-build (repeatable)')
    parser.add_argument('--palette-hex', type=Path)
    parser.add_argument('--texture-hex', type=Path)
    args = parser.parse_args()
    if args.frames < 1:
        parser.error('--frames must be positive')
    root = Path.cwd()
    traces = root / 'out/traces'
    worktree = None
    runs = []
    try:
        binary = args.binary.resolve(strict=True)
        images = [(args.images / f'kc_{name}.hex').resolve(strict=True) for name in ('imem', 'dmem')]
        keys = args.keys.resolve(strict=True) if args.keys else None
        palette = args.palette_hex.resolve(strict=True) if args.palette_hex else None
        texture = args.texture_hex.resolve(strict=True) if args.texture_hex else None
        if Path(args.ref).is_dir():
            reference = Path(args.ref).resolve()
        else:
            reference = root / 'out/ref'
            if reference.exists():
                raise ValueError('out/ref already exists; remove its git worktree before comparing')
            subprocess.run(['git', 'worktree', 'add', '--detach', str(reference), args.ref], check=True)
            worktree = reference
        ref_binary = build_reference(reference, args.make_var, palette, texture)
        traces.mkdir(parents=True, exist_ok=True)
        runs = [start(label, executable, images, traces, args.frames, keys)
                for label, executable in (('reference', ref_binary), ('current', binary))]
        result = compare_lines(runs[0][1], runs[1][1], 'reference', 'current')
        for (process, _, _), label in zip(runs, ('reference', 'current')):
            # After a difference the other run is still going; it is stopped below.
            if (process.wait() if result == 0 else process.poll()):
                print(f'tracediff: {label} kcvl exited {process.returncode} '
                      f'(see {traces / label / "kcvl.log"})', file=sys.stderr)
                result = result or 5
        if result == 0:
            print(f'tracediff: traces identical over {args.frames} frame(s)')
        return result
    except subprocess.CalledProcessError as error:
        print(f'tracediff: command failed ({error.returncode}): {error.cmd}', file=sys.stderr)
        return error.returncode if 1 <= error.returncode <= 5 else 5
    except (OSError, ValueError) as error:
        print(f'tracediff: {error}', file=sys.stderr)
        return 5
    finally:
        for process, pipe, log in runs:
            if process.poll() is None:
                process.terminate()
            process.wait()
            pipe.close()
            log.close()
        if worktree is not None:
            cleanup = subprocess.run(['git', 'worktree', 'remove', str(worktree)],
                                     capture_output=True, text=True)
            if cleanup.returncode:
                print(f'tracediff: reference worktree retained: {cleanup.stderr.strip()}', file=sys.stderr)
                return 5


if __name__ == '__main__':
    sys.exit(main())
