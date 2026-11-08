# KennyCraft: Kenny's column (engine, game, look)

Plain C that builds for the laptop (`-DKC_HOST`) and for the chip (rv32i_zmmul) from the **same files**.

```
make            # generate assets (gen/) + laptop build (build/kc_host)
make shots      # golden camera shots  -> out/shots/*.png + *.fb (raw 320x240 back buffer)
make play       # scripted play-through with checks (physics, place/break, chunk round trip, chunk tags, reset) -> out/play
make contract   # vtrace_ref against the VTRACE rules (ties, saturation, cap 0)
make models     # static entity checks + renderer and close-up shots -> out/models
make cr6        # CR6 UART link checks -> out/cr6/cr6_hud.png (+ .fb)
make vectors    # VTRACE test vectors from the C reference -> out/vectors/{world.hex,rays.txt}
make bench      # laptop ms/frame and DDA steps per frame at 160x120 and 320x240
make chip       # rv32i_zmmul ELF build/kc_chip.elf (chip/bench/kc.ld + crt0.S), fails on div/float/libcalls/ecall/csr
make chip8      # same with KC_LANES=8 (build/kc_chip8.elf), plus lane lint (no per-lane branches in the kernel)
make atlas-edit # copy gen/textures_atlas.png to assets/textures.png for editing
make clean      # rm -rf build out gen
```

Run these commands from `game/`. Use Linux (including WSL) for the laptop
frontend: `host/main_host.c` uses `clock_nanosleep` with `TIMER_ABSTIME`,
which is unavailable on native macOS. Asset generation needs Python 3; editable
or custom texture atlases also need Pillow. Chip builds need RISC-V-capable clang
and a compatible linker (lld in the command below); checks use `llvm-objdump`
and `llvm-nm` on `PATH`. `llvm-size` is optional, for section-size diagnostics.
macOS can cross-build the chip images with the full LLVM toolchain using
`make chip chip8 CHIP_CC="clang -fuse-ld=lld"`.

`CC` (default `cc`) builds `kc_host`; `CHIP_CC` (default `clang`) builds the chip ELFs. The chip build compiles the lane-0 game files (`arena.c terrain.c chunks.c game.c kc_main.c cr6.c`) with `-Os` and the kernel files with `-O2`; IMEM is 32 KB. At main 12faff7, `.text` is 32,180 bytes in `kc_chip.elf` (Stage 0) and 30,944 in `kc_chip8_vtrace.elf` (Stage 2). The Stage 0/1 golden builds (`scripts/golden.py`) add the shot harness, so they also build `entity.c` with `-Os`; the frames are the same. `build/`, `out/`, `gen/` and `assets/` are gitignored.

Both chip targets run `tools/chip_check.sh` (no `div`/`rem`, float, libgcc calls, `ecall` or CSR instructions; prints section sizes) and `tools/stack_check.sh`; `chip8` also runs `tools/lane_lint.sh`. That script checks the named symbols `qrcp`, `ray_setup`, `kc_shade_pixel`, `kc_shade_pixel_ent`, `ent_box_hit` and `vtrace_ref` only when present: zero branches for the first five, exactly two uniform branches for `vtrace_ref`. It is not an exhaustive audit of every current kernel function.

`tools/stack_check.sh` computes the worst-case stack depth of each call chain that runs on a lane (`main` on lane 0, `kc_render_frame` on lanes 1-7) from the ELF's prologues (`addi sp,sp,-N`) and call graph, against the 1 KB lane stack (limit: second argument or `STACK_LIMIT`, default 1024). It also fails on recursion, on calls it cannot resolve (indirect, or not to a function start) and on unsized stack adjustments. Nothing catches an overflow on the chip (lane n runs into lane n+1's stack, lane 7 into the statics), so keep big locals out of anything the kernel calls.

## Controls

The game reads one byte per key event from the UART: the key code, with bit 7 set for key down and clear for key up (mouse look is bytes 0x14-0x17). `scripts/kc.py`
and `scripts/kc_live.py` send them from a laptop window; `kc_host link` reads them on stdin.

