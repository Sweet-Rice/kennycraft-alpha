"""Mob brains at two sizes.

- Chickens and zombies: rules only (wander, flee, chase). A model adds lag and nothing visible.
- Villagers (trader, contractor): a small Nemotron Nano agent. One JSON decision per call,
  two villagers per call, with a short memory. Any timeout, error or bad answer falls back
  to the rules, so the game never waits on the model.

Decisions become CR6 MOVE commands (the chip does the walking). `say` text stays on the
laptop (overlay / companion page); it never goes over UART.
"""
import json
import math
import random

from .world import KINDS

NAMES = {v: k for k, v in KINDS.items()}
VILLAGERS = {KINDS["trader"], KINDS["contractor"]}
VILLAGER_ACTS = ("wander", "idle", "greet", "follow", "go_home", "offer_job")
MAX_OFFSET = 8          # one decision moves a mob at most 8 blocks per axis
LEASH = 16              # villagers stay within 16 blocks of home
NEAR = 24               # only villagers this close to the player ask the model
THINK = {"rules": 4.0, "model": 2.0}     # seconds between decisions

MOB_SYSTEM = """You control villagers in a voxel world. For each villager listed, pick one action:
wander (stroll somewhere nearby), idle (stay), greet (turn to the player and say hello),
follow (walk toward the player), go_home, offer_job (the contractor offers to build something).
dx, dz move the villager relative to where it stands, at most 8 blocks each.
"say" is optional, at most 40 characters, in character. Traders sell, contractors build for KCN coins.
Use each villager's own id (the number after #), one decision per villager, in order.
Answer only compact JSON: {"decisions": [{"id": 5, "act": "wander", "dx": 3, "dz": -2, "say": "..."}]}"""


class Mob:
    def __init__(self, eid, kind, home):
        self.id, self.kind, self.home = eid, kind, home
        self.next_think = 0.0
        self.greeted = False
        self.memory = []            # last few things this villager did or saw

    def remember(self, text):
        self.memory = (self.memory + [text])[-3:]


def rule_decision(mob, pos, player, rnd):
    """The rule brain: every kind, and the fallback for villagers."""
    dx, dz = player[0] - pos[0], player[1] - pos[1]
    dist = math.hypot(dx, dz)
    if mob.kind == KINDS["zombie"] and dist < 12:
        return {"act": "chase", "dx": dx, "dz": dz}
    if mob.kind == KINDS["chicken"] and dist < 3:
        k = 4 / max(dist, 0.1)
        return {"act": "flee", "dx": -dx * k, "dz": -dz * k}
    if mob.kind in VILLAGERS and dist < 5 and not mob.greeted:
        return {"act": "greet", "dx": 0, "dz": 0, "say": "Hello there!"}
    if rnd.random() < 0.3:
        return {"act": "idle", "dx": 0, "dz": 0}
    return {"act": "wander", "dx": rnd.uniform(-4, 4), "dz": rnd.uniform(-4, 4)}


def validate(mob, d, pos, player):
    """Turn any decision (model or rules) into a safe target. Returns (act, tx, tz, say)."""
    act = d.get("act", "idle")
    if mob.kind in VILLAGERS and act not in VILLAGER_ACTS:
        act = "idle"
    if act == "offer_job" and mob.kind != KINDS["contractor"]:
        act = "greet"
    try:
        dx, dz = float(d.get("dx", 0)), float(d.get("dz", 0))
    except (TypeError, ValueError):
        dx = dz = 0.0
    if act == "go_home":
        dx, dz = mob.home[0] - pos[0], mob.home[1] - pos[1]
    if act in ("follow", "chase"):
        dx, dz = player[0] - pos[0], player[1] - pos[1]
    dx = max(-MAX_OFFSET, min(MAX_OFFSET, dx))
    dz = max(-MAX_OFFSET, min(MAX_OFFSET, dz))
    tx, tz = pos[0] + dx, pos[1] + dz
    if mob.kind in VILLAGERS:                                   # leash to home
        hx, hz = tx - mob.home[0], tz - mob.home[1]
        r = math.hypot(hx, hz)
        if r > LEASH:
            tx, tz = mob.home[0] + hx * LEASH / r, mob.home[1] + hz * LEASH / r
    say = str(d.get("say", ""))[:40] if mob.kind in VILLAGERS else ""
    if not any(c.isalpha() for c in say):                       # Nano sometimes "says" "..."
        say = ""
    return act, tx, tz, say


