"""Premade builds for the builder agent. Picking one is a single quick tool call; writing
30 box ops by hand took the model 15 s or more. Each blueprint fits itself to the zone
(centered, front = z 0), and its parts can be re-materialed ("a brick cottage").

  ops(name, zone, materials) -> (box ops for world.expand, error or None)
"""
from .world import PLACEABLE

CATALOG = {
    "cottage": "Cobble floor, plank walls with a door and windows, brick roof. Up to 7x7.",
    "tower": "Stone watchtower, 4x4, about 7 tall, door, windows and a cobble crown.",
    "stall": "Market stall: log posts, plank counter in front, sand awning.",
    "longhouse": "Long plank hall with a log frame and a brick roof. Needs a 10-wide zone.",
}
PARTS = ("floor", "walls", "roof", "trim")


def _box(op, part, at, size=(1, 1, 1)):
    return {"op": op, "part": part, "at": list(at), "size": list(size)}


def _house(x0, z0, w, d, h):
    """Floor, walls h high with a door and two windows, flat roof; a log post at each corner."""
    door = x0 + w // 2
    return [_box("fill", "floor", (x0, 0, z0), (w, 1, d)),
            _box("walls", "walls", (x0, 1, z0), (w, h, d)),
            *[_box("fill", "trim", (x, 1, z), (1, h, 1)) for x in (x0, x0 + w - 1) for z in (z0, z0 + d - 1)],
            _box("clear", "walls", (door, 1, z0), (1, 2, 1)),
            _box("clear", "walls", (x0, 2, z0 + d // 2)), _box("clear", "walls", (x0 + w - 1, 2, z0 + d // 2)),
            _box("fill", "roof", (x0, h + 1, z0), (w, 1, d))]


def _layout(name, sx, sy, sz):
    if name == "cottage":
        w, d = min(sx, 7), min(sz, 7)
        return _house((sx - w) // 2, (sz - d) // 2, w, d, 3), (w >= 5 and d >= 5 and sy >= 5)
    if name == "longhouse":
        w, d = min(sx, 12), min(sz, 7)
        return _house((sx - w) // 2, (sz - d) // 2, w, d, 4), (w >= 10 and d >= 5 and sy >= 6)
    if name == "tower":
        h = min(sy - 3, 7)              # walls, then roof (h + 1) and crown (h + 2)
        x0, z0 = (sx - 4) // 2, (sz - 4) // 2
        return [_box("fill", "floor", (x0, 0, z0), (4, 1, 4)),
                _box("walls", "walls", (x0, 1, z0), (4, h, 4)),
                _box("clear", "walls", (x0 + 1, 1, z0), (1, 2, 1)),
                *[_box("clear", "walls", (x0 + dx, h - 1, z0 + dz)) for dx, dz in ((0, 2), (3, 1), (2, 3))],
                _box("fill", "roof", (x0, h + 1, z0), (4, 1, 4)),
                *[_box("block", "trim", (x0 + dx, h + 2, z0 + dz)) for dx in (0, 3) for dz in (0, 3)],
                ], (sx >= 4 and sz >= 4 and sy >= 6)
    if name == "stall":
        w, d = min(sx, 5), min(sz, 4)
        x0, z0 = (sx - w) // 2, (sz - d) // 2
        return [*[_box("fill", "trim", (x, 0, z), (1, 3, 1)) for x in (x0, x0 + w - 1) for z in (z0, z0 + d - 1)],
                _box("fill", "walls", (x0 + 1, 0, z0), (w - 2, 1, 1)),
                _box("fill", "roof", (x0, 3, z0), (w, 1, d))], (w >= 3 and d >= 2 and sy >= 4)
    return None, False


DEFAULTS = {"floor": "cobble", "walls": "planks", "roof": "brick", "trim": "log"}
DEFAULTS_BY = {"tower": {"walls": "stone", "roof": "cobble", "trim": "cobble"},
               "stall": {"roof": "sand"}}


def ops(name, zone, materials=None):
    layout, fits = _layout(name, *zone)
    if layout is None:
        return None, f"no blueprint {name!r}; pick one of {sorted(CATALOG)}"
    if not fits:
        return None, f"{name} doesn't fit the {list(zone)} zone; pick a smaller blueprint"
    mats = {**DEFAULTS, **DEFAULTS_BY.get(name, {})}
    for part, block in (materials or {}).items():
        if block is None:
            continue
        if part not in PARTS:
            return None, f"unknown part {part!r}; parts are {list(PARTS)}"
        if block not in PLACEABLE:
            return None, f"block {block!r} can't be placed; use one of {sorted(PLACEABLE)}"
        mats[part] = block
    out = []
    for op in layout:
        op = dict(op)
        part = op.pop("part")
        if op["op"] != "clear":
            op["block"] = mats[part]
        out.append(op)
    return out, None
