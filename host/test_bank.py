"""Bank checks, run from the repo root:

    python host/test_bank.py            ledger rules only (no network)
    python host/test_bank.py devnet     also: 20 transfers through an RPC outage

The devnet run uses a throwaway ledger and moves 10 KCN treasury -> player and
back, so wallet balances end where they started (fees ~0.0001 SOL).
"""
import asyncio
import sys
import tempfile
import time
from pathlib import Path

from bank import InsufficientFunds, Ledger, Settler


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
    if sys.argv[1:] == ["devnet"]:
        asyncio.run(devnet())