class MobManager:
    """Owns the mobs: spawns them on the chip and sends a MOVE when a brain decides.
    chat_json(messages) -> dict is the Nano call (None = rules only)."""

    def __init__(self, chip, chat_json=None, seed=0, log=print):
        self.chip, self.chat, self.log = chip, chat_json, log
        self.rnd = random.Random(seed)
        self.mobs = {}
        self.busy = set()               # ids on a job (the builder drives them); brains skip these
        self.stats = {"model": 0, "rules": 0, "fallback": 0, "moves": 0}
        self.context = ""               # what's going on in the game, for the villagers to react to

    def spawn(self, kind, x, z):
        eid = next((i for i in range(8) if i not in self.mobs), None)
        if eid is None or not self.chip.spawn(eid, KINDS[kind], x, z):
            return None
        self.mobs[eid] = Mob(eid, KINDS[kind], (x, z))
        return eid

    def _pos(self, m):
        x, _, z = self.chip.entity(m.id)
        return x, z

    def _apply(self, m, d, player, source):
        pos = self._pos(m)
        act, tx, tz, say = validate(m, d, pos, player)
        if act == "greet":
            m.greeted = True
        if (tx, tz) != pos and self.chip.move(m.id, tx, tz):
            self.stats["moves"] += 1
        self.stats[source] += 1
        m.remember(act)
        m.next_think = self.now + THINK["model" if source == "model" else "rules"]
        if say:
            self.log(f"  {NAMES[m.kind]} #{m.id}: \"{say}\"")
        return act, say

    def _ask_model(self, group, player):
        lines = []
        for m in group:
            x, z = self._pos(m)
            lines.append(f"#{m.id} {NAMES[m.kind]} at ({x - player[0]:+.0f},{z - player[1]:+.0f}) from the player, "
                         f"home ({m.home[0] - player[0]:+.0f},{m.home[1] - player[1]:+.0f}), "
                         f"recently: {', '.join(m.memory) or 'nothing'}")
        reply = self.chat([{"role": "system", "content": MOB_SYSTEM},
                           {"role": "user", "content": "\n".join(([self.context] if self.context else []) + lines)}])
        ds = [d for d in reply.get("decisions", []) if isinstance(d, dict)]
        ids = [m.id for m in group]
        if {d.get("id") for d in ds} <= set(ids):
            return {d.get("id"): d for d in ds}
        return dict(zip(ids, ds))       # Nano often copies the example's id 0: match by order instead

    def step(self, now, player):
        """Call every ~250 ms with the player's (x, z). Returns [(id, act, say)] decided this step."""
        self.now = now
        due = [m for m in self.mobs.values() if m.next_think <= now and m.id not in self.busy]
        smart = [m for m in due if self.chat and m.kind in VILLAGERS
                 and math.dist(self._pos(m), player) < NEAR]
        done = []
        for i in range(0, len(smart), 2):                       # two villagers per call
            group = smart[i:i + 2]
            try:
                answers = self._ask_model(group, player)
            except Exception as e:                               # timeout, bad JSON, server down
                self.log(f"  model failed ({type(e).__name__}); rules decide")
                answers = {}
            for m in group:
                if m.id in answers:
                    done.append((m.id, *self._apply(m, answers[m.id], player, "model")))
                else:
                    self.stats["fallback"] += 1
                    done.append((m.id, *self._apply(m, rule_decision(m, self._pos(m), player, self.rnd), player, "rules")))
        for m in due:
            if m not in smart:
                done.append((m.id, *self._apply(m, rule_decision(m, self._pos(m), player, self.rnd), player, "rules")))
        return done


def json_reply(text):
    """Parse a model reply that should be JSON, tolerating a ```json fence."""
    text = text.strip().removeprefix("```json").removeprefix("```").removesuffix("```")
    return json.loads(text)
