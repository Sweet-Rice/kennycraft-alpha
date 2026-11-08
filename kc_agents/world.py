"""Blocks, build plans and the chip interface the agents talk to.

A plan is a list of box ops in zone-local coordinates. expand() turns it into cells,
compress() turns cells into CR6 PLACE / FILL commands. FakeChip stands in for the board
(uart_bridge implements the same four methods over CR6).
"""
import random

BLOCKS = ["air", "grass", "dirt", "stone", "cobble", "log", "leaves", "planks", "sand", "brick", "bedrock"]
ID = {name: i for i, name in enumerate(BLOCKS)}
PLACEABLE = set(BLOCKS[1:10])          # CR6: only IDs 1-9 may be placed
BEDROCK = ID["bedrock"]
Y_MIN, Y_MAX = 1, 28                    # CR6: y = 0 and y > 28 are never written
ZONE_MAX = 16
OPS = ("fill", "hollow", "walls", "clear", "block")


def expand(ops, zone):
    """ops -> ({(x, y, z) zone-local: block id}, [errors]). Later ops win."""
    sx, sy, sz = zone
    cells, errors = {}, []
    for i, op in enumerate(ops):
        kind = op.get("op")
        at = op.get("at", [0, 0, 0])
        size = [1, 1, 1] if kind == "block" else op.get("size", [1, 1, 1])
        block = "air" if kind == "clear" else op.get("block", "")
        if kind not in OPS:
            errors.append(f"op {i}: unknown op {kind!r}, use one of {OPS}")
            continue
        if block != "air" and block not in PLACEABLE:
            errors.append(f"op {i}: block {block!r} can't be placed, use one of {sorted(PLACEABLE)}")
            continue
        if len(at) != 3 or len(size) != 3 or min(size) < 1:
            errors.append(f"op {i}: at and size must be [x, y, z] with sizes >= 1")
            continue
        x0, y0, z0 = at
        x1, y1, z1 = x0 + size[0], y0 + size[1], z0 + size[2]
        if min(x0, y0, z0) < 0 or x1 > sx or y1 > sy or z1 > sz:
            errors.append(f"op {i}: box {at}+{size} leaves the zone {list(zone)}")
            continue
        for x in range(x0, x1):
            for y in range(y0, y1):
                for z in range(z0, z1):
                    side = x in (x0, x1 - 1) or z in (z0, z1 - 1)
                    if kind == "walls" and not side:
                        continue
                    if kind == "hollow" and not (side or y in (y0, y1 - 1)):
                        continue
                    cells[(x, y, z)] = ID[block]
    return cells, errors


def compress(cells):
    """{(x, y, z): id} -> CR6 commands, greedy same-block rectangles per layer.
    Each command is ("place", x, y, z, id) or ("fill", x, y, z, sx, sz, id), bottom layer first."""
    left = dict(cells)
    cmds = []
    for (x, y, z) in sorted(cells, key=lambda c: (c[1], c[2], c[0])):
        if (x, y, z) not in left:
            continue
        b = left[(x, y, z)]
        w = 1
        while w < ZONE_MAX and left.get((x + w, y, z)) == b:
            w += 1
        d = 1
        while d < ZONE_MAX and all(left.get((x + i, y, z + d)) == b for i in range(w)):
            d += 1
        for i in range(w):
            for k in range(d):
                del left[(x + i, y, z + k)]
        cmds.append(("place", x, y, z, b) if w * d == 1 else ("fill", x, y, z, w, d, b))
    return cmds


KINDS = {"trader": 0, "contractor": 1, "pig": 2, "zombie": 3}      # game/src/entity.h order
SPEED = {0: 1.5, 1: 1.5, 2: 1.0, 3: 1.2}                            # blocks/s, entity.c walk_speed
ENT_MAX = 8


class FakeChip:
    """The chip as the agents see it: ground height, read a cell, place, fill, and entities
    (CR6 SPAWN / MOVE). Rough terrain, and the same checks CR6 puts on the chip."""

    def __init__(self, seed=1):
        self.blocks = {}
        self.heights = {}
        self.ents = {}                  # id -> {"kind", "pos": [x, y, z], "tgt": [x, z]}
        self.reject_rate = 0.0
        self.rnd = random.Random(seed)

    # ---- entities, as game/src/entity.c does them --------------------------------------
    def spawn(self, eid, kind, x, z):
        if not 0 <= eid < ENT_MAX or kind not in SPEED:
            return False
        self.ents[eid] = {"kind": kind, "pos": [x, self.ground(int(x), int(z)) + 1, z], "tgt": [x, z]}
        return True

    def move(self, eid, tx, tz):
        if eid not in self.ents:
            return False
        self.ents[eid]["tgt"] = [tx, tz]
        return True

    def entity(self, eid):
        return tuple(self.ents[eid]["pos"])

    def tick(self, dt):
        for e in self.ents.values():
            step = SPEED[e["kind"]] * dt
            p, t = e["pos"], e["tgt"]
            for a, b in ((0, 0), (2, 1)):
                p[a] += max(-step, min(step, t[b] - p[a]))
            p[1] = self.ground(int(p[0] // 1), int(p[2] // 1)) + 1

    def ground(self, x, z):
        if (x, z) not in self.heights:
            self.heights[(x, z)] = 10 + (x * 7 + z * 13) % 3 // 2   # gentle 10/11 bumps
        return self.heights[(x, z)]

    def get(self, x, y, z):
        if (x, y, z) in self.blocks:
            return self.blocks[(x, y, z)]
        g = self.ground(x, z)
        return BEDROCK if y == 0 else ID["grass"] if y == g else ID["dirt"] if y < g else 0

    def _ok(self, y, b):
        return Y_MIN <= y <= Y_MAX and (b == 0 or b in range(1, 10)) and self.rnd.random() >= self.reject_rate

    def place(self, x, y, z, b):
        if not self._ok(y, b) or self.get(x, y, z) == BEDROCK:
            return False
        self.blocks[(x, y, z)] = b
        return True

    def fill(self, x, y, z, sx, sz, b):
        if sx * sz > 256 or not self._ok(y, b):
            return False
        for i in range(sx):
            for k in range(sz):
                if self.get(x + i, y, z + k) != BEDROCK:
                    self.blocks[(x + i, y, z + k)] = b
        return True
