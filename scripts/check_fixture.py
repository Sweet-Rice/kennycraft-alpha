#!/usr/bin/env python3
"""Verify the no-CPU fixture's pixels, frame-boundary UART, and determinism."""
from pathlib import Path
import re
import subprocess
from PIL import Image


def main():
    directory = Path('out/fixture-check')
    args = [str(Path('out/vl-fixture/kcvl').resolve()), '--headless', '--frames', '5',
            '--keys', 'tb/harness/fixture/keys.txt', '--png-dir', str(directory)]
    first = subprocess.run(args, capture_output=True, text=True, check=True)
    frames = re.findall(r'frame (\d+) cycles (\d+) \(\+(\d+)\) fps@50MHz (\d+\.\d)', first.stdout)
    assert [int(row[0]) for row in frames] == [1, 2, 3, 4, 5], first.stdout
    assert first.stdout.index('frame 2 ') < first.stdout.index('\\xF7') < first.stdout.index('frame 3 '), first.stdout
    assert first.stdout.index('frame 3 ') < first.stdout.index('w') < first.stdout.index('frame 4 '), first.stdout
    paths = sorted(directory.glob('frame_*.png'))
    assert [p.name for p in paths] == [f'frame_{n:05d}.png' for n in range(1, 6)]
    original = [p.read_bytes() for p in paths]
    for frame, path in enumerate(paths):
        with Image.open(path) as source:
            image = source.convert('RGB')
        assert image.size == (320, 240), image.size
        expected = bytearray()
        for y in range(240):
            for x in range(320):
                i = (x + y + frame) & 255
                expected.extend(((i >> 4) * 17, (i & 15) * 17, 8 * 17))
        # Read from the fixture's RTL back buffer and palette at the accepted swap.
        assert image.tobytes() == expected, f'RGB mismatch in frame {frame + 1}'
    second = subprocess.run(args, capture_output=True, text=True, check=True)
    assert first.stdout == second.stdout, 'nondeterministic UART/frame log'
    assert original == [p.read_bytes() for p in paths], 'nondeterministic PNGs'
    print(first.stdout, end='')
    print('fixture: exact RGB, boundary UART, deterministic replay PASS')


if __name__ == '__main__':
    main()
