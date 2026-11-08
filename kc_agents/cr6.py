"""CR6 UART command frames, laptop side (accepted on issue #8; wiki Shared.md CR6, D8 amended).

Frame, both ways:  A5 | len | seq | op | payload (0..7 laptop->chip) | crc8
  len  = bytes in seq + op + payload; crc8 = poly 0x07, init 0, over len..payload, bitwise
  little-endian; blocks x, z u16, y u8; entities x, z u16 in 1/16 block, y u8 in 1/8 block
Pacing: the chip drains its 16-byte RX FIFO once per frame and answers with one STATUS
(result of the last command, frame_lo, credit, cumulative drained bytes). The laptop keeps
sent - drained <= credit = RX_DEPTH - RX_RESERVE, keys included, so the FIFO never overflows.

This module: framing, a stream decoder, the link with credits, a fake chip that speaks the
bytes (FakeUartChip), and Cr6Chip, which gives the agents the same methods as FakeChip.
"""
import struct

SOF = 0xA5
RX_DEPTH, RX_RESERVE = 16, 4
CREDIT = RX_DEPTH - RX_RESERVE
VERSION = 1

# laptop -> chip
HELLO, BYE = 0x01, 0x02
PLACE, BREAK, FILL = 0x10, 0x11, 0x12
SPAWN, MOVE, STATE = 0x20, 0x21, 0x22
Q_PLAYER, Q_BLOCKS, Q_INV, Q_ENTITY = 0x30, 0x31, 0x32, 0x33
SET_BALANCE, SET_QUOTE, SET_CONTRACT = 0x40, 0x41, 0x42
# chip -> laptop
STATUS, HELLO_ACK, R_PLAYER, R_BLOCKS, R_INV, R_ENTITY, EVENT = 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x8F

RESULTS = ["OK", "CRC", "BAD_OP", "OUT_OF_ZONE", "BAD_BLOCK", "PROTECTED", "RATE", "BUSY",
           "NOT_LINKED", "BAD_ENTITY"]
R = {name: i for i, name in enumerate(RESULTS)}
EVENTS = {1: "EDIT", 2: "HIT", 3: "INTERACT", 4: "CONFIRM"}
# Q_BLOCKS / R_BLOCKS / Q_ENTITY / R_ENTITY payloads aren't spelled out in CR6. The chip
# handlers in game/src/cr6.c (kenny/cr6) use exactly these layouts:
#   Q_BLOCKS x u16, z u16, y u8, (sx-1)|(sy-1)<<2|(sz-1)<<4   (<= 4x4x4)
#   R_BLOCKS ids, two per byte (low nibble first), x fastest, then z, then y
#   R_ENTITY id, x u16, z u16 (1/16), y u8 (1/8), state


def crc8(data):
    c = 0
    for b in data:
        c ^= b
        for _ in range(8):
            c = ((c << 1) ^ 0x07) & 0xFF if c & 0x80 else (c << 1) & 0xFF
    return c


def frame(seq, op, payload=b""):
    body = bytes([len(payload) + 2, seq & 0xFF, op]) + bytes(payload)
    return bytes([SOF]) + body + bytes([crc8(body)])


class Decoder:
    """Feed bytes in any chunks; yields ("frame", seq, op, payload), ("bad",) or ("byte", b).
    A frame split across two feeds still completes (CR6: across two drains)."""

    def __init__(self, max_len=42):
        self.buf, self.max_len = bytearray(), max_len

    def feed(self, data):
        out = []
        self.buf += data
        while self.buf:
            if self.buf[0] != SOF:
                out.append(("byte", self.buf.pop(0)))
                continue
            if len(self.buf) < 2:
                break
            n = self.buf[1]
            if not 2 <= n <= self.max_len:
                del self.buf[:1]
                out.append(("bad",))
                continue
            if len(self.buf) < n + 3:
                break
            body, crc = bytes(self.buf[1:n + 2]), self.buf[n + 2]
            del self.buf[:n + 3]
            out.append(("frame", body[1], body[2], body[3:]) if crc8(body) == crc else ("bad",))
        return out


# ---- payloads ----------------------------------------------------------------------------
def p_place(x, z, y, b):        return struct.pack("<HHBB", x, z, y, b)
def p_break(x, z, y):           return struct.pack("<HHB", x, z, y)
def p_fill(x, z, y, sx, sy, sz, b):
    return struct.pack("<HHBBB", x, z, y, (sx - 1) | (sz - 1) << 4, (sy - 1) | b << 4)
def p_spawn(eid, kind, x, z, y): return struct.pack("<BHHB", eid | kind << 4, round(x * 16), round(z * 16), round(y * 8))
def p_move(eid, x, z):          return struct.pack("<BHH", eid, round(x * 16), round(z * 16))
def p_qblocks(x, z, y, sx=1, sy=1, sz=1):
    return struct.pack("<HHBB", x, z, y, (sx - 1) | (sy - 1) << 2 | (sz - 1) << 4)


