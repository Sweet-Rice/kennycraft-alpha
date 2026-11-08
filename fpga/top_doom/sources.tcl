# Doom bitstream (KC_TARGET=top_doom): rtl/top.sv with HAS_DDR_MEM = 1 (code and
# data in DDR3 behind the I-cache and D-cache, 64 KB scratch), the pipelined
# core at CORE_MHZ = 100, LANES = 8, divergence stack, QRCP, no ray unit, two
# framebuffers. Run `make doom` and `make top-hex` first; see fpga/sources.tcl.
#   tools/fpga_mcp.py --project <checkout> --target top_doom build-wait
set kc_stage 2
set kc_pipelined 1
set kc_core_mhz 100
set kc_timing_opt 1
set kc_doom 1
source fpga/sources.tcl
