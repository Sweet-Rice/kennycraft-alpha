# KennyCraft: Kenny's column (engine, game, look)

Plain C that builds for the laptop (`-DKC_HOST`) and for the chip (rv32i_zmmul) from the **same files**.

```
make            # generate assets + laptop build (build/kc_host)
make shots      # golden camera shots  -> out/shots/*.png + *.fb (raw 320x240 back buffer)
make play       # scripted play-through (physics, place/break, edit log survives leaving and returning)
make vectors    # VTRACE test vectors from the C reference -> out/vectors/{world.hex,rays.txt}
make bench      # DDA steps per frame
make chip       # rv32i_zmmul ELF (stand-in crt0/linker), fails on div/float/libcalls/ecall/csr
make chip8      # same with KC_LANES=8, plus lane lint (no per-lane branches in the kernel)
make chip-raster # tile rasterizer ELFs (1 and 8 lanes), same checks
```

Every chip target also runs `tools/stack_check.sh`: the worst-case stack depth of each call chain that runs on a lane (`main` on lane 0, `kc_render_frame` / `kc_raster_kernel` on lanes 1-7), from the ELF's prologues and call graph, against the 1 KB lane stack. Nothing catches an overflow on the chip (lane n runs into lane n+1's stack, lane 7 into the statics), so keep big locals out of anything the kernel calls.

## Files

