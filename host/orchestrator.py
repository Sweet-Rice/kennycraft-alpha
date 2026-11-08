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
from kc_agents import banker, builder, trader             # noqa: E402
from kc_agents.mobs import Mob, MobManager                # noqa: E402
from kc_agents.bank import FEE                            # noqa: E402

import cr6                                                # noqa: E402
from bank import InsufficientFunds, exchange              # noqa: E402
from nessie import NessieError                            # noqa: E402

TYPES = ["builder", "miner", "farmer"]                      # contract type byte = index
# Villagers the laptop spawns next to the player (CR6 SPAWN): role, entity kind
# (game/src/entity.h: 0 trader, 1 contractor), offset from the player in blocks.
# Beside the player (north and south, within E's 3-block reach), clear of the site to the
# east and of the camera stepping back west to watch the build.
VILLAGERS = [("banker", 0, -1, 3), ("builder", 1, -1, -3), ("trader", 0, -4, 0)]   # trader: walk 1 west to talk
STOCK = {"brick": 200, "planks": 300, "cobble": 300, "stone": 200, "log": 100, "sand": 100,
         "dirt": 300, "grass": 100, "leaves": 100}                                      # the trader's first stock
OPEN = ("SURVEY", "PLANNED", "FUNDED", "BUILT", "VERIFIED")
HUD_STATE = {"FUNDED": 1, "BUILT": 2, "VERIFIED": 2, "PAID": 3}   # 2-bit state on the chip
SITE = (6, 8, 6)        # x, y, z: east of the player, inside the chip's 16^3 zone around them
# Demo village (KC_DEMO=1, with the game built `make KC_DEMO=1`): the same numbers as
# game/src/blocks.h. Villagers stand behind their stall counters, chickens are in the pen, and
# every build goes on the plot (the chip makes the plot the zone when you talk to anyone).
DEMO = os.environ.get("KC_DEMO") == "1"
DEMO_X0, DEMO_Z0, DEMO_H, DEMO_PLOT_X0, DEMO_PLOT_Z0, DEMO_PLOT_W = 2048, 2048, 14, -7, 20, 14
DEMO_SITE = (DEMO_PLOT_W - 2, 10, DEMO_PLOT_W - 2)           # inside the plot's cobble border
DEMO_MOBS = [("banker", 0, -6.5, 9.5, 1), ("builder", 1, 0.5, 16.5, 1), ("trader", 0, 7.5, 9.5, 1),
             ("chicken", 2, -7.5, 2.5, 1.5), ("chicken", 2, -6.5, 3.5, 1.5), ("chicken", 2, -7.5, 4.5, 1.5)]
TALKERS = ("banker", "builder", "trader")
DEMO_START = 300        # KCN the player has when kc-host starts in the demo (topped up from the treasury)
DEMO_CAP = 400          # price cap for builds on the 12x12 plot (200 elsewhere)
RETRY = ("RATE", "BUSY")
EXPLORER = "https://explorer.solana.com/tx/{}?cluster=devnet"


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

    def teleport(self, eid, x, z):          # MOVE with bit 7 of the id: there at once (cr6.c)
        res, _ = self.sync(self.orch.send(cr6.MOVE, struct.pack("<BHH", eid | 0x80, round(x * 16), round(z * 16))))
        return res == "OK"

    # -- bank -----------------------------------------------------------------------------
    def materials(self):
        return self.sync(self._call(self.orch.ledger.stock, "player"))

    def use_materials(self, used):
        self.sync(self._call(self.orch.ledger.move_items, [("player", k, -n) for k, n in used.items()]))

    @staticmethod
    async def _call(fn, *args):             # sqlite stays on the loop's thread
        return fn(*args)

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


class VisitJob:
    """One conversation with a villager agent that isn't a contract (banker, trader)."""
    contract, hud_v, cancel = None, None, False
    sync = Job.sync

    def __init__(self, orch, cid, text):
        self.orch, self.id, self.text = orch, cid, text
        self.note, self.answer, self.over, self.visit = "", None, False, None

    @property
    def state(self):
        return "DONE" if self.over else "TALKING"

    def progress(self):
        return 0, 0

    def ask(self, question, kcn):
        self.orch.loop.call_soon_threadsafe(self.orch.say, f"{self.kind}: {question}")
        return self.sync(self.orch.ask(self, kcn))


