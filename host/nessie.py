"""Nessie v2 client: the dollar side of the bank.

Key and account come from the environment or .env (NESSIE_KEY, NESSIE_ACCOUNT).

    python host/nessie.py          print the player's checking balance
    python host/nessie.py setup    create a customer + $50 checking, add NESSIE_ACCOUNT to .env
"""
import asyncio
import os
import sys
from pathlib import Path

import httpx

ROOT = Path(__file__).resolve().parent.parent
BASE = "https://v2-prod-api.nessieisreal.com"


def env(name):
    if name in os.environ:
        return os.environ[name]
    found = None
    for line in (ROOT / ".env").read_text().splitlines():
        k, _, v = line.partition("=")
        if k.strip() == name:
            found = v.strip()  # last one wins, so `setup` can append
    return found


class NessieError(Exception):
    """Anything that stops a Nessie call. type is the problem type, e.g. insufficient_funds,
    or 'unreachable' when Nessie didn't answer."""
    def __init__(self, type_, detail):
        super().__init__(f"{type_}: {detail}")
        self.type = type_


class Nessie:
    def __init__(self, key=None, account=None):
        self.account = account or env("NESSIE_ACCOUNT")
        self.http = httpx.AsyncClient(base_url=BASE, timeout=10,
                                      headers={"Authorization": f"Bearer {key or env('NESSIE_KEY')}"})

    async def call(self, method, path, body=None):
        try:
            r = await self.http.request(method, path, json=body)
        except httpx.TransportError as x:
            raise NessieError("unreachable", repr(x)) from x
        if r.status_code >= 400:
            try:
                p = r.json()
                raise NessieError(p.get("type", "").rsplit("/", 1)[-1] or str(r.status_code), p.get("detail"))
            except ValueError:
                raise NessieError(str(r.status_code), r.text[:200]) from None
        return r.json()

    async def move(self, kind, cents, desc):
        """kind 'withdrawals' (dollars into the game) or 'deposits'. desc must be unique."""
        try:
            return await self.call("POST", f"/accounts/{self.account}/{kind}",
                                   {"amount_cents": cents, "description": desc})
        except NessieError as x:
            if x.type != "unreachable":
                raise
            # No idempotency key: a create that timed out may still have happened.
            try:
                for t in await self.transactions():
                    if t["description"] == desc:
                        return t
            except NessieError:
                pass
            raise

    async def transactions(self, limit=20):
        return (await self.call("GET", f"/accounts/{self.account}/transactions?limit={limit}"))["items"]

    async def available_cents(self):
        return (await self.call("GET", f"/accounts/{self.account}"))["available_cents"]


async def main():
    n = Nessie()
    if sys.argv[1:] == ["setup"]:
        c = await n.call("POST", "/customers", {"first_name": "Kenny", "last_name": "Player", "address": {
            "street_number": "1", "street_name": "Main St", "city": "Austin", "state": "TX", "zip": "78701"}})
        a = await n.call("POST", f"/customers/{c['id']}/accounts",
                         {"type": "Checking", "nickname": "KennyCraft", "balance_cents": 5000})
        with open(ROOT / ".env", "a") as f:
            f.write(f"NESSIE_ACCOUNT={a['id']}\n")
        n.account = a["id"]
    print(n.account, f"${await n.available_cents() / 100:.2f} available")


if __name__ == "__main__":
    asyncio.run(main())
