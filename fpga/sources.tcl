# Sources for the main KennyCraft bitstream (KC_TARGET=top). Sourced by
# fpga/build.tcl from the repo root with $root and $out set.
#
# Memory images: `make top-hex` (tb/top/tb.mk) builds Kennedy's chip program
# and copies his assets into obj_dir/top_hex: kc_imem.hex, kc_dmem.hex,
# textures.hex, palette.hex. rtl/top.sv names them in $readmemh and read_mem
# hands them to synthesis. To change them without a rebuild, use the
# updatemem commands in fpga/build.tcl.
set hex_dir obj_dir/top_hex
puts [exec make -C $root top-hex 2>@1]
foreach f {kc_imem.hex kc_dmem.hex textures.hex palette.hex} {
    read_mem $hex_dir/$f
}

read_verilog -sv rtl/kc_isa_pkg.sv
read_verilog -sv [glob rtl/core/*.sv] [glob rtl/mem/*.sv] [glob rtl/soc/*.sv] [glob rtl/display/*.sv]
read_verilog -sv {
    rtl/ddr/ddr_clk.sv
    rtl/ddr/ddr_bridge.sv
    rtl/ddr/chunk_engine.sv
    rtl/ddr/world_remap.sv
    rtl/top.sv
}
source rtl/ddr/mig/mig_ddr3.tcl
read_xdc fpga/arty.xdc
read_xdc fpga/top.xdc
read_xdc rtl/ddr/ddr_bridge.xdc
set top top
