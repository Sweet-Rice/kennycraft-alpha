# KennyCraft

An 8-lane SIMD GPU grown from a multi-cycle RV32I core, running a voxel Minecraft on one Arty A7-100T. HackUTD 2026.

The design doc is the [GitHub wiki](https://github.com/Sweet-Rice/kennycraft-alpha/wiki). Tai_2 wins wherever pages disagree.

## Layout

| Path | What |
| --- | --- |
| `rtl/` | SystemVerilog (`core/`, `soc/`, `mem/`, `display/`, `ddr/`, `top.sv`) |
| `tb/` | Verilator testbenches; each `tb/<area>/tb.mk` registers its targets with `make check` |
| `fpga/` | `arty.xdc`, `build.tcl` (non-project Vivado flow), per-target `sources.tcl` |
| `build/` | `build.tcl` entry and `summarize.py` for the fpga-tools MCP build contract |

## Checks

```sh
make check                                     # every registered Verilator testbench and lint target, JOBS (default nproc) at a time
vivado -mode batch -source fpga/build.tcl      # KC_TARGET=<name> picks fpga/<name>/sources.tcl
```

## Bench

Requires the pinned RISC-V GCC (`RISCV_PREFIX`, default the AMD 2026.1
`riscv64-unknown-elf-`; Zmmul, D5), Verilator 5.020 and Python with Pillow.
SDL3 with `pkg-config` is optional: without it the harness builds headless and
needs `--headless`. `make golden-check` also needs clang and `zig cc`;
`make keys` needs pyserial and pygame. All bench outputs go under the ignored
`out/` directory, and `make clean` removes it.

| Target | Behavior |
| --- | --- |
| `make check-bench` | Fixture checks, every self-checking test at Stage 0 (LANES = 1), Stage 1 (LANES = 8, divergence stack) and Stage 2 (plus the VTRACE ray unit and triple buffering, on `rtl/top.sv`), and the golden shots (part of `make check`) |
| `make sw [PROG="sources.c"]` | Build ELF, disassembly, map and two 8192-word memory images |
| `make arena-host` | Compile the allocator for the host with `HOST_CC` |
| `make vl [RUN_ARGS="..."]` | Run the Verilated RTL; SDL3 window, UART and keyboard when built with SDL3 |
| `make check-fixture` | Check RGB pixels, replay, UART, run control and VCD windows without a CPU |
| `make test-stage0 test-ddr` | Run self-checking assembly through the chip model |
| `make test-t_uart` | Run one named software test |
| `make test-stage1-build` | Assemble the eight-lane tests without requiring Stage 1 RTL |
| `make tracediff REF=<ref> [KEYS=file] [FRAMES=5]` | Build a reference worktree and compare retire traces using identical images |
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
test `t_fbswap3` replaces the double-buffering `t_fbswap`) and `t_vtrace`, and builds
`CHIP_TOP=top`, the same configuration as the Stage 2 bitstream (`top_s2`).
The default `CHIP_TOP=bench_chip` below Stage 2 wires the shipped
RTL like `rtl/top.sv` without the ray unit, takes `LANES` and `HAS_DIV_STACK`, and
has stub clocks (reset releases at once, `ui_clk` is the core clock).
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

`make board` uses `fpga/program.tcl`, `fpga/hex2mem.py` and the `kc.mmi` from `fpga/build.tcl`, and
Vivado from `VIVADO_BIN` (default `/home/tai/AMD/2026.1/Vivado/bin`). It holds the
workspace `.fpga-state/hardware.lock` (the fpga-mcp lock; override with
`HARDWARE_LOCK=`) while programming, and `make keys` holds it while the UART is
open. Both post `taking-board` and `releasing-board` on issue #1 as `BOARD_AGENT`
(default `kc-bench`). `kc.mmi` has no palette BRAM, so a `PAL_HEX` change
needs a Vivado rebuild.

## Pipelined core (P8)

`rtl/core_pipe/` is a pipelined version of the core (IF, F2, ID, EX, MEM,
WB) with the same ports and parameters as `rtl/core/core.sv`, built from its
leaf modules. `PIPELINED = 1` (a parameter of `rtl/top.sv` and
`rtl/soc/kc_soc.sv`) selects it, and the core sits at `g_core.u_core`
whichever core is built. It retires the same instructions, masks and
register writes as the multi-cycle core. Only CPI changes:

| Class | Cycles |
| --- | --- |
| ALU, LUI, AUIPC, FENCE, MASKGET, BALLOT, LANEID, not-taken branch | 1 |
| MUL family | 2 |
| Taken branch or JAL that the BTB predicts, right target | 1 |
| Other taken branch or JAL, JALR, branch predicted taken but not taken, LMASK, MASKSET, MASKALL, DIF, DELSE, DENDIF (flush 4) | 5 |
| Load, N bus accesses (groups of coalesced lanes) | N + 3 (+3 per lane for world LW and texture LW; +2 per framebuffer read access on the top) |
| Store, N bus accesses, every bus lane to dmem or the framebuffer | N + 1 |
| Store, N bus accesses, otherwise | N + 2 (+3 per lane for world SW) |
| Load or store lanes in the dmem window (0x6000 to 0x7FFF) | 1 when every lane is in its own stack's bank, else one more than the words the busiest bank serves; in parallel with the bus lanes |
| QRCP | 8 after the previous retirement (12 after a flush) |
| Load-use, mul-use | +1 bubble |
| VTRACE | start until done, plus 1 |

Branches and the branch uniform check (ERR.DIVERGE) resolve in EX; a JALR's
target uniformity is checked in MEM from registers. The redirect is
registered (flush 4). The mask and divergence stack are written in EX, and
every mask writer flushes behind it. ERR halts report the faulting
instruction's own PC.

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

`make check` runs every tb/core test at `PIPELINED=1` and its tracediff.
Where a test polls MMIO or reads `CYCLES`, `tb/core_pipe/tracediff_pipe.py`
collapses each listed poll loop and masks each listed `CYCLES` value, and
prints both with their iteration counts and values for each core. `POLLS=1` does the
same for bench traces (`scripts/tracecollapse.py`). For a replay that matches
on both cores, build the game with `KC_FIXED_DT=1 KC_TAG_PERSIST=1`.

The Stage 2 bitstream on the pipelined core is `KC_TARGET=top_s2p`
(`fpga/top_s2p/`), which is `top_s2` with `PIPELINED=1`.

## Credits

The Stage 0 CPU core is inspired by Tai's [RISC-V-Core-progression](https://github.com/Sweet-Rice/RISC-V-Core-progression) multicycle RV32I core (D11).
