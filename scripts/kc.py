#!/usr/bin/env python3
"""KennyCraft window: keyboard and mouse to the board's 1 Mbaud UART, or with --host
the laptop build (game/build/kc_host link) played inside this window, or with --kchost
the game kc-host is already running (KC_CHIP=host), so the villagers, bank and agents work:
this window shows its frames and sends your keys and mouse to kc-host.

The board UART is only opened under the board claim and hardware lock of
scripts/board.sh keys (issue #1 taking-board, fpga-tools MCP hardware.lock);
run directly, it re-runs itself through board.sh. --host needs no board.
"""
import argparse

import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

MOUSE_LEFT, MOUSE_RIGHT, MOUSE_UP, MOUSE_DOWN = 0x14, 0x15, 0x16, 0x17   # game/src/game.h
PIXELS_PER_STEP = 4   # mouse sensitivity: pointer pixels per look byte (MOUSE_STEP in game.c)
SIZES = {320 * 240 * 3: (320, 240), 160 * 120 * 3: (160, 120)}   # KC_RAW frame sizes


def hold_board(port):
    """Return None when board.sh holds the lock for us, else exec board.sh keys."""
    fd = os.environ.get('KC_HARDWARE_LOCK_FD')
    if fd is None:
        root = Path(__file__).resolve().parents[1]
        os.chdir(root)
        os.environ['PYTHON'] = sys.executable
        print('keys: claiming the board through scripts/board.sh keys', file=sys.stderr)
        os.execvp('bash', ['bash', 'scripts/board.sh', 'keys', '--port', port])
    try:
        # board.sh holds the flock on this open file description; taking it
        # again here is a no-op and guarantees it is held while the UART is open.
        if not stat.S_ISREG(os.fstat(int(fd)).st_mode):
            raise OSError(f'KC_HARDWARE_LOCK_FD={fd} is not a lock file')
        import fcntl   # POSIX only; the board path runs in WSL/Linux
        fcntl.flock(int(fd), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (OSError, ValueError) as error:
        print(f'keys: hardware lock not held: {error}', file=sys.stderr)
        return 5
    return None


def open_host():
    """Start the laptop build; returns (process, path of its raw RGB frame).
    On Windows kc_host runs in WSL (like host/kchost.py) and writes the frame under game/out."""
    game = Path(__file__).resolve().parents[1] / 'game'
    exe = game / 'build' / 'kc_host'
    if not exe.exists():
        raise OSError(f'{exe} is not built; run make -C game (in WSL)')
    fps = os.environ.get('KC_LINK_FPS', '50')
    if os.name == 'nt':
        out = game / 'out' / 'window'
        out.mkdir(parents=True, exist_ok=True)
        wsl = '/mnt/' + game.drive[0].lower() + game.as_posix()[2:]
        cmd = ['wsl', '-e', 'bash', '-lc',
               f"cd '{wsl}' && KC_RAW=out/window/frame.rgb KC_LINK_FPS={int(fps)} exec ./build/kc_host link out/window"]
        env = None
    else:
        out = Path(tempfile.mkdtemp(prefix='kc_window_'))
        cmd = [str(exe), 'link', str(out)]
        env = dict(os.environ, KC_RAW=str(out / 'frame.rgb'), KC_LINK_FPS=fps)
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, env=env, bufsize=0)
    return proc, out / 'frame.rgb'


