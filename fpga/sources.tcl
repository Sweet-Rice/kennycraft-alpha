# Sources for the main KennyCraft bitstream (KC_TARGET=top): the Stage 1 GPU,
# rtl/top.sv with LANES = 8 and the divergence stack, running Kennedy's 8-lane
# game (kc_chip8). Sourced by fpga/build.tcl from the repo root with $root and
# $out set. fpga/top_s0/sources.tcl sets kc_stage 0 and sources this file for
# the Stage 0 build (LANES = 1, no divergence stack, kc_chip), and
# fpga/top_s2/sources.tcl kc_stage 2 for Stage 2 (Stage 1 plus the VTRACE ray
# unit, HAS_RAY_UNIT = 1, the per-lane QRCP unit, HAS_QRCP = 1 (D22), and
# triple buffering, FB_COUNT = 3 (D24), running the VTRACE kernel
# kc_chip8_vtrace), and fpga/top_s2p/sources.tcl kc_stage 2 with
# kc_pipelined 1: top_s2 on the 5-stage pipelined core (PIPELINED = 1,
# rtl/core_pipe):
#   tools/fpga_mcp.py --project <checkout> --target top_s0 build-wait
#   tools/fpga_mcp.py --project <checkout> --target top_s2 build-wait
#   tools/fpga_mcp.py --project <checkout> --target top_s2p build-wait
# fpga/top_s2p100/sources.tcl is top_s2p with kc_core_mhz 100 (CORE_MHZ = 100).
#
# Memory images: run `make top-hex` (tb/top/tb.mk) before the build. It builds
# Kennedy's chip programs and copies his assets into obj_dir/top_hex/<build>:
# kc_imem.hex, kc_dmem.hex, textures.hex, palette.hex (not run from here: the
# asset generator's python does not run under Vivado's environment).
# rtl/top.sv names them in $readmemh and read_mem hands them to synthesis.
# To change imem, dmem or textures without a rebuild, use the updatemem
# commands in fpga/build.tcl.
if {![info exists kc_stage]} { set kc_stage 1 }
if {![info exists kc_pipelined]} { set kc_pipelined 0 }
if {$kc_stage == 2} {
    set hex_dir obj_dir/top_hex/kc_chip8_vtrace
    set generics {LANES=8 HAS_DIV_STACK=1 HAS_RAY_UNIT=1 HAS_QRCP=1 FB_COUNT=3}
} elseif {$kc_stage == 1} {
    set hex_dir obj_dir/top_hex/kc_chip8
    set generics {LANES=8 HAS_DIV_STACK=1}
} else {
    set hex_dir obj_dir/top_hex/kc_chip
    set generics {LANES=1 HAS_DIV_STACK=0}
}
if {$kc_pipelined} { lappend generics PIPELINED=1 }
if {[info exists kc_core_mhz]} { lappend generics CORE_MHZ=$kc_core_mhz }
set kc_mmi 1
foreach f {kc_imem.hex kc_dmem.hex textures.hex palette.hex} {
    if {![file exists $hex_dir/$f]} { error "$hex_dir/$f missing: run `make top-hex` first" }
    read_mem $hex_dir/$f
    # snapshot next to the bitstream (fpga/patch_bit.sh checks the palette)
    file copy -force $hex_dir/$f $out/$f
}

read_verilog -sv rtl/kc_isa_pkg.sv
read_verilog -sv [glob rtl/core/*.sv] [glob rtl/mem/*.sv] [glob rtl/soc/*.sv] [glob rtl/display/*.sv]
set kc_core_pipe [glob -nocomplain rtl/core_pipe/*.sv]
if {[llength $kc_core_pipe]} { read_verilog -sv $kc_core_pipe }
read_verilog -sv {
    rtl/ddr/ddr_clk.sv
    rtl/ddr/ddr_bridge.sv
    rtl/ddr/chunk_engine.sv
    rtl/ddr/world_remap.sv
    rtl/vtrace/vtrace.sv
    rtl/top.sv
}
source rtl/ddr/mig/mig_ddr3.tcl
read_xdc fpga/arty.xdc
read_xdc fpga/top.xdc
read_xdc rtl/ddr/ddr_bridge.xdc
set top top
