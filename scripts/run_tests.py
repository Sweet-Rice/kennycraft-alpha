#!/usr/bin/env python3
"""Build self-checking programs and run them on the production Verilated chip."""
import argparse
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys


def build(name, args):
    if not re.fullmatch(r't_[A-Za-z0-9_]+', name):
        raise ValueError(f'bad test name: {name}')
    source = Path('sw/tests') / f'{name}.S'
    if not source.is_file():
        raise ValueError(f'missing self-checking test: {source}')
    directory = Path('out/tests') / name
    directory.mkdir(parents=True, exist_ok=True)
    elf = directory / 'kc.elf'
    subprocess.run([args.cc, *shlex.split(args.cflags), f'-DKC_STAGE={args.stage}',
                    '-T', 'sw/kc.ld', '-nostdlib', f'-Wl,-Map,{directory}/kc.map',
                    'sw/crt0.S', str(source), 'sw/arena.c', '-lgcc', '-o', str(elf)], check=True)
    for kind, sections, offset in [('imem', ['.text'], '0'), ('dmem', ['.rodata', '.data'], '0x100')]:
        binary = directory / f'kc_{kind}.bin'
        command = [args.objcopy, '-O', 'binary']
        for section in sections:
            command += ['-j', section]
        subprocess.run([*command, str(elf), str(binary)], check=True)
        subprocess.run([sys.executable, 'scripts/elf2hex.py', str(binary),
                        str(directory / f'kc_{kind}.hex'), '--offset-bytes', offset,
                        '--words', '8192', *(['--nonempty'] if kind == 'imem' else [])], check=True)
    return directory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tests', nargs='+')
    parser.add_argument('--stage', type=int, choices=(0, 1, 2), default=0)
    parser.add_argument('--cc', default='riscv-none-elf-gcc')
    parser.add_argument('--objcopy', default='riscv-none-elf-objcopy')
    parser.add_argument('--nm', default='riscv-none-elf-nm')
    parser.add_argument('--cflags', default='-march=rv32i_zmmul -mabi=ilp32 -O2 -ffreestanding -nostdlib -fno-builtin -msmall-data-limit=0 -Wall -DKC_CHIP -Isw')
    parser.add_argument('--binary', type=Path, default=Path('out/vl/kcvl'))
    parser.add_argument('--build-only', action='store_true')
    args = parser.parse_args()
    originals = {}
    changed = False
    try:
        binary = None if args.build_only else args.binary.resolve(strict=True)
        if not args.build_only:
            for kind in ('imem', 'dmem'):
                path = Path(f'out/kc_{kind}.hex')
                originals[path] = path.read_bytes() if path.exists() else None
        for name in args.tests:
            directory = build(name, args)
            expected = ('ILLEGAL' if name.startswith('t_illegal_') else
                        {'t_branch_uniform': 'DIVERGE', 't_jalr_uniform': 'DIVERGE',
                         't_divstack_overflow': 'DIVSTACK'}.get(name))
            expect = ['--expect-pass']
            if expected:
                symbols = subprocess.check_output([args.nm, '-g', str(directory / 'kc.elf')], text=True)
                sites = [row.split()[0] for row in symbols.splitlines()
                         if len(row.split()) >= 3 and row.split()[-1] == 'err_site']
                if len(sites) != 1:
                    raise ValueError(f'{name} needs one exported err_site')
                expect = ['--expect-err', f'{expected}@0x{sites[0]}']
            if args.build_only:
                print(f'{name}: built' + (f' ({expect[1]})' if expected else ''))
                continue
            changed = True
            for kind in ('imem', 'dmem'):
                shutil.copyfile(directory / f'kc_{kind}.hex', f'out/kc_{kind}.hex')
            command = [str(binary), '--headless', '--max-cycles', '20000000',
                       '--png-dir', str(directory / 'frames'), *expect]
            keys = Path('sw/tests') / f'{name}.keys'
            if keys.exists():
                command += ['--keys', str(keys)]
            proc = subprocess.run(command, capture_output=True, text=True)
            if proc.stdout:
                sys.stdout.write(proc.stdout)
                sys.stdout.flush()
            if proc.returncode != 0:
                if proc.stderr:
                    sys.stderr.write(proc.stderr)
                    sys.stderr.flush()
                raise subprocess.CalledProcessError(proc.returncode, command,
                                                    output=proc.stdout, stderr=proc.stderr)
            if expected:
                site_hex = f'0x{int(sites[0], 16):08x}'
                if expected not in proc.stderr or site_hex not in proc.stderr.lower():
                    if proc.stderr:
                        sys.stderr.write(proc.stderr)
                        sys.stderr.flush()
                    raise ValueError(f'{name}: ERR/PC mismatch or early quit without {expected} at {site_hex}')
            else:
                has_pass = bool(re.search(r'\bPASS\b', proc.stdout))
                has_fail = bool(re.search(r'\bFAIL(\s+\d+)?\b', proc.stdout))
                if has_fail or not has_pass:
                    if proc.stderr:
                        sys.stderr.write(proc.stderr)
                        sys.stderr.flush()
                    raise ValueError(f'{name}: consumer-visible failure or early quit without PASS')
            print(f'{name}: PASS', flush=True)
    except subprocess.CalledProcessError as error:
        print(f'tests: command failed ({error.returncode}): {error.cmd}', file=sys.stderr)
        return error.returncode if 1 <= error.returncode <= 5 else 5
    except (OSError, ValueError) as error:
        print(f'tests: {error}', file=sys.stderr)
        return 5
    finally:
        if changed:
            for path, content in originals.items():
                if content is None:
                    path.unlink(missing_ok=True)
                else:
                    path.write_bytes(content)


if __name__ == '__main__':
    sys.exit(main())
