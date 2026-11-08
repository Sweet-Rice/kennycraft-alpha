"""Builder contractor: a Nemotron agent that surveys the site, plans a build, prices it,
gets the player's OK, builds it on the chip, checks the work and asks to be paid.

The model only chooses tools and arguments. The contract state machine in this file decides
what is allowed: no quote without a valid plan, no build before the escrow is funded, no
payment before the chip's blocks check out. Prices are clamped by the bank.

  python -m kc_agents.builder "a small plank hut with a brick roof"
"""
import json
import random
import sys

from . import bank as bankmod
from . import blueprints
from .world import ID, BLOCKS, BEDROCK, Y_MIN, Y_MAX, expand, compress

SYSTEM = """You are a builder villager in a voxel world. A player hires you to build something.
The site survey (zone size, ground, the player's balance) comes with the request.
Work in steps with the tools, in this order:
1. use_blueprint with the premade design closest to the request; set materials to match
   what the player asked for (e.g. walls "brick"). Only for something no blueprint covers,
   submit_plan with box ops in zone-local coordinates (x, z across, y up; y = 0 is the first
   layer above the ground; ops fill, hollow, walls, clear, block). If a plan is rejected,
   fix it and try again.
3. quote a fair price (the tool tells you the guild's rule price) with one short sentence for the player.
4. If the player accepts: build, then inspect. If inspect finds mistakes, build again, then inspect.
5. request_payment once inspect passes. If something goes wrong you can't fix, cancel.
Only tool calls do anything: the player sees your price only through quote.
Keep builds within the player's budget. Finish with one short sentence to the player."""


def _tool(name, desc, props=None, required=()):
    return {"type": "function", "function": {"name": name, "description": desc, "parameters": {
        "type": "object", "properties": props or {}, "required": list(required)}}}


_VEC = {"type": "array", "items": {"type": "integer"}, "minItems": 3, "maxItems": 3}
TOOLS = [
    _tool("look_at_site", "Zone size, ground heights relative to the zone floor, and the player's balance."),
    _tool("use_blueprint", "Plan a premade build, fitted to the zone: " +
          "; ".join(f"{k}: {v}" for k, v in blueprints.CATALOG.items()) +
          " Returns the same check as submit_plan.",
          {"name": {"type": "string", "enum": sorted(blueprints.CATALOG)},
           "materials": {"type": "object", "description": "optional block per part: floor, walls, roof, trim",
                         "properties": {p: {"type": "string", "enum": sorted(BLOCKS[1:10])} for p in blueprints.PARTS}}},
          ["name"]),
    _tool("submit_plan", "Check a build plan. Returns errors, or the block counts, command count and rule price.",
          {"name": {"type": "string"},
           "ops": {"type": "array", "items": {"type": "object", "properties": {
               "op": {"type": "string", "enum": ["fill", "hollow", "walls", "clear", "block"]},
               "at": _VEC, "size": _VEC,
               "block": {"type": "string", "enum": sorted(BLOCKS[1:10])}},
               "required": ["op", "at"]}}},
          ["name", "ops"]),
    _tool("quote", "Offer the checked plan to the player for a price in KCN. Returns whether they accepted.",
          {"price": {"type": "integer"}, "message": {"type": "string"}}, ["price", "message"]),
    _tool("build", "Send the build commands to the chip. Only after the player accepted."),
    _tool("inspect", "Read back random cells of the plan from the chip and compare them."),
    _tool("request_payment", "Ask the bank to release the escrow. Only after inspect passed."),
    _tool("cancel", "Stop the contract; the player is refunded for the work not done.",
          {"reason": {"type": "string"}}, ["reason"]),
]


