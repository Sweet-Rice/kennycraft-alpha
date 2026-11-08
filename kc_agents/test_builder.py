"""python -m unittest kc_agents.test_builder  (no model or network needed)"""
import unittest

from .bank import FakeBank, clamp_price
from .builder import Contract, run
from .world import FakeChip, expand, compress, ID

HUT = [{"op": "fill", "at": [0, 0, 0], "size": [5, 1, 5], "block": "cobble"},
       {"op": "walls", "at": [0, 1, 0], "size": [5, 3, 5], "block": "planks"},
       {"op": "clear", "at": [2, 1, 0], "size": [1, 2, 1]},
       {"op": "fill", "at": [0, 4, 0], "size": [5, 1, 5], "block": "brick"}]


def scripted(*steps):
    """A fake model: each step is a list of (tool, args), or a string for the final answer."""
    steps = list(steps)

    def chat(messages, tools):
        s = steps.pop(0) if len(steps) > 1 or not isinstance(steps[0], str) else steps[0]   # last words repeat
        if isinstance(s, str):
            return {"content": s, "tool_calls": []}
        return {"content": "", "tool_calls": [{"id": f"c{len(steps)}{i}", "name": n, "args": a}
                                              for i, (n, a) in enumerate(s)]}
    return chat


def contract(player=200, yes=True):
    bank = FakeBank(player=player)
    return Contract(7, FakeChip(), bank, ask_player=lambda q: yes, origin=(100, 100)), bank


class TestPlans(unittest.TestCase):
    def test_compress_covers_every_cell_once(self):
        cells, errors = expand(HUT, (8, 8, 8))
        self.assertEqual(errors, [])
        seen = {}
        for c in compress(cells):
            if c[0] == "place":
                _, x, y, z, b = c
                box = [(x, y, z)]
            else:
                _, x, y, z, sx, sz, b = c
                box = [(x + i, y, z + k) for i in range(sx) for k in range(sz)]
            for cell in box:
                self.assertNotIn(cell, seen)
                seen[cell] = b
        self.assertEqual(seen, cells)

    def test_bad_ops_are_explained(self):
        _, errors = expand([{"op": "fill", "at": [6, 0, 0], "size": [4, 1, 1], "block": "planks"},
                            {"op": "fill", "at": [0, 0, 0], "size": [1, 1, 1], "block": "bedrock"},
                            {"op": "dome", "at": [0, 0, 0]}], (8, 8, 8))
        self.assertEqual(len(errors), 3)
        self.assertIn("leaves the zone", errors[0])
        self.assertIn("can't be placed", errors[1])

    def test_price_clamp(self):
        self.assertEqual(clamp_price(1000, 100, 500), 150)
        self.assertEqual(clamp_price(1, 100, 500), 50)
        self.assertEqual(clamp_price(80, 100, 60), 60)          # capped at the balance
        self.assertIsNone(clamp_price(80, 100, 40))             # can't afford half the rule price