def look_bytes(acc):
    """Turn accumulated pointer motion [dx, dy] into look bytes; keeps the remainder in acc."""
    out = bytearray()
    for axis, (neg, pos) in enumerate(((MOUSE_LEFT, MOUSE_RIGHT), (MOUSE_UP, MOUSE_DOWN))):
        steps = int(acc[axis] / PIXELS_PER_STEP)
        acc[axis] -= steps * PIXELS_PER_STEP
        out += bytes([(pos if steps > 0 else neg) | 0x80]) * abs(steps)
    return bytes(out)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', default='/dev/ttyUSB1', help='board UART (default: %(default)s)')
    parser.add_argument('--host', action='store_true', help='play the laptop build in this window')
    parser.add_argument('--kchost', nargs='?', const='http://127.0.0.1:8000', metavar='URL',
                        help="play the game kc-host runs (KC_CHIP=host), with its agents (default %(const)s)")
    args = parser.parse_args(argv)
    try:
        import pygame
    except ImportError:
        print('keys: pygame is not installed (needed for the window); pip install pygame', file=sys.stderr)
        return 5
    proc = connection = raw = None
    if args.kchost:
        import json
        import urllib.request
        raw = Path(__file__).resolve().parents[1] / 'game' / 'out' / 'window' / 'frame.rgb'
        url = args.kchost.rstrip('/') + '/api/input'

        def send(data):
            req = urllib.request.Request(url, json.dumps({'hex': bytes(data).hex()}).encode(),
                                         {'Content-Type': 'application/json'})
            try:
                urllib.request.urlopen(req, timeout=1).close()
            except OSError as error:
                print(f'keys: kc-host not reachable at {url}: {error}', file=sys.stderr)
        port_errors = ()
        live = {}                                     # kc-host's latest /events snapshot

        def watch():
            while True:
                try:
                    with urllib.request.urlopen(args.kchost.rstrip('/') + '/events', timeout=30) as stream:
                        for line in stream:
                            if line.startswith(b'data:'):
                                live.clear()
                                live.update(json.loads(line[5:]))
                except (OSError, ValueError):
                    import time
                    time.sleep(1)

        def post(path, body):
            req = urllib.request.Request(args.kchost.rstrip('/') + path, json.dumps(body).encode(),
                                         {'Content-Type': 'application/json'})
            try:
                urllib.request.urlopen(req, timeout=5).close()
            except OSError as error:
                print(f'keys: {path}: {error}', file=sys.stderr)
        import threading
        threading.Thread(target=watch, daemon=True).start()
    elif args.host:
        try:
            proc, raw = open_host()
        except OSError as error:
            print(f'keys: {error}', file=sys.stderr)
            return 5
        send = proc.stdin.write
        port_errors = ()
    else:
        try:
            import serial
        except ImportError:
            print('keys: pyserial is not installed; pip install pyserial', file=sys.stderr)
            return 5
        port_errors = (serial.SerialException,)
        port = args.port
        if not os.path.exists(port):
            print(f'keys: {port} does not exist; set --port (make keys PORT=)', file=sys.stderr)
            return 5
        status = hold_board(port)
        if status is not None:
            return status
    keymap = {
        pygame.K_w: 0x77, pygame.K_a: 0x61, pygame.K_s: 0x73, pygame.K_d: 0x64,
        pygame.K_SPACE: 0x20,
        pygame.K_LEFT: 0x10, pygame.K_RIGHT: 0x11, pygame.K_UP: 0x12, pygame.K_DOWN: 0x13,
        pygame.K_j: 0x6A, pygame.K_k: 0x6B,
        pygame.K_e: 0x65, pygame.K_y: 0x79, pygame.K_n: 0x6E,   # CR6: talk, accept, decline
        pygame.K_p: 0x70,                                        # Nether travel
        pygame.K_f: 0x66,                                        # performance overlay
        **{getattr(pygame, f'K_{n}'): 0x30 + n for n in range(1, 10)},
    }
    clicks = {1: 0x6A, 3: 0x6B}   # left button breaks (J), right button places (K)
    try:
        if connection is None and not args.host and not args.kchost:
            connection = serial.Serial(port, baudrate=1_000_000, bytesize=8, parity='N',
                                       stopbits=1, timeout=0, write_timeout=1)
            send = connection.write
        pygame.display.init()
        pygame.font.init()
        screen = pygame.display.set_mode((640, 480) if args.host or args.kchost else (320, 120))
        pygame.display.set_caption('KennyCraft')
        screen.fill((20, 20, 20))
        font = pygame.font.Font(None, 22)
        for y, text in enumerate(('Click to capture the mouse, Esc frees it', 'WASD Space / mouse / click or J K / 1-9',
                                  'Esc again closes')):
            screen.blit(font.render(text, True, (230, 230, 230)), (8, 14 + 30 * y))
        pygame.display.flip()
        pygame.event.pump()
        focused = pygame.key.get_focused()
        held = set()
        typing = None                     # --kchost: text for the villager you're talking to
        grabbed = False
        acc = [0, 0]
        clock = pygame.time.Clock()

        def grab(on):
            nonlocal grabbed
            grabbed = on
            pygame.event.set_grab(on)
            pygame.mouse.set_visible(not on)
            pygame.mouse.get_rel()   # drop the jump from before the grab
            acc[0] = acc[1] = 0

        while True:
            if proc is not None and proc.poll() is not None:
                print(f'keys: kc_host exited ({proc.returncode})', file=sys.stderr)
                return 5
            if args.kchost and typing is None and live.get('prompt'):
                typing = ''                       # E at a villager: your keys type to them now
                for key in sorted(held):
                    send(bytes([keymap[key]]))
                held.clear()
            elif args.kchost and typing is not None and not live.get('prompt'):
                typing = None
            for event in pygame.event.get():
                if typing is not None and event.type == pygame.KEYDOWN:
                    if event.key == pygame.K_RETURN and typing.strip():
                        post('/api/request', {'kind': live['prompt'], 'text': typing.strip()})
                        live['prompt'] = None
                        typing = None
                    elif event.key == pygame.K_ESCAPE:
                        post('/api/close', {})
                        live['prompt'] = None
                        typing = None
                    elif event.key == pygame.K_BACKSPACE:
                        typing = typing[:-1]
                    elif event.unicode and event.unicode.isprintable() and len(typing) < 120:
                        typing += event.unicode
                    continue
                esc = event.type == pygame.KEYDOWN and event.key == pygame.K_ESCAPE
                if esc and grabbed:
                    grab(False)
                    continue
                closing = event.type == pygame.QUIT or esc
                focus_lost = (event.type == getattr(pygame, 'WINDOWFOCUSLOST', None) or
                              (event.type == getattr(pygame, 'ACTIVEEVENT', None) and getattr(event, 'state', 0) & 2 and not getattr(event, 'gain', 1)))
                focus_gained = (event.type == getattr(pygame, 'WINDOWFOCUSGAINED', None) or
                                (event.type == getattr(pygame, 'ACTIVEEVENT', None) and getattr(event, 'state', 0) & 2 and getattr(event, 'gain', 0)))
                if closing or focus_lost:
                    for key in sorted(held):
                        send(bytes([keymap[key]]))
                    held.clear()
                    if grabbed:
                        grab(False)
                    if closing:
                        return 0
                    focused = False
                elif focus_gained:
                    focused = True
                elif event.type == pygame.MOUSEBUTTONDOWN:
                    if not grabbed:
                        grab(True)            # the first click only captures the mouse
                    elif event.button in clicks:
                        send(bytes([clicks[event.button] | 0x80, clicks[event.button]]))
                elif event.type == pygame.MOUSEMOTION and grabbed:
                    acc[0] += event.rel[0]
                    acc[1] += event.rel[1]
                elif event.type == pygame.KEYDOWN and focused:
                    if event.key in keymap and event.key not in held and not getattr(event, 'repeat', False):
                        send(bytes([keymap[event.key] | 0x80]))
                        held.add(event.key)
                elif event.type == pygame.KEYUP and event.key in held:
                    send(bytes([keymap[event.key]]))
                    held.remove(event.key)
            look = look_bytes(acc)
            if look:
                send(look)
            if raw is not None:
                try:
                    data = raw.read_bytes()
                except OSError:
                    data = b''
                if len(data) in SIZES:
                    frame = pygame.image.frombuffer(data, SIZES[len(data)], 'RGB')
                    screen.blit(pygame.transform.scale(frame, screen.get_size()), (0, 0))
                    if args.kchost:               # what the agents say, and the text box
                        lines = (live.get('log') or [])[-2:]
                        for i, text in enumerate(lines):
                            img = font.render(text[9:][:90], True, (255, 255, 255), (0, 0, 0))
                            screen.blit(img, (6, 6 + 20 * i + 40))
                        if typing is not None:
                            box = font.render(f"To the {live.get('prompt')}: {typing}_   (Enter sends, Esc closes)",
                                              True, (255, 255, 255), (30, 30, 90))
                            screen.blit(box, (6, screen.get_height() - 70))
                    pygame.display.flip()
            else:
                in_waiting = getattr(connection, 'in_waiting', 0)
                if in_waiting:
                    data = connection.read(in_waiting)
                    if data:
                        sys.stdout.write(''.join(chr(b) if 0x20 <= b <= 0x7E or b == 10 else f'\\x{b:02X}' for b in data))
                        sys.stdout.flush()
            clock.tick(60 if args.host or args.kchost else 240)
    except (OSError, pygame.error, *port_errors) as error:
        print(f'keys: {error}', file=sys.stderr)
        return 5
    finally:
        if connection is not None:
            try:
                connection.close()
            except Exception:
                pass
        if proc is not None:
            proc.kill()
        try:
            pygame.quit()
        except Exception:
            pass


if __name__ == '__main__':
    if sys.argv[1:] == ['--selftest']:
        a = [9, -5]
        assert look_bytes(a) == bytes([MOUSE_RIGHT | 0x80] * 2 + [MOUSE_UP | 0x80]) and a == [1, -1]
        assert look_bytes([3, 3]) == b''
        print('kc.py selftest ok')
        sys.exit(0)
    sys.exit(main())
