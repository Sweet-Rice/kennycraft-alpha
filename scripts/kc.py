#!/usr/bin/env python3
"""Forward focused pygame keyboard events to KennyCraft's 1 Mbaud UART.

The board UART is only opened under the board claim and hardware lock of
scripts/board.sh keys (issue #1 taking-board, fpga-tools MCP hardware.lock);
run directly, it re-runs itself through board.sh.
"""
import argparse
import fcntl
import os
from pathlib import Path
import stat
import sys


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
        fcntl.flock(int(fd), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (OSError, ValueError) as error:
        print(f'keys: hardware lock not held: {error}', file=sys.stderr)
        return 5
    return None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', default='/dev/ttyUSB1', help='board UART (default: %(default)s)')
    args = parser.parse_args(argv)
    try:
        import pygame
    except ImportError:
        print('keys: pygame is not installed (needed for the key window); pip install pygame', file=sys.stderr)
        return 5
    try:
        import serial
    except ImportError:
        print('keys: pyserial is not installed; pip install pyserial', file=sys.stderr)
        return 5
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
        **{getattr(pygame, f'K_{n}'): 0x30 + n for n in range(1, 10)},
    }
    connection = None
    try:
        connection = serial.Serial(port, baudrate=1_000_000, bytesize=8, parity='N',
                                   stopbits=1, timeout=0, write_timeout=1)
        pygame.display.init()
        pygame.font.init()
        screen = pygame.display.set_mode((320, 120))
        pygame.display.set_caption('KennyCraft keys')
        screen.fill((20, 20, 20))
        font = pygame.font.Font(None, 22)
        for y, text in enumerate(('Focus here to control KennyCraft', 'WASD / arrows / Space / J K / 1-9', 'Esc closes; UART output in terminal')):
            screen.blit(font.render(text, True, (230, 230, 230)), (8, 14 + 30 * y))
        pygame.display.flip()
        pygame.event.pump()
        focused = pygame.key.get_focused()
        held = set()
        clock = pygame.time.Clock()
        while True:
            for event in pygame.event.get():
                closing = event.type == pygame.QUIT or (event.type == pygame.KEYDOWN and event.key == pygame.K_ESCAPE)
                focus_lost = (event.type == getattr(pygame, 'WINDOWFOCUSLOST', None) or
                              (event.type == getattr(pygame, 'ACTIVEEVENT', None) and getattr(event, 'state', 0) & 2 and not getattr(event, 'gain', 1)))
                focus_gained = (event.type == getattr(pygame, 'WINDOWFOCUSGAINED', None) or
                                (event.type == getattr(pygame, 'ACTIVEEVENT', None) and getattr(event, 'state', 0) & 2 and getattr(event, 'gain', 0)))
                if closing or focus_lost:
                    for key in sorted(held):
                        connection.write(bytes([keymap[key]]))
                    held.clear()
                    if closing:
                        return 0
                    focused = False
                elif focus_gained:
                    focused = True
                elif event.type == pygame.KEYDOWN and focused:
                    if event.key in keymap and event.key not in held and not getattr(event, 'repeat', False):
                        connection.write(bytes([keymap[event.key] | 0x80]))
                        held.add(event.key)
                elif event.type == pygame.KEYUP and event.key in held:
                    connection.write(bytes([keymap[event.key]]))
                    held.remove(event.key)
            in_waiting = getattr(connection, 'in_waiting', 0)
            if in_waiting:
                data = connection.read(in_waiting)
                if data:
                    sys.stdout.write(''.join(chr(b) if 0x20 <= b <= 0x7E or b == 10 else f'\\x{b:02X}' for b in data))
                    sys.stdout.flush()
            clock.tick(240)
    except (OSError, serial.SerialException, pygame.error) as error:
        print(f'keys: {error}', file=sys.stderr)
        return 5
    finally:
        if connection is not None:
            try:
                connection.close()
            except Exception:
                pass
        try:
            pygame.quit()
        except Exception:
            pass


if __name__ == '__main__':
    sys.exit(main())
