"""Contracts: the villagers you hire, refereed by the chip.

QUOTED -> FUNDED -> WORKING -> VERIFYING -> RELEASED, plus QUOTED -> EXPIRED and
FUNDED/WORKING/VERIFYING -> REFUNDED. Money only moves through the ledger
(player -> escrow on Y, escrow -> contractor 90% + treasury 10% once the chip
confirms the work). One open contract per contractor type.
"""
import asyncio
import random
import re
import struct
import time
from dataclasses import dataclass, field

import cr6
from bank import InsufficientFunds, clamp_price, rule_price

TYPES = ["builder", "miner", "farmer"]                      # contract type byte = index
# Villagers the laptop spawns next to the player (CR6 SPAWN): role, entity kind
# (game/src/entity.h: 0 trader, 1 contractor), offset from the player in blocks.
# West of the player, so they never stand in the hut (built to the east).
VILLAGERS = [("banker", 0, -3, 1), ("builder", 1, -3, -1)]
OPEN = ("QUOTED", "FUNDED", "WORKING", "VERIFYING")
HUD_STATE = {"FUNDED": 1, "WORKING": 1, "VERIFYING": 2, "RELEASED": 3}   # 2-bit state on the chip
MATERIALS = {"grass": 1, "dirt": 2, "stone": 3, "cobble": 4, "log": 5, "wood": 5, "leaves": 6,
             "plank": 7, "sand": 8, "brick": 9}


@dataclass
class Contract:
    id: int
    kind: str
    text: str
    blueprint: list
    rule: int
    price: int
    state: str = "QUOTED"
    placed: list = field(default_factory=list)
    rejected: int = 0
    note: str = ""
    cancel: bool = False
    ts: float = field(default_factory=time.time)


def plan_hut(text, player):
    """'4x4 dirt hut' -> hollow walls 2 high with a door, flat roof, east of the player."""
    m = re.search(r"(\d)\s*[x×]\s*(\d)", text)
    sx, sz = (min(max(int(m[1]), 3), 7), min(max(int(m[2]), 3), 7)) if m else (4, 4)
    t = next((v for k, v in MATERIALS.items() if k in text.lower()), 2)
    px, pz, py = player
    x0, z0 = px + 2, pz - sz // 2
    cells = []
    for y in (py, py + 1):
        for x in range(x0, x0 + sx):
            for z in range(z0, z0 + sz):
                wall = x in (x0, x0 + sx - 1) or z in (z0, z0 + sz - 1)
                door = x == x0 and z == z0 + sz // 2
                if wall and not door:
                    cells.append((x, z, y, t))
    cells += [(x, z, py + 2, t) for x in range(x0, x0 + sx) for z in range(z0, z0 + sz)]
    return cells


