"""Contracts: the kc_agents builder agent (Nemotron) hired through the chip, paid through the ledger.

The agent runs in a worker thread (its tool loop and the OpenAI client are blocking). Every
tool it calls lands here, in Job, which is the chip and the bank as kc_agents sees them
(kc_agents/world.FakeChip and kc_agents/bank.FakeBank methods): chip calls go over CR6,
money goes into the ledger, both on the event loop. The agent only picks tools; the
kc_agents Contract state machine decides what is allowed, and the chip checks every edit.

States (kc_agents Contract): SURVEY -> PLANNED -> FUNDED -> BUILT -> VERIFIED -> PAID,
plus DECLINED, CANCELLED and REFUNDED. One open contract per contractor type.
"""
import asyncio
import os
import struct
import time
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from kc_agents import builder                             # noqa: E402
from kc_agents.bank import FEE                            # noqa: E402

import cr6                                                # noqa: E402

TYPES = ["builder", "miner", "farmer"]                      # contract type byte = index
# Villagers the laptop spawns next to the player (CR6 SPAWN): role, entity kind
# (game/src/entity.h: 0 trader, 1 contractor), offset from the player in blocks.
# Beside the player (north and south, within E's 3-block reach), clear of the site to the
# east and of the camera stepping back west to watch the build.
VILLAGERS = [("banker", 0, -1, 3), ("builder", 1, -1, -3)]
OPEN = ("SURVEY", "PLANNED", "FUNDED", "BUILT", "VERIFIED")
HUD_STATE = {"FUNDED": 1, "BUILT": 2, "VERIFIED": 2, "PAID": 3}   # 2-bit state on the chip
SITE = (6, 8, 6)        # x, y, z: east of the player, inside the chip's 16^3 zone around them
RETRY = ("RATE", "BUSY")


def chat():
    """Nemotron Super when NVIDIA_API_KEY is set (or NEMOTRON_BASE_URL points at a Brev/local
    server), else the scripted demo builder: same tool calls, fixed hut, no network."""
    if os.environ.get("NVIDIA_API_KEY") or os.environ.get("NEMOTRON_BASE_URL"):
        from kc_agents.llm import nemotron_chat
        return nemotron_chat()
    from kc_agents.demo import scripted_builder
    return scripted_builder()


class Cancelled(Exception):
    pass