class TestContract(unittest.TestCase):
    def test_full_job_pays_builder_after_inspect(self):
        c, bank = contract()
        run("small hut", c, scripted([("look_at_site", {})],
                                     [("submit_plan", {"name": "hut", "ops": HUT})],
                                     [("quote", {"price": 90, "message": "A cozy hut."})],
                                     [("build", {})], [("inspect", {})], [("request_payment", {})],
                                     "Enjoy your hut!"), log=lambda *a: None)
        self.assertEqual(c.state, "PAID")
        self.assertEqual(bank.wallets["escrow"], 0)
        self.assertEqual(bank.wallets["builder"] + bank.wallets["treasury"], c.price)
        self.assertEqual(bank.wallets["player"], 200 - c.price)
        self.assertTrue(all(c.chip.get(*cell) == b for cell, b in c.target.items()))
        door = c._abs(2, 1, 0)
        self.assertEqual(c.chip.get(*door), 0)

    def test_own_materials_cut_the_price_and_are_used_on_payment(self):
        c, bank = contract()
        full = c.submit_plan("hut", HUT)["rule_price_kcn"]
        c2, bank2 = contract()
        bank2.items = {"brick": 30, "planks": 4}
        r = c2.submit_plan("hut", HUT)
        self.assertEqual(r["player_materials_used"], {"brick": 25, "planks": 4})
        self.assertEqual(r["rule_price_kcn"], full - 14)
        for step in (lambda: c2.quote(r["rule_price_kcn"], "ok"), c2.build, c2.inspect, c2.request_payment):
            step()
        self.assertEqual(c2.state, "PAID")
        self.assertEqual(bank2.items, {"brick": 5, "planks": 0})

    def test_blueprints_fit_and_pass_the_plan_checks(self):
        from .blueprints import CATALOG, ops
        for zone, expect in (((6, 8, 6), {"cottage", "tower", "stall"}), ((12, 10, 12), set(CATALOG))):
            fits = set()
            for name in CATALOG:
                c, _ = contract()
                c.zone = zone
                r = c.use_blueprint(name)
                if r["ok"]:
                    fits.add(name)
                    self.assertGreater(r["commands"], 0)
                else:
                    self.assertIn("doesn't fit", r["errors"][0])
            self.assertEqual(fits, expect, zone)
        brick, _ = ops("cottage", (6, 8, 6), {"walls": "brick", "roof": None})
        self.assertTrue(any(o.get("block") == "brick" and o["op"] == "walls" for o in brick))
        self.assertIn("can't be placed", ops("cottage", (6, 8, 6), {"walls": "bedrock"})[1])
        self.assertIn("no blueprint", ops("castle", (6, 8, 6))[1])

    def test_autopilot_builds_inspects_and_collects_after_yes(self):
        c, bank = contract()
        r = run("a cottage", c, scripted([("use_blueprint", {"name": "cottage"})],
                                         [("quote", {"price": 60, "message": "ok"})]),
                log=lambda t: None, autopilot=True)
        self.assertEqual(c.state, "PAID")
        self.assertIn("Done", r)
        self.assertEqual(bank.wallets["escrow"], 0)
        bad, bank = contract()
        bad.chip.reject_rate = 1.0                          # the chip refuses everything
        run("a cottage", bad, scripted([("use_blueprint", {"name": "cottage"})],
                                       [("quote", {"price": 60, "message": "ok"})]),
            log=lambda t: None, autopilot=True)
        self.assertEqual((bad.state, bank.wallets["escrow"], bank.wallets["player"]), ("REFUNDED", 0, 200))

    def test_site_survey_rides_with_the_request(self):
        c, _ = contract()
        seen = []
        def chat(messages, tools):
            seen.append(messages[1]["content"])
            return {"content": "done", "tool_calls": []}
        run("a cottage", c, chat, log=lambda t: None, next_tool={})
        self.assertIn("Site survey", seen[0])
        self.assertIn("zone_size_xyz", seen[0])

    def test_floating_build_is_rejected(self):
        c, _ = contract()
        up = [dict(op, at=[op["at"][0], op["at"][1] + 3, op["at"][2]]) for op in HUT]
        r = c.submit_plan("sky hut", up)
        self.assertFalse(r["ok"])
        self.assertIn("floats", r["errors"][0])
        self.assertTrue(c.submit_plan("hut", HUT)["ok"])

    def test_order_is_enforced(self):
        c, bank = contract()
        self.assertIn("error", c.call("build", {}))
        self.assertIn("error", c.call("quote", {"price": 10, "message": ""}))
        c.call("submit_plan", {"name": "hut", "ops": HUT})
        self.assertIn("error", c.call("build", {}))              # not funded yet
        c.call("quote", {"price": 10, "message": ""})
        self.assertIn("error", c.call("request_payment", {}))    # not inspected
        self.assertEqual(bank.wallets["builder"], 0)

    def test_declined_quote_moves_no_money(self):
        c, bank = contract(yes=False)
        c.call("submit_plan", {"name": "hut", "ops": HUT})
        self.assertFalse(c.call("quote", {"price": 50, "message": ""})["accepted"])
        self.assertEqual(bank.wallets["player"], 200)
        self.assertIn("error", c.call("build", {}))

    def test_rejected_commands_fail_inspect_then_refund_pro_rata(self):
        c, bank = contract()
        c.chip.reject_rate = 0.5
        c.call("submit_plan", {"name": "hut", "ops": HUT})
        c.call("quote", {"price": 60, "message": ""})
        c.call("build", {})
        c.chip.reject_rate = 1.0
        for _ in range(50):                                      # random sample may miss the holes
            if not c.call("inspect", {})["passed"]:
                break
        self.assertNotEqual(c.state, "VERIFIED")
        self.assertIn("error", c.call("request_payment", {}))
        r = c.call("cancel", {"reason": "chip keeps refusing"})
        self.assertEqual(c.state, "REFUNDED")
        self.assertEqual(r["refunded_kcn"] + r["builder_kept_kcn"], c.price)
        self.assertEqual(bank.wallets["escrow"], 0)

    def test_agent_that_stops_mid_job_refunds(self):
        c, bank = contract()
        run("hut", c, scripted([("submit_plan", {"name": "hut", "ops": HUT})],
                               [("quote", {"price": 60, "message": ""})], "bye"), log=lambda *a: None)
        self.assertEqual(c.state, "REFUNDED")
        self.assertEqual(bank.wallets["player"], 200)

    def test_bad_tool_calls_are_errors_not_crashes(self):
        c, _ = contract()
        self.assertIn("error", c.call("teleport", {}))
        self.assertIn("error", c.call("quote", {"bogus": 1}))
        self.assertIn("error", c.call("submit_plan", {"_bad_json": "{"}))
        r = c.call("submit_plan", {"name": "x", "ops": [{"op": "fill", "at": [0, 0, 0], "size": [1, 30, 1],
                                                        "block": "stone"}]})
        self.assertFalse(r["ok"])

    def test_worker_walks_to_the_site_on_build(self):
        c, _ = contract()
        c.chip.spawn(3, 1, 90.0, 90.0)
        c.worker = 3
        c.call("submit_plan", {"name": "hut", "ops": HUT})
        c.call("quote", {"price": 60, "message": ""})
        c.call("build", {})
        self.assertEqual(c.chip.ents[3]["tgt"], [c.origin[0] - 1, c.origin[2] - 1])

    def test_bank_clamps_greedy_price(self):
        c, bank = contract()
        rule = c.call("submit_plan", {"name": "hut", "ops": HUT})["rule_price_kcn"]
        r = c.call("quote", {"price": 10_000, "message": ""})
        self.assertEqual(r["price_kcn"], min(200, rule * 3 // 2))


if __name__ == "__main__":
    unittest.main()
