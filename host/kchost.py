"""kc-host: the laptop side of KennyCraft banking in one asyncio process.

    python host/kchost.py        fake chip + devnet + Nessie, companion page on http://127.0.0.1:8000

The fake chip speaks the same CR6 bytes as the board; the buttons in its panel
stand in for the player's INTERACT and Y/N presses.
"""
import asyncio
import json
import time
from contextlib import asynccontextmanager
from pathlib import Path

import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, StreamingResponse

import agents
import cr6
from bank import InsufficientFunds, Ledger, Settler, exchange
from nessie import Nessie, NessieError
from orchestrator import TYPES, Orchestrator

HERE = Path(__file__).resolve().parent


class Host:
    async def start(self):
        self.log = []
        self.ledger = Ledger()
        self.settler = Settler(self.ledger)
        drift = await self.settler.reconcile()
        if drift:
            self.say(f"chain and ledger differ: {drift}")
        self.nessie, self.usd = Nessie(), None
        self.chip = None
        self.bridge = cr6.Bridge(lambda b: self.chip.receive(b), on_link=self.linked)
        self.chip = cr6.FakeChip(self.bridge.feed)
        self.orch = Orchestrator(self.ledger, self.bridge, agents.price)
        for coro in (self.settler.run(), self.orch.events(), self.poll_nessie()):
            self.orch.spawn(coro)
        await self.bridge.hello()

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

    def snapshot(self):
        mode, queued = self.settler.mode()
        rows = self.ledger.db.execute(
            "SELECT id, kind, from_wallet, to_wallet, amount, contract_id, status, sig FROM entries"
            " WHERE kind != 'mint' ORDER BY id DESC LIMIT 14").fetchall()
        x0, z0, y0, n = self.chip.zone
        px, pz, py = self.chip.player
        return {
            "hud": {"kcn": self.chip.hud["kcn"], "quote": self.chip.hud["quote"],
                    "contracts": {TYPES[t]: v for t, v in self.chip.hud["contracts"].items()}},
            "mode": mode, "queued": queued, "usd": self.usd, "prompt": self.orch.prompt,
            "wallets": {w: self.ledger.balance(w) for w in ("player", "escrow", "builder", "miner", "farmer", "treasury")},
            "contracts": [{"id": c.id, "kind": c.kind, "text": c.text, "price": c.price, "rule": c.rule,
                           "state": c.state, "placed": len(c.placed), "total": len(c.blueprint), "note": c.note}
                          for c in list(self.orch.contracts.values())[-5:][::-1]],
            "ledger": [dict(r) for r in rows],
            "world": {"size": n, "player": [px - x0, pz - z0], "ground": self.chip.ground,
                      "blocks": [[x - x0, z - z0, y, t] for (x, z, y), t in self.chip.world.items() if t]},
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


@app.post("/api/interact")
async def interact(body: dict):
    host.chip.interact(int(body["entity"]))


@app.post("/api/confirm")
async def confirm(body: dict):
    host.chip.confirm(bool(body["yes"]))


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
    host.say(f"{c.kind} quotes {c.price} KCN (rule price {c.rule}) for: {c.text}")


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
