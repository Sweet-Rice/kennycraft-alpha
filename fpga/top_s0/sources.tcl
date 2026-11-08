# Stage 0 KennyCraft bitstream (KC_TARGET=top_s0): rtl/top.sv with LANES = 1
# and no divergence stack, running Kennedy's one-lane game (kc_chip, images in
# obj_dir/top_hex/kc_chip from `make top-hex`). Same design and flow as the
# Stage 1 top otherwise; see fpga/sources.tcl.
set kc_stage 0
source fpga/sources.tcl
