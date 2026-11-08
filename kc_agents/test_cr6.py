"""python -m unittest kc_agents.test_cr6  (no board, no serial port)"""
import itertools
import unittest

from . import cr6
from .bank import FakeBank
from .builder import Contract
from .mobs import MobManager
from .test_builder import HUT
from .world import FakeChip, KINDS


def linked(zone=None):
    world = FakeChip()
    uart = cr6.FakeUartChip(world, zone)
    link = cr6.Link(uart)
    assert link.hello()
    return world, uart, link


class TestFraming(unittest.TestCase):
    def test_crc_catches_every_single_dropped_byte(self):
        f = cr6.frame(7, cr6.FILL, cr6.p_fill(100, 200, 12, 5, 1, 5, 7))
        self.assertEqual(len(f), 12)                              # the longest laptop frame
        for i in range(1, len(f)):
            got = cr6.Decoder().feed(f[:i] + f[i + 1:] + b"\x00" * 12)
            self.assertFalse(any(x[0] == "frame" and x[3] == f[4:-1] for x in got), i)

    def test_frames_keys_and_text_interleave_and_split(self):
        stream = b"w" + cr6.frame(3, cr6.MOVE, cr6.p_move(2, 10.5, 20.25)) + b"kc: boot\n"
        for cut in range(len(stream)):
            d = cr6.Decoder()
            got = d.feed(stream[:cut]) + d.feed(stream[cut:])
            frames = [g for g in got if g[0] == "frame"]
            self.assertEqual(len(frames), 1)
            self.assertEqual(frames[0][1:3], (3, cr6.MOVE))
            self.assertEqual(bytes(g[1] for g in got if g[0] == "byte"), b"wkc: boot\n")

    def test_crc8_known_value(self):
        self.assertEqual(cr6.crc8(b"123456789"), 0xF4)            # CRC-8/SMBUS check value


class TestLink(unittest.TestCase):
    def test_nothing_runs_before_hello(self):
        world, uart = FakeChip(), None
        uart = cr6.FakeUartChip(world)
        link = cr6.Link(uart)
        self.assertEqual(link.call(cr6.PLACE, cr6.p_place(100, 100, 20, 7)), "NOT_LINKED")
        uart.write(b"junk before hello")                         # stray bytes: the count resyncs
        self.assertFalse(uart.linked)
        self.assertTrue(link.hello())

    def test_credits_never_drop_a_byte_naive_sender_does(self):
        world, uart, link = linked()
        link.keys += b"wasd" * 50                                 # keys pile up while commands stream
        for i in range(40):
            self.assertEqual(link.call(cr6.PLACE, cr6.p_place(100 + i, 100, 20, 7)), "OK")
        for _ in range(30):
            link.pump()
        self.assertEqual(uart.dropped, 0)
        self.assertEqual(len(uart.keys), 200)
        naive = cr6.FakeUartChip(FakeChip())
        for i in range(40):
            naive.write(cr6.frame(i + 1, cr6.PLACE, cr6.p_place(100 + i, 100, 20, 7)))
        self.assertGreater(naive.dropped, 300)

    def test_results_and_idempotent_retransmit(self):
        world, uart, link = linked(zone=(90, 90, 110, 110))
        self.assertEqual(link.call(cr6.PLACE, cr6.p_place(200, 200, 20, 7)), "OUT_OF_ZONE")
        self.assertEqual(link.call(cr6.PLACE, cr6.p_place(100, 100, 20, 10)), "BAD_BLOCK")   # bedrock
        self.assertEqual(link.call(0x7E), "BAD_OP")
        seq = link.seq + 1
        f = cr6.frame(seq, cr6.SPAWN, cr6.p_spawn(0, 2, 100, 100, 12))
        link._write(f); link.pump(); link.pump()
        link._write(f); link.pump(); link.pump()                 # same seq again: OK, not run twice
        self.assertEqual(link.results[seq], "OK")
        self.assertEqual(len(world.ents), 1)

    def test_bad_crc_is_reported(self):
        world, uart, link = linked()
        f = bytearray(cr6.frame(9, cr6.PLACE, cr6.p_place(100, 100, 20, 7)))
        f[-1] ^= 1
        link._write(bytes(f))
        link.pump(); link.pump()
        self.assertEqual(uart.last_result, cr6.R["CRC"])
        self.assertNotIn((100, 20, 100), world.blocks)


class TestAgentsOverCr6(unittest.TestCase):
    def test_builder_contract_matches_the_direct_fake_chip(self):
        world, uart, link = linked()
        model = FakeChip()                                        # the laptop's terrain copy
        chip = cr6.Cr6Chip(link, model.ground, model.get)
        bank = FakeBank(200)
        c = Contract(1, chip, bank, ask_player=lambda q: True, origin=(100, 100))
        self.assertTrue(c.call("submit_plan", {"name": "hut", "ops": HUT})["ok"])
        c.call("quote", {"price": 60, "message": ""})
        r = c.call("build", {})
        self.assertEqual(r["rejected"], 0)
        self.assertTrue(c.call("inspect", {})["passed"])
        self.assertEqual(c.call("request_payment", {})["paid_kcn"], 60)
        self.assertTrue(all(world.get(*cell) == b for cell, b in c.target.items()))
        self.assertEqual(uart.dropped, 0)
        frames_used = uart.frame_no
        self.assertLess(frames_used, 30)                          # 16 commands + 8 spot checks + hello

    def test_mobs_spawn_and_walk_over_cr6(self):
        world, uart, link = linked()
        model = FakeChip()
        chip = cr6.Cr6Chip(link, model.ground, model.get)
        mm = MobManager(chip, log=lambda *a: None)
        z = mm.spawn("zombie", 105, 100)
        self.assertEqual(world.ents[z]["kind"], KINDS["zombie"])
        mm.step(0, (100, 100))
        for _ in range(20):
            world.tick(0.25)
        x, _, _ = chip.entity(z)
        self.assertLess(x, 105)                                    # chased toward the player


if __name__ == "__main__":
    unittest.main()
