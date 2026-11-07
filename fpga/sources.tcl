# Sources for the main KennyCraft bitstream (KC_TARGET=top). Sourced by
# fpga/build.tcl from the repo root with $root and $out set.
#
# Memory images: run `make top-hex` (tb/top/tb.mk) before the build. It builds
# Kennedy's chip program and copies his assets into obj_dir/top_hex:
# kc_imem.hex, kc_dmem.hex, textures.hex, palette.hex (not run from here: the
# asset generator's python does not run under Vivado's environment).
# rtl/top.sv names them in $readmemh and read_mem hands them to synthesis.
# To change imem, dmem or textures without a rebuild, use the updatemem
# commands in fpga/build.tcl.
set hex_dir obj_dir/top_hex
foreach f {kc_imem.hex kc_dmem.hex textures.hex palette.hex} {
    if {![file exists $hex_dir/$f]} { error "$hex_dir/$f missing: run `make top-hex` first" }
    read_mem $hex_dir/$f
    # snapshot next to the bitstream (fpga/patch_bit.sh checks the palette)
    file copy -force $hex_dir/$f $out/$f
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
