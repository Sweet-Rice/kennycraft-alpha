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
| `prompts/` | Stage agent prompts (preamble plus prompt, from Tai_2) |

## Checks

```sh
make check                                     # every registered Verilator testbench and lint target
vivado -mode batch -source fpga/build.tcl      # KC_TARGET=<name> picks fpga/<name>/sources.tcl
```

## Bench

Requires RISC-V GCC 12+ (`riscv-none-elf-` or `riscv64-unknown-elf-` on `PATH`),
Verilator, SDL3, `pkg-config`, and Python with Pillow, pyserial and pygame.
The RTL team's baseline is Verilator 5.020; 5.054 currently reports additional
warnings in upstream simulation models. Override `CROSS=`, `VERILATOR=` or
`PYTHON=` as needed. All bench outputs go under the ignored `out/` directory.

| Target | Behavior |
| --- | --- |
| `make sw [PROG="sources.c"]` | Build ELF, disassembly, map and two 8192-word memory images |
| `make arena-host` | Compile the allocator without chip MMIO |
| `make vl [RUN_ARGS="..."]` | Run the real Verilated RTL with SDL3 display, UART and keyboard |
| `make check-fixture` | Check RGB pixels, replay, UART, run control and VCD windows without a CPU |
| `make test-stage0 test-ddr` | Run self-checking assembly through the real chip model |
| `make test-t_uart` | Run one named software test |
| `make test-stage1-build` | Assemble the eight-lane tests without requiring Stage 1 RTL |
| `make tracediff REF=<ref> [KEYS=file] [FRAMES=5]` | Build a reference worktree and compare retire traces using identical images |
| `make golden-check` | Compare approved replay PNGs in `sw/golden/`, if present |
| `make golden-update NAME=name FRAMES=3 KEYS=file` | Capture a candidate golden and replay; review before committing |
| `make board BIT=file.bit MMI=file.mmi` | Run checks, patch memories and program on the Vivado host |
| `make keys [PORT=/dev/tty.usbserial-...]` | Forward focused-window key events at 1 Mbaud |

```sh
make vl RUN_ARGS="--frames 3 --keys tb/harness/fixture/keys.txt --trace out/pattern.trace"
make vl RUN_ARGS="--headless --frames 3 --png-dir out/pattern"
make vl-fixture RUN_ARGS="--frames 5 --record out/keys.txt"
```

Production uses `out/vl/kcvl`; the independent fixture uses `out/vl-fixture/kcvl`.
`STAGE=0 DDR=1` is the default. Later stages require the corresponding merged RTL.
The misaligned-JALR source-PC test runs with the merged P4 alignment behavior.
Until P3 merges, `CHIP_TOP=bench_chip` composes the core, display and chunk engine
under `tb/harness/`; board RTL is not replaced. P3 binding uses `CHIP_TOP=top`.
`PAL_HEX=` and `TEX_HEX=` select build-time assets; the runtime palette option is
`--palette-hex`.

Traces compare exact retired instructions and register writes, not cycles.
Different-CPI MMIO polling and `CYCLES` reads can legitimately change those
instructions or values; frame replay does not make peripheral timing identical.
Self-checking tests and C-reference frames remain necessary. Candidate captures
are regression images, not an independent instruction oracle. An empty golden
directory is reported explicitly; it is not pixel-match evidence.

Hardware programming requires Vivado's `updatemem`, openFPGALoader, `flock` and an
available board. Programming takes `.fpga-state/hardware.lock` (override with
`HARDWARE_LOCK=`) to exclude the hardware MCP. Board claims go to alpha issue #1
under the authenticated user's name; bench coordination lives in issue #7.

## Credits

The Stage 0 CPU core is inspired by Tai's [RISC-V-Core-progression](https://github.com/Sweet-Rice/RISC-V-Core-progression) multicycle RV32I core (D11).