| Key | Action |
|---|---|
| W A S D | Walk |
| Space | Jump |
| Arrows | Look (the laptop windows also turn with the mouse) |
| J / K | Break / place the block in the crosshair |
| 1–9 | Hotbar: grass, dirt, stone, cobble, log, obsidian, planks, sand, brick |
| E | Talk to the villager in front of you (CR6 INTERACT) |
| Y / N | Accept / decline the quote on the HUD (CR6 CONFIRM) |
| P | Travel to the Nether and back |
| F | Frames-per-second overlay on/off |

## Build options


Makefile variables (any target): `build/defs` tracks changes to `KC_GEN_BITMAP`,
`KC_TAG_PERSIST`, `KC_QRCP`, `KC_FIXED_DT` and `KC_DEMO`.

| Option | Effect |
|---|---|
| `KC_GEN_BITMAP=1` | Issue #2's 8 KB "generated" bitmap instead of chunk tags |
| `KC_TAG_PERSIST=1` | Chunk tags without the boot nonce: stored chunks survive a reset |
| `KC_QRCP=1` | 8-lane chip builds use the QRCP instruction for `qrcp()` (D22, Stage 2 core); other builds keep `fixed.c` |
| `KC_FIXED_DT=1` | Fixed per-frame dt (`KC_DT_FIXED`, Q16 0.08 s) and frame-synchronous chunk loads, so replays retire the same instructions on any core speed; use with `KC_TAG_PERSIST=1` |
| `KC_DEMO=1` | The demo village (`src/terrain.c`, numbers in `src/blocks.h`): flat grass, banker / trader / contractor stalls around a plaza and well, a chicken pen, houses, a 14x14 build plot and a ruined obsidian portal missing one block. You spawn facing it. Talking to any villager makes the plot the CR6 contract zone. Run kc-host with `KC_DEMO=1` too |
| `ARENA_SIZE=n` | Per-frame arena size for laptop and chip (default 8 KB, `src/arena.h`); `make clean` after changing |

Source defines without a Makefile variable (pass through `CC`/`CHIP_CC`):

| Define | Default | Effect |
|---|---|---|
| `KC_LANES` | 1 | 1: software lane ops; 8: `.insn` lane ops (set per chip variant) |
| `KC_VTRACE` | 0 | `kc_trace` and the kernel use the VTRACE unit (custom-1) |
| `KC_MAX_STEPS` | 64 | DDA step cap set at boot |
| `KC_WIDTH` | 160 | Boot resolution (160 or 320) |
| `KC_NO_DDR` | 0 | Compile in the no-DDR3 fallback (every chunk generated) |
| `KC_BUDGET_COUNT_FB` | 0 | Count the two 160x120 framebuffers in the 192 KB budget |
| `KC_RCP_TABLE` | 0 | `qrcp` seed from a 512 B table instead of the computed seed |

Changes to compiler commands or these source defines are not tracked by
`build/defs`; run `make clean` before rebuilding with different flags (or a
different `ARENA_SIZE`). Cleaning also removes `out/` and `gen/`; assets are
regenerated by the next build.

Environment variables for `kc_host` (`host/hal_host.c`): `KC_DDR_FILL=random|zero|bedrock|ones` (power-on DDR3 contents, default random), `KC_NO_STORAGE` (DDR_STATUS never calibrates).

## Files

