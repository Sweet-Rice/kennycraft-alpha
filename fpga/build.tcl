# KennyCraft non-project Vivado build.
#
#   KC_TARGET   which design to build (default "top"). "top" reads
#               fpga/sources.tcl; any other name reads fpga/<name>/sources.tcl.
#               A sources.tcl reads every RTL, IP and constraint file and sets
#               the variable `top` to the top module name. It may also set
#               `generics` (NAME=VALUE list for synth_design -generic) and
#               `kc_mmi 1` (the KennyCraft top: write kc.mmi). Targets "top"
#               (Stage 1, LANES = 8), "top_s0" (Stage 0, LANES = 1),
#               "top_s2" (Stage 2: Stage 1 plus the VTRACE ray unit and
#               QRCP), "top_s2p" (top_s2 on the pipelined core,
#               PIPELINED = 1) and "top_s2p100" (top_s2p with the core
#               clock at 100 MHz, CORE_MHZ = 100) build rtl/top.sv.
#   FPGA_BUILD_OUT  output directory (the fpga-tools MCP sets it per job;
#               defaults to build/out/<target> for manual runs).
#
# Run from the repo root:  vivado -mode batch -source fpga/build.tcl
# The MCP enters through build/build.tcl, which sources this file.
#
# Outputs in $out: top.bit, timing.rpt, paths.rpt and paths_summary.rpt (the
# core clock's worst setup paths), utilization.rpt (+ _hier), routed.dcp,
# top.mmi (write_mem_info: XPM memories only, i.e. the ddr_bridge FIFOs) and,
# for the rtl/top.sv targets, kc.mmi (fpga/kc_mmi.tcl): the imem, dmem and texture
# BRAMs, which are inferred and so missing from top.mmi. The palette is not in
# it: it sits in a RAMB18, and updatemem 2026.1 mis-places RAMB18 bit lanes
# (it read RAMB18_X0Y26 as RAMB36_X0Y26, i.e. imem), so palette.hex changes
# need a rebuild.
#
# Fast rebuild (D8): new kc_imem.hex / kc_dmem.hex / textures.hex go into the
# last bitstream without Vivado:
#   [FPGA_STATE=<MCP state dir>] fpga/patch_bit.sh $out obj_dir/top_hex/<build> <dir> [program]
# (FPGA_STATE is required with `program`: it names the MCP's hardware.lock)
# which converts each image with fpga/hex2mem.py (kc_imem 32, kc_dmem 32,
# textures 4 bits) and runs
#   updatemem -force -meminfo $out/kc.mmi -bit $out/top.bit \
#     -data kc_imem.mem -proc imem -data kc_dmem.mem -proc dmem \
#     -data textures.mem -proc tex \
#     -out <dir>/patched.bit
# then, with `program`, fpga/program.tcl under the MCP hardware lock (the
# MCP's own `program` only accepts unmodified build outputs).

set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
set part xc7a100tcsg324-1
set target [expr {[info exists ::env(KC_TARGET)] && $::env(KC_TARGET) ne "" ? $::env(KC_TARGET) : "top"}]
set out [expr {[info exists ::env(FPGA_BUILD_OUT)] ? $::env(FPGA_BUILD_OUT) : "$root/build/out/$target"}]
file mkdir $out

if {[info exists ::env(FPGA_ILA_PROBES_JSON)] && $::env(FPGA_ILA_PROBES_JSON) ni {{} {[]}}} {
    error "ILA probes are not supported by fpga/build.tcl yet"
}

# 14 of the machine's 16 hardware threads; the other 2 are kept for agents.
set_param general.maxThreads 14
create_project -in_memory -part $part
set sources [expr {$target eq "top" ? "fpga/sources.tcl" : "fpga/$target/sources.tcl"}]
if {![file exists $sources]} { error "No sources script for target '$target': $sources" }
set top ""
set generics {}
set kc_mmi 0
source $sources
if {$top eq ""} { error "$sources did not set top" }

synth_design -top $top -part $part {*}[concat {*}[lmap g $generics {list -generic $g}]]
if {$kc_mmi} {
    source fpga/kc_mmi.tcl
    set kc_mems {
        {imem    u_soc/u_imem/*    32 8192}
        {dmem    u_soc/u_dmem/*    32 8192}
        {tex     u_soc/u_tex/*      4 16384}
    }
    kc_record_brams $kc_mems
}
if {[info exists ::env(FPGA_FAIL_TIMING)] && $::env(FPGA_FAIL_TIMING)} {
    # Acceptance-only: every target's 100 MHz board clock port is `clk` (E3).
    create_clock -name sys_clk -period 0.5 [get_ports clk]
}
opt_design
place_design
phys_opt_design
route_design

report_timing_summary -report_unconstrained -check_timing_verbose -file $out/timing.rpt
# The worst setup endpoints of the core clock, one path each, for
# critical-path work: 3000 in a one-line-per-path summary, the worst 300 in
# full (paths.rpt).
set kc_core_clk [get_clocks -quiet clk0_raw]
if {[llength $kc_core_clk]} {
    report_timing -group $kc_core_clk -max_paths 3000 -nworst 1 -sort_by slack -path_type summary -file $out/paths_summary.rpt
    report_timing -group $kc_core_clk -max_paths 300 -nworst 1 -sort_by slack -file $out/paths.rpt
}
report_utilization -file $out/utilization.rpt
report_utilization -hierarchical -hierarchical_depth 4 -file $out/utilization_hier.rpt
check_timing -verbose -file $out/check_timing.rpt
write_checkpoint -force $out/routed.dcp
write_bitstream -force $out/top.bit
write_mem_info -force $out/top.mmi
if {$kc_mmi} {
    kc_write_mmi $out/kc.mmi $kc_mems
}

set log $out/build.log
if {![file exists $log]} {
    # Manual runs have no MCP log; summarize.py still needs one.
    close [open $log a]
}
exec python3 -I build/summarize.py $out false
puts "KC_BUILD_DONE target=$target out=$out"