class Link:
    """The laptop's end: the only writer to the chip. send() only puts bytes on the wire when
    sent - drained fits the credit, so the chip's FIFO never drops anything."""

    def __init__(self, port):
        self.port = port                # write(bytes), poll() -> bytes (one chip frame's worth)
        self.dec = Decoder()
        self.seq = 0
        self.sent = 0                   # bytes written, mod 256
        self.drained = 0                # from the last STATUS
        self.credit = CREDIT
        self.keys = bytearray()
        self.results = {}               # seq -> result name
        self.replies = {}               # seq -> (op, payload)
        self.events = []
        self.text = bytearray()         # debug text from the chip
        self.linked = False

    def in_flight(self):
        return (self.sent - self.drained) & 0xFF

    def _write(self, data):
        self.port.write(data)
        self.sent = (self.sent + len(data)) & 0xFF

    def pump(self):
        """One chip frame: send keys that fit, then read what the chip sent."""
        k = max(0, min(len(self.keys), self.credit - self.in_flight()))
        if k:
            self._write(bytes(self.keys[:k]))
            del self.keys[:k]
        last, acked = None, False
        for item in self.dec.feed(self.port.poll()):
            if item[0] == "byte":
                self.text.append(item[1])
            elif item[0] == "frame":
                _, seq, op, p = item
                if op == STATUS:
                    self.drained, self.credit = p[3], p[2]
                    last = (seq, RESULTS[p[0]] if p[0] < len(RESULTS) else "?")
                    self.results[seq] = last[1]
                elif op == HELLO_ACK:
                    self.linked = acked = True
                elif op == EVENT:
                    self.events.append((EVENTS.get(p[0], p[0]), struct.unpack("<H", p[1:3])[0]))
                else:
                    self.replies[seq] = (op, p)
        if acked:                       # the chip counts bytes since boot (dropped ones not at all):
            self.sent = self.drained    # resync on the STATUS that follows HELLO_ACK; nothing else is in flight
        return last

    def call(self, op, payload=b"", max_frames=60):
        """Send one command when it fits the credit, pump until its STATUS. Returns the result name."""
        if op != HELLO and not self.linked:
            return "NOT_LINKED"         # CR6: nothing but HELLO before linking; the chip would ignore it
        self.seq = self.seq % 255 + 1
        f = frame(self.seq, op, payload)
        for _ in range(max_frames):
            if not self.keys and self.in_flight() + len(f) <= self.credit:
                self._write(f)
                break
            self.pump()
        else:
            return "TIMEOUT"
        for _ in range(max_frames):
            self.pump()
            if self.seq in self.results:
                return self.results.pop(self.seq)
        return "TIMEOUT"

    def hello(self):
        self.pump()                     # let the chip drain whatever was sent before
        self.drained = self.sent        # unlinked: no STATUS yet, assume the FIFO is empty now
        self.call(HELLO, b"KC" + bytes([VERSION]))
        return self.linked


class Cr6Chip:
    """The agents' chip interface (same methods as world.FakeChip) over a CR6 link.
    The laptop keeps its own world copy: ground(x, z) and block(x, y, z) come from its terrain
    model, plus every edit the chip acked. get() reads that copy (no UART); verify() asks the chip.
    ponytail: player edits reach the copy only through EDIT events (not wired yet)."""

    def __init__(self, link, ground, block):
        self.link, self.ground, self.block = link, ground, block
        self.mirror = {}
        self.ents = {}

    def place(self, x, y, z, b):
        ok = self.link.call(PLACE if b else BREAK, p_place(x, z, y, b) if b else p_break(x, z, y)) == "OK"
        if ok:
            self.mirror[(x, y, z)] = b
        return ok

    def fill(self, x, y, z, sx, sz, b):
        ok = self.link.call(FILL, p_fill(x, z, y, sx, 1, sz, b)) == "OK"
        if ok:
            self.mirror.update({(x + i, y, z + k): b for i in range(sx) for k in range(sz)})
        return ok

    def get(self, x, y, z):
        return self.mirror.get((x, y, z), self.block(x, y, z))

    def verify(self, x, y, z):
        if self.link.call(Q_BLOCKS, p_qblocks(x, z, y)) != "OK":
            return None
        _, p = self.link.replies.pop(self.link.seq, (None, b"\0"))
        return p[0] & 15

    def spawn(self, eid, kind, x, z):
        ok = self.link.call(SPAWN, p_spawn(eid, kind, x, z, self.ground(int(x), int(z)) + 1)) == "OK"
        if ok:
            self.ents[eid] = kind
        return ok

    def move(self, eid, tx, tz):
        return self.link.call(MOVE, p_move(eid, tx, tz)) == "OK"

    def entity(self, eid):
        if self.link.call(Q_ENTITY, bytes([eid])) != "OK":
            raise KeyError(eid)
        _, p = self.link.replies.pop(self.link.seq)
        _, x, z, y, _ = struct.unpack("<BHHBB", p)
        return x / 16, y / 8, z / 16


