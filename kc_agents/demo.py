"""End-to-end demo on the fake chip: four mobs live around the player, then the player hires
the contractor, who walks to the site while the builder agent plans, quotes, builds and gets paid.

  python -m kc_agents.demo               rules for mobs, a scripted builder (no GPU, no key)
  NANO_BASE_URL=... python -m kc_agents.demo     villagers think with Nemotron Nano
  NVIDIA_API_KEY=... python -m kc_agents.demo    the builder runs on Nemotron Super
"""
import os

from .bank import FakeBank
from .builder import Contract, run
from .mobs import MobManager
from .world import FakeChip

DEMO_HUT = [{"op": "fill", "at": [0, 0, 0], "size": [5, 1, 5], "block": "cobble"},
            {"op": "walls", "at": [0, 1, 0], "size": [5, 3, 5], "block": "planks"},
            {"op": "clear", "at": [2, 1, 0], "size": [1, 2, 1]},
            {"op": "fill", "at": [0, 4, 0], "size": [5, 1, 5], "block": "brick"}]


def scripted_builder():
    """Stands in for Nemotron Super when there's no API key: the same tool calls, in order."""
    steps = [[("look_at_site", {})], [("submit_plan", {"name": "hut", "ops": DEMO_HUT})],
             [("quote", {"price": 60, "message": "A cobble hut with plank walls and a brick roof."})],
             [("build", {})], [("inspect", {})], [("request_payment", {})], "Your hut is done. Enjoy!"]

    def chat(messages, tools):
        s = steps.pop(0)
        if isinstance(s, str):
            return {"content": s, "tool_calls": []}
        return {"content": "", "tool_calls": [{"id": f"s{len(steps)}", "name": n, "args": a} for n, a in s]}
    return chat


def main():
    chip, bank = FakeChip(), FakeBank(player=100)
    nano = None
    if os.environ.get("NANO_BASE_URL"):
        from .llm import nano_json
        nano = nano_json()
    mobs = MobManager(chip, nano)
    px, pz = 100.0, 100.0
    for kind, dx, dz in (("pig", 6, 2), ("zombie", -14, 9), ("trader", 3, -5), ("contractor", -4, -3)):
        mobs.spawn(kind, px + dx, pz + dz)

    print(f"== 20 s of mob life ({'Nemotron Nano villagers' if nano else 'rules only'})")
    t = 0.0
    while t < 20:
        for eid, act, say in mobs.step(t, (px, pz)):
            if act not in ("idle", "wander"):
                print(f"  t={t:4.1f}s mob #{eid} {act}")
        chip.tick(0.25)
        px += 0.25 * 0.5                                 # the player strolls east
        t += 0.25
    print("  decisions:", mobs.stats)

    print("== hire the contractor")
    worker = next(i for i, m in mobs.mobs.items() if m.kind == 1)
    mobs.busy.add(worker)
    contract = Contract(1, chip, bank, ask_player=lambda q: (print("  PLAYER sees:", q, "-> Y"), True)[1],
                        origin=(int(px) + 3, int(pz) + 3), worker=worker)
    if os.environ.get("NVIDIA_API_KEY"):
        from .llm import nemotron_chat
        chat = nemotron_chat()
    else:
        chat = scripted_builder()
    print("  BUILDER:", run("Build me a small hut right here.", contract, chat))
    for _ in range(40):
        chip.tick(0.25)
    mobs.busy.discard(worker)
    x, _, z = chip.entity(worker)
    print(f"  contract {contract.state}; contractor at ({x:.1f}, {z:.1f}), site corner "
          f"({contract.origin[0] - 1}, {contract.origin[2] - 1})")
    print("  wallets:", bank.wallets)


if __name__ == "__main__":
    main()