class BankerJob(VisitJob):
    """kc_agents/banker.py's bank methods on the ledger, Nessie and Solana devnet."""
    kind, agent = "banker", banker

    async def _accounts(self):
        o = self.orch
        mode, queued = o.settler.mode() if o.settler else ("OFFLINE", 0)
        cents = await o.nessie.available_cents()
        return {"kcn": o.ledger.balance("player"), "dollars_available": cents / 100,
                "payments_waiting": queued, "chain": mode}

    def accounts(self):
        return self.sync(self._accounts())

    async def _exchange(self, dollars, to_game):
        try:
            entry = await exchange(self.orch.ledger, self.orch.nessie, dollars, to_game)
        except NessieError as x:
            raise ValueError("not enough dollars in checking" if x.type == "insufficient_funds"
                             else "the bank is closed (Nessie is down)")
        except InsufficientFunds as x:
            raise ValueError(str(x))
        self.orch.say(f"banker: ${dollars} {'->' if to_game else '<-'} {dollars * 10} KCN")
        await self.orch.hud()
        return entry

    def exchange(self, dollars, to_game):
        return self.sync(self._exchange(dollars, to_game))

    async def _history(self, n):
        rows = self.orch.ledger.db.execute(
            "SELECT id, kind, from_wallet, to_wallet, amount, contract_id, status, sig FROM entries"
            " WHERE kind != 'mint' ORDER BY id DESC LIMIT ?", (n,)).fetchall()
        return [{"entry_id": r["id"], "kind": r["kind"], "from": r["from_wallet"], "to": r["to_wallet"],
                 "kcn": r["amount"], "contract": r["contract_id"], "status": r["status"],
                 "explorer": r["sig"] and EXPLORER.format(r["sig"])} for r in rows]

    def history(self, n):
        return self.sync(self._history(n))

    async def _dollar_history(self, n):
        keep = ("type", "amount_cents", "status", "description", "created_at")
        return [{k: t[k] for k in keep if k in t} for t in await self.orch.nessie.transactions(n)]

    def dollar_history(self, n):
        return self.sync(self._dollar_history(n))

    async def _chain_lookup(self, entry_id):
        r = self.orch.ledger.db.execute("SELECT kind, amount, status, sig FROM entries WHERE id = ?",
                                        (entry_id,)).fetchone()
        if not r:
            return {"error": f"no ledger entry {entry_id}"}
        if not r["sig"]:
            return {"entry_id": entry_id, "status": "waiting to settle on chain"}
        tx = await self.orch.settler.rpc("getTransaction", r["sig"], {
            "encoding": "json", "commitment": "confirmed", "maxSupportedTransactionVersion": 0})
        if not tx:
            return {"entry_id": entry_id, "status": "not found on chain yet"}
        meta = tx["meta"] or {}
        memo = next((m.split("): ", 1)[-1].strip('"') for m in meta.get("logMessages") or [] if "Memo (len" in m), None)
        return {"entry_id": entry_id, "kind": r["kind"], "kcn": r["amount"],
                "status": "failed" if meta.get("err") else "confirmed", "slot": tx["slot"],
                "block_time": tx.get("blockTime"), "fee_lamports": meta.get("fee"), "memo": memo,
                "explorer": EXPLORER.format(r["sig"])}

    def chain_lookup(self, entry_id):
        return self.sync(self._chain_lookup(entry_id))


class MobChip:
    """The two chip calls kc_agents' MobManager makes (Q_ENTITY, MOVE), from its thread."""

    def __init__(self, orch):
        self.orch = orch

    def sync(self, coro):
        return asyncio.run_coroutine_threadsafe(coro, self.orch.loop).result()

    def entity(self, eid):
        res, p = self.sync(self.orch.send(cr6.Q_ENTITY, bytes([eid])))
        if res != "OK" or not p:
            raise KeyError(eid)
        _, x, z, y, _ = struct.unpack("<BHHBB", p)
        return x / 16, y / 8, z / 16

    def move(self, eid, tx, tz):
        res, _ = self.sync(self.orch.send(cr6.MOVE, struct.pack("<BHH", eid, round(tx * 16), round(tz * 16))))
        return res == "OK"


