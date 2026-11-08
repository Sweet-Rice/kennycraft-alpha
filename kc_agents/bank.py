"""The bank as the agents see it. The real one (ledger + Solana settler) lives in the banking
service and must expose these same methods; agents never hold keys, they only call these.

All amounts are whole KCN.
"""

FEE = 0.10          # treasury's cut of every released contract


def rule_price(cells, breaks):
    return 5 + cells + 2 * breaks


def clamp_price(proposed, rule, balance, cap=200):
    """The agent proposes, the bank decides: within 0.5x-1.5x of the rule price, the cap and the balance."""
    lo, hi = max(1, rule // 2), min(cap, rule * 3 // 2, balance)
    return max(lo, min(int(proposed), hi)) if hi >= lo else None


class FakeBank:
    def __init__(self, player=100):
        self.wallets = {"player": player, "escrow": 0, "treasury": 0, "builder": 0}
        self.log = []

    def balance(self, wallet="player"):
        return self.wallets[wallet]

    def _move(self, kind, src, dst, amount, contract):
        if amount < 0 or self.wallets[src] < amount:
            raise ValueError(f"{kind}: {src} has {self.wallets[src]}, needs {amount}")
        self.wallets[src] -= amount
        self.wallets[dst] += amount
        self.log.append((kind, src, dst, amount, contract))

    def fund(self, contract, amount):
        self._move("fund", "player", "escrow", amount, contract)

    def release(self, contract, amount, to="builder"):
        fee = round(amount * FEE)
        self._move("release", "escrow", to, amount - fee, contract)
        self._move("fee", "escrow", "treasury", fee, contract)

    def refund(self, contract, amount, paid_to_builder=0, to="builder"):
        if paid_to_builder:
            self._move("release", "escrow", to, paid_to_builder, contract)
        self._move("refund", "escrow", "player", amount - paid_to_builder, contract)