| File | What |
|---|---|
| `Makefile` | Asset generation, laptop build and checks, chip ELFs |
| `src/kc_hal.h` | The only platform switch. Chip: memory map + MMIO from Interfaces v1.0, camera block and `kc_rparams` layout. Host: `host/hal_host.c` |
| `src/blocks.h` | Block types (air, grass, dirt, stone, cobble, log, leaves, planks, sand, brick, bedrock, netherrack, lava, glowstone, obsidian, portal: all 16 4-bit codes), world size, build height, seed, the Nether boundary and the demo village layout |
| `src/fixed.[ch]` | Q16.16, `qrcp` (1/x: computed seed + Newton, branch-free, no table by default), `qsin`, `sel()` |
| `src/trace.[ch]` | `ray_setup` + `kc_trace` with the exact VTRACE contract. `vtrace_ref` = C reference for one ray; `KC_VTRACE=1` maps `kc_trace` onto the ray unit |
| `src/render.[ch]` | Ray-tracing kernel. 4x2 block per lane pass (D15), blocks in rows; frame state and the ray in registers, one LBU + one SB per pixel. Each VTRACE walk overlaps the next block's ray setup (asynchronous VTRACE), and blocks under the hotbar are not traced. Pixel byte per spec |
| `src/entity.[ch]` | Villager (trader, contractor), chicken and zombie box models (flat colors) that walk to a target; drawn by the ray tracer |
| `src/kc_libc.c` | memcpy/memset for the freestanding chip build |
| `src/kc_lanes.h` | LANEID/LMASK/BALLOT/MASKGET/MASKSET/MASKALL: software for 1 lane, `.insn` for 8; `qrcp_hw` (QRCP `.insn`) on 8 lanes only |
| `src/terrain.[ch]` | Deterministic terrain + trees from absolute coordinates, Nether terrain east of x = 3072 and the `KC_DEMO=1` village; generates one chunk into its window slot |
| `src/chunks.[ch]` | Issue #2 memory API: world_update/get/set, chunk_load/store tickets, slot_valid, window_origin; tags inside the DDR3 chunks replace the 8 KB generated bitmap (`KC_GEN_BITMAP=1` brings it back) |
| `src/arena.[ch]` | Per-frame 8 KB arena (`sw/arena.[ch]` with an overridable `ARENA_SIZE`) |
| `src/game.[ch]` | Keys, physics, picking, place/break, camera, crosshair, selection box + hotbar |
| `src/hud.[ch]` | HUD drawing shared by the CR6 bank HUD and the performance overlay: 3x5 font, rects, divide-free numbers |
| `src/cr6.[ch]` | CR6 UART command link with the laptop (lane 0): framing, commands, STATUS/EVENT replies, HUD |
| `src/kc_main.[ch]` | Init, frame loop, `kc_draw_world`, resolution and step cap setters; `main()` for the chip |
| `src/kc_budget.h` | Compile-time check of the 192 KB rendering budget |
| `chip/bench/` | `kc.ld` and `crt0.S` used by the chip build, derived from `sw/`; game startup now restores `.data` from a separate DMEM load copy on every reset before clearing `.bss`. `arena.[ch]` and `gpu.h` are copies not compiled here; `arena.[ch]` still match `sw/` |
| `host/hal_host.[ch]` | Memory-map emulation: world window with WIN_ORIGIN and SLOT_VALID, DDR3 chunk engine, double framebuffer, UART RX/TX, CYCLES |
| `host/png.c` | PNG writer |
| `host/main_host.c` | Headless front-end (`kc_host` commands below) |
| `tools/gen_assets.py` | `gen/`: palette.hex, textures.hex, kc_tables.h (face color table, face/shade pixel table, qrcp and sine constants), kc_assets.h (textures + palette for the laptop), atlas.png and the editable textures_atlas.png. `assets/textures.png`, if present, overrides the procedural textures |
| `tools/chip_check.sh` | Fails a chip ELF that uses div/rem, float, libgcc calls, ecall or CSRs |
| `tools/lane_lint.sh` | Checks branch counts for selected ELF symbols when present; not every kernel function |
| `tools/stack_check.sh` | Worst-case stack depth per lane call chain |

## Laptop front-end

`build/kc_host <command> [dir]`:

| Command | What |
|---|---|
| `shots <dir>` | Golden camera shots g0..g5 (PNG + raw `.fb`), world reads per shot |
| `play <dir>` | Scripted play-through with checks: physics, editing, chunk round trip, walk, reset, tag visibility |
| `vectors <dir>` | `world.hex` + `rays.txt` from the C reference |
| `contract` | `vtrace_ref` against the VTRACE rules |
| `models <dir>` | Entity checks and review shots |
| `cr6 <dir>` | CR6 link checks (framing, ops, chip-side rules, HUD); saves `cr6_hud` |
| `bench` | Laptop render time and DDA steps per frame |
| `sweep` | Arena high water over many locations, frames and edits, plus a window digest |
| `gencost` | Terrain generation cost per chunk, plus a chunk digest |
| `link <dir>` | stdin = UART RX, stdout = UART TX at ~20 fps, `<dir>/live.png` every 4th frame |

## The Nether

