"""KennyCraft bank: SQLite ledger first, Solana devnet second.

Ledger.post() checks the balance and queues an entry in one SQLite
transaction, so the game sees the new balance at once. Settler drains queued
entries to the chain strictly in id order, one TransferChecked + Memo each,
with the treasury paying every fee. This is the only module that loads keys
(keys/*.json, addresses from kcn.json; both made by scripts/setup_kcn.sh).

    python host/bank.py        run the settler and print its mode every 5 s
"""
import asyncio
import base64
import json
import os
import sqlite3
import time
from pathlib import Path

import httpx
from solders.hash import Hash
from solders.instruction import AccountMeta, Instruction
from solders.keypair import Keypair
from solders.message import Message
from solders.pubkey import Pubkey
from solders.transaction import Transaction

ROOT = Path(__file__).resolve().parent.parent
TOKEN = Pubkey.from_string("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA")
MEMO = Pubkey.from_string("Memo4c2pN8afCj432Lb7RMVKi9PbQnnW7ewFFaV3oAH")  # what spl-token --with-memo uses
KINDS = {"exchange_in", "exchange_out", "fund", "release", "fee", "refund", "trade_buy", "trade_sell"}
RATE = 10  # KCN per dollar (placeholder)

# tx/lvbh hold the last signed attempt: it is rebroadcast until its blockhash
# expires, and only then rebuilt, so a timeout can never pay twice.
SCHEMA = """CREATE TABLE IF NOT EXISTS entries (
  id INTEGER PRIMARY KEY, ts REAL, kind TEXT,
  from_wallet TEXT, to_wallet TEXT, amount INTEGER,
  contract_id INTEGER, status TEXT,
  sig TEXT, err TEXT, tries INTEGER DEFAULT 0,
  tx TEXT, lvbh INTEGER)"""
# Building materials live on the laptop only (the chip has no inventory): the trader's
# stock and the player's, moved in the same transaction as the KCN that pays for them.
ITEMS = "CREATE TABLE IF NOT EXISTS items (owner TEXT, item TEXT, qty INTEGER, PRIMARY KEY (owner, item))"


def kcn():
    return json.loads((ROOT / "kcn.json").read_text())


class InsufficientFunds(Exception):
    pass


