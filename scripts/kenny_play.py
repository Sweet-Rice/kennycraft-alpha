#!/usr/bin/env python3
"""Play on the board with one command: Nemotron Nano for the villagers (llama-server, if it isn't
running), kc-host on the board's UART (dashboard, Nemotron agents, villagers spawned when the chip
links), the dashboard in the browser, and the kenny_keys window for keyboard, mouse and villager
chat. Quit the keys window to stop it all. Any kc-host, kenny_keys or kenny_play already running
is stopped first.

    pip install -r host/requirements.txt pygame-ce
    python scripts/kenny_play.py                  COM3, demo village (the board's game built KC_DEMO=1)
    python scripts/kenny_play.py --port COM5 --no-demo

--no-demo is for a game built without KC_DEMO: a demo chip only accepts builds on the village plot
and answers OUT_OF_ZONE anywhere else. kc-host reads its keys (NVIDIA_API_KEY, NANO_BASE_URL, ...)
from .env at the repo root.
"""
import argparse
import os
import shutil
import socket
import subprocess
import sys
import time
import webbrowser
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NANO = ['-hf', 'nvidia/NVIDIA-Nemotron-3-Nano-4B-GGUF:Q4_K_M', '--device', 'Vulkan0', '-ngl', '999',
        '-c', '8192', '-np', '4', '--jinja', '--host', '127.0.0.1', '--port', '8080']   # kc_agents/README.md


def stop_old():
    """Stop any kc-host, kenny_keys or kenny_play already running, so this one gets the port."""
    pattern = r'kchost\.py|kenny_keys\.py|kenny_play\.py'
    if os.name == 'nt':
        ps = ("Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match '" + pattern +
              f"' -and $_.ProcessId -ne {os.getpid()} -and $_.Name -like 'python*' }} | "
              "ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; $_.ProcessId }")
        out = subprocess.run(['powershell', '-NoProfile', '-Command', ps], capture_output=True, text=True).stdout
        pids = out.split()
    else:
        out = subprocess.run(['pgrep', '-f', rf'python[^ ]* .*({pattern})'], capture_output=True, text=True).stdout
        pids = [p for p in out.split() if int(p) != os.getpid()]
        for p in pids:
            os.kill(int(p), 15)
    if pids:
        print(f'kenny_play: stopped the running copies ({", ".join(pids)})')
    for _ in range(20):
        if not listening(8000):
            return
        time.sleep(0.5)
    sys.exit('kenny_play: port 8000 is still taken by something other than kc-host')


def listening(port):
    with socket.socket() as s:
        s.settimeout(0.3)
        return s.connect_ex(('127.0.0.1', port)) == 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--port', default='COM3' if os.name == 'nt' else '/dev/ttyUSB1', help='board UART (default %(default)s)')
    ap.add_argument('--no-demo', action='store_true', help='the board runs a game built without KC_DEMO')
    args = ap.parse_args()
    stop_old()
    started = []
    try:
        if not listening(8080):
            if shutil.which('llama-server'):
                started.append(subprocess.Popen(['llama-server', *NANO], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
            else:
                print('kenny_play: no llama-server, so the villagers move by rules (kc_agents/README.md)')
        env = {**os.environ, 'KC_CHIP': 'serial', 'KC_PORT': args.port}
        env.pop('KC_DEMO', None)
        if not args.no_demo:
            env['KC_DEMO'] = '1'
        kc = subprocess.Popen([sys.executable, 'host/kchost.py'], cwd=ROOT, env=env)
        started.append(kc)
        for _ in range(60):
            if listening(8000):
                break
            if kc.poll() is not None:
                sys.exit(f'kenny_play: kc-host exited (is {args.port} free and the board plugged in?)')
            time.sleep(0.5)
        else:
            sys.exit('kenny_play: kc-host did not start in 30 s')
        webbrowser.open('http://127.0.0.1:8000')
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import kenny_keys
        sys.argv = ['kenny_keys', '--kchost']
        return kenny_keys.main()
    finally:
        for p in started:
            if p.poll() is None:
                p.terminate()


if __name__ == '__main__':
    sys.exit(main())
