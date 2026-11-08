"""python -m unittest kc_agents.test_mobs  (no model or network needed)"""
import math
import unittest

from .mobs import MobManager, Mob, validate, rule_decision, LEASH, json_reply
from .world import FakeChip, KINDS


def manager(chat=None):
    return MobManager(FakeChip(), chat, log=lambda *a: None)


class TestRules(unittest.TestCase):
    def test_zombie_chases_near_player_only(self):
        mm = manager()
        z = mm.spawn("zombie", 105, 100)
        mm.step(0, (100, 100))
        self.assertLess(mm.chip.ents[z]["tgt"][0], 105)          # heads toward the player
        far = Mob(9, KINDS["zombie"], (0, 0))
        import random
        self.assertNotEqual(rule_decision(far, (0, 0), (50, 50), random.Random(1))["act"], "chase")

    def test_pig_flees(self):
        mm = manager()
        p = mm.spawn("pig", 101, 100)
        mm.step(0, (100, 100))
        self.assertGreater(mm.chip.ents[p]["tgt"][0], 101)

    def test_only_eight_mobs(self):
        mm = manager()
        ids = [mm.spawn("pig", 100 + i, 100) for i in range(9)]
        self.assertEqual(ids[:8], list(range(8)))
        self.assertIsNone(ids[8])


class TestValidation(unittest.TestCase):
    def test_bad_model_output_is_made_safe(self):
        v = Mob(0, KINDS["trader"], (0, 0))
        act, tx, tz, say = validate(v, {"act": "fly", "dx": 500, "dz": "x", "say": "y" * 99}, (0, 0), (5, 5))
        self.assertEqual(act, "idle")
        self.assertEqual((tx, tz), (0, 0))
        self.assertEqual(len(say), 40)
        act, tx, tz, _ = validate(v, {"act": "wander", "dx": 500, "dz": -500}, (0, 0), (0, 0))
        self.assertEqual((tx, tz), (8, -8))                       # one decision moves at most 8

    def test_villagers_stay_leashed_to_home(self):
        v = Mob(0, KINDS["contractor"], (0, 0))
        _, tx, tz, _ = validate(v, {"act": "wander", "dx": 8, "dz": 8}, (14, 14), (0, 0))
        self.assertLessEqual(math.hypot(tx, tz), LEASH + 1e-9)

    def test_pigs_never_talk(self):
        p = Mob(0, KINDS["pig"], (0, 0))
        self.assertEqual(validate(p, {"act": "wander", "say": "oink"}, (0, 0), (0, 0))[3], "")


class TestModelBrain(unittest.TestCase):
    def test_villagers_use_the_model_two_per_call(self):
        calls = []

        def chat(messages):
            ids = [int(line.split()[0][1:]) for line in messages[1]["content"].splitlines()]
            calls.append(ids)
            return {"decisions": [{"id": i, "act": "follow", "say": "Need a house?"} for i in ids]}
        mm = manager(chat)
        for k in ("trader", "contractor", "trader"):
            mm.spawn(k, 103, 103)
        mm.spawn("pig", 110, 110)
        mm.step(0, (100, 100))
        self.assertEqual(calls, [[0, 1], [2]])
        self.assertEqual(mm.stats["model"], 3)
        self.assertEqual(mm.stats["rules"], 1)                    # the pig
        self.assertEqual(mm.chip.ents[0]["tgt"], [100, 100])      # follow -> walks to the player

    def test_model_failure_falls_back_to_rules(self):
        def chat(messages):
            raise TimeoutError
        mm = manager(chat)
        mm.spawn("trader", 103, 103)
        done = mm.step(0, (100, 100))
        self.assertEqual(len(done), 1)
        self.assertEqual(mm.stats["fallback"], 1)

    def test_missing_answer_falls_back_and_far_villagers_skip_the_model(self):
        calls = []
        mm = manager(lambda m: calls.append(1) or {"decisions": []})
        mm.spawn("trader", 103, 103)
        mm.spawn("trader", 200, 200)                              # > 24 blocks away
        mm.step(0, (100, 100))
        self.assertEqual(len(calls), 1)
        self.assertEqual(mm.stats["fallback"], 1)
        self.assertEqual(mm.stats["rules"], 2)

    def test_busy_mobs_are_left_alone(self):
        mm = manager()
        z = mm.spawn("zombie", 105, 100)
        mm.busy.add(z)
        self.assertEqual(mm.step(0, (100, 100)), [])

    def test_json_reply_accepts_fences(self):
        self.assertEqual(json_reply('```json\n{"decisions": []}\n```'), {"decisions": []})


class TestFakeChipWalking(unittest.TestCase):
    def test_walks_at_kind_speed_and_stands_on_ground(self):
        chip = FakeChip()
        chip.spawn(0, KINDS["pig"], 100.5, 100.5)
        chip.move(0, 104.5, 100.5)
        for _ in range(4):
            chip.tick(0.5)
        self.assertAlmostEqual(chip.entity(0)[0], 102.5)          # 1 block/s for 2 s
        for _ in range(10):
            chip.tick(0.5)
        x, y, z = chip.entity(0)
        self.assertEqual((x, z), (104.5, 100.5))
        self.assertEqual(y, chip.ground(104, 100) + 1)
        self.assertFalse(chip.spawn(8, 0, 0, 0))
        self.assertFalse(chip.move(5, 0, 0))


if __name__ == "__main__":
    unittest.main()
