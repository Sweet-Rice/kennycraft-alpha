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

## Credits

The Stage 0 CPU core is inspired by Tai's [RISC-V-Core-progression](https://github.com/Sweet-Rice/RISC-V-Core-progression) multicycle RV32I core (D11).
