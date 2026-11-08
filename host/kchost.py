"""kc-host: the laptop side of KennyCraft banking in one asyncio process.

    python host/kchost.py                 fake chip + devnet + Nessie, page on http://127.0.0.1:8000
    KC_CHIP=host python host/kchost.py    the real game (game/ host build, `kc_host link` in WSL)
                                          over CR6; the page shows it live and sends your keys
    KC_CHIP=serial KC_PORT=COM5 python host/kchost.py
                                          the Arty board over its USB UART at 1 Mbaud. kc-host
                                          owns the port, so keys go through the page (click the
                                          key box and play), not scripts/kc.py

KC_GAME_DIR picks the game/ folder for KC_CHIP=host (build it first: make -C game).
The fake chip speaks the same CR6 bytes as the board; its buttons stand in for the
player's E and Y/N presses.
"""
import asyncio
import json
import os
import shlex
import sys
import threading
import time
from contextlib import asynccontextmanager
from pathlib import Path

import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, StreamingResponse

import cr6
from bank import InsufficientFunds, Ledger, Settler, exchange
from nessie import Nessie, NessieError, env
from orchestrator import STOCK, TYPES, Orchestrator

HERE = Path(__file__).resolve().parent
for k in ("NVIDIA_API_KEY", "NEMOTRON_API_KEY", "NEMOTRON_BASE_URL", "NEMOTRON_MODEL", "NANO_BASE_URL", "NANO_MODEL", "NANO_API_KEY"):    # kc_agents/llm.py reads os.environ
    if env(k) and k not in os.environ:
        os.environ[k] = env(k)


class Host:
    async def start(self):
        self.log = []
        self.ledger = Ledger()
        if not self.ledger.stock("trader"):
            self.ledger.move_items([("trader", k, n) for k, n in STOCK.items()])
        self.settler = Settler(self.ledger)
        drift = await self.settler.reconcile()
        if drift:
            self.say(f"chain and ledger differ: {drift}")
        self.nessie, self.usd = Nessie(), None
        self.chip = self.proc = self.port = None
        if os.environ.get("KC_CHIP") == "serial":
            import serial
            self.port = serial.serial_for_url(os.environ.get("KC_PORT", "COM3"), baudrate=1_000_000, timeout=0.02)
            self.bridge = cr6.Bridge(self.port.write, on_link=self.linked)
            threading.Thread(target=self.read_port, args=(asyncio.get_running_loop(),), daemon=True).start()
        elif os.environ.get("KC_CHIP") == "host":
            self.game = Path(os.environ.get("KC_GAME_DIR", HERE.parent / "game")).resolve()
            wsl = "/mnt/" + self.game.drive[0].lower() + self.game.as_posix()[2:]
            # KC_LINK_FPS / KC_REC (a WSL path): smooth recording, see cmd_link in game/host/main_host.c
            rec = shlex.quote(os.environ["KC_REC"]) if os.environ.get("KC_REC") else ""
            opts = " ".join(f"{k}={shlex.quote(os.environ[k])}" for k in ("KC_LINK_FPS", "KC_REC") if os.environ.get(k))
            self.proc = await asyncio.create_subprocess_exec(
                "wsl", "-e", "bash", "-lc", f"cd '{wsl}' && mkdir -p out/link {rec} && {opts} exec ./build/kc_host link out/link",
                stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE)
            self.bridge = cr6.Bridge(self.proc.stdin.write, on_link=self.linked)
        else:
            self.bridge = cr6.Bridge(lambda b: self.chip.receive(b), on_link=self.linked)
            self.chip = cr6.FakeChip(self.bridge.feed)
        self.orch = Orchestrator(self.ledger, self.bridge, say=self.say)
        self.orch.nessie, self.orch.settler = self.nessie, self.settler
        nano = None
        if os.environ.get("NANO_BASE_URL"):     # villagers think with Nemotron Nano; rules otherwise
            sys.path.insert(0, str(HERE.parent))
            from kc_agents.llm import nano_json
            nano = nano_json()
        for coro in (self.settler.run(), self.orch.events(), self.poll_nessie(), self.orch.villagers(nano)):
            self.orch.spawn(coro)
        if self.proc:
            self.orch.spawn(self.read_chip())
        await self.bridge.hello()

    def read_port(self, loop):
        """The board's UART, read on its own thread (pyserial blocks); bytes go to the bridge."""
        while True:
            data = self.port.read(512)
            if data:
                loop.call_soon_threadsafe(self.bridge.feed, data)

    async def read_chip(self):
        while data := await self.proc.stdout.read(512):
            self.bridge.feed(data)
        self.say("the game process exited")

    def say(self, text):
        self.log = (self.log + [time.strftime("%H:%M:%S ") + text])[-8:]

    def linked(self, boot):
        self.say(f"chip linked (boot {boot}), sending balance and contracts")
        self.orch.spawn(self.orch.resync())

    async def poll_nessie(self):
        while True:
            try:
                self.usd = await self.nessie.available_cents()
            except NessieError:
                self.usd = None
            await asyncio.sleep(5)

    @staticmethod
    def job(j):
        c, (done, total) = j.contract or getattr(j, "visit", None), j.progress()
        waiting = bool(j.answer and not j.answer.done())
        return {"id": j.id, "kind": j.kind, "text": j.text, "state": "QUOTED" if waiting else j.state,
                "price": getattr(c, "price", 0) or getattr(c, "offer", 0), "rule": getattr(c, "rule", 0),
                "placed": done, "total": total, "note": j.note}

    def snapshot(self):
        mode, queued = self.settler.mode()
        rows = self.ledger.db.execute(
            "SELECT id, kind, from_wallet, to_wallet, amount, contract_id, status, sig FROM entries"
            " WHERE kind != 'mint' ORDER BY id DESC LIMIT 14").fetchall()
        if self.chip:
            x0, z0, y0, n = self.chip.zone
            px, pz, py = self.chip.player
            hud = {"kcn": self.chip.hud["kcn"], "quote": self.chip.hud["quote"],
                   "contracts": {TYPES[t]: v for t, v in self.chip.hud["contracts"].items()}}
            world = {"size": n, "player": [px - x0, pz - z0], "ground": self.chip.ground,
                     "blocks": [[x - x0, z - z0, y, t] for (x, z, y), t in self.chip.world.items() if t]}
        else:
            hud, world = None, None                      # the live frame shows the chip's own HUD
        return {
            "hud": hud, "world": world, "live": self.proc is not None, "board": self.port is not None,
            "roles": {r: i for i, r in self.orch.roles.items()},
            "items": {"player": self.ledger.stock("player"), "trader": self.ledger.stock("trader")},
            "player_at": self.orch.player_at,
            "speech": self.orch.speech, "brains": self.orch.mobs and self.orch.mobs.stats,
            "mode": mode, "queued": queued, "usd": self.usd, "prompt": self.orch.prompt,
            "wallets": {w: self.ledger.balance(w) for w in ("player", "escrow", "builder", "miner", "farmer", "treasury")},
            "contracts": [self.job(j) for j in list(self.orch.jobs.values())[-5:][::-1]],
            "ledger": [dict(r) for r in rows],
            "log": self.log,
        }