The Nether is the east strip of the same world, from x = 3072 (`NETHER_X0` in `src/blocks.h`), so
chunk storage, tags and the window need nothing new. `src/terrain.c` fills it with a bedrock
floor, roof and wall at x = 3072, netherrack floor (y 1..10) and ceiling (y 24..30), lava lakes
up to y 5 and glowstone hanging from the ceiling.

- **Portals:** obsidian is hotbar slot 6. A frame of obsidian around a 2 wide x 3 tall hole
  (corners optional), standing along x or z, lights when its last block is placed: the hole
  fills with portal blocks. Walk into one to travel; it fires again only after you step out.
  The demo village (`KC_DEMO=1`) has a ruined portal missing one block in front of spawn.
- **P** travels without a portal.
- **Travel:** from the overworld you arrive at the same z, 512 blocks past the wall, standing in
  a new lit portal; going back returns you to where you left. The window reloads around the
  new spot (one chunk generated per frame), physics waits for it, and you land in the first
  column with standing room that is not over lava.
- **Colors:** the Nether has a red sky and fog. Only the palette changes: the sky and fogged
  entries are rewritten on the way in and out (`set_world_colors` in `src/game.c`, colors from
  `tools/gen_assets.py`).

## Entity models


The game spawns no entities on its own. Lane-0 code (including CR6 SPAWN) calls `entity_add(kind, x, y, z, facing)`
with an absolute Q16 feet center; facing 0/1/2/3 means +z/+x/-z/-x.
The table holds eight entities; invalid kinds/facings or a full table return -1.
`entity_clear()` empties it; `entity_count()` reports its size.

`entity_move(id, x, z)` sets a walk target; `entity_tick(dt)` (lane 0, once per
frame) advances at the kind's speed (chicken 1.0, zombie 1.2, villagers 1.5
blocks/s per axis). In loaded columns it follows the floor under the entity,
not roofs or awnings overhead: it steps up one block when clear, falls onto
support below, and stops at taller obstacles. Air, leaves, logs and portal
blocks do not count as solid support or obstacles. Movement is straight-line,
without pathfinding; the laptop chooses the route.

`kc_draw_world()` calls `entity_prepare()` after `write_camera()`. It builds
eye-relative model-part boxes, per-box screen bounds, and per-block-row spans,
column bitmasks and box bins. `kc_render_frame` uses the plain world loop outside
the entity rows; inside them, only eligible 4x2 blocks enter entity compositing,
which scans the row's boxes and skips boxes hidden by nearer world hits.

Model part counts are derived from their arrays, so rendering cannot read past a
model into neighboring geometry. Both villager variants use the same five boxes.

Colors reuse the existing palette: villagers have light-dirt skin and black
eyes; trader robes are brick, contractor robes light wood. The chicken is white with
a brick comb and wattle, a planks beak and light-wood legs. The zombie has light-grass skin, a dark-stone shirt
and near-black pants/eyes.

`make models` checks visibility, palette colors, terrain occlusion, behind-camera
rejection, table limits and walking (target, facing, ground under a canopy).
It saves `base`, `m0_models`, `m1_trader`, `m1_contractor`, `m1_chicken`, `m1_zombie`,
`buried` and `behind` as PNG and raw `.fb` files in `out/models/`.

## CR6 link

`src/cr6.c` (lane 0) speaks the CR6 UART protocol: frames `A5 | len | seq | op | payload | crc8` (CRC-8 poly 0x07). Nothing changes until the laptop sends HELLO, so key replays and golden frames are unaffected. Ops: HELLO, BYE, PLACE, BREAK, FILL, SPAWN, MOVE, Q_PLAYER, Q_BLOCKS, Q_ENTITY, SET_BALANCE, SET_QUOTE, SET_CONTRACT; the chip answers with HELLO_ACK, STATUS (one per drain while linked), R_PLAYER, R_BLOCKS, R_ENTITY and EVENT (INTERACT on E, CONFIRM on Y/N). Edits are only accepted inside the 16^3 zone the player set by pressing E next to an entity, at y 1..28, block types 1..9 (or air), in loaded chunks, never into the player, one edit command per frame of at most 256 cells, paid from a cell bucket (up to 512, refilled 16 per frame). PLACE only goes into air, a non-air FILL only fills air cells, and bedrock is never changed. SPAWN and MOVE must be within 32 blocks of the player. `cr6_draw_hud` draws balance, quote and contract bars when linked.

