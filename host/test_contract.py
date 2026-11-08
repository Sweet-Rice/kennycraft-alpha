"""The builder agent's contract on the real ledger, over CR6 to the byte-level fake chip, no network:

    python host/test_contract.py

The agent is kc_agents' scripted builder (the demo hut: 96 cells, rule price 101, it quotes 60).
"""
import asyncio
import struct
import tempfile
from pathlib import Path

import cr6
from bank import Ledger
from cr6 import Bridge, Decoder, FakeChip, frame
from orchestrator import Orchestrator

WALLETS = {"treasury", "escrow", "player", "builder", "miner", "farmer", "banker"}
CELLS, PRICE = 96, 60


async def rig(frame_s=0.001, balance=100, **kw):
    led = Ledger(Path(tempfile.mkdtemp()) / "t.db", wallets=WALLETS)
    led.seed({"treasury": 1000, "player": balance})
    chip = None
    bridge = Bridge(lambda b: chip.receive(b), timeout=0.2)
    chip = FakeChip(bridge.feed, frame_s=frame_s)
    orch = Orchestrator(led, bridge, **{"stall_s": 2, **kw})
    orch.spawn(orch.events())
    await bridge.hello()
    return led, chip, orch


async def until(pred, timeout=20):
    for _ in range(int(timeout / 0.01)):
        if pred():
            return
        await asyncio.sleep(0.01)
    raise AssertionError("timed out")


def kinds(led, j):
    return [r[0] for r in led.db.execute("SELECT kind FROM entries WHERE contract_id = ? ORDER BY id", (j.id,))]


def framing():
    f = frame(7, cr6.PLACE, struct.pack("<HHBB", 1, 2, 3, 4))
    assert f[0] == 0xA5 and f[1] == 8 and len(f) == 11   # fits the chip's 12 B credit
    d = Decoder(9)
    assert d.feed(b"debug text\n" + f[:5]) == [] and d.feed(f[5:]) == [(7, 0x10, f[4:-1])]
    bad = bytearray(f)
    bad[6] ^= 1
    assert d.feed(bytes(bad)) == [] and d.bad == 1
    assert cr6.crc8(b"123456789") == 0xF4                 # CRC-8, poly 0x07, init 0
    print("framing ok")


async def happy():
    led, chip, orch = await rig()
    j = await orch.request("builder", "Build me a small hut right here.")
    await until(lambda: chip.hud["quote"] == (j.id, PRICE))          # "60? Y/N" on the chip
    chip.confirm(True)                                               # the player presses Y
    await until(lambda: j.over)
    assert j.state == "PAID", (j.state, j.note)
    assert led.balance("player") == 40 and led.balance("escrow") == 0
    assert led.balance("builder") == 54 and led.balance("treasury") == 1006
    assert chip.hud["kcn"] == 40 and chip.hud["quote"] == (0, 0) and chip.hud["contracts"][0] == (3, 63), chip.hud
    assert len([t for t in chip.world.values() if t]) == CELLS
    assert kinds(led, j) == ["fund", "release", "fee"], kinds(led, j)
    await orch.request("builder", "another")                         # free again
    print(f"full contract ok: fund {PRICE}, builder 54, fee 6, {CELLS} blocks placed")


async def declined_and_expired():
    led, chip, orch = await rig(quote_s=0.3)
    j = await orch.request("builder", "hut")
    try:
        await orch.request("builder", "again")
        raise AssertionError("two open builder contracts")
    except ValueError:
        pass
    await until(lambda: chip.hud["quote"][0] == j.id)
    chip.confirm(False)
    await until(lambda: j.over)
    assert j.state == "DECLINED", j.state
    j2 = await orch.request("builder", "hut")
    await until(lambda: j2.over)
    assert j2.state == "DECLINED" and j2.note == "quote expired", (j2.state, j2.note)
    led2, _, orch2 = await rig(balance=10)
    j3 = await orch2.request("builder", "hut")
    await until(lambda: j3.over)
    assert j3.state == "CANCELLED", j3.state                        # the bank wouldn't quote it
    assert led.balance("player") == 100 and led2.balance("player") == 10 and chip.hud["quote"] == (0, 0)
    print("declined, expired and unaffordable quotes ok: no money moved")


async def cancel_midway():
    led, chip, orch = await rig(frame_s=0.02)
    j = await orch.request("builder", "hut")
    await until(lambda: chip.hud["quote"][0] == j.id)
    chip.confirm(True)
    await until(lambda: j.progress()[0] >= 30)
    await orch.cancel(j.id)
    await until(lambda: j.over)
    done = j.progress()[0]
    earned = PRICE * done // CELLS
    assert j.state == "REFUNDED", j.state
    assert led.balance("builder") == earned and led.balance("player") == 40 + PRICE - earned
    assert led.balance("escrow") == 0
    print(f"cancel ok: {done}/{CELLS} placed, builder {earned}, player refunded {PRICE - earned}")


async def chip_rejects():
    led, chip, orch = await rig()
    x0, z0, y0, n = chip.zone
    chip.zone = (x0, z0, y0, 9)                           # the site is outside the player's zone
    j = await orch.request("builder", "hut")
    await until(lambda: chip.hud["quote"][0] == j.id)
    chip.confirm(True)
    await until(lambda: j.over)
    assert j.state == "REFUNDED" and led.balance("escrow") == 0, (j.state, j.note)
    assert led.balance("player") == 100 and not chip.world
    print("rejections ok: nothing built, player refunded in full")


async def chip_dies():
    led, chip, orch = await rig(stall_s=0.5, frame_s=0.01)
    j = await orch.request("builder", "hut")
    await until(lambda: chip.hud["quote"][0] == j.id)
    chip.confirm(True)
    await until(lambda: j.progress()[0] >= 30)
    chip.receive = lambda data: None                      # unplugged
    await until(lambda: j.over)
    assert j.state == "REFUNDED" and "no answer" in j.note and led.balance("escrow") == 0, (j.state, j.note)
    assert led.balance("player") + led.balance("builder") == 100
    print(f"stall ok: {j.note or 'timeout'}")


async def main():
    framing()
    for t in (happy, declined_and_expired, cancel_midway, chip_rejects, chip_dies):
        await t()


if __name__ == "__main__":
    asyncio.run(main())
