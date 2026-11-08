# KennyCraft

An 8-lane SIMD TPU (Tai Processing Unit) grown from a multi-cycle RV32I core, running a voxel game on one Arty A7-100T. HackUTD 2026.

This README describes the current state of the files in this repository. The
[GitHub wiki](https://github.com/Sweet-Rice/kennycraft-alpha/wiki) holds the
design history; decision numbers such as D22 refer to it.

## Layout

| Path | What |
| --- | --- |
| `rtl/core/` | Multi-cycle core (`core.sv`) and its leaf modules: lane datapath, ALU, register file, decoder, LSU, MUL, QRCP, divergence stack |
| `rtl/core_pipe/` | 5-stage pipelined core (`core_pipe.sv`, `lane_pipe.sv`) built from `rtl/core`'s leaf modules |
| `rtl/soc/` | `kc_soc.sv` (core, imem, dmem, textures), address decoder, MMIO, UART, byte bridge for the byte-wide regions |
| `rtl/mem/` | `memory_arr.sv`, `world_mem.sv` |
| `rtl/display/` | Framebuffers, palette, VGA timing, clock generator |
| `rtl/ddr/` | DDR3 chunk store: chunk engine, DDR bridge, world remap, `ddr_clk.sv`, `ddr_model.sv` (simulation MIG), MIG project files in `mig/` |
| `rtl/vtrace/` | VTRACE ray unit |
| `rtl/top.sv` | Board top for the Arty A7-100T |
| `rtl/kc_isa_pkg.sv`, `rtl/isa_decode_check.sv` | ISA package and the decode module `tb/isa` checks it through |
| `tb/` | Testbenches; each `tb/<area>/tb.mk` registers its targets with `make check`. `tb/harness/` is the kcvl harness for the bench |
| `sw/` | Bench software: `crt0.S`, `kc.ld`, `gpu.h`, the arena allocator, `demo/pattern.c` (default `PROG`), self-checking tests in `tests/`, `ref/vtrace_vectors.c` |
| `scripts/` | Bench, trace, golden-shot, encoding and board scripts; `setup_kcn.sh` creates the KCN token on Solana devnet for `host/` |
| `mk/bench.mk` | Bench targets (below), included by `tb/bench/tb.mk` |
| `fpga/` | Non-project Vivado flow (`build.tcl`), per-target `sources.tcl`, constraints (`arty.xdc`, `top.xdc`, reference XDCs in `ref/`), `kc_mmi.tcl`, `hex2mem.py`, `patch_bit.sh`, `program.tcl` |
| `build/` | `build.tcl` entry and `summarize.py` for the fpga-tools MCP build contract |
| `host/` | Laptop-side banking host (Python): `kchost.py` serves `companion.html` and links to the chip over CR6 (`cr6.py`, with a fake chip), `bank.py` (SQLite ledger settled on Solana devnet), `nessie.py`, `agents.py`, `orchestrator.py`, tests `test_bank.py` and `test_contract.py`, `requirements.txt` |
| `game/` | The game, built for the laptop and the chip; see `game/README.md` |
| `kc_agents/` | Nemotron agents that act in the game world; see `kc_agents/README.md` |
| `tight_setup_hold_pins.txt` | Vivado table of the 68 `u_bridge` FIFO and calibration-sync pins with tight setup and hold (clocks `clk50_unbuf`, `clk_pll_i`) |

## Bank companion

| Command | Runs against |
| --- | --- |
| `python host/kchost.py` | A byte-level fake chip (no board, no game build) |
| `KC_CHIP=host python host/kchost.py` | The game's laptop build (`game/build/kc_host link` in WSL); `KC_GAME_DIR` picks the folder |
| `KC_CHIP=serial KC_PORT=COM5 python host/kchost.py` | The Arty's UART at 1 Mbaud; keys come from the page's key box |
| `KC_DEMO=1 KC_CHIP=host python host/kchost.py` | The demo village (build the game with `make KC_DEMO=1`): villagers at their stalls, chickens in the pen, builds on the plot, and the player starts with 300 KCN from the treasury |

`KC_LINK_FPS=50 KC_REC=/tmp/kcrec` makes the game build run a 50 fps clock and save every
frame. Nemotron reasoning is off by default for speed; `NEMOTRON_THINKING=1` turns it on.

With the existing bank configuration in place, run `python host/kchost.py` and
open http://127.0.0.1:8000. The Wallets card includes a native-canvas player KCN
chart fed by the page's existing `/events` stream; no separate dashboard,
Node.js, npm install, or extra wallet configuration is needed.

The chart starts with one observation, adds a point only when the player's
balance changes, and retains the latest 120 observations until the page reloads.
World, HUD, speech, and settlement-only updates do not consume chart history.
These are game-ledger balances, including queued payments, not reconstructed
on-chain history. Existing ledger settlement badges and devnet transaction
links remain available. The chart is read-only; companion game/bank controls
are unchanged.

## Checks

```sh
make check                                     # every target registered by a tb/*/tb.mk, JOBS (default nproc) at a time
make clean                                     # removes obj_dir/ and out/
```

Not in `make check`: `make tracediff-base-core` (every tb/core test except the
divergence-stack ones against the Stage 0 core of git ref `CORE_BASE_REF`),
`make qrcp-exhaustive` and `make qrcp-bench-inc`. `make tb-core-t_cpi` (part of
`make check`) also prints the measured CPI per instruction class.

## FPGA

```sh
make top-hex                                   # memory images in obj_dir/top_hex/<build>, needed by the rtl/top.sv targets
vivado -mode batch -source fpga/build.tcl      # KC_TARGET=<name> picks fpga/<name>/sources.tcl
```

| `KC_TARGET` | Design | Images |
| --- | --- | --- |
| `top` (default, `fpga/sources.tcl`) | `rtl/top.sv`, Stage 1: `LANES=8`, divergence stack | `kc_chip8` |
| `top_s0` | Stage 0: `LANES=1`, no divergence stack | `kc_chip` |
| `top_s2` | Stage 2: Stage 1 plus `HAS_RAY_UNIT=1`, `HAS_QRCP=1`, `FB_COUNT=3` | `kc_chip8_vtrace` |
| `top_s2p` | `top_s2` with `PIPELINED=1` | `kc_chip8_vtrace` |
| `ddr_test` | Standalone DDR3 chunk store test (`fpga/ddr_test/`) | none |
| `display_test` | Standalone display pattern (`fpga/display_test/`) | none |

Outputs go to `FPGA_BUILD_OUT` (default `build/out/<target>`): `top.bit`,
timing and utilization reports, `routed.dcp`, `top.mmi`, and for the
`rtl/top.sv` targets `kc.mmi` (imem, dmem and texture BRAMs; the RAMB18
palette is left out). `fpga/patch_bit.sh <build_dir> <hex_dir> <out_dir> [program]`
patches new `kc_imem.hex`, `kc_dmem.hex` and `textures.hex` into a built
`top.bit` with updatemem and, with `program`, programs it through
`fpga/program.tcl` under the hardware lock in `FPGA_STATE` (required). A
changed `palette.hex` needs a rebuild.

## Bench

Requires the pinned RISC-V GCC (`RISCV_PREFIX`, default the AMD 2026.1
`riscv64-unknown-elf-`; Zmmul, D5), Verilator 5.020 and Python with Pillow.
SDL3 with `pkg-config` is optional: without it the harness builds headless and
needs `--headless`. `make golden-check` also needs clang (`GAME_CHIP_CC`) and
`zig cc` (`HOST_CC`); `make keys` needs pyserial and pygame. All bench outputs
go under the ignored `out/` directory.

| Target | Behavior |
| --- | --- |
| `make check-bench` | Fixture checks, every self-checking test at Stage 0 (LANES = 1), Stage 1 (LANES = 8, divergence stack) and Stage 2 (plus the VTRACE ray unit, QRCP and triple buffering, on `rtl/top.sv`), and the golden shots at Stages 0, 1 and 2 (part of `make check`) |
| `make sw [PROG="sources.c"]` | Build ELF, disassembly, map and two 8192-word memory images |
| `make arena-host` | Compile the allocator for the host with `HOST_CC` |
| `make vl [RUN_ARGS="..."]` | Run the Verilated RTL; SDL3 window, UART and keyboard when built with SDL3 |
| `make check-fixture` | Check RGB pixels, replay, UART, run control and VCD windows without a CPU |
| `make test-stage0 test-ddr` | Run self-checking assembly through the chip model |
| `make test-t_uart` | Run one named software test |
| `make test-images` | Build the current configuration's test images without running them |
| `make test-stage1-build` | Assemble the eight-lane tests without requiring Stage 1 RTL |
| `make tracediff REF=<ref> [KEYS=file] [FRAMES=5] [IMAGES=dir] [POLLS=1] [REF_MAKE="..."]` | Build a reference (a git ref as a worktree in `out/ref`, or a checkout directory built in place) and compare retire traces using identical images |
| `make golden-check` | Render Kennedy's plain C shots and compare them pixel for pixel with kcvl frames |
| `make board BIT=file.bit MMI=file.mmi [TEX_HEX=] [PAL_HEX=]` | Run `make check`, patch memories with updatemem and program through `fpga/program.tcl` |
| `make keys [PORT=/dev/ttyUSB1]` | Forward focused-window key events at 1 Mbaud |

```sh
make vl RUN_ARGS="--headless --frames 3 --keys tb/harness/fixture/keys.txt --trace out/pattern.trace"
make vl RUN_ARGS="--headless --frames 3 --png-dir out/pattern"
make vl-fixture RUN_ARGS="--headless --frames 5 --record out/keys.txt"
make vl TRACE=1 RUN_ARGS="--headless --frames 1 --vcd out/chip.vcd --vcd-window 100:200"
```

Production uses `out/vl/kcvl`; the independent fixture uses `out/vl-fixture/kcvl`.
`--vcd` needs `TRACE=1`, which builds kcvl with waveform support (a slower model);
the fixture always has it.
`STAGE=0 DDR=1` is the default; `STAGE=1` builds 8 lanes with the divergence
stack. `STAGE=2` adds the ray unit (`HAS_RAY_UNIT=1`), the per-lane QRCP unit
(`HAS_QRCP=1`), three framebuffers (`FB_COUNT=3`, triple buffering, D24; the
test `t_fbswap3` replaces the double-buffering `t_fbswap`) and the tests
`t_vtrace` and `t_qrcp`, and builds `CHIP_TOP=top`, the same configuration as
the Stage 2 bitstream (`top_s2`); `STAGE=2` with `CHIP_TOP=bench_chip` is an
error. The default `CHIP_TOP=bench_chip` below Stage 2
(`tb/harness/bench_chip.sv`) wires the shipped RTL like `rtl/top.sv` without
the ray unit, takes `LANES` and `HAS_DIV_STACK`, always has two framebuffers,
and has stub clocks (reset releases at once, `ui_clk` is the core clock).
`CHIP_TOP=top` builds the board top with the same stubs. `PAL_HEX=` and `TEX_HEX=`
load build-time assets, and frames are read from the RTL framebuffer (the
CPU's draw buffer) and palette.
Keys, live or replayed, reach the UART only when the RTL accepts an FB_SWAP.

With `FB_COUNT=3` a store of 1 to FB_SWAP makes the draw buffer the ready
frame (replacing an older ready frame that vblank has not shown yet) and
hands the CPU a free buffer within about 10 core cycles; the ready frame
becomes the front buffer at the next vblank. FB_SWAP reads 1 only during
that hand-over, so the game's `while (FB_SWAP) {}` before the kernel is
unchanged and frames take their render time instead of whole refreshes.

Traces compare exact retired instructions and register writes, not cycles.
Different-CPI MMIO polling and `CYCLES` reads can legitimately change those
instructions or values; frame replay does not make peripheral timing identical.
Golden shots come from the plain C renderer, never from kcvl itself; only
`g0_spawn` is wired so far, and `golden-check` fails when it compares nothing.

`make board` runs `scripts/board.sh program`: it patches `out/kc_imem.bin`
and `out/kc_dmem.bin` (from `make sw`), plus `TEX_HEX`/`PAL_HEX` through
`fpga/hex2mem.py`, into `BIT` using the `kc.mmi` from `fpga/build.tcl`, and
programs `out/kc_patched.bit` with `fpga/program.tcl`, using Vivado from
`VIVADO_BIN` (default `/home/tai/AMD/2026.1/Vivado/bin`). It holds the
workspace `.fpga-state/hardware.lock` (the fpga-mcp lock; override with
`HARDWARE_LOCK=`) while programming, and `make keys` (`scripts/kc.py`, which
re-runs itself through `scripts/board.sh keys`) holds it while the UART is
open. Both refuse while another agent holds the board, and post
`taking-board` and `releasing-board` on issue #1 as `BOARD_AGENT` (default
`kc-bench`). `kc.mmi` has no palette BRAM, so a `PAL_HEX` change needs a
Vivado rebuild.

`scripts/kc_live.py` plays the board in one window: it shows the HDMI capture
card (ffmpeg, `--video /dev/video2`, MJPEG `--capture 1280x720`, scaled to a
4:3 `--size 960x720`) and sends keys and mouse to the UART (`--port
/dev/ttyUSB1`) with `scripts/kc.py`'s key bytes. Click to capture the mouse;
Esc releases it, Esc again quits. It needs pygame-ce, pyserial and ffmpeg,
and holds the same hardware lock while open (`--no-lock` skips it), but does
not post on issue #1. It clears HUPCL on the UART so closing the port leaves
DTR up: the Arty resets the design on a DTR edge, so only the first open after
a replug resets the board. It runs on Linux only (`fcntl`, `termios`, v4l2).

## Pipelined core (P8)

`rtl/core_pipe/` is a pipelined version of the core (IF, F2, ID, EX, MEM,
WB) with the same ports and parameters as `rtl/core/core.sv`, built from its
leaf modules. `PIPELINED = 1` (a parameter of `rtl/top.sv` and
`rtl/soc/kc_soc.sv`) selects it, and the core sits at `g_core.u_core`
whichever core is built. It retires the same instructions, masks and
register writes as the multi-cycle core. Only CPI changes:

| Class | Cycles |
| --- | --- |
| ALU, LUI, AUIPC, FENCE, MASKGET, BALLOT, LANEID, VSET, VGET, not-taken branch | 1 |
| MUL family | 2 |
| Taken branch or JAL that the BTB predicts, right target | 1 |
| Other taken branch or JAL, JALR, branch predicted taken but not taken, LMASK, MASKSET, MASKALL, DIF, DELSE, DENDIF (flush 4) | 5 |
| Load, N bus accesses (groups of coalesced lanes) | N + 3 (+3 per lane for world LW and texture LW; +2 per framebuffer read access on the top) |
| Store, N bus accesses, every bus lane to dmem or the framebuffer | N + 1 |
| Store, N bus accesses, otherwise | N + 2 (+3 per lane for world SW) |
| Load or store lanes in the dmem window (0x6000 to 0x7FFF) | 1 when every lane is in its own stack's bank, else one more than the words the busiest bank serves; in parallel with the bus lanes |
| QRCP | 8 after the previous retirement (12 after a flush) |
| Load-use, mul-use | +1 bubble |
| VTRACE rd (rd != x0) | start until done, plus 1 |
| VTRACE x0 | 1; the walk runs on |

Branches and the branch uniform check (ERR.DIVERGE) resolve in EX; a JALR's
target uniformity is checked in MEM from registers. The redirect is
registered (flush 4). The mask and divergence stack are written in EX, and
every mask writer flushes behind it. ERR halts report the faulting
instruction's own PC. While a VTRACE x0 walk is in flight, the next custom-1
instruction waits in EX, and world accesses and MMIO stores wait in MEM.

- **BTB** (`rtl/core_pipe/btb.sv`): 64 entries of distributed RAM, looked up
  from the fetch PC, with 2-bit counters. A hit predicted taken fetches the
  target next; ID checks the target and EX redirects only on a wrong guess.
  Only conditional branches and JAL are predicted.
- **dmem window** (`rtl/mem/dmem_win.sv`, `rtl/core_pipe/win_lsu.sv`): dmem
  0x6000 to 0x7FFF, where crt0 puts the eight 1 KB lane stacks, is 8 banks
  of distributed RAM (bank = address bits 12:10) on the pipelined core, so
  an 8-lane spill or reload is one cycle with no load tail. Same addresses
  and values as the dmem BRAM, which still holds the rest. It is initialized
  from `kc_dmem.hex` at build time; `fpga/patch_bit.sh` refuses images that
  change that range.
- **LSU** (`rtl/core_pipe/lsu_pipe.sv`): `rtl/core/lsu.sv` with a registered
  bus request and registered read data. **MUL** (`rtl/core_pipe/mul_pipe.sv`)
  is two MEM cycles into WB, forwarded from WB only (mul-use bubble);
  **QRCP** (`rtl/core_pipe/qrcp_pipe.sv`) is seven register stages,
  bit-exact with `rtl/core/qrcp.sv`.

### 100 MHz (`top_s2p100`)

`CORE_MHZ` (a parameter of `rtl/top.sv`, default 50) sets the core clock; the
`top_s2p100` Vivado target builds the pipelined Stage 2 design at 100 MHz
with timing-driven directives (`kc_timing_opt` in `fpga/build.tcl`). On
pipelined tops the framebuffer reads take 3 cycles and the chunk engine
buffers its DDR3 beats. MMIO CYCLES counts 20 ns ticks at either clock, so
software timing is unchanged.

`top_s2p100`, build ff7f70: core clock WNS +0.100 ns at 10 ns, every clock
met; 27,340 LUT, 14,971 FF, 111.5 BRAM36, 48 DSP. Frames in Verilator, with
the shallower pipeline of the extreme-hardware-optimizations branch at
50 MHz for comparison:

| Frame | Before: cycles at 50 MHz | Now: cycles at 100 MHz |
| --- | --- | --- |
| 160×120 | 209,190 = 239.0 fps | 244,535 = 408.9 fps |
| 320×240 | 804,185 = 62.2 fps | 938,057 = 106.6 fps |

```sh
make tb-core-pipe-<t>          # any tb/core test on the pipelined core
make tracediff-core-pipe-<t>   # its retire trace against the multi-cycle core
make check-bench PIPELINED=1   # bench at Stages 0, 1 and 2 (models in out/vl-pipe)
make tb-top-t_top_frame PIPELINED=1 TOP_ELF=kc_chip8_vtrace TOP_SWAPS=4
make tracediff STAGE=2 PIPELINED=1 REF=<dir|ref> POLLS=1 KEYS=<file> IMAGES=<dir>
```

`make check` runs every tb/core test at `PIPELINED=1` and its tracediff, the
hazard stress test `tb/core_pipe/sw/t_pipe_stress.S` on both cores, and the
`lint-core-pipe` matrix.
Where a test polls MMIO or reads `CYCLES`, `tb/core_pipe/tracediff_pipe.py`
collapses each listed poll loop and masks each listed `CYCLES` value, and
prints both with their iteration counts and values for each core. `POLLS=1` does the
same for bench traces (`scripts/tracecollapse.py`). For a replay that matches
on both cores, build the game with `KC_FIXED_DT=1 KC_TAG_PERSIST=1`.

The Stage 2 bitstream on the pipelined core is `KC_TARGET=top_s2p`
(`fpga/top_s2p/`), which is `top_s2` with `PIPELINED=1`.

## Credits

The Stage 0 CPU core is inspired by Tai's [RISC-V-Core-progression](https://github.com/Sweet-Rice/RISC-V-Core-progression) multicycle RV32I core (D11).
