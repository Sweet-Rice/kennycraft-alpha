#!/usr/bin/env python3
"""KennyCraft live: one window that shows the board's video from the HDMI capture card
and sends keyboard and mouse input to the board's 1 Mbaud UART (key byte protocol of
game/src/game.h: bit 7 = down, bits 6:0 = code).

Holds the fpga-tools MCP hardware lock (the workspace .fpga-state/hardware.lock, as
scripts/board.sh finds it; override with HARDWARE_LOCK= or --lock) while open, so MCP
program/video tools and fpga/patch_bit.sh wait. It does not post on issue #1.

Controls: click the video to capture the mouse (Esc releases it, Esc again quits).
  WASD move, Space jump, arrows look, mouse look, left click break (J), right click
  place (K), 1-9 or wheel hotbar, E talk, Y/N accept/decline quote, P Nether travel,
  F performance overlay.
"""
import argparse
import fcntl
import os
import subprocess
import sys
import termios
import threading
import time
from pathlib import Path

os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame  # noqa: E402
import serial


def default_lock():
    """HARDWARE_LOCK, else <workspace>/.fpga-state/hardware.lock next to the main checkout."""
    if os.environ.get('HARDWARE_LOCK'):
        return os.environ['HARDWARE_LOCK']
    try:
        common = subprocess.run(['git', 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                                cwd=Path(__file__).resolve().parent, capture_output=True, text=True,
                                check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    return str(Path(common).parent.parent / '.fpga-state' / 'hardware.lock')


DOWN = 0x80
MOUSE_LEFT, MOUSE_RIGHT, MOUSE_UP, MOUSE_DOWN = 0x14, 0x15, 0x16, 0x17
KEYMAP = {
    pygame.K_w: 0x77, pygame.K_a: 0x61, pygame.K_s: 0x73, pygame.K_d: 0x64,
    pygame.K_SPACE: 0x20,
    pygame.K_LEFT: 0x10, pygame.K_RIGHT: 0x11, pygame.K_UP: 0x12, pygame.K_DOWN: 0x13,
    pygame.K_j: 0x6A, pygame.K_k: 0x6B,
    pygame.K_e: 0x65, pygame.K_y: 0x79, pygame.K_n: 0x6E, pygame.K_p: 0x70,
    pygame.K_f: 0x66,                                        # performance overlay
    **{getattr(pygame, f'K_{n}'): 0x30 + n for n in range(1, 10)},
}
CLICKS = {1: 0x6A, 3: 0x6B}   # left button breaks (J), right button places (K)


class Video:
    """ffmpeg decodes the capture card to raw RGB at the window size; keeps the latest frame."""

    def __init__(self, device, capture, size, fps):
        self.size = size
        self.frame = None
        self.count = 0
        self.error = None
        w, h = size
        self.proc = subprocess.Popen(
            ['ffmpeg', '-loglevel', 'error', '-fflags', 'nobuffer', '-flags', 'low_delay',
             '-f', 'v4l2', '-input_format', 'mjpeg', '-video_size', capture, '-framerate', str(fps),
             '-i', device, '-vf', f'scale={w}:{h}', '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-'],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        n = self.size[0] * self.size[1] * 3
        out = self.proc.stdout
        while True:
            buf = bytearray(n)
            view, got = memoryview(buf), 0
            while got < n:
                k = out.readinto(view[got:])
                if not k:
                    self.error = (self.proc.stderr.read() or b'').decode(errors='replace').strip() or 'ffmpeg exited'
                    return
                got += k
            self.frame = bytes(buf)
            self.count += 1

    def close(self):
        self.proc.kill()


def take_lock(path):
    fd = os.open(path, os.O_RDWR)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        return None
    return fd


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--port', default='/dev/ttyUSB1', help='board UART (default %(default)s)')
    ap.add_argument('--video', default='/dev/video2', help='capture card (default %(default)s)')
    ap.add_argument('--capture', default='1280x720', help='capture mode, MJPEG (default %(default)s)')
    ap.add_argument('--fps', type=int, default=60, help='capture frame rate (default %(default)s)')
    ap.add_argument('--size', default='960x720', help='window size; the board image is 4:3 (default %(default)s)')
    ap.add_argument('--sens', type=float, default=4.0, help='mouse pixels per look step (default %(default)s)')
    ap.add_argument('--lock', default=default_lock(), help='MCP hardware lock (default %(default)s)')
    ap.add_argument('--no-lock', action='store_true', help="don't take the hardware lock")
    ap.add_argument('--doom', action='store_true',
                    help='Doom keys (doom/README.md): Enter, Ctrl fires, Tab is the Doom menu (Esc stays local); '
                         'no mouse look, since its codes are Doom keys')
    args = ap.parse_args()
    size = tuple(int(v) for v in args.size.split('x'))
    if args.doom:
        KEYMAP.update({pygame.K_RETURN: 0x0D, pygame.K_LCTRL: 0x14, pygame.K_RCTRL: 0x14, pygame.K_TAB: 0x1B})

    lock = None
    if not args.no_lock:
        if not args.lock or not os.path.isfile(args.lock):
            print(f'kc_live: no hardware lock at {args.lock}; pass --lock PATH, or --no-lock off this machine',
                  file=sys.stderr)
            return 5
        lock = take_lock(args.lock)
        if lock is None:
            print(f'kc_live: {args.lock} is held (an MCP program/video call or patch_bit.sh is running); try again',
                  file=sys.stderr)
            return 5
    uart = serial.Serial(args.port, baudrate=1_000_000, timeout=0, write_timeout=1)
    # The Arty resets the design on a DTR edge, and Linux raises DTR on open and drops it
    # on close (HUPCL). Clear HUPCL so DTR stays up after we close: later opens of the
    # port (this app, kc.py, scripts) then don't reboot the game. The first open after
    # a replug or a close with HUPCL set still resets it once.
    attrs = termios.tcgetattr(uart.fileno())
    attrs[2] &= ~termios.HUPCL
    termios.tcsetattr(uart.fileno(), termios.TCSANOW, attrs)
    video = Video(args.video, args.capture, size, args.fps)

    pygame.display.init()
    screen = pygame.display.set_mode(size)
    caption = 'KennyCraft live: click to capture the mouse, Esc releases, Esc again quits'
    pygame.display.set_caption(caption)
    held, acc = set(), [0.0, 0.0]
    grabbed = False
    slot = 0
    shown, t_fps, fps_count = None, time.monotonic(), 0

    def send(data):
        uart.write(bytes(data))

    def release_all():
        for key in sorted(held):
            send([KEYMAP[key]])
        held.clear()

    def grab(on):
        nonlocal grabbed
        grabbed = on
        pygame.event.set_grab(on)
        pygame.mouse.set_visible(not on)
        pygame.mouse.set_relative_mode(on)
        pygame.mouse.get_rel()
        acc[0] = acc[1] = 0.0

    try:
        clock = pygame.time.Clock()
        while True:
            for ev in pygame.event.get():
                if ev.type == pygame.QUIT:
                    return 0
                if ev.type == pygame.KEYDOWN and ev.key == pygame.K_ESCAPE:
                    if grabbed:
                        grab(False)
                        continue
                    return 0
                if ev.type == pygame.WINDOWFOCUSLOST:
                    release_all()
                    if grabbed:
                        grab(False)
                elif ev.type == pygame.KEYDOWN and ev.key in KEYMAP and ev.key not in held:
                    code = KEYMAP[ev.key]
                    send([code | DOWN])
                    held.add(ev.key)
                    if 0x31 <= code <= 0x39:
                        slot = code - 0x31
                elif ev.type == pygame.KEYUP and ev.key in held:
                    send([KEYMAP[ev.key]])
                    held.discard(ev.key)
                elif ev.type == pygame.MOUSEBUTTONDOWN:
                    if not grabbed:
                        grab(True)            # the first click only captures the mouse
                    elif ev.button in CLICKS:
                        send([CLICKS[ev.button] | DOWN, CLICKS[ev.button]])
                elif ev.type == pygame.MOUSEWHEEL and grabbed and ev.y:
                    slot = (slot - (1 if ev.y > 0 else -1)) % 9
                    send([(0x31 + slot) | DOWN, 0x31 + slot])
                elif ev.type == pygame.MOUSEMOTION and grabbed:
                    acc[0] += ev.rel[0]
                    acc[1] += ev.rel[1]
            look = bytearray()
            for axis, (neg, pos) in enumerate(((MOUSE_LEFT, MOUSE_RIGHT), (MOUSE_UP, MOUSE_DOWN))):
                steps = int(acc[axis] / args.sens)
                acc[axis] -= steps * args.sens
                look += bytes([(pos if steps > 0 else neg) | DOWN]) * abs(steps)
            if look and not args.doom:
                send(look)
            rx = uart.read(4096)
            if rx:   # board text (kc: boot, ...); CR6 frames and other bytes as hex
                sys.stdout.write(''.join(chr(b) if 0x20 <= b <= 0x7E or b == 10 else f'\\x{b:02X}' for b in rx))
                sys.stdout.flush()
            if video.error:
                print(f'kc_live: video: {video.error}', file=sys.stderr)
                return 5
            frame = video.frame
            if frame is not None and frame is not shown:
                shown = frame
                fps_count += 1
                screen.blit(pygame.image.frombuffer(frame, size, 'RGB'), (0, 0))
                pygame.display.flip()
            now = time.monotonic()
            if now - t_fps >= 1.0:
                pygame.display.set_caption(f'{caption}  [{fps_count / (now - t_fps):.0f} fps capture]')
                t_fps, fps_count = now, 0
            clock.tick(250)
    except (OSError, serial.SerialException, pygame.error) as err:
        print(f'kc_live: {err}', file=sys.stderr)
        return 5
    finally:
        try:
            release_all()
            uart.close()
        except Exception:
            pass
        video.close()
        pygame.quit()
        if lock is not None:
            os.close(lock)


if __name__ == '__main__':
    sys.exit(main())