CR6 `MOVE` walks by default. Set bit 7 of its entity-ID byte to teleport
instead; the remaining seven bits are the ID, and x/z use 1/16-block units.
Teleporting onto a loaded column places the entity above its highest solid
block (including a roof); an unloaded column preserves its previous height.
This differs from ordinary floor-following movement under an awning.

## Assets and pixel format

- **Vertex colors, no textures.** The ray tracer and the hotbar color each block face from `kc_face_color` (one 4-bit color per block type and face, generated into `gen/kc_tables.h` from the block art). The game never reads texture memory. `textures.hex` is still generated for the RTL's `$readmemh`.
- Pixel byte: 7:4 color index, 3:2 face shade, 1:0 fog level.
- `gen/textures.hex`: 12,288 lines, **one byte per line**, index `((type*3+face)<<8)|(v<<4)|u`, face 0 top / 1 side / 2 bottom. Values 0–14.
- `gen/palette.hex`: 256 lines, **3 hex digits** RGB444 (11:8 R, 7:4 G, 3:0 B).
- Palette convention (palette-only, no interface change): color index 15 is sky, and its 16 bytes are a top-to-bottom gradient rather than shade/fog variants.

## VTRACE reference and vectors

- `out/vectors/rays.txt`: a header line and 2,000 rays, `f0..f7 max_steps -> res cell t` (hex). `world.hex` holds 131,072 window blocks, one per line, `(y*64+z)*64+x`, WIN_ORIGIN = 0.
- VTRACE rules the reference implements (`src/trace.h`, `src/trace.c`; `make contract` checks them):
  - Step x if tMax.x < tMax.y and tMax.x < tMax.z, else y if tMax.y < tMax.z, else z (strict compares: ties go to z, then y).
  - tMax additions saturate at 0x7FFF_FFFF; a zero direction component has tDelta 0x7FFF_FFFF.
  - The start cell is never tested.
  - max_steps = 0 returns at once and leaves the result unchanged.
  - Leaving the window or hitting the step cap gives hit = 0 and type = 0. Steps, axis, sign, cell and t still report the last step.
  - Face sign = step sign of the face axis.
- `.fb` files are the raw 320×240 back buffer (stride 320) for pixel-match against the simulator.
- `sel()` contains an empty `asm` to keep clang from turning selects into per-lane branches that would trip ERR.DIVERGE on 8 lanes. `make chip8` runs the selected-symbol lane lint described above; it is not a proof that every kernel branch is uniform.

## Shared state Kenny added

`kc_rparams` at 0x1000_0030 (inside "reserved shared state", after the 48-byte camera block at 0x1000_0000): width, height, max_steps, sky_k, fog_d[3], right[3], up[3], focal, corner_x, corner_z, and the hotbar rectangle `hud_x0/x1/y0/y1` (80 bytes, ends at 0x1000_0080). Kernel-only, set by the game (`kc_set_resolution`, `kc_set_max_steps`, `write_camera`).

## Numbers

- Performance overlay: press **F** in game (`kc.py` and `kc_live.py` send it) for frames per second, top right, from the last frame's CYCLES (20 ns ticks). It costs nothing while off. It is built for the Stage 2 chip and the laptop only: the Stage 0/1 chip builds have no code memory to spare, and `KC_FIXED_DT` builds keep CYCLES off the screen.
- Software DDA loop (`vtrace_ref`): 53 RV32I instructions per step on `kc_chip8.elf`, 49 on `kc_chip.elf`, counted in `llvm-objdump -d`.
- The default cap is 64 (`-DKC_MAX_STEPS`). At that cap the 160×120 spawn shot (`g0_spawn`) is 297,672 steps.
- Stage 2 frame time, measured with `make tb-top-t_top_frame TOP_ELF=kc_chip8_vtrace TOP_SWAPS=6` (add `PIPELINED=1` for the pipelined core): the core cycles between FB_SWAPs at the spawn pose, no entities. 160×120 measured at main 12faff7; 320×240 at 7315b19. The multi-cycle core (`top_s2`) runs at 50 MHz, the pipelined core at 50 MHz (`top_s2p`) or 100 MHz (`top_s2p100`).

