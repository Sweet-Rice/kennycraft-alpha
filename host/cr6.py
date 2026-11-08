"""CR6 UART command frames (wiki Shared.md, CR6 / D8): A5 | len | seq | op | payload (0..7) | crc8.

Bridge is the laptop end: one command in flight, so a frame never exceeds the
chip's credit (RX_DEPTH - RX_RESERVE = 12 B). FakeChip is a stand-in for the
board that answers the same bytes, with the chip's checks, for laptop-only runs.
"""
import asyncio
import struct

SYNC = 0xA5
HELLO, BYE, PLACE, BREAK, FILL = 0x01, 0x02, 0x10, 0x11, 0x12
SPAWN, MOVE = 0x20, 0x21
Q_PLAYER, Q_BLOCKS, Q_ENTITY = 0x30, 0x31, 0x33
SET_BALANCE, SET_QUOTE, SET_CONTRACT = 0x40, 0x41, 0x42
STATUS, HELLO_ACK, R_PLAYER, R_BLOCKS, R_ENTITY, EVENT = 0x81, 0x82, 0x83, 0x84, 0x86, 0x8F
RESULTS = ["OK", "CRC", "BAD_OP", "OUT_OF_ZONE", "BAD_BLOCK", "PROTECTED", "RATE", "BUSY",
           "NOT_LINKED", "BAD_ENTITY"]
EV_EDIT, EV_HIT, EV_INTERACT, EV_CONFIRM = 1, 2, 3, 4
RX_DEPTH, RX_RESERVE = 16, 4


def crc8(data):
    c = 0
    for b in data:
        c ^= b
        for _ in range(8):
            c = ((c << 1) ^ 0x07) & 0xFF if c & 0x80 else (c << 1) & 0xFF
    return c


def frame(seq, op, payload=b""):
    body = bytes([2 + len(payload), seq, op]) + payload
    return bytes([SYNC]) + body + bytes([crc8(body)])


class Decoder:
    """Bytes in, (seq, op, payload) out. Non-frame bytes (debug text, keys) are skipped;
    a bad CRC drops the frame."""
    def __init__(self, max_len):
        self.buf, self.max_len, self.bad = bytearray(), max_len, 0

    def feed(self, data):
        self.buf += data
        out = []
        while True:
            i = self.buf.find(SYNC)
            if i < 0:
                self.buf.clear()
                return out
            del self.buf[:i]
            if len(self.buf) < 2:
                return out
            n = self.buf[1]
            if not 2 <= n <= self.max_len:
                del self.buf[:1]
                continue
            if len(self.buf) < n + 3:
                return out
            body, crc = bytes(self.buf[1:n + 2]), self.buf[n + 2]
            if crc8(body) == crc:
                out.append((body[1], body[2], body[3:]))
                del self.buf[:n + 3]
            else:
                self.bad += 1
                del self.buf[:1]


class Bridge:
    """Laptop end of the link. write(bytes) goes to the chip; call feed() with bytes from it."""
    def __init__(self, write, timeout=1.0, on_link=None):
        self.write, self.timeout, self.on_link = write, timeout, on_link
        self.dec = Decoder(max_len=42)
        self.seq, self.lock, self.waiting, self.reply = 0, asyncio.Lock(), None, None
        self.events = asyncio.Queue()
        self.boot = None

    def feed(self, data):
        for seq, op, p in self.dec.feed(data):
            if op == EVENT and seq == 0:
                code, arg = struct.unpack("<BH", p[:3])
                self.events.put_nowait((code, arg))
            elif op == HELLO_ACK:
                self.boot = struct.unpack("<H", p[5:7])[0]
                if self.waiting and not self.waiting.done():
                    self.waiting.set_result(("OK", p))
                if self.on_link:
                    self.on_link(self.boot)
            elif op in (R_PLAYER, R_BLOCKS, R_ENTITY):
                self.reply = (seq, p)
            elif op == STATUS and self.waiting and not self.waiting.done() and seq == self.seq:
                reply = self.reply[1] if self.reply and self.reply[0] == seq else None
                self.waiting.set_result((RESULTS[p[0]] if p[0] < len(RESULTS) else str(p[0]), reply))

    async def send(self, op, payload=b"", tries=None):
        """Send one command and wait for its STATUS. Retransmits the same seq on timeout
        (the chip runs a seq only once). Returns (result, reply payload or None)."""
        async with self.lock:
            self.seq = self.seq % 255 + 1
            self.reply = None
            n = 0
            while True:
                self.waiting = asyncio.get_running_loop().create_future()
                self.write(frame(self.seq, op, payload))
                try:
                    return await asyncio.wait_for(asyncio.shield(self.waiting), self.timeout)
                except asyncio.TimeoutError:
                    n += 1
                    if tries is not None and n >= tries:
                        raise

    async def hello(self):
        return await self.send(HELLO, b"KC\x01")


