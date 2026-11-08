# top_s2p with the core clock at 100 MHz (KC_TARGET=top_s2p100): the
# pipelined Stage 2 design, CORE_MHZ = 100, timed against a 10 ns core clock.
#   tools/fpga_mcp.py --project <checkout> --target top_s2p100 build-wait
set kc_stage 2
set kc_pipelined 1
set kc_core_mhz 100
source fpga/sources.tcl