| Frame | Multi-cycle core, 50 MHz | Pipelined core, 50 MHz | Pipelined core, 100 MHz |
|---|---|---|---|
| 160×120 | 596,381 cycles, 83.8 fps | 246,677 cycles, 202.7 fps | 405.4 fps |
| 320×240 | 2,296,081 cycles, 21.8 fps | 941,479 cycles, 53.1 fps | 106.2 fps |

- On the board (`top_s2p100`, 160×120) the 60 Hz display is the limit: 59.4 new frames/s while turning.
- How the kernel uses the hardware: the hotbar's 9 opaque slots are drawn over every frame, so `write_camera` passes their rectangle in `kc_rparams` and covered block rows run the block loop over two ranges (no per-block test). With asynchronous VTRACE (`VTRACE x0` starts the walk, `VGET 3` and `VGET 1` wait for it), the kernel builds the next block's ray in registers while the walk runs, reads this walk's result, sets and starts the next ray, and only then shades and stores this block. A row's first block is started before the loop and its last block is shaded after it, which keeps the fog thresholds and the face table in registers.
- Entity overlays run through `ent_composite` / `composite`, with `box_hit` inlined, on top of the world-ray path.

## Memory budget (data memory, 32 KB)

Measured on `build/kc_chip.elf` with LLVM 18 clang/lld at main `12faff7`
(default build options), using `llvm-nm -S` and `llvm-readelf -S -l`; layout from
`chip/bench/kc.ld` and `crt0.S`. Compiler versions and build options change the
footprint; these are not measurements of the Stage 2 build.

| Item | Bytes |
|---|---|
| Reserved shared state 0x1000_0000–0x1000_00FF (camera block 48 + render params 80) | 256 |
| 1/x and sine (computed, no tables) | 0 |
| Per-frame arena (.bss) | 8,192 |
| Entity boxes, records, row bins, spans, bitmasks and state (.bss) | 14,288 |
| Chunk slot tables, dirty mask, tag key (.bss) | 118 |
| Everything else (.rodata + .data + .bss) | 1,659 |
| Section padding and warm-reset `.data` load copy | 23 |
| Lane stacks, 8 x 1 KB (0x1000_6000–0x1000_7FFF) | 8,192 |
| **Total** | **32,728 of 32,768 bytes (40 bytes spare)** |

The `.data` load copy lives after `.bss` and is restored on every chip reset;
the linker asserts that it ends before the lane stacks at 0x1000_6000.
`KC_GEN_BITMAP=1` adds an 8,192-byte bitmap, so it does not fit this measured
configuration with the default 8 KB arena. Reduce other allocations before
enabling it.

No malloc anywhere: every structure is a fixed-size static array, sized at compile time.

On the pipelined core, 0x1000_6000–0x1000_7FFF is the dmem window (8 banks of distributed RAM, so a lane-stack spill or reload takes one cycle). `.rodata` and `.data` must end below 0x1000_6000: `fpga/patch_bit.sh` refuses dmem images that change the window, which then needs a Vivado rebuild.

## Rendering