class FakeUartChip:
    """The chip's side of CR6 for tests and demos: a 16-byte RX FIFO that drops bytes when
    full, drained once per frame, commands checked and run on a world.FakeChip, one STATUS per
    drain once linked. Key bytes (not A5) count as keys. Not the real chip, but the same bytes."""

    def __init__(self, world, zone=None):
        self.world = world
        self.fifo = bytearray()
        self.dropped = 0
        self.drained = 0
        self.frame_no = 0
        self.dec = Decoder(max_len=9)
        self.linked = False
        self.last_result = R["OK"]
        self.last_seq = 0
        self.done_seqs = []
        self.keys = []
        self.zone = zone                # (x0, z0, x1, z1) player-set; None = anywhere
        self.tx = bytearray()

    # the UART: bytes arriving while the FIFO is full are lost (uart.sv)
    def write(self, data):
        for b in data:
            if len(self.fifo) < RX_DEPTH:
                self.fifo.append(b)
            else:
                self.dropped += 1

    def poll(self):
        """One frame: drain the FIFO, run commands, return the bytes the chip sends."""
        self.frame_no += 1
        data, self.fifo = bytes(self.fifo), bytearray()
        self.drained = (self.drained + len(data)) & 0xFF
        replies = bytearray()
        for item in self.dec.feed(data):
            if item[0] == "byte":
                self.keys.append(item[1])
            elif item[0] == "bad":
                self.dec.buf.clear()                         # CR6: drop the rest of the drain
                self.last_result = R["CRC"]
            else:
                replies += self._run(*item[1:])
        out = bytes(self.tx) + bytes(replies)
        self.tx.clear()
        if self.linked:
            out += frame(self.last_seq, STATUS, bytes([self.last_result, self.frame_no & 0xFF,
                                                       CREDIT, self.drained]))
        return out

    def _run(self, seq, op, p):
        self.last_seq = seq
        if op == HELLO:
            self.linked = p[:2] == b"KC"
            self.last_result = R["OK"]
            return frame(seq, HELLO_ACK, bytes([VERSION, RX_DEPTH, 1, 8, 0]) + struct.pack("<H", 1))
        if not self.linked:
            self.last_result = R["NOT_LINKED"]
            return b""
        if seq in self.done_seqs:                            # retransmit: OK without running again
            self.last_result = R["OK"]
            return b""
        self.done_seqs = (self.done_seqs + [seq])[-16:]
        res, reply = self._exec(seq, op, p)
        self.last_result = R[res]
        return reply

    def _in_zone(self, x, z):
        return self.zone is None or (self.zone[0] <= x < self.zone[2] and self.zone[1] <= z < self.zone[3])

    def _exec(self, seq, op, p):
        w = self.world
        try:
            if op in (PLACE, BREAK):
                x, z, y = struct.unpack("<HHB", p[:5])
                b = p[5] if op == PLACE else 0
                if op == PLACE and not 1 <= b <= 9:
                    return "BAD_BLOCK", b""
                if not self._in_zone(x, z):
                    return "OUT_OF_ZONE", b""
                return ("OK" if w.place(x, y, z, b) else "PROTECTED"), b""
            if op == FILL:
                x, z, y, a, c = struct.unpack("<HHBBB", p)
                sx, sz, sy, b = (a & 15) + 1, (a >> 4) + 1, (c & 15) + 1, c >> 4
                if b and not 1 <= b <= 9:
                    return "BAD_BLOCK", b""
                if not (self._in_zone(x, z) and self._in_zone(x + sx - 1, z + sz - 1)):
                    return "OUT_OF_ZONE", b""
                return ("OK" if all(w.fill(x, y + k, z, sx, sz, b) for k in range(sy)) else "PROTECTED"), b""
            if op == SPAWN:
                a, x, z, y = struct.unpack("<BHHB", p)
                return ("OK" if w.spawn(a & 15, a >> 4, x / 16, z / 16) else "BAD_ENTITY"), b""
            if op == MOVE:
                eid, x, z = struct.unpack("<BHH", p)
                return ("OK" if w.move(eid, x / 16, z / 16) else "BAD_ENTITY"), b""
            if op == Q_BLOCKS:
                x, z, y, d = struct.unpack("<HHBB", p)
                return "OK", frame(seq, R_BLOCKS, bytes([w.get(x, y, z)]))
            if op == Q_ENTITY:
                if p[0] not in w.ents:
                    return "BAD_ENTITY", b""
                x, y, z = w.entity(p[0])
                return "OK", frame(seq, R_ENTITY, struct.pack("<BHHBB", p[0], round(x * 16), round(z * 16),
                                                               round(y * 8), 0))
            if op in (SET_BALANCE, SET_QUOTE, SET_CONTRACT, STATE, BYE, Q_PLAYER, Q_INV):
                return "OK", b""
        except struct.error:
            return "BAD_OP", b""
        return "BAD_OP", b""

    def tick(self, dt):
        self.world.tick(dt)
