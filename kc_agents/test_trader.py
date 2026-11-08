"""Trader agent rules with a scripted model and a fake market, no network:

    python -m unittest kc_agents.test_trader
"""
import unittest

from .test_builder import scripted
from .trader import Visit, clamp, list_price, run


class FakeMarket:
    def __init__(self, kcn=100, yes=True):
        self.trader, self.player, self.kcn, self.yes, self.asked = {"brick": 100, "planks": 50}, {}, kcn, yes, []

    def stock(self):
        return {"trader": dict(self.trader), "player": dict(self.player), "kcn": self.kcn}

    def trade(self, item, qty, kcn, buy):
        src, dst = (self.trader, self.player) if buy else (self.player, self.trader)
        src[item] -= qty
        dst[item] = dst.get(item, 0) + qty
        self.kcn += -kcn if buy else kcn

    def ask(self, question, kcn):
        self.asked.append((question, kcn))
        return self.yes


class TestTrader(unittest.TestCase):
    def test_haggle_within_limits(self):
        self.assertEqual(list_price("brick", 40), 40)
        self.assertEqual(clamp("brick", 40, 1, True), 32)        # at least 80% of list
        self.assertEqual(clamp("brick", 40, 999, True), 52)      # at most 130%
        self.assertEqual(clamp("brick", 40, 999, False), 28)     # buys back at most 70%
        self.assertEqual(clamp("brick", 40, 35, True), 35)

    def test_deal_needs_yes_and_stock(self):
        m = FakeMarket(kcn=100)
        v = Visit(m)
        r = run("40 bricks please, can you do 30?", v, scripted(
            [("look", {})], [("offer", {"item": "brick", "qty": 40, "buy": True, "price": 30, "message": "Deal!"})],
            "Enjoy your bricks!"), log=lambda t: None)
        self.assertEqual(r, "Enjoy your bricks!")
        self.assertEqual((m.player, m.trader["brick"], m.kcn), ({"brick": 40}, 60, 68))   # 30 -> 32 (80% floor)
        no = FakeMarket(yes=False)
        self.assertFalse(Visit(no).offer_deal("brick", 10, True, 10)["accepted"])
        self.assertEqual(no.player, {})

    def test_refusals(self):
        v = Visit(FakeMarket(kcn=10))
        self.assertIn("error", v.offer_deal("brick", 500, True, 500))     # over MAX_QTY
        self.assertIn("error", v.offer_deal("planks", 60, True, 40))      # trader has 50
        self.assertIn("error", v.offer_deal("brick", 20, True, 20))       # 16+ KCN, player has 10
        self.assertIn("error", v.offer_deal("brick", 5, False, 2))        # player has no brick
        self.assertIn("error", v.offer_deal("diamond", 1, True, 1))
        self.assertIn("error", v.call("give_everything", {}))


if __name__ == "__main__":
    unittest.main()