class FakeChip:
    """Board stand-in at the byte level: world, HUD and the CR6 chip-side checks.
    deliver(bytes) carries its frames back to the bridge."""
    def __init__(self, deliver, frame_s=0.05, player=(200, 200, 9), boot=1):
        self.deliver, self.frame_s, self.boot = deliver, frame_s, boot
        self.dec = Decoder(max_len=9)
        self.player = player
        px, pz, py = player
        self.zone = (px - 8, pz - 8, max(1, py - 4), 16)   # x0, z0, y0, size: set on the chip, not by the laptop
        self.world, self.entities = {}, []
        self.ground = py - 1
        self.linked, self.frame_no, self.drained = False, 0, 0
        self.last = (None, 0)                               # (seq, result) for retransmits
        self.hud = {"kcn": 0, "quote": (0, 0), "contracts": {}}
        self.edited_this_frame = False

    def block(self, x, z, y):
        return self.world.get((x, z, y), 3 if y < self.ground else (1 if y == self.ground else 0))

    def receive(self, data):
        self.drained = (self.drained + len(data)) & 0xFF
        frames = self.dec.feed(data)
        asyncio.get_running_loop().call_later(self.frame_s, self.run_frame, frames)

    def send(self, seq, op, payload=b""):
        self.deliver(frame(seq, op, payload))

    def run_frame(self, frames):
        self.frame_no += 1
        self.edited_this_frame = False
        for seq, op, p in frames:
            if seq == self.last[0] and op != HELLO:
                self.status(seq, self.last[1])              # retransmit: answer, don't rerun
                continue
            res = self.run(seq, op, p)
            self.last = (seq, res)
            if res is not None:
                self.status(seq, res)

    def status(self, seq, res):
        self.send(seq, STATUS, bytes([res, self.frame_no & 0xFF, RX_DEPTH - RX_RESERVE, self.drained]))

    def run(self, seq, op, p):
        if op == HELLO:
            self.linked = p == b"KC\x01"
            if self.linked:
                self.send(seq, HELLO_ACK, struct.pack("<BBBBBH", 1, RX_DEPTH, 1, 16, 0, self.boot))
            return None if self.linked else 2
        if not self.linked:
            return 8
        try:
            if op == PLACE:
                x, z, y, t = struct.unpack("<HHBB", p)
                return self.edit(x, z, y, t)
            if op == BREAK:
                x, z, y = struct.unpack("<HHB", p)
                return self.edit(x, z, y, 0)
            if op == FILL:
                x, z, y, a, c = struct.unpack("<HHBBB", p)
                return self.fill(x, z, y, (a & 15) + 1, (c & 15) + 1, (a >> 4) + 1, c >> 4)
            if op == MOVE:
                eid, x, z = struct.unpack("<BHH", p)
                eid &= 0x7F                                  # bit 7: teleport; the fake chip has no walking
                if eid >= len(self.entities):
                    return 9
                k, _, _, y = self.entities[eid]
                self.entities[eid] = (k, x / 16, z / 16, y)
                return 0
            if op == SPAWN:
                eid, x, z, y = struct.unpack("<BHHB", p)
                if eid & 15 != len(self.entities):
                    return 9                                 # BAD_ENTITY: ids come in order
                self.entities.append((eid >> 4, x / 16, z / 16, y / 8))
                return 0
            if op == Q_ENTITY:
                if p[0] >= len(self.entities):
                    return 9
                _, x, z, y = self.entities[p[0]]
                self.send(seq, R_ENTITY, struct.pack("<BHHBB", p[0], round(x * 16), round(z * 16), round(y * 8), 0))
                return 0
            if op == Q_PLAYER:
                px, pz, py = self.player
                self.send(seq, R_PLAYER, struct.pack("<HHB", px * 16, pz * 16, py * 8))
                return 0
            if op == Q_BLOCKS:
                # x, z, y, (sx-1) | (sy-1) << 2 | (sz-1) << 4; nibbles x fastest, then z, then y
                x, z, y, s = struct.unpack("<HHBB", p)
                if s & 0xC0:
                    return 2
                cells = [self.block(x + i, z + k, y + j) for j in range((s >> 2 & 3) + 1)
                         for k in range((s >> 4) + 1) for i in range((s & 3) + 1)]
                cells += [0] * (len(cells) & 1)
                self.send(seq, R_BLOCKS, bytes(a | b << 4 for a, b in zip(cells[::2], cells[1::2])))
                return 0
            if op == SET_BALANCE:
                self.hud["kcn"] = struct.unpack("<H", p)[0]
                return 0
            if op == SET_QUOTE:
                self.hud["quote"] = struct.unpack("<BH", p)
                return 0
            if op == SET_CONTRACT:
                t, v = struct.unpack("<BB", p)
                self.hud["contracts"][t] = (v >> 6, v & 63)
                return 0
        except struct.error:
            return 2
        return 2

    def edit(self, x, z, y, t):
        if self.edited_this_frame:
            return 6                                         # RATE: one edit command per frame
        x0, z0, y0, n = self.zone
        if not (x0 <= x < x0 + n and z0 <= z < z0 + n and y0 <= y < y0 + n and 1 <= y <= 28):
            return 3
        if t > 9 or (t == 0 and self.block(x, z, y) == 10):
            return 4
        px, pz, py = self.player
        if (x, z) == (px, pz) and y in (py, py + 1):
            return 5                                         # never inside the player box
        if t and self.block(x, z, y):
            return 5                                         # PLACE only into air
        self.edited_this_frame = True
        self.world[(x, z, y)] = t
        return 0

    def fill(self, x, z, y, sx, sy, sz, t):
        """FILL as cr6.c runs it: the whole box in the zone, air cells only (never overwrites)."""
        if self.edited_this_frame:
            return 6
        x0, z0, y0, n = self.zone
        if not (x0 <= x and x + sx <= x0 + n and z0 <= z and z + sz <= z0 + n
                and y0 <= y and y + sy <= y0 + n and 1 <= y and y + sy - 1 <= 28):
            return 3
        if t > 9:
            return 4
        px, pz, py = self.player
        if t and x <= px < x + sx and z <= pz < z + sz and y <= py + 1 and py < y + sy:
            return 5
        self.edited_this_frame = True
        for i in range(sx):
            for k in range(sz):
                for j in range(sy):
                    old = self.block(x + i, z + k, y + j)
                    if old != 10 and (old == 0 or not t):
                        self.world[(x + i, z + k, y + j)] = t
        return 0

    def event(self, code, arg):
        self.send(0, EVENT, struct.pack("<BH", code, arg))

    def interact(self, entity):
        self.event(EV_INTERACT, entity)

    def confirm(self, yes):
        qid = self.hud["quote"][0]
        if qid:
            self.event(EV_CONFIRM, qid | (1 if yes else 0) << 8)
