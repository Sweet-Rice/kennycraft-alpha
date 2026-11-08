# Stage 2 KennyCraft bitstream on the pipelined core (KC_TARGET=top_s2p): the
# top_s2 design (LANES = 8, divergence stack, VTRACE ray unit, QRCP, three
# framebuffers, kc_chip8_vtrace images) with PIPELINED = 1, so kc_soc builds
# the 5-stage rtl/core_pipe instead of the multi-cycle rtl/core. Same images
# and flow as top_s2; see fpga/sources.tcl.
#   tools/fpga_mcp.py --project <checkout> --target top_s2p build-wait
set kc_stage 2
set kc_pipelined 1
source fpga/sources.tcl
