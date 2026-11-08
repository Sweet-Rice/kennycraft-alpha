# Doom on KennyCraft

Stock [doomgeneric](https://github.com/ozkl/doomgeneric) (submodule `doom/doomgeneric`, unmodified) with the
shareware `doom1.wad` v1.9, on the Doom configuration of the chip (`HAS_DDR_MEM=1`: code and data in DDR3 behind
the I-cache and D-cache). This directory holds the platform layer and libc glue only.

## Build and run

    make doom                               # software: out/doom/
    make doom DOOM_ARGS="-warp 1 1"         # extra Doom arguments baked into the image
    make doom-vl-build                      # Verilator model (RTL side)
    make doom-vl RUN_ARGS="--headless --frames 3 --png-dir out/doom/png"
    scripts/doom_load.py [--port /dev/ttyUSB1]   # board: send the DDR3 image to the bootloader

Build options (`make doom VAR=value`; each one rebuilds the platform objects and relinks):

| Option | Default | Effect |
| --- | --- | --- |
| `KC_PROF=1` | 0 | per-frame cycle profile on the UART, one `kcprof` line per frame (below) |
| `KC_VCLOCK=1` | 0 | virtual clock: time moves only on `DG_SleepMs` and by one tic (1000/35 ms) per frame, so each frame depends on the frame number alone; for frame-for-frame comparisons of builds that run at different speeds |

`KC_PROF=1` reads CYCLES (core cycles in the simulation, where CORE_MHZ is 50) around the main per-frame calls and
prints, from `DG_DrawFrame`, `kcprof N total T` and `name calls/cycles` for each counter, then clears them. `total` is
the time since the previous report (the report's own UART time is left out). Counters nest: `rpv`
(R_RenderPlayerView) holds `bsp` (R_RenderBSPNode, walls), `planes` (R_DrawPlanes) and `masked` (R_DrawMasked); `col`
(calls through colfunc/basecolfunc: R_DrawColumn, walls, sky and sprites) runs inside `bsp` and `masked`, `span`
(spanfunc: R_DrawSpan) inside `planes`; `tics` (TryRunTics) holds `gtick` (G_Ticker); `st` (ST_Drawer), `hu`
(HU_Drawer) and `v` (V_DrawPatch, V_DrawPatchDirect, V_CopyRect, V_DrawBlock, mostly inside `st`); `dgdraw` is
DG_DrawFrame (wait for the swap, palette, copy to the framebuffer). The cross-object calls are linker wraps; colfunc
and spanfunc are pointed at timing shims after every R_ExecuteSetViewSize.

`make doom` outputs, in `out/doom/`:

| File | What |
| --- | --- |
| kc_imem.hex | bootloader, imem BRAM (8192 words) |
| kc_dmem.hex | bootloader strings at dmem 0x1000_0000; 0x6000..0x7FFF stays zero |
| header.bin, text.bin, data.bin, doom1.wad | DDR3 image |
| ddr.manifest | `<hex DDR3 addr> <path>` per line, for `+ddr_manifest=` and doom_load.py |

The WAD is fetched by `make doom` and checked against MD5 `f0cefca49926d00903cf57551d901abe`; it is never committed.
`make doom` also runs `doom/check_elf.py` on both ELFs: no instruction the core rejects (compressed, ECALL/EBREAK/CSR,
DIV/REM, A/F/D) and every section inside its region.

## Memory

| DDR3 address | CPU address | Contents |
| --- | --- | --- |
| 0x0000_0000 | 0x8000_0000 | boot header: magic `KCDM` (0x4D44434B), entry PC, image end, checksum (sum of u32 words 0x0010_0000..end, skipping the WAD area 0x0040_0000..0x00FF_FFFF) |
| 0x0010_0000 | PC 0x0010_0000 | `.text` (fetch only: loads there read 0, so it holds instructions only) |
| 0x0040_0000 | 0x8040_0000 | doom1.wad, raw; `open("doom1.wad")` reads it with memcpy |
| 0x0100_0000 | 0x8100_0000 | `.rodata`, `.data`, `.bss`, heap (Doom's zone: `-mb 16`), 1 MB stack below 0x8F00_0000 |
| 0x0F00_0000 | 0x8F00_0000 | D-cache flush area, reserved |

Doom's 320x200 screen (`I_VideoBuffer`, also `DG_ScreenBuffer`) is the SCRATCH BRAM at 0x7000_0000. The linker wraps
`I_InitGraphics` (to swap doomgeneric's zone buffer for SCRATCH) and `I_FinishUpdate` (to skip its copy and draw).
`DG_DrawFrame` waits for `FB_SWAP == 0`, writes the palette if Doom changed it (RGB888 to RGB444), copies the frame to
framebuffer rows 20..219, clears rows 0..19 and 220..239, stores 1 to `FB_SWAP` and logs `kc: frame N at T ms`.

The bootloader's dmem is free once Doom runs (`doom/kc_mem.h`). `--wrap=R_Init` (`doom/kc_render.c`) copies the
COLORMAP lump (34 x 256 bytes) to dmem 0x1000_0000..0x1000_21FF, points `colormaps` at the copy and rebuilds `zlight`
from it (`scalelight` is built later by R_ExecuteSetViewSize; the rest reads `colormaps` every frame), so every light
lookup is a BRAM read. It does not fit in SCRATCH: the screen leaves only 1,536 bytes there (0x7000_FA00..FFFF).

Sound and music are compiled out: `doom/kc_nosound.c` replaces `s_sound.c`/`i_sound.c` with no-ops, so no sound or
music lump is ever loaded, and `sounds.c`, `memio.c`, `i_cdmus.c`, `mus2mid.c`, `gusconf.c` and every backend are not
built. Files other than the WAD (config, savegames) fail with ENOENT, which Doom tolerates.

## Bootloader (doom/boot)

Runs from imem at 0x0, data and stack in dmem below 0x1000_6000. It waits for DDR_STATUS bit 0, then checks the boot
header and checksum. A valid image (preloaded by the simulation manifest, or left in DDR3 across a reset) boots: the
D-cache is cleaned by loading one word from each line of the flush area and the bootloader jumps to the entry PC.
Otherwise it waits for the image on the UART (1 Mbaud, little-endian; every frame answered `A` or `N`):

| Frame | Meaning |
| --- | --- |
| `W` addr len data[len] sum | write len bytes at DDR3 addr; sum = 32-bit sum of the bytes |
| `Z` addr len | zero len bytes at DDR3 addr (both multiples of 4) |
| `G` | check the header and boot; the check may log lowercase text before the `A`/`N` |

`scripts/doom_load.py` zero-fills the gaps from 0x0010_0000 to the image end, writes text, WAD and data in 4 KB
frames, then the header, then sends `G`.

## Keys

UART RX key bytes: bit 7 = down (1) / up (0), bits 6:0 = code.

| Code | Key | Doom |
| --- | --- | --- |
| 0x77 / 0x12 | `w` / up arrow | forward |
| 0x73 / 0x13 | `s` / down arrow | backward |
| 0x61 / 0x64 | `a` / `d` | strafe left / right |
| 0x10 / 0x11 | left / right arrow | turn |
| 0x14 | Ctrl | fire |
| 0x6A | `j` | fire |
| 0x20 | space | use (open doors) |
| 0x6B | `k` | use |
| 0x0D | Enter | menu select |
| 0x1B | Escape | menu |
| 0x79 / 0x6E | `y` / `n` | confirm / decline |
| 0x31..0x37 | `1`..`7` | weapons |