class Orchestrator:
    def __init__(self, ledger, bridge, pricer=None, quote_s=30, stall_s=20, on_change=lambda: None):
        self.ledger, self.bridge, self.pricer = ledger, bridge, pricer
        self.quote_s, self.stall_s, self.on_change = quote_s, stall_s, on_change
        self.contracts, self.prompt, self.roles = {}, None, {}   # roles: entity id -> villager
        # Continue numbering after a restart so KC#<id> memos stay unique on chain.
        self.next_id = (ledger.db.execute("SELECT MAX(contract_id) FROM entries").fetchone()[0] or 0) + 1
        self.tasks = set()

    def spawn(self, coro):
        t = asyncio.create_task(coro)
        self.tasks.add(t)
        t.add_done_callback(self.tasks.discard)

    def open(self, kind):
        return next((c for c in self.contracts.values() if c.kind == kind and c.state in OPEN), None)

    async def hud(self, c=None):
        await self.send(cr6.SET_BALANCE, struct.pack("<H", min(self.ledger.balance("player"), 65535)))
        if c:
            prog = len(c.placed) * 63 // max(1, len(c.blueprint))
            await self.send(cr6.SET_CONTRACT, struct.pack("<BB", TYPES.index(c.kind),
                                                                 HUD_STATE.get(c.state, 0) << 6 | prog))
        self.on_change()

    async def spawn_villagers(self):
        _, p = await self.send(cr6.Q_PLAYER)
        x, z, y = struct.unpack("<HHB", p)
        for i, (role, kind, dx, dz) in enumerate(VILLAGERS):
            # BAD_ENTITY here means the chip already has them (kc-host restarted, chip didn't).
            await self.send(cr6.SPAWN, struct.pack("<BHHB", i | kind << 4, x + dx * 16, z + dz * 16, y))
            self.roles[i] = role

    async def resync(self):
        """After HELLO_ACK: a rebooted chip kept nothing, so send everything again."""
        await self.spawn_villagers()
        await self.hud()
        for c in self.contracts.values():
            if c.state == "QUOTED":
                await self.send(cr6.SET_QUOTE, struct.pack("<BH", c.id & 0xFF, c.price))
            elif c.state in OPEN:
                await self.hud(c)

    async def events(self):
        while True:
            code, arg = await self.bridge.events.get()
            if code == cr6.EV_INTERACT and arg in self.roles:
                self.prompt = self.roles[arg]
                self.on_change()
            elif code == cr6.EV_CONFIRM:
                c = next((c for c in self.contracts.values() if c.id & 0xFF == arg & 0xFF), None)
                if c:
                    await self.confirm(c.id, bool(arg >> 8))

    async def request(self, kind, text):
        if kind not in TYPES:
            raise ValueError(f"no contractor {kind!r}")
        if self.open(kind):
            raise ValueError(f"the {kind} already has an open contract")
        _, p = await self.send(cr6.Q_PLAYER)
        x, z, y = struct.unpack("<HHB", p)
        blueprint = plan_hut(text, (x // 16, z // 16, y // 8))
        rule = rule_price(len(blueprint))
        proposed = await self.pricer(text, len(blueprint), rule) if self.pricer else None
        price = clamp_price(proposed if proposed is not None else rule, rule)
        have = self.ledger.balance("player")
        if price > have:
            raise InsufficientFunds(f"the quote is {price} KCN and you have {have}")
        c = Contract(self.next_id, kind, text, blueprint, rule, price)
        self.next_id += 1
        self.contracts[c.id] = c
        await self.send(cr6.SET_QUOTE, struct.pack("<BH", c.id & 0xFF, price))
        self.on_change()
        self.spawn(self.expire(c))
        return c

    async def expire(self, c):
        await asyncio.sleep(self.quote_s)
        if c.state == "QUOTED":
            await self.close_quote(c, "EXPIRED", "quote expired")

    async def close_quote(self, c, state, note):
        c.state, c.note = state, note
        await self.send(cr6.SET_QUOTE, struct.pack("<BH", 0, 0))
        self.on_change()

    async def confirm(self, cid, yes):
        c = self.contracts.get(cid)
        if not c or c.state != "QUOTED":
            return
        if not yes:
            return await self.close_quote(c, "EXPIRED", "declined")
        try:
            self.ledger.post("fund", "player", "escrow", c.price, c.id)
        except InsufficientFunds as x:
            return await self.close_quote(c, "EXPIRED", str(x))
        c.state = "FUNDED"
        await self.send(cr6.SET_QUOTE, struct.pack("<BH", 0, 0))
        await self.hud(c)
        self.spawn(self.work(c))

    async def cancel(self, cid):
        c = self.contracts.get(cid)
        if c and c.state == "QUOTED":
            await self.close_quote(c, "EXPIRED", "cancelled")
        elif c and c.state in OPEN:
            c.cancel = True

    async def send(self, op, payload=b""):
        return await asyncio.wait_for(self.bridge.send(op, payload), self.stall_s)

    async def work(self, c):
        c.state = "WORKING"
        last = None
        try:
            for x, z, y, t in c.blueprint:
                if c.cancel:
                    return await self.refund(c, "cancelled")
                res, _ = await self.send(cr6.PLACE, struct.pack("<HHBB", x, z, y, t))
                if res == "OK":
                    c.placed.append((x, z, y, t))
                else:
                    c.rejected += 1
                    if c.rejected * 10 > len(c.blueprint):
                        return await self.refund(c, f"chip rejected {c.rejected} commands (last: {res})")
                prog = len(c.placed) * 63 // len(c.blueprint)
                if prog != last:
                    last = prog
                    await self.hud(c)
            c.state = "VERIFYING"
            await self.hud(c)
            for x, z, y, t in random.sample(c.placed, min(8, len(c.placed))):
                _, p = await self.send(cr6.Q_BLOCKS, struct.pack("<HHBB", x, z, y, 0))   # one cell
                if not p or p[0] & 15 != t:
                    return await self.refund(c, f"spot check failed at {x},{z},{y}")
        except asyncio.TimeoutError:
            return await self.refund(c, f"no answer from the chip for {self.stall_s} s")
        pay = c.price * 9 // 10
        self.ledger.post("release", "escrow", c.kind, pay, c.id)
        self.ledger.post("fee", "escrow", "treasury", c.price - pay, c.id)
        c.state = "RELEASED"
        await self.hud(c)

    async def refund(self, c, why):
        """Pay for the blocks placed so far; the player gets the rest. Placed blocks stay."""
        earned = c.price * len(c.placed) // len(c.blueprint)
        if earned:
            self.ledger.post("release", "escrow", c.kind, earned, c.id)
        if c.price - earned:
            self.ledger.post("refund", "escrow", "player", c.price - earned, c.id)
        c.state, c.note = "REFUNDED", why
        try:
            await self.hud(c)
        except asyncio.TimeoutError:
            self.on_change()