class Job:
    """One hire. Chip methods (ground/get/place/fill/verify/move) and bank methods
    (balance/fund/release/refund) for kc_agents' Contract, called from the agent's thread."""

    def __init__(self, orch, cid, kind, text, zone):
        self.orch, self.id, self.kind, self.text = orch, cid, kind, text
        self.zone = zone                    # chip's zone: x0, y0, z0 (16^3), set when E was pressed
        self.known, self.mirror = {}, {}    # chip blocks read once, then every acked edit
        self.contract, self.note, self.cancel, self.answer, self.over = None, "", False, None, False
        self.hud_v = None

    # -- plumbing -------------------------------------------------------------------------
    def sync(self, coro):
        if self.cancel:
            coro.close()
            raise Cancelled
        return asyncio.run_coroutine_threadsafe(coro, self.orch.loop).result()

    async def _ledger(self, kind, src, dst, amount):
        if amount > 0:
            self.orch.ledger.post(kind, src, dst, amount, self.id)
        await self.orch.hud(self)

    # -- chip -----------------------------------------------------------------------------
    def scan(self, x0, z0, sx, sz, y0, sy):
        """Read a box of blocks with Q_BLOCKS (4x4x4 per call) into self.known."""
        for y in range(y0, y0 + sy, 4):
            for z in range(z0, z0 + sz, 4):
                for x in range(x0, x0 + sx, 4):
                    _, p = self.sync(self.orch.send(cr6.Q_BLOCKS, struct.pack("<HHBB", x, z, y, 0x3F)))
                    p = p or b""
                    c = 0
                    for j in range(4):
                        for k in range(4):
                            for i in range(4):
                                v = p[c >> 1] >> (c & 1) * 4 & 15 if c >> 1 < len(p) else 0
                                self.known[(x + i, y + j, z + k)] = v
                                c += 1

    def ground(self, x, z):
        ys = [y for (a, y, b), v in self.known.items() if (a, b) == (x, z) and v]
        return max(ys) if ys else self.zone[1] - 1

    def get(self, x, y, z):
        return self.mirror.get((x, y, z), self.known.get((x, y, z), 0))

    def _edit(self, op, payload, cells):
        res = self.sync(self.orch.edit(self, op, payload))
        if res == "OK":
            self.mirror.update(cells)
        return res == "OK"

    def place(self, x, y, z, b):
        if b:
            return self._edit(cr6.PLACE, struct.pack("<HHBB", x, z, y, b), {(x, y, z): b})
        return self._edit(cr6.BREAK, struct.pack("<HHB", x, z, y), {(x, y, z): 0})

    def fill(self, x, y, z, sx, sz, b):
        cells = {(x + i, y, z + k): b for i in range(sx) for k in range(sz) if not self.get(x + i, y, z + k)}
        return self._edit(cr6.FILL, struct.pack("<HHBBB", x, z, y, (sx - 1) | (sz - 1) << 4, b << 4), cells)

    def verify(self, x, y, z):
        _, p = self.sync(self.orch.send(cr6.Q_BLOCKS, struct.pack("<HHBB", x, z, y, 0)))
        return p[0] & 15 if p else None

    def move(self, eid, tx, tz):
        res, _ = self.sync(self.orch.send(cr6.MOVE, struct.pack("<BHH", eid, round(tx * 16), round(tz * 16))))
        return res == "OK"

    # -- bank -----------------------------------------------------------------------------
    def balance(self, wallet="player"):
        return self.sync(self._read(wallet))

    async def _read(self, wallet):          # sqlite connections stay on the loop's thread
        return self.orch.ledger.balance(wallet)

    def fund(self, contract, amount):
        self.sync(self._ledger("fund", "player", "escrow", amount))

    def release(self, contract, amount, to=None):
        fee = round(amount * FEE)
        self.sync(self._ledger("release", "escrow", self.kind, amount - fee))
        self.sync(self._ledger("fee", "escrow", "treasury", fee))

    def refund(self, contract, amount, paid_to_builder=0, to=None):
        self.sync(self._ledger("release", "escrow", self.kind, paid_to_builder))
        self.sync(self._ledger("refund", "escrow", "player", amount - paid_to_builder))

    def ask(self, question):
        self.orch.loop.call_soon_threadsafe(self.orch.say, f"{self.kind}: {question}")
        return self.sync(self.orch.ask(self, self.contract.offer))

    # -- page -----------------------------------------------------------------------------
    @property
    def state(self):
        return self.contract.state if self.contract else "CANCELLED" if self.over else "SURVEY"

    def progress(self):
        t = self.contract.target if self.contract else {}
        return sum(self.get(*c) == b for c, b in t.items()), len(t)


