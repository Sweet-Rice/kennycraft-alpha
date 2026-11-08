# Stage 2 KennyCraft bitstream (KC_TARGET=top_s2): rtl/top.sv with LANES = 8,
# the divergence stack, the VTRACE ray unit (HAS_RAY_UNIT = 1), the
# per-lane QRCP unit (HAS_QRCP = 1, D22) and three framebuffers
# (FB_COUNT = 3, triple buffering, D24), running
# Kennedy's VTRACE kernel (kc_chip8_vtrace, images in
# obj_dir/top_hex/kc_chip8_vtrace from `make top-hex`). Same design and flow
# as the Stage 1 top otherwise; see fpga/sources.tcl.
set kc_stage 2
source fpga/sources.tcl
