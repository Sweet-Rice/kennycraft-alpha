#!/usr/bin/env python3
"""Exercise fixture UART verdicts, replay errors, deadlines, and waveform bounds."""
from pathlib import Path
import re
import subprocess
import tempfile


def main():
    executable = Path('out/vl-fixture/kcvl').resolve()
    with tempfile.TemporaryDirectory(prefix='harness-check-', dir='out') as directory:
        directory = Path(directory)

        def run(arguments, expected):
            result = subprocess.run([str(executable), '--headless', '--png-dir',
                                     str(directory / 'frames'), *arguments],
                                    text=True, capture_output=True, timeout=20)
            assert result.returncode == expected, (arguments, result.returncode,
                                                   result.stdout, result.stderr)
            return result

        timeout = run(['--max-cycles', '100'], 2)
        assert 'timeout after 100 cycles' in timeout.stderr
        for option, value, probes in [('--trace', str(directory / 'retire.trace'), 'retire'),
                                       ('--expect-err', 'ILLEGAL', 'ERR')]:
            result = run([option, value], 5)
            assert f'{option} needs {probes} probes' in result.stderr
        keys = directory / 'keys.txt'
        for line, code in [('PASS\n', 0), ('FAIL 17\n', 1)]:
            keys.write_text(''.join(f'0 0x{ord(c):02X}\n' for c in line))
            result = run(['--keys', str(keys), '--expect-pass', '--max-cycles', '10000'], code)
            assert line in result.stdout
        for entry in ['-1 0x77', '0 0x100', '0 0xGG', '0 0x77 extra',
                      '1 0x77\n0 0x77']:
            keys.write_text('# replay boundary check\n' + entry + '\n')
            result = run(['--keys', str(keys), '--max-cycles', '100'], 5)
            assert f'keys {keys}:' in result.stderr and 'bad entry' in result.stderr
        result = run(['--keys', str(directory / 'missing.keys')], 5)
        assert 'keys' in result.stderr
        waveform = directory / 'window.vcd'
        run(['--vcd', str(waveform), '--vcd-window', '5:10', '--max-cycles', '20'], 2)
        stamps = [int(s) for s in re.findall(r'^#(\d+)$', waveform.read_text(), re.M)]
        # Twenty reset cycles, then two evaluations per core cycle; endpoints inclusive.
        assert stamps == list(range(50, 62)), stamps
    print('harness: UART PASS/FAIL, replay boundaries, timeout, probes, VCD window PASS')


if __name__ == '__main__':
    main()
