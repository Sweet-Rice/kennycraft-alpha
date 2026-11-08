#!/usr/bin/env python3
"""Kenny's keys: keyboard and mouse to the board's 1 Mbaud UART, from Windows (also runs on
Linux and macOS). No video: watch the board on its own monitor.

Key byte protocol of game/src/game.h: bit 7 = down, bits 6:0 = code.

    pip install pygame-ce pyserial
    python scripts/kenny_keys.py --port COM5

Click the window to capture the mouse; Esc releases it, Esc again quits.
  WASD move, Space jump, arrows or mouse look, left click / J break, right click / K
  place, 1-9 or wheel hotbar, E talk, Y/N accept/decline quote, P Nether, F perf overlay.

Opening or closing the port may reset the game: the Arty resets the design on a DTR edge,
and Windows raises DTR on open and drops it on close.
"""
import argparse
import os
import sys

os.environ.setdefault('PYGAME_HIDE_SUPPORT_PROMPT', '1')
import pygame  # noqa: E402
import serial  # noqa: E402

DOWN = 0x80
MOUSE_LEFT, MOUSE_RIGHT, MOUSE_UP, MOUSE_DOWN = 0x14, 0x15, 0x16, 0x17   # game/src/game.h
KEYMAP = {
    pygame.K_w: 0x77, pygame.K_a: 0x61, pygame.K_s: 0x73, pygame.K_d: 0x64,
    pygame.K_SPACE: 0x20,
    pygame.K_LEFT: 0x10, pygame.K_RIGHT: 0x11, pygame.K_UP: 0x12, pygame.K_DOWN: 0x13,
    pygame.K_j: 0x6A, pygame.K_k: 0x6B,
    pygame.K_e: 0x65, pygame.K_y: 0x79, pygame.K_n: 0x6E, pygame.K_p: 0x70, pygame.K_f: 0x66,
    **{getattr(pygame, f'K_{n}'): 0x30 + n for n in range(1, 10)},
}
CLICKS = {1: 0x6A, 3: 0x6B}   # left button breaks (J), right button places (K)
HELP = ('Click to capture the mouse, Esc frees it, Esc again quits',
        'WASD Space / mouse or arrows / click or J K / 1-9 wheel',
        'E talk  Y/N quote  P Nether  F overlay')


def look_bytes(acc, sens):
    """Turn accumulated mouse motion [dx, dy] into look key-down bytes; keep the remainder."""
    out = bytearray()
    for axis, (neg, pos) in enumerate(((MOUSE_LEFT, MOUSE_RIGHT), (MOUSE_UP, MOUSE_DOWN))):
        steps = int(acc[axis] / sens)
        acc[axis] -= steps * sens
        out += bytes([(pos if steps > 0 else neg) | DOWN]) * abs(steps)
    return bytes(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--port', default='COM5', help='board UART (default %(default)s; Linux /dev/ttyUSB1)')
    ap.add_argument('--sens', type=float, default=4.0, help='mouse pixels per look step (default %(default)s)')
    args = ap.parse_args()

    try:
        uart = serial.Serial(args.port, baudrate=1_000_000, timeout=0, write_timeout=1)
    except serial.SerialException as err:
        print(f'kenny_keys: {err}', file=sys.stderr)
        return 5

    pygame.display.init()
    pygame.font.init()
    screen = pygame.display.set_mode((520, 120))
    pygame.display.set_caption(f'Kenny keys ({args.port})')
    font = pygame.font.Font(None, 24)
    held, acc = set(), [0.0, 0.0]
    grabbed = False
    slot = 0

    def draw():
        screen.fill((24, 24, 24))
        for i, line in enumerate(HELP):
            screen.blit(font.render(line, True, (220, 220, 220)), (12, 12 + 26 * i))
        state = 'mouse captured' if grabbed else 'mouse free'
        screen.blit(font.render(f'{args.port}  {state}  slot {slot + 1}', True, (120, 200, 120)), (12, 12 + 26 * 3))
        pygame.display.flip()

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
        pygame.mouse.get_rel()   # drop the jump from before the grab
        acc[0] = acc[1] = 0.0
        draw()

    draw()
    try:
        clock = pygame.time.Clock()
        while True:
            for ev in pygame.event.get():
                if ev.type == pygame.QUIT:
                    return 0
                if ev.type == pygame.KEYDOWN and ev.key == pygame.K_ESCAPE:
                    if grabbed:
                        release_all()
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
                        draw()
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
                    draw()
                elif ev.type == pygame.MOUSEMOTION and grabbed:
                    acc[0] += ev.rel[0]
                    acc[1] += ev.rel[1]
            look = look_bytes(acc, args.sens)
            if look:
                send(look)
            rx = uart.read(4096)
            if rx:   # board text (kc: boot, ...); CR6 frames and other bytes as hex
                sys.stdout.write(''.join(chr(b) if 0x20 <= b <= 0x7E or b == 10 else f'\\x{b:02X}' for b in rx))
                sys.stdout.flush()
            clock.tick(250)
    except (OSError, serial.SerialException, pygame.error) as err:
        print(f'kenny_keys: {err}', file=sys.stderr)
        return 5
    finally:
        try:
            release_all()
            uart.close()
        except Exception:
            pass
        pygame.quit()


if __name__ == '__main__':
    sys.exit(main())
