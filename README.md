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
| `make check-bench` | Fixture checks, every self-checking test at Stage 0 (LANES = 1), Stage 1 (LANES = 8, divergence stack) and Stage 2 (plus the VTRACE ray unit, on `rtl/top.sv`), and the golden shots (part of `make check`) |
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
```

Production uses `out/vl/kcvl`; the independent fixture uses `out/vl-fixture/kcvl`.
`STAGE=0 DDR=1` is the default; `STAGE=1` builds 8 lanes with the divergence
stack. `STAGE=2` adds the ray unit (`HAS_RAY_UNIT=1`), the per-lane QRCP unit
(`HAS_QRCP=1`) and `t_vtrace`, and builds
`CHIP_TOP=top`. The default `CHIP_TOP=bench_chip` below Stage 2 wires the shipped
RTL like `rtl/top.sv` without the ray unit, takes `LANES` and `HAS_DIV_STACK`, and
has stub clocks (reset releases at once, `ui_clk` is the core clock).
`CHIP_TOP=top` builds the board top with the same stubs. `PAL_HEX=` and `TEX_HEX=`
load build-time assets, and frames are read from the RTL framebuffer and palette.
Keys, live or replayed, reach the UART only when the RTL accepts an FB_SWAP.

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

## Credits

The Stage 0 CPU core is inspired by Tai's [RISC-V-Core-progression](https://github.com/Sweet-Rice/RISC-V-Core-progression) multicycle RV32I core (D11).