class TraderJob(VisitJob):
    """kc_agents/trader.py's market: laptop-side materials, paid in KCN through the ledger."""
    kind, agent = "trader", trader

    async def _stock(self):
        led = self.orch.ledger
        return {"trader": led.stock("trader"), "player": led.stock("player"), "kcn": led.balance("player")}

    def stock(self):
        return self.sync(self._stock())

    async def _trade(self, item, qty, kcn, buy):
        moves = [("trader", item, -qty), ("player", item, qty)] if buy else [("player", item, -qty), ("trader", item, qty)]
        try:
            entry = (self.orch.ledger.post("trade_buy", "player", "treasury", kcn, items=moves) if buy else
                     self.orch.ledger.post("trade_sell", "treasury", "player", kcn, items=moves))
        except InsufficientFunds as x:
            raise ValueError(str(x))
        self.orch.say(f"trader: {'sold' if buy else 'bought'} {qty} {item} for {kcn} KCN")
        await self.orch.hud()
        return entry

    def trade(self, item, qty, kcn, buy):
        return self.sync(self._trade(item, qty, kcn, buy))


class Orchestrator:
    def __init__(self, ledger, bridge, chat=chat, quote_s=30, stall_s=20, on_change=lambda: None, say=lambda t: None):
        self.nessie = self.settler = None       # kc-host sets these; the banker agent needs them
        self.ledger, self.bridge, self.chat = ledger, bridge, chat
        self.quote_s, self.stall_s, self.on_change = quote_s, stall_s, on_change
        self._say = say
        self.jobs, self.prompt, self.roles, self.zone = {}, None, {}, None   # roles: entity id -> villager
        # Continue numbering after a restart so KC#<id> memos stay unique on chain.
        self.next_id = (ledger.db.execute("SELECT MAX(contract_id) FROM entries").fetchone()[0] or 0) + 1
        self.tasks = set()
        self.loop, self.hud_kcn = None, None
        self.homes, self.speech, self.mobs = {}, {}, None       # villager brains (villagers())
        self.recent = []                                        # what happened lately, for their context
        self.player_at = None                                   # (x, z) blocks, refreshed with the brains

    def say(self, text):
        self._say(text)
        self.recent = (self.recent + [text[:120]])[-5:]

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
        if job and job.kind in TYPES:
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
        if DEMO:                        # fixed spots in the village, not around the player
            for i, (role, kind, dx, dz, leash) in enumerate(DEMO_MOBS):
                x, z = DEMO_X0 + dx, DEMO_Z0 + dz
                await self.send(cr6.SPAWN, struct.pack("<BHHB", i | kind << 4, round(x * 16), round(z * 16),
                                                       (DEMO_H + 1) * 8))
                self.roles[i] = role
                self.homes[i] = (kind, x, z, leash)
            return
        _, p = await self.send(cr6.Q_PLAYER)
        x, z, y = struct.unpack("<HHB", p)
        for i, (role, kind, dx, dz) in enumerate(VILLAGERS):
            # BAD_ENTITY here means the chip already has them (kc-host restarted, chip didn't).
            await self.send(cr6.SPAWN, struct.pack("<BHHB", i | kind << 4, x + dx * 16, z + dz * 16, y))
            self.roles[i] = role
            self.homes[i] = (kind, x / 16 + dx, z / 16 + dz, None)

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
                await self.send(cr6.SET_QUOTE, struct.pack("<BH", j.id & 0xFF, (j.contract or j.visit).offer))

    async def mark_zone(self):
        """The chip marks its 16^3 contract zone around the player when E is pressed (cr6.c)."""
        if DEMO:
            self.zone = (DEMO_X0 + DEMO_PLOT_X0 - 1, DEMO_H + 1, DEMO_Z0 + DEMO_PLOT_Z0 - 1)
            return
        px, pz, py = await self.player()
        self.zone = (px - 8, max(1, py - 4), pz - 8)

    async def events(self):
        while True:
            code, arg = await self.bridge.events.get()
            if code == cr6.EV_INTERACT and self.roles.get(arg) in TALKERS:
                self.prompt = self.roles[arg]
                await self.mark_zone()
                self.on_change()
            elif code == cr6.EV_CONFIRM:
                j = next((j for j in self.jobs.values() if j.id & 0xFF == arg & 0xFF), None)
                if j:
                    self.confirm(j.id, bool(arg >> 8))

    async def request(self, kind, text):
        """Hire a contractor or talk to the banker; the agent works in the background."""
        self.loop = asyncio.get_running_loop()
        if kind in ("banker", "trader"):
            if any(j.kind == kind and not j.over for j in self.jobs.values()):
                raise ValueError(f"the {kind} is still busy with you")
            job = (BankerJob if kind == "banker" else TraderJob)(self, self.next_id, text)
            self.next_id += 1
            self.jobs[job.id] = job
            self.spawn(self.run_visit(job))
            return job
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
        if DEMO:                                    # inside the plot's border
            site = (DEMO_X0 + DEMO_PLOT_X0 + 1, DEMO_Z0 + DEMO_PLOT_Z0 + 1)
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
        size = DEMO_SITE if DEMO else SITE
        job.scan(site[0], site[1], size[0], size[2], y0 - 1, 17)   # from the ground layer up: plans must rest on it
        job.contract = builder.Contract(job.id, job, job, job.ask, origin=site, zone=size, worker=worker,
                                        cap=DEMO_CAP if DEMO else 200)
        reply = builder.run(job.text, job.contract, self.chat(), autopilot=True,
                            log=lambda t: print(time.strftime("%H:%M:%S"), f"#{job.id}", t, file=sys.stderr, flush=True))
        job.note = job.note or reply or ""      # "quote expired" beats the agent's sign-off

    async def villagers(self, chat_json=None):
        """Villager brains: kc_agents' MobManager (Nemotron Nano, rules on any failure) decides
        twice a second; its moves go to the chip as CR6 MOVE. Villagers stand still while the
        player talks to them or while they work a contract. Speech goes to the page only."""
        self.loop = asyncio.get_running_loop()
        self.mobs = MobManager(MobChip(self), chat_json, log=lambda t: None)
        while True:
            await asyncio.sleep(0.5)
            for i, (kind, hx, hz, leash) in self.homes.items():
                if i not in self.mobs.mobs:
                    self.mobs.mobs[i] = Mob(i, kind, (hx, hz), leash)
            if not self.mobs.mobs:
                continue
            busy = {i for i, r in self.roles.items() if r == self.prompt}
            busy |= {i for i, r in self.roles.items() for j in self.jobs.values() if j.kind == r and not j.over}
            self.mobs.busy = busy
            role = {r: i for i, r in self.roles.items()}
            self.mobs.context = (f"Game: #{role.get('banker', 0)} is the banker (swaps the player's dollars "
                                 f"for KCN coins), #{role.get('builder', 1)} is the builder (builds for KCN). "
                                 f"The player has {self.ledger.balance('player')} KCN. Just happened: "
                                 f"{'; '.join(self.recent[-3:]) or 'nothing yet'}. Each villager speaks only for itself; react in 'say'.")
            try:
                px, pz, _ = await self.player()
                self.player_at = (px, pz)
                done = await asyncio.to_thread(self.mobs.step, time.monotonic(), (px + 0.5, pz + 0.5))
            except Exception as x:          # chip stall or a villager gone: try again next tick
                print(time.strftime("%H:%M:%S"), "villagers:", type(x).__name__, x, file=sys.stderr, flush=True)
                continue
            for eid, act, say in done:
                if say and eid in self.roles:
                    self.speech[self.roles[eid]] = say
                    self.on_change()

    async def run_visit(self, job):
        def agent():
            job.visit = job.agent.Visit(job)
            return job.agent.run(job.text, job.visit, self.chat(), log=lambda t: print(
                time.strftime("%H:%M:%S"), f"{job.kind} #{job.id}", t, file=sys.stderr, flush=True))
        self.on_change()
        try:
            job.note = job.note or await asyncio.to_thread(agent) or ""
        except Exception as x:
            job.note = f"{type(x).__name__}: {x}"
        job.over = True
        self.say(f"{job.kind}: {job.note}")
        self.on_change()

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