class Contract:
    def __init__(self, cid, chip, bank, ask_player, origin=(0, 0), zone=(8, 8, 8), seed=0, worker=None):
        self.id, self.chip, self.bank, self.ask = cid, chip, bank, ask_player
        self.worker = worker            # entity id of the contractor villager, walked to the site on build
        self.zone = zone
        ox, oz = origin
        grounds = sorted(chip.ground(ox + x, oz + z) for x in range(zone[0]) for z in range(zone[2]))
        self.origin = (ox, grounds[len(grounds) // 2] + 1, oz)     # floor = median ground + 1
        self.state, self.supplied = "SURVEY", {}
        self.target, self.cmds, self.price, self.builds = {}, [], 0, 0
        self.rnd = random.Random(seed)

    def _abs(self, x, y, z):
        return self.origin[0] + x, self.origin[1] + y, self.origin[2] + z

    # ---- tools -------------------------------------------------------------------------
    def look_at_site(self):
        ox, fy, oz = self.origin
        rows = [[self.chip.ground(ox + x, oz + z) - fy + 1 for x in range(self.zone[0])]
                for z in range(self.zone[2])]
        return {"zone_size_xyz": list(self.zone), "ground_top_relative_to_floor_by_z_then_x": rows,
                "note": "0 means the ground is right under layer y=0; 1 means it pokes into layer 0",
                "player_balance_kcn": self.bank.balance("player")}

    def submit_plan(self, name="", ops=()):
        if self.state not in ("SURVEY", "PLANNED"):
            return {"error": f"can't change the plan in state {self.state}"}
        cells, errors = expand(list(ops), self.zone)
        target, breaks = {}, 0
        for (x, y, z), b in cells.items():
            ax, ay, az = self._abs(x, y, z)
            have = self.chip.get(ax, ay, az)
            if not Y_MIN <= ay <= Y_MAX:
                errors.append(f"cell {(x, y, z)} is at world height {ay}, outside {Y_MIN}..{Y_MAX}")
                break
            if have == b or have == BEDROCK:
                continue
            breaks += b == 0
            target[(ax, ay, az)] = b
        if not errors and not target:
            errors.append("the plan changes nothing")
        solid = lambda c: target.get(c, self.chip.get(*c)) != 0          # after the build
        if not errors and not any(b and solid((x, y - 1, z)) and (x, y - 1, z) not in target
                                  for (x, y, z), b in target.items()):
            errors.append("the build floats: nothing in it rests on the ground. Start the bottom layer at y = 0.")
        if errors:
            return {"ok": False, "errors": errors[:8]}
        self.target, self.cmds, self.state = target, compress(target), "PLANNED"
        counts = {}
        for b in target.values():
            counts[BLOCKS[b]] = counts.get(BLOCKS[b], 0) + 1
        # Blocks the player already owns (bought from the trader) are used first: half off each.
        have = getattr(self.bank, "materials", lambda: {})()
        self.supplied = {k: min(n, have.get(k, 0)) for k, n in counts.items() if k != "air" and have.get(k)}
        discount = sum(self.supplied.values()) // 2
        self.rule = max(5, bankmod.rule_price(len(target) - breaks, breaks) - discount)
        return {"ok": True, "name": name, "cells": counts, "commands": len(self.cmds),
                "rule_price_kcn": self.rule, "player_materials_used": self.supplied,
                "materials_discount_kcn": discount, "player_balance_kcn": self.bank.balance("player")}

    def use_blueprint(self, name="", materials=None):
        ops, error = blueprints.ops(name, self.zone, materials)
        if error:
            return {"ok": False, "errors": [error]}
        return self.submit_plan(name, ops)

    def quote(self, price=0, message=""):
        if self.state != "PLANNED":
            return {"error": "submit a plan that passes first"}
        p = bankmod.clamp_price(price, self.rule, self.bank.balance("player"))
        if p is None:
            return {"error": "the player can't afford this plan; make it smaller", "rule_price_kcn": self.rule}
        self.offer = p                  # the chip's quote prompt shows it while ask() waits
        if not self.ask(f"{message} Price: {p} KCN. Accept?"):
            self.state = "DECLINED"
            return {"accepted": False, "price_kcn": p}
        self.bank.fund(self.id, p)
        self.price, self.state = p, "FUNDED"
        return {"accepted": True, "price_kcn": p, "note": "" if p == price else "the bank adjusted your price"}

    def build(self):
        if self.state not in ("FUNDED", "BUILT"):
            return {"error": f"can't build in state {self.state}"}
        if self.builds >= 3:
            return {"error": "out of build attempts; cancel"}
        self.builds += 1
        if self.worker is not None:     # the contractor walks to the corner of the site (CR6 MOVE)
            self.chip.move(self.worker, self.origin[0] - 1, self.origin[2] - 1)
        ok = 0
        for c in self.cmds:
            ok += self.chip.place(*c[1:]) if c[0] == "place" else self.chip.fill(*c[1:])
        self.state = "BUILT"
        return {"commands": len(self.cmds), "accepted_by_chip": ok, "rejected": len(self.cmds) - ok}

    def inspect(self, n=8):
        if self.state != "BUILT":
            return {"error": "build first"}
        sample = self.rnd.sample(sorted(self.target), min(n, len(self.target)))
        read = getattr(self.chip, "verify", self.chip.get)        # over CR6: ask the chip itself
        wrong = [c for c in sample if read(*c) != self.target[c]]
        placed = sum(self.chip.get(*c) == b for c, b in self.target.items())
        if not wrong:
            self.state = "VERIFIED"
        return {"passed": not wrong, "checked": len(sample), "wrong": len(wrong),
                "progress": f"{placed}/{len(self.target)}"}

    def request_payment(self):
        if self.state != "VERIFIED":
            return {"error": "inspect must pass first"}
        self.bank.release(self.id, self.price)
        if self.supplied:               # ponytail: a refunded job keeps the player's blocks
            self.bank.use_materials(self.supplied)
        self.state = "PAID"
        return {"paid_kcn": self.price, "fee_kcn": round(self.price * bankmod.FEE)}

    def cancel(self, reason=""):
        if self.state in ("FUNDED", "BUILT"):
            done = sum(self.chip.get(*c) == b for c, b in self.target.items())
            earned = self.price * done // len(self.target)
            self.bank.refund(self.id, self.price, paid_to_builder=earned)
            self.state = "REFUNDED"
            return {"refunded_kcn": self.price - earned, "builder_kept_kcn": earned}
        if self.state in ("PAID", "REFUNDED"):
            return {"error": f"already {self.state}"}
        self.state = "CANCELLED"
        return {"cancelled": True}

    def call(self, name, args):
        if name not in {t["function"]["name"] for t in TOOLS}:
            return {"error": f"no tool {name}"}
        if "_bad_json" in args:
            return {"error": "arguments were not valid JSON"}
        try:
            return getattr(self, name)(**args)
        except TypeError as e:
            return {"error": f"bad arguments: {e}"}


NEXT = {"SURVEY": "use_blueprint", "PLANNED": "quote", "FUNDED": "build", "BUILT": "inspect",
        "VERIFIED": "request_payment"}      # the tool a stalled contract is waiting on


def finish(contract, log=print, tries=3):
    """After the player paid: build, inspect (rebuilding what's wrong), get paid. These steps
    are mechanical, so code runs them instead of a model round trip each (about 5 s saved)."""
    for _ in range(tries):
        for name in ("build", "inspect"):
            log(f"  {name}() -> {json.dumps(getattr(contract, name)())[:160]}")
        if contract.state == "VERIFIED":
            log(f"  request_payment() -> {json.dumps(contract.request_payment())}")
            return "Done! Your build is finished and checked."
    log(f"  gave up after {tries} builds: {contract.cancel('the chip kept rejecting the build')}")
    return "I couldn't finish the build, so you were refunded for the work not done."


def run(request, contract, chat, max_steps=20, log=print, system=SYSTEM, tools=TOOLS, next_tool=NEXT,
        autopilot=False):
    """The agent loop (the builder's by default; the banker passes its own prompt and tools).
    autopilot: once the player accepts the quote, code builds, inspects and collects (finish).
    Returns the model's last message to the player."""
    first = request
    if hasattr(contract, "look_at_site"):   # one less round trip: the survey rides with the request
        first += "\n\nSite survey: " + json.dumps(contract.look_at_site())
    messages = [{"role": "system", "content": system}, {"role": "user", "content": first}]
    nudges = 0
    for _ in range(max_steps):
        reply = chat(messages, tools)
        messages.append({"role": "assistant", "content": reply["content"], "tool_calls": [
            {"id": c["id"], "type": "function",
             "function": {"name": c["name"], "arguments": json.dumps(c["args"])}} for c in reply["tool_calls"]]
            or None})
        if not reply["tool_calls"]:
            nxt = next_tool.get(contract.state)
            if not nxt or nudges >= 2:
                break
            nudges += 1         # it said what it would do instead of doing it
            messages.append({"role": "user", "content": f"Don't tell me, use the tools: call {nxt} now."})
            continue
        for c in reply["tool_calls"]:
            result = contract.call(c["name"], c["args"])
            log(f"  {c['name']}({json.dumps(c['args'])[:120]}) -> {json.dumps(result)[:160]}")
            messages.append({"role": "tool", "tool_call_id": c["id"], "content": json.dumps(result)})
        if autopilot and contract.state == "FUNDED":
            return finish(contract, log)
    if contract.state in ("FUNDED", "BUILT", "VERIFIED"):          # the model stopped mid-contract
        log(f"  agent stopped in {contract.state}: {contract.cancel('agent stopped')}")
    return reply["content"]


if __name__ == "__main__":
    from .llm import nemotron_chat
    from .world import FakeChip
    b = bankmod.FakeBank(player=100)
    c = Contract(1, FakeChip(), b, ask_player=lambda q: (print("  PLAYER:", q), True)[1])
    print("BUILDER:", run(" ".join(sys.argv[1:]) or "a small plank hut", c, nemotron_chat()))
    print("state:", c.state, "| wallets:", b.wallets)
