#!/usr/bin/env python3
"""Deterministic generator for sw/tests/t_vtrace_expected.inc from Kennedy's C reference.

Compiles sw/ref/vtrace_vectors.c with game/src/trace.c and fixed.c,
executes the resulting binary, and generates the exact assembly include file
containing genuine C-reference expected values for VSET / VTRACE / VGET.

Reference Sources & Dependencies:
  - game/src/trace.h (VSET, VTRACE, VGET formats and structs)
  - game/src/trace.c (vtrace_ref() DDA traversal algorithm)
  - game/src/kc_hal.h (WIN_INDEX, hal_win_get contract)
  - sw/ref/vtrace_vectors.c (host test harness and sparse world)

Discrepancy & Exclusion Contract:
  P6 identified reference discrepancies:
    1. Tie-breaking: game trace.c uses <= (x-first) vs wiki strict < (z-first).
    2. Cap 0: game executes 1 step vs wiki no-statechange.
    3. Overflow: game allows normal int32 overflow vs saturating MAX.
  All vectors generated here strictly use distinct positive tMax with NO equal
  crossings at any step, positive caps (max_steps >= 2), and no overflow.
  Disputed boundary conditions are covered separately in P6 verification.
"""

import argparse
import shlex
import shutil
import subprocess
import sys
from pathlib import Path


def find_host_compiler(preferred=None):
    candidates = [preferred] if preferred else ['clang', 'gcc', 'cc']
    for candidate in candidates:
        if not candidate:
            continue
        path = shutil.which(candidate)
        if path:
            return path
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        '--out',
        type=Path,
        default=Path('sw/tests/t_vtrace_expected.inc'),
        help='Output assembly include path (default: sw/tests/t_vtrace_expected.inc)'
    )
    parser.add_argument(
        '--cc',
        type=str,
        default=None,
        help='Host C compiler binary (default: auto-detect clang, gcc, cc)'
    )
    parser.add_argument(
        '--cflags',
        type=str,
        default='-O2 -DKC_HOST -Igame/src',
        help='Host C compiler flags (default: -O2 -DKC_HOST -Igame/src)'
    )
    args = parser.parse_args()

    # Verify reference source prerequisites
    prerequisites = [
        Path('sw/ref/vtrace_vectors.c'),
        Path('game/src/trace.c'),
        Path('game/src/trace.h'),
        Path('game/src/kc_hal.h'),
        Path('game/src/fixed.c'),
        Path('game/tools/gen_assets.py'),
    ]
    missing = [str(p) for p in prerequisites if not p.is_file()]
    if missing:
        sys.stderr.write(
            f"gen_vtrace_expected: missing required reference source files:\n"
            + "\n".join(f"  - {f}" for f in missing) + "\n"
        )
        sys.exit(1)

    # Locate host C compiler
    cc = find_host_compiler(args.cc)
    if not cc:
        sys.stderr.write(
            "gen_vtrace_expected: host C compiler not found (tried clang, gcc, cc).\n"
            "Please ensure a host C compiler is installed and available on PATH.\n"
        )
        sys.exit(1)

    # Prepare output directory for the compiled tool
    out_bin_dir = Path('out')
    out_bin_dir.mkdir(parents=True, exist_ok=True)
    out_bin = out_bin_dir / 'vtrace_vectors_ref'

    # Use the reference's real fixed-point helpers, never replacement math.
    assets = out_bin_dir / 'vtrace-reference' / 'gen'
    subprocess.run([sys.executable, 'game/tools/gen_assets.py', str(assets)], check=True)
    cflags = shlex.split(args.cflags)
    cmd_compile = [
        cc,
        *cflags, f'-I{assets}',
        'sw/ref/vtrace_vectors.c',
        'game/src/trace.c', 'game/src/fixed.c',
        '-o', str(out_bin)
    ]
    try:
        subprocess.run(cmd_compile, check=True)
    except subprocess.CalledProcessError as e:
        sys.stderr.write(f"gen_vtrace_expected: compilation failed with code {e.returncode}\n")
        sys.exit(e.returncode)

    # Ensure target output directory exists
    args.out.parent.mkdir(parents=True, exist_ok=True)

    # Execute generator to emit deterministic include
    cmd_run = [str(out_bin), str(args.out)]
    try:
        subprocess.run(cmd_run, check=True)
    except subprocess.CalledProcessError as e:
        sys.stderr.write(f"gen_vtrace_expected: generator execution failed with code {e.returncode}\n")
        sys.exit(e.returncode)

    if not args.out.is_file() or args.out.stat().st_size == 0:
        sys.stderr.write(f"gen_vtrace_expected: output file was not created or is empty: {args.out}\n")
        sys.exit(1)

    print(f"gen_vtrace_expected: wrote {args.out} ({args.out.stat().st_size} bytes)")


if __name__ == '__main__':
    main()
