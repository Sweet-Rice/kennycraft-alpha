"""Banker agent rules with a scripted model and a fake bank, no network:

    python -m unittest kc_agents.test_banker
"""
import unittest

from .banker import Visit, run
from .test_builder import scripted


class FakeBank:
    def __init__(self, kcn=30, dollars=12.0, yes=True):
        self.kcn, self.dollars, self.yes, self.asked, self.log = kcn, dollars, yes, [], []

    def accounts(self):
        return {"kcn": self.kcn, "dollars_available": self.dollars, "payments_waiting": 0, "chain": "ONLINE"}

    def exchange(self, dollars, to_game):
        self.kcn += dollars * 10 if to_game else -dollars * 10
        self.dollars += -dollars if to_game else dollars
        self.log.append((dollars, to_game))
        return len(self.log)

    def history(self, n):
        return [{"id": 1, "kind": "exchange_in", "kcn": 50, "status": "settled"}][:n]

    def dollar_history(self, n):
        return []

    def chain_lookup(self, entry_id):
        return {"entry_id": entry_id, "status": "finalized"}

    def ask(self, question, kcn):
        self.asked.append((question, kcn))
        return self.yes


class TestBanker(unittest.TestCase):
    def test_exchange_needs_the_players_yes(self):
        b = FakeBank()
        v = Visit(b)
        r = run("turn $5 into coins", v, scripted([("accounts", {})], [("exchange", {"dollars": 5, "to_game": True})],
                                                  "Done: 80 KCN."), log=lambda t: None)
        self.assertEqual(r, "Done: 80 KCN.")
        self.assertEqual((b.kcn, b.dollars, b.asked[0][1]), (80, 7.0, 50))
        b2 = FakeBank(yes=False)
        Visit(b2).exchange(5, True)
        self.assertEqual((b2.kcn, b2.log), (30, []))

    def test_limits(self):
        v = Visit(FakeBank(kcn=30, dollars=12.0))
        self.assertIn("error", v.exchange(50, True))          # over $20
        self.assertIn("error", v.exchange(13, True))          # more than checking holds
        self.assertIn("error", v.exchange(4, False))          # 40 KCN, has 30
        self.assertIn("error", v.exchange(2.5, True))         # whole dollars
        self.assertTrue(v.exchange(2.0, True)["accepted"])
        self.assertTrue(v.exchange(1, True)["accepted"])
        self.assertIn("error", v.exchange(1, True))           # two per visit
        self.assertIn("error", v.call("send_money", {}))      # no such tool

    def test_reads_need_no_confirmation(self):
        b = FakeBank()
        v = Visit(b)
        self.assertEqual(v.call("chain_lookup", {"entry_id": 3})["status"], "finalized")
        self.assertEqual(len(v.call("history", {"n": 50})["payments"]), 1)
        self.assertEqual(b.asked, [])


if __name__ == "__main__":
    unittest.main()
