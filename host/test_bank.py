"""Bank checks, run from the repo root:

    python host/test_bank.py            ledger rules only (no network)
    python host/test_bank.py devnet     also: 20 transfers through an RPC outage
    python host/test_bank.py nessie     also: $5 -> 50 KCN and back on Nessie + devnet

Live runs use a throwaway ledger and put every balance back where it started
(the devnet run costs ~0.0001 SOL in fees).
"""
import asyncio
import sys
import tempfile
import time
from pathlib import Path

from bank import InsufficientFunds, Ledger, Settler, exchange
from nessie import Nessie, NessieError


def ledger_rules():
    db = Path(tempfile.mkdtemp()) / "t.db"
    led = Ledger(db, wallets={"a", "b"})
    led.seed({"a": 10, "b": 0})
    led.seed({"a": 999})                      # ignored: ledger not empty
    led.post("fund", "a", "b", 7)
    assert (led.balance("a"), led.balance("b")) == (3, 7)
    assert led.balance("a", settled_only=True) == 10
    for bad in [("fund", "a", "b", 4), ("fund", "a", "b", 0), ("fund", "a", "b", 1.5),
                ("fund", "a", "a", 1), ("fund", "a", "x", 1), ("mint", "a", "b", 1)]:
        try:
            led.post(*bad)
            raise AssertionError(f"accepted {bad}")
        except (InsufficientFunds, ValueError):
            pass
    assert len(led.queued()) == 1 and led.balance("a") == 3
    print("ledger rules ok")


def item_rules():
    led = Ledger(Path(tempfile.mkdtemp()) / "t.db", wallets={"player", "treasury"})
    led.seed({"player": 20, "treasury": 100})
    led.move_items([("trader", "brick", 50)])
    buy = [("trader", "brick", -30), ("player", "brick", 30)]
    led.post("trade_buy", "player", "treasury", 12, items=buy)
    assert led.stock("player") == {"brick": 30} and led.stock("trader") == {"brick": 20} and led.balance("player") == 8
    for amount, items in [(9, buy), (1, [("trader", "brick", -21), ("player", "brick", 21)])]:
        try:                                  # can't pay, or the trader hasn't got it: nothing moves
            led.post("trade_buy", "player", "treasury", amount, items=items)
            raise AssertionError("accepted")
        except InsufficientFunds:
            pass
    try:
        led.move_items([("player", "brick", -10), ("player", "planks", -1)])
        raise AssertionError("used planks the player doesn't have")
    except InsufficientFunds:
        pass
    assert led.stock("player") == {"brick": 30} and led.balance("player") == 8
    led.move_items([("player", "brick", -30)])
    assert led.stock("player") == {}
    print("item rules ok: trades and material use are all or nothing")


class FakeNessie:
    def __init__(self):
        self.moves, self.fail, self.during = [], None, None

    async def move(self, kind, cents, desc):
        if self.fail:
            raise NessieError(self.fail, "fake")
        if self.during:
            hook, self.during = self.during, None
            hook()
        self.moves.append((kind, cents))


async def exchange_rules():
    led = Ledger(Path(tempfile.mkdtemp()) / "t.db", wallets={"treasury", "player"})
    led.seed({"treasury": 1000})
    n = FakeNessie()
    await exchange(led, n, 5)
    assert led.balance("player") == 50 and n.moves == [("withdrawals", 500)]
    await exchange(led, n, 5, to_game=False)
    assert led.balance("player") == 0 and n.moves[-1] == ("deposits", 500)

    for args, err in [((1, False), InsufficientFunds), ((0,), ValueError), ((101,), InsufficientFunds)]:
        try:
            await exchange(led, n, *args)
            raise AssertionError(f"accepted {args}")
        except err:
            pass
    n.fail = "unreachable"
    try:
        await exchange(led, n, 5)
        raise AssertionError("exchanged while Nessie was down")
    except NessieError:
        pass
    assert len(n.moves) == 2 and len(led.queued()) == 2

    n.fail = None
    await exchange(led, n, 5)                                         # player has 50
    n.during = lambda: led.post("fund", "player", "treasury", 50)   # spent mid-exchange
    try:
        await exchange(led, n, 5, to_game=False)
        raise AssertionError("paid out KCN the player no longer had")
    except InsufficientFunds:
        pass
    assert n.moves[-2:] == [("deposits", 500), ("withdrawals", 500)]  # dollars given back
    print("exchange rules ok")


async def drain(s):
    task = asyncio.create_task(s.run())
    t0 = time.time()
    while s.ledger.queued():
        assert time.time() - t0 < 300, f"{len(s.ledger.queued())} still queued"
        await asyncio.sleep(1)
    task.cancel()
    return time.time() - t0


async def nessie_live():
    led = Ledger(Path(tempfile.mkdtemp()) / "t.db")
    s = Settler(led)
    assert not await s.reconcile(), "chain and fresh ledger disagree"
    start = await s.chain_balances()
    n = Nessie()
    usd0 = await n.available_cents()

    await exchange(led, n, 5)
    usd1 = await n.available_cents()
    assert usd1 == usd0 - 500 and led.balance("player") == start["player"] + 50, (usd1, led.balance("player"))
    print(f"$5 -> 50 KCN: Nessie {usd0 / 100:.2f} -> {usd1 / 100:.2f}, HUD {start['player']} -> {led.balance('player')}")

    await exchange(led, n, 5, to_game=False)
    assert led.balance("player") == start["player"]
    print(f"50 KCN -> $5: HUD back to {led.balance('player')}, Nessie deposit pending")

    print(f"devnet settled both in {await drain(s):.0f} s")
    assert not await s.reconcile() and await s.chain_balances() == start
    descs = [t["description"] for t in await n.transactions(4)]
    assert sum(d.startswith("KC exchange_") for d in descs) >= 2, descs


async def devnet():
    led = Ledger(Path(tempfile.mkdtemp()) / "t.db")
    s = Settler(led)
    assert not await s.reconcile(), "chain and fresh ledger disagree"
    start = await s.chain_balances()
    for i in range(10):
        led.post("exchange_in", "treasury", "player", 1)
        led.post("exchange_out", "player", "treasury", 1)

    real, s.urls = s.urls, ["http://127.0.0.1:9"]   # outage: nothing listens there
    task = asyncio.create_task(s.run())
    for _ in range(30):                              # Windows takes ~2 s per refused connect
        await asyncio.sleep(1)
        if s.mode()[0] == "OFFLINE":
            break
    assert s.mode() == ("OFFLINE", 20), s.mode()
    print("outage:", *s.mode(), "queued")

    s.urls, s.url_i = real, 0
    t0 = time.time()
    while led.queued():
        assert time.time() - t0 < 300, f"{len(led.queued())} still queued"
        await asyncio.sleep(1)
    task.cancel()
    print(f"recovered: all 20 settled in {time.time() - t0:.0f} s, mode {s.mode()[0]}")

    assert not await s.reconcile(), "chain and ledger disagree after settling"
    assert await s.chain_balances() == start
    sigs = [r[0] for r in led.db.execute("SELECT sig FROM entries WHERE kind != 'mint' ORDER BY id")]
    assert len(set(sigs)) == 20
    print("last tx: https://explorer.solana.com/tx/" + sigs[-1] + "?cluster=devnet")


if __name__ == "__main__":
    ledger_rules()
    item_rules()
    asyncio.run(exchange_rules())
    if sys.argv[1:] == ["devnet"]:
        asyncio.run(devnet())
    if sys.argv[1:] == ["nessie"]:
        asyncio.run(nessie_live())