class Orchestrator:
    def __init__(self, ledger, bridge, chat=chat, quote_s=30, stall_s=20, on_change=lambda: None, say=lambda t: None):
        self.ledger, self.bridge, self.chat = ledger, bridge, chat
        self.quote_s, self.stall_s, self.on_change, self.say = quote_s, stall_s, on_change, say
        self.jobs, self.prompt, self.roles, self.zone = {}, None, {}, None   # roles: entity id -> villager
        # Continue numbering after a restart so KC#<id> memos stay unique on chain.
        self.next_id = (ledger.db.execute("SELECT MAX(contract_id) FROM entries").fetchone()[0] or 0) + 1
        self.tasks = set()
        self.loop, self.hud_kcn = None, None

    def spawn(self, coro):
        t = asyncio.create_task(coro)
        self.tasks.add(t)
        t.add_done_callback(self.tasks.discard)

    def open(self, kind):
        return next((j for j in self.jobs.values() if j.kind == kind and j.state in OPEN), None)

    async def send(self, op, payload=b""):
        return await asyncio.wait_for(self.bridge.send(op, payload), self.stall_s)

    async def edit(self, job, op, payload):
        """One edit command; the chip's cell bucket and chunk loads say "later" (RATE, BUSY)."""
        for _ in range(100):
            res, _ = await self.send(op, payload)
            if res not in RETRY:
                break
            await asyncio.sleep(0.05)
        await self.hud(job)
        return res

    async def hud(self, job=None):
        """Send the balance and the job's bar, only when they changed (resync clears the cache)."""
        kcn = min(self.ledger.balance("player"), 65535)
        if kcn != self.hud_kcn:
            await self.send(cr6.SET_BALANCE, struct.pack("<H", kcn))
            self.hud_kcn = kcn
        if job:
            done, total = job.progress()
            v = HUD_STATE.get(job.state, 0) << 6 | done * 63 // max(1, total)
            if v != job.hud_v:
                await self.send(cr6.SET_CONTRACT, struct.pack("<BB", TYPES.index(job.kind), v))
                job.hud_v = v
        self.on_change()

    async def player(self):
        _, p = await self.send(cr6.Q_PLAYER)
        x, z, y = struct.unpack("<HHB", p)
        return x // 16, z // 16, y // 8

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
        self.hud_kcn = None
        await self.hud()
        for j in self.jobs.values():
            j.hud_v = None
            if j.state in OPEN:
                await self.hud(j)
            if j.answer and not j.answer.done():
                await self.send(cr6.SET_QUOTE, struct.pack("<BH", j.id & 0xFF, j.contract.offer))

    async def mark_zone(self):
        """The chip marks its 16^3 contract zone around the player when E is pressed (cr6.c)."""
        px, pz, py = await self.player()
        self.zone = (px - 8, max(1, py - 4), pz - 8)

    async def events(self):
        while True:
            code, arg = await self.bridge.events.get()
            if code == cr6.EV_INTERACT and arg in self.roles:
                self.prompt = self.roles[arg]
                await self.mark_zone()
                self.on_change()
            elif code == cr6.EV_CONFIRM:
                j = next((j for j in self.jobs.values() if j.id & 0xFF == arg & 0xFF), None)
                if j:
                    self.confirm(j.id, bool(arg >> 8))

    async def request(self, kind, text):
        """Hire a contractor; the agent surveys, plans and quotes in the background."""
        if kind not in TYPES:
            raise ValueError(f"no contractor {kind!r}")
        if self.open(kind):
            raise ValueError(f"the {kind} already has an open contract")
        if not self.zone:
            await self.mark_zone()      # page-only runs; on the chip, E already marked it
        job = Job(self, self.next_id, kind, text, self.zone)
        self.next_id += 1
        self.jobs[job.id] = job
        self.on_change()
        self.loop = asyncio.get_running_loop()
        self.spawn(self.run(job))
        return job

    async def run(self, job):
        x0, y0, z0 = job.zone
        site = (x0 + 10, z0 + 8 - SITE[2] // 2)    # 2 blocks east of where the player stood at E
        worker = next((i for i, r in self.roles.items() if r == job.kind), None)
        try:
            await asyncio.to_thread(self._agent, job, site, worker, y0)
        except Exception as x:          # chip stall, model error, player cancel
            job.note = ("cancelled" if isinstance(x, Cancelled) else
                        f"no answer from the chip for {self.stall_s} s" if isinstance(x, asyncio.TimeoutError)
                        else f"{type(x).__name__}: {x}")
        await self.stop(job)            # the agent may also just stop talking before it quoted
        self.say(f"{job.kind} #{job.id}: {job.state} {job.note}")
        try:
            await self.hud(job)
        except asyncio.TimeoutError:
            self.on_change()
        job.over = True

    def _agent(self, job, site, worker, y0):
        job.scan(site[0], site[1], SITE[0], SITE[2], y0, 16)
        job.contract = builder.Contract(job.id, job, job, job.ask, origin=site, zone=SITE, worker=worker)
        reply = builder.run(job.text, job.contract, self.chat(),
                            log=lambda t: print(time.strftime("%H:%M:%S"), f"#{job.id}", t, file=sys.stderr, flush=True))
        job.note = job.note or reply or ""      # "quote expired" beats the agent's sign-off

    async def stop(self, job):
        """Refund whatever the agent left open: the builder keeps pay for the blocks placed."""
        if job.contract and job.state in OPEN:
            c = job.contract
            done, total = job.progress()
            earned = c.price * done // max(1, total)
            if c.state in ("FUNDED", "BUILT", "VERIFIED"):
                if earned:
                    self.ledger.post("release", "escrow", job.kind, earned, job.id)
                if c.price - earned:
                    self.ledger.post("refund", "escrow", "player", c.price - earned, job.id)
                c.state = "REFUNDED"
            else:
                c.state = "CANCELLED"

    async def ask(self, job, price):
        """Show the quote on the chip; Y/N there (or on the page) answers, else it expires."""
        job.answer = asyncio.get_running_loop().create_future()
        await self.send(cr6.SET_QUOTE, struct.pack("<BH", job.id & 0xFF, price))
        self.on_change()
        try:
            yes = await asyncio.wait_for(job.answer, self.quote_s)
        except asyncio.TimeoutError:
            yes, job.note = False, "quote expired"
        await self.send(cr6.SET_QUOTE, struct.pack("<BH", 0, 0))
        return yes

    def confirm(self, cid, yes):
        j = self.jobs.get(cid)
        if j and j.answer and not j.answer.done():
            j.answer.set_result(yes)

    async def cancel(self, cid):
        j = self.jobs.get(cid)
        if j and j.state in OPEN:
            j.cancel = True
            self.confirm(cid, False)