class Ledger:
    def __init__(self, path=ROOT / "bank.db", wallets=None):
        self.wallets = set(wallets or kcn()["wallets"])
        self.db = sqlite3.connect(path, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute(SCHEMA)
        self.db.execute(ITEMS)

    def balance(self, wallet, settled_only=False):
        q = ("SELECT COALESCE(SUM(CASE WHEN to_wallet = ?1 THEN amount ELSE -amount END), 0)"
             " FROM entries WHERE (to_wallet = ?1 OR from_wallet = ?1)")
        if settled_only:
            q += " AND status = 'settled'"
        return self.db.execute(q, (wallet,)).fetchone()[0]

    def post(self, kind, src, dst, amount, contract_id=None, items=()):
        """Queue src -> dst and return the entry id. Never lets a balance go negative.
        items: (owner, item, change) moves made in the same transaction, for a trade."""
        if kind not in KINDS or src not in self.wallets or dst not in self.wallets or src == dst:
            raise ValueError(f"bad entry {kind} {src} -> {dst}")
        if type(amount) is not int or amount <= 0:
            raise ValueError(f"bad amount {amount!r}")
        self.db.execute("BEGIN IMMEDIATE")
        try:
            have = self.balance(src)
            if have < amount:
                raise InsufficientFunds(f"{src} has {have} KCN, needs {amount}")
            self._move_items(items)
            cur = self.db.execute(
                "INSERT INTO entries (ts, kind, from_wallet, to_wallet, amount, contract_id, status)"
                " VALUES (?, ?, ?, ?, ?, ?, 'queued')", (time.time(), kind, src, dst, amount, contract_id))
            self.db.execute("COMMIT")
            return cur.lastrowid
        except BaseException:
            self.db.execute("ROLLBACK")
            raise

    def stock(self, owner):
        return {r["item"]: r["qty"] for r in self.db.execute(
            "SELECT item, qty FROM items WHERE owner = ? AND qty > 0 ORDER BY item", (owner,))}

    def _move_items(self, changes):
        for owner, item, change in changes:
            have = self.stock(owner).get(item, 0)
            if have + change < 0:
                raise InsufficientFunds(f"{owner} has {have} {item}, needs {-change}")
            self.db.execute("INSERT INTO items (owner, item, qty) VALUES (?, ?, ?) ON CONFLICT (owner, item)"
                            " DO UPDATE SET qty = qty + excluded.qty", (owner, item, change))

    def move_items(self, changes):
        """Items only (the builder using the player's materials): all or nothing."""
        self.db.execute("BEGIN IMMEDIATE")
        try:
            self._move_items(changes)
            self.db.execute("COMMIT")
        except BaseException:
            self.db.execute("ROLLBACK")
            raise

    def seed(self, balances):
        """Empty ledger only: record what the chain already holds as settled mints."""
        if self.db.execute("SELECT 1 FROM entries").fetchone():
            return
        self.db.execute("BEGIN IMMEDIATE")
        for w, amount in balances.items():
            if amount:
                self.db.execute("INSERT INTO entries (ts, kind, to_wallet, amount, status)"
                                " VALUES (?, 'mint', ?, ?, 'settled')", (time.time(), w, amount))
        self.db.execute("COMMIT")

    def queued(self):
        return self.db.execute("SELECT * FROM entries WHERE status = 'queued' ORDER BY id").fetchall()


async def exchange(ledger, nessie, dollars, to_game=True):
    """The banker villager. to_game: $ -> KCN (Nessie withdrawal), else KCN -> $ (Nessie deposit).

    Nessie goes first and the ledger entry is written only once Nessie accepted
    the transaction, so a NessieError (show "bank is closed", or "not enough
    money" for type insufficient_funds) leaves everything unchanged. Returns the entry id.
    """
    if type(dollars) is not int or dollars <= 0:
        raise ValueError(f"bad amount {dollars!r}")
    kcn, cents = dollars * RATE, dollars * 100
    kind, src, dst, move, undo = (("exchange_in", "treasury", "player", "withdrawals", "deposits") if to_game
                                  else ("exchange_out", "player", "treasury", "deposits", "withdrawals"))
    if ledger.balance(src) < kcn:
        raise InsufficientFunds(f"{src} has {ledger.balance(src)} KCN, needs {kcn}")
    desc = f"KC {kind} {kcn} KCN #{time.time_ns()}"
    await nessie.move(move, cents, desc)
    # ponytail: Nessie can still decline at settlement (~1 min later); only the bank
    # touches this account, so funds checked at create time stay put.
    try:
        return ledger.post(kind, src, dst, kcn)
    except InsufficientFunds:  # KCN spent while Nessie was answering: give the dollars back
        await nessie.move(undo, cents, desc + " undo")
        raise


class Settler:
    def __init__(self, ledger, rpc_urls=None):
        cfg = kcn()
        self.ledger = ledger
        self.mint = Pubkey.from_string(cfg["mint"])
        self.ata = {w: Pubkey.from_string(v["token_account"]) for w, v in cfg["wallets"].items()}
        self.keys = {w: Keypair.from_json((ROOT / "keys" / f"{w}.json").read_text()) for w in cfg["wallets"]}
        self.urls = rpc_urls or [u for u in (os.environ.get("RPC_URL", cfg["rpc_url"]),
                                             os.environ.get("RPC_URL_2")) if u]
        self.url_i = 0
        self.http = httpx.AsyncClient(timeout=10)
        self.fails = 0
        self.last_ok = 0.0

    async def rpc(self, method, *params):
        r = await self.http.post(self.urls[self.url_i],
                                 json={"jsonrpc": "2.0", "id": 1, "method": method, "params": list(params)})
        r.raise_for_status()
        body = r.json()
        if "error" in body:
            raise RuntimeError(f"{method}: {body['error'].get('message')}")
        return body["result"]

    def mode(self):
        n = len(self.ledger.queued())
        if self.fails >= 3:
            return "OFFLINE", n
        if n < 3 and (n == 0 or time.time() - self.last_ok < 20):
            return "ONLINE", n
        return "DEGRADED", n

    async def chain_balances(self):
        return {w: int((await self.rpc("getTokenAccountBalance", str(a)))["value"]["amount"])
                for w, a in self.ata.items()}

    async def reconcile(self):
        """Seed an empty ledger from the chain; return {wallet: (chain, settled)} where they differ."""
        chain = await self.chain_balances()
        self.ledger.seed(chain)
        settled = {w: self.ledger.balance(w, settled_only=True) for w in chain}
        return {w: (chain[w], settled[w]) for w in chain if chain[w] != settled[w]}

    def build(self, e, blockhash):
        payer, owner = self.keys["treasury"], self.keys[e["from_wallet"]]
        data = bytes([12]) + e["amount"].to_bytes(8, "little") + bytes([0])  # TransferChecked, 0 decimals
        xfer = Instruction(TOKEN, data, [
            AccountMeta(self.ata[e["from_wallet"]], False, True),
            AccountMeta(self.mint, False, False),
            AccountMeta(self.ata[e["to_wallet"]], False, True),
            AccountMeta(owner.pubkey(), True, False)])
        tag = f"KC#{e['contract_id']}" if e["contract_id"] else "KC"
        memo = Instruction(MEMO, f"{tag} {e['kind']} e{e['id']}".encode(), [])
        msg = Message.new_with_blockhash([xfer, memo], payer.pubkey(), blockhash)
        return Transaction(list({payer.pubkey(): payer, owner.pubkey(): owner}.values()), msg, blockhash)

    async def status(self, sig):
        return (await self.rpc("getSignatureStatuses", [sig], {"searchTransactionHistory": True}))["value"][0]

    def landed(self, st):
        return st and st["err"] is None and st["confirmationStatus"] in ("confirmed", "finalized")

    async def settle(self, e):
        db = self.ledger.db
        reuse = False
        if e["tx"]:
            st = await self.status(e["sig"])
            if self.landed(st):
                return self.done(e["id"], e["sig"])
            height = await self.rpc("getBlockHeight", {"commitment": "confirmed"})
            reuse = (st is not None and st["err"] is None) or (st is None and height <= e["lvbh"])
        if reuse:
            raw, sig = e["tx"], e["sig"]
        else:
            bh = (await self.rpc("getLatestBlockhash", {"commitment": "confirmed"}))["value"]
            tx = self.build(e, Hash.from_string(bh["blockhash"]))
            raw, sig = base64.b64encode(bytes(tx)).decode(), str(tx.signatures[0])
            # Saved before sending, so a crash right after the send is still tracked.
            db.execute("UPDATE entries SET tx = ?, sig = ?, lvbh = ? WHERE id = ?",
                       (raw, sig, bh["lastValidBlockHeight"], e["id"]))
        await self.rpc("sendTransaction", raw, {"encoding": "base64", "skipPreflight": reuse,
                                                "preflightCommitment": "confirmed"})
        for _ in range(30):  # 15 s for confirmed
            await asyncio.sleep(0.5)
            st = await self.status(sig)
            if st and st["err"]:
                raise RuntimeError(f"on-chain error {st['err']}")
            if self.landed(st):
                return self.done(e["id"], sig)
        raise TimeoutError("not confirmed within 15 s")

    def done(self, entry_id, sig):
        self.ledger.db.execute("UPDATE entries SET status = 'settled', sig = ?, err = NULL WHERE id = ?",
                               (sig, entry_id))

    async def run(self):
        while True:
            q = self.ledger.queued()
            if not q:
                await asyncio.sleep(0.5)
                continue
            e = q[0]
            try:
                await self.settle(e)
                self.fails, self.last_ok = 0, time.time()
            except Exception as x:
                self.fails += 1
                self.ledger.db.execute("UPDATE entries SET tries = tries + 1, err = ? WHERE id = ?",
                                       (f"{type(x).__name__}: {x}"[:200], e["id"]))
                if self.fails % 3 == 0:  # switch RPC after 3 failures in a row
                    self.url_i = (self.url_i + 1) % len(self.urls)
                await asyncio.sleep(min(2 ** (self.fails - 1), 10))  # 10 s = OFFLINE probe interval


async def main():
    settler = Settler(Ledger())
    print("drift:", await settler.reconcile() or "none")
    asyncio.create_task(settler.run())
    while True:
        print(*settler.mode(), "queued")
        await asyncio.sleep(5)


if __name__ == "__main__":
    asyncio.run(main())