Everything is ray traced: one ray per pixel through the voxel grid (`render.c`, `trace.c`). The Stage 2 build `kc_chip8_vtrace` (built by `tb/top/tb.mk` through this Makefile's `CHIP_ELF` macro with `-DKC_LANES=8 -DKC_VTRACE=1 -DKC_QRCP=1`) walks on the VTRACE unit; the other builds run `vtrace_ref`. Each block face is one flat color (vertex colors), with face shading and fog.

### Look

All of it lives in the palette and in the fog thresholds, so it costs no cycles per pixel:

- **Cool shadows:** each face shade (top, x sides, z sides, bottom) scales red and green more
  than blue (`SHADE` in `tools/gen_assets.py`), so shaded faces read as sky light instead of
  flat grey; tops stay true color.
- **Fog to the horizon:** three fog levels mix 15%, 45% and 100% of the horizon color
  (`FOG_MIX`), starting at 45%, 65% and 85% of the view distance (`fog_d` in `src/kc_main.c`).
  The far edge of the world fades into the sky instead of ending in a wall.
- **Dithered fog bands:** blocks are 4x2 at even coordinates, so each lane's pixel has a fixed
  checkerboard parity. Odd lanes reach each fog level half a band sooner (`dth` in
  `src/render.c`), which turns each hard fog ring into a wide checkerboard strip.

### Memory: 192 KB for rendering
 and real-time updates (checked at compile time)

`src/kc_budget.h` checks its `BUDGET_TOTAL` formula against 192 KiB, including a
second assertion with two 160x120 framebuffers added. This is not complete
buffer accounting: its entity formula counts 5,004 bytes, while the linked
entity state above occupies 14,288 bytes. In particular, it omits the 8,640-byte
`ent_bin` and 120-byte `ent_bin_n` row-bin arrays. Use the ELF for actual DMEM
use. Chunk storage through the memory API (up to 256 MB) is outside this formula.

| Component counted by `BUDGET_TOTAL` | Size (KiB) |
|---|---|
| World window, 1 copy, 4 bits per block | 64.0 |
| Textures (1 byte per texel) + palette (RGB444, 12 bits per entry) | 12.4 |
| Chunk slot tables + tag key | 0.1 |
| Entity formula (not the full linked entity state) | 4.9 |
| **Total** | **81.4 of 192** |
| + two 160x120 framebuffers (`KC_BUDGET_COUNT_FB=1`) | 118.9 |

Chunk storage:
- World: 256 × 256 chunks of 16 × 32 × 16; BRAM holds a 4 × 4-chunk window, chunk (cx, cz) in slot (cx & 3, cz & 3). `world_update` keeps the player 24-40 blocks from every window edge.
- Every generated or edited chunk is written through the memory API (CHUNK_CMD) when it leaves the window. Every incoming chunk is loaded.
- DDR3 is random at power-on, so a stored chunk carries a 128-bit tag in 32 of its y = 0 bedrock cells (z = 0..1, x = 0..15). The tag is a hash of (seed, chunk id, format version, boot nonce). This replaces issue #2's 8 KB "generated" bitmap. `KC_GEN_BITMAP=1` brings the bitmap back.
- Store: clear the slot's SLOT_VALID bit, write the tag cells, then chunk_store. Load: when the ticket is done, set SLOT_VALID only for the 32 tag reads (reads of an invalid slot return air), clear it, and on a match write bedrock back. Only then is the slot valid and S_READY. No match: the chunk is generated. Never-seen chunks cost one extra LOAD.
- The boot nonce hashes a boot counter kept in DDR3 with CYCLES after the first loads, so a reset behaves like the bitmap even when boot timing repeats exactly: chunks from the previous boot don't match and are regenerated. The counter lives in chunk (0, 0)'s y = 0 row z = 2 (16 nibbles: count and a check hash). Every boot loads that chunk, bumps the count and stores it back before the window loads; storing chunk (0, 0) later rewrites the count, and loading it puts bedrock back, like the tag cells. Cost: one extra LOAD and STORE at boot, about 550 B of code. `KC_TAG_PERSIST=1` skips the counter and fixes the nonce at 0, so stored chunks survive a reset. The nonce is printed over UART at boot (`kc: chunk tag nonce ...`); check on the board that it changes across resets.
- `make play` uses random power-on DDR3. `KC_DDR_FILL=zero|bedrock|ones make play` tests other fills.
- If DDR_STATUS bit 0 stays 0 (2 s timeout; `KC_FIXED_DT=1` waits without one), every chunk is regenerated and edits are lost on leaving. Run `KC_NO_STORAGE=1 make play` to test that path.

## Issue #2 conformance (memory API)

- `chunks.h` uses the names and order from issue #2; extras are grouped under "Kenny extras". The frame loop in `kc_main.c` follows issue #2 steps 1–9, with the FB_SWAP wait moved into `kc_draw_world` just before the kernel (D21).
- The camera block origin is in absolute world coordinates. Kernels read the committed corner from `kc_rparams.corner_x/z`.
- Chip builds link with `chip/bench/kc.ld` + `crt0.S` and `-DKC_CHIP -msmall-data-limit=0` (`kc.ld` only collects `.bss*`, no `.sdata`/`.sbss`), `--gc-sections`, entry `_start`.
- `KC_NO_STORAGE=1 ./build/kc_host play out/play` runs the no-DDR3 fallback.