| File | What |
|---|---|
| `src/kc_hal.h` | The only platform switch. Chip: memory map + MMIO from Interfaces v1.0. Host: `host/hal_host.c` |
| `src/fixed.[ch]` | Q16.16, `qrcp` (1/x: computed seed + Newton, branch-free, no table), `qsin`, `sel()` |
| `src/trace.[ch]` | `ray_setup` + `kc_trace` with the exact VTRACE contract. `vtrace_ref` = C reference for one ray |
| `src/render.[ch]` | Ray-tracing kernel. 8x8 tiles, 4x2 block per lane pass (D15). Pixel byte per spec |
| `src/mesh.[ch]` | Greedy mesher: per-chunk vertex + index buffers in a pool of 4 KB pages |
| `src/raster.[ch]` | Tile rasterizer (Josh's design): binning into per-tile command lists, 16x16 tile of 2-byte color + 2-byte depth, one framebuffer write per pixel |
| `src/kc_libc.c` | memcpy/memset for the freestanding chip build |
| `src/kc_lanes.h` | LANEID/LMASK/BALLOT/MASKGET/MASKSET/MASKALL: software for 1 lane, `.insn` for 8 |
| `src/terrain.[ch]` | Deterministic terrain + trees from absolute coordinates |
| `src/chunks.[ch]` | Issue #2 memory API: world_update/get/set, chunk_load/store tickets, slot_valid, window_origin, 8 KB generated bitmap |
| `src/arena.[ch]` | Bennett's 8 KB per-frame arena (bench/kc-bench), unchanged |
| `chip/bench/` | Bennett's kc.ld, crt0.S, gpu.h, arena (copied from bench/kc-bench) |
| `src/game.[ch]` | Keys, physics, picking, place/break, camera, crosshair, selection box + hotbar |
| `src/kc_main.c` | Frame loop; `main()` for the chip |
| `tools/gen_assets.py` | textures.hex, palette.hex, kc_tables.h, atlas.png |
| `host/` | Memory-map emulation, PNG writer, headless front-end |
| `chip/stub_*` | **Stand-ins only** so the chip build links. Bennett's kc.ld / crt0 replace them |

## For Tai

- `gen/textures.hex`: 12,288 lines, **one byte per line**, index `((type*3+face)<<8)|(v<<4)|u`, face 0 top / 1 side / 2 bottom. Values 0–14.
- `gen/palette.hex`: 256 lines, **3 hex digits** RGB444 (11:8 R, 7:4 G, 3:0 B).
- Palette convention (palette-only, no interface change): color index 15 is sky, and its 16 bytes are a top-to-bottom gradient rather than shade/fog variants.
- No DDR3 and no chunk engine. The CPU still uses WIN_ORIGIN and SLOT_VALID, so the window can scroll; CHUNK_CMD, CHUNK_DONE and DDR_STATUS are unused.

## For Bennett

- `out/vectors/rays.txt`: 2,000 rays, `f0..f7 max_steps -> res cell t` (hex). `world.hex` holds 131,072 window blocks, one per line, `(y*64+z)*64+x`, WIN_ORIGIN = 0, all slots valid.
- VTRACE rules the reference implements (put these in the VTRACE spec):
  - Ties pick x, then y, then z.
  - The start cell is never tested.
  - Every call takes at least 1 step.
  - Leaving the window or hitting the step cap gives hit = 0 and type = 0. Steps, cell and t still report the last step.
  - Face sign = step sign of the face axis.
- `.fb` files are the raw 320×240 back buffer (stride 320) for pixel-match against the simulator.
- `sel()` contains an empty `asm` on purpose. Without it clang turns selects into branches, which would trip ERR.DIVERGE on 8 lanes. `make chip8` checks this.

## Shared state Kenny added

`kc_rparams` at 0x1000_0030 (inside "reserved shared state"): width, height, max_steps, sky_k, fog_d[3]. Kernel-only, set by the game.

## Numbers

- Software DDA loop: 52 RV32I instructions per step.
- 160×120 with a 16-step cap is about 207k steps per frame, roughly 11M instructions. At about 4 CPI on a 50 MHz multi-cycle core that's ~1 fps, which matches the Stage 0 plan.
- The default cap is 64 (`-DKC_MAX_STEPS`). At that cap a frame is 302k steps.

## Memory budget (data memory, 32 KB)

| Item | Bytes |
|---|---|
| Camera block + render params | 64 |
| 1/x and sine (computed, no tables) | 0 |
| Edit log, 1,024 edits (.bss) | 5,120 |
| Everything else (.data + .bss) | ~150 |
| Lane stacks, 8 x 1 KB | 8,192 |
| **Total** | **~13.5 KB of 32 KB** |

No malloc anywhere: every structure is a fixed-size static array, sized at compile time.

## Tile rasterizer (build with -DKC_RASTER=1)

Per frame:
1. **Mesh** (only when chunks change). Greedy meshing turns each chunk into quads. A quad uses 4 vertices (uint16, chunk-local x5 y6 z5), 6 indices (uint16) and 1 material byte. Quads go into a pool of 4 KB pages, 192 quads per page, chained per chunk. Moving the window doesn't remesh anything, because vertices are chunk-local.
2. **Bin** (lane 0):
   - Cull back faces from the face direction alone, without transforming anything.
   - Transform and clip each remaining quad against the near, left, right, bottom and top planes.
   - Append the quad to the command list of every 16×16 tile it touches.
3. **Tiles** (all lanes): for each tile:
   - Clear a 1 KB tile buffer (2-byte color + 2-byte linear depth, no stencil).
   - Rasterize the tile's quads with edge functions. Textures are perspective-correct, and depth is tested inside the tile.
   - Write the tile to the framebuffer once.

Rules that keep it working on 8 lanes:
- Per-pixel work is branch-free. Writes go through LMASK, so only the winning lanes store.
- An 8-pixel group that no lane covers is skipped with BALLOT, which is a uniform branch.

| Golden shot (160×120) | Ray tracer (64 steps) | Rasterizer |
|---|---|---|
| spawn | 19.5 M instr | 12.3 M instr |
| horizon | 31.5 M | 11.7 M |
| looking down | 7.1 M | 7.7 M |
| from higher up | 35.1 M | 12.4 M |

Estimates come from rv32 instruction counts × the host's work counters (`make compare`). Geometry matches the ray tracer on 99% of pixels. Texel rounding differs on about 20%, which is invisible.

Each edge is grown by 2 subpixels (1/8 px) to close the hairline T-junction cracks that greedy meshing creates. Without that, 93 sky pixels show through across the golden shots; with it, 0 do.

### Memory: 192 KB for rendering and real-time updates (checked at compile time)

`src/kc_budget.h` sums every buffer and fails the build over 192 KB. Chunk storage through the memory API (up to 256 MB) is outside the budget.

| Buffer | Size |
|---|---|
| World window, 1 copy, 4 bits per block | 64.0 KB |
| Textures (1 byte per texel) + palette | 12.5 KB |
| Mesh pool, 52 × 1 KB pages (worst of 60 sampled locations: 42) | 52.0 KB |
| Command lists: 1,024 visible quads + 4,096 tile entries (worst seen: 790 / 3,056) | 17.2 KB |
| Tile buffer 16×16 × (2 B color + 2 B depth) | 1.0 KB |
| Mesher scratch | 1.8 KB |
| Chunk tables (stored-chunk set, fallback edit log, slots) | 3.3 KB |
| **Total** | **151.8 KB of 192** |
| + two 160×120 framebuffers, if they end up inside the budget | 189.3 KB |

How the mesh got small enough:
- **Shared index buffer.** Every quad is two triangles in the same order, so there's one 6-entry index buffer drawn with base vertex = quad × 4. That's 9 bytes per quad instead of 21.
- **1 KB pages.** A page holds 113 quads. A chunk wastes at most one partly filled page, so 1 KB pages waste far less than 4 KB ones.

Chunk storage:
- An edited chunk is written through the memory API (CHUNK_CMD) when it leaves the window and read back when it returns.
- Untouched chunks are regenerated from the seed, so storage never needs to be initialized.
- If DDR_STATUS bit 0 is 0, a 256-entry edit log is used instead. Run `KC_NO_STORAGE=1 make play` to test that path.

The ray tracer's VTRACE plan (four world copies, 256 KB) does not fit in 192 KB. With one copy the ray tracer fits, and VTRACE would serve 2 lanes per cycle instead of 8.

## Issue #2 conformance (memory API)

- `chunks.h` uses exactly the names and order from issue #2. The frame loop in `kc_main.c` follows issue #2 steps 1–9.
- The camera block origin is in absolute world coordinates. Kernels read the committed corner from `kc_rparams.corner_x/z`.
- Chip builds link with Bennett's `kc.ld` + `crt0.S` (`chip/bench/`) and `-DKC_CHIP -msmall-data-limit=0`.
- `KC_NO_STORAGE=1 ./build/kc_host play out/play` runs the no-DDR3 fallback.
- `ISSUE2_REPLY.md` is a ready-to-post reply with the two kc-bench bugs and the open questions for Tai.