host = Host()


@asynccontextmanager
async def lifespan(app):
    await host.start()
    yield


app = FastAPI(lifespan=lifespan)


def fail(x):
    raise HTTPException(400, str(x))


@app.get("/")
async def page():
    return FileResponse(HERE / "companion.html")


@app.get("/events")
async def events():
    async def stream():
        last = None
        while True:
            s = json.dumps(host.snapshot())
            if s != last:
                last = s
                yield f"data: {s}\n\n"
            await asyncio.sleep(0.25)
    return StreamingResponse(stream(), media_type="text/event-stream")


@app.get("/live.png")
async def live():
    f = getattr(host, "game", HERE) / "out" / "link" / "live.png"
    if not f.exists():
        raise HTTPException(404)
    return FileResponse(f, headers={"Cache-Control": "no-store"})


@app.post("/api/key")
async def key(body: dict):
    """A key from the page, as kc.py would send it: bit 7 set on key-down."""
    if host.proc or host.port:
        host.bridge.write(bytes([int(body["code"]) & 0x7F | (0x80 if body["down"] else 0)]))


@app.post("/api/interact")
async def interact(body: dict):
    if host.chip and body["role"] in host.orch.roles.values():
        host.chip.interact(next(i for i, r in host.orch.roles.items() if r == body["role"]))


@app.post("/api/confirm")
async def confirm(body: dict):
    if host.chip:
        host.chip.confirm(bool(body["yes"]))          # through the fake chip's Y/N, like the board
    else:
        for j in host.orch.jobs.values():
            host.orch.confirm(j.id, bool(body["yes"]))


@app.post("/api/close")
async def close():
    host.orch.prompt = None


@app.post("/api/request")
async def request(body: dict):
    try:
        c = await host.orch.request(body["kind"], str(body["text"])[:200])
    except (ValueError, InsufficientFunds, asyncio.TimeoutError) as x:
        fail(x)
    host.orch.prompt = None
    host.say(f"{c.kind} #{c.id}: {c.text}")


@app.post("/api/cancel")
async def cancel(body: dict):
    await host.orch.cancel(int(body["id"]))


@app.post("/api/exchange")
async def do_exchange(body: dict):
    try:
        dollars, to_game = int(body["dollars"]), bool(body["to_game"])
        await exchange(host.ledger, host.nessie, dollars, to_game)
    except NessieError as x:
        fail("not enough dollars in checking" if x.type == "insufficient_funds" else "the bank is closed (Nessie is down)")
    except (ValueError, InsufficientFunds) as x:
        fail(x)
    await host.orch.hud()
    host.say(f"banker: ${dollars} {'->' if to_game else '<-'} {dollars * 10} KCN")


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8000, log_level="warning")
