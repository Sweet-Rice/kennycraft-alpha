# Program a bitstream on the Arty over JTAG, outside the fpga-tools MCP. Used
# for bitstreams patched by updatemem (fpga/build.tcl), which the MCP's
# `program` tool refuses because their SHA256 differs from the build job.
#
#   flock -w 600 <FPGA_STATE>/hardware.lock \
#       vivado -mode batch -nojournal -nolog -source fpga/program.tcl -tclargs <file.bit>
#
# The flock takes the MCP's own hardware lock, so no MCP board access runs at
# the same time. It connects to the hw_server on localhost:3121 when one is
# running (the MCP's), else starts one. Prints done=1 when DONE went high.
if {[llength $argv] != 1} { error "usage: program.tcl <file.bit>" }
set bit [file normalize [lindex $argv 0]]

open_hw_manager
if {[catch {connect_hw_server -url localhost:3121 -allow_non_jtag}]} {
    connect_hw_server -allow_non_jtag
}
open_hw_target
set dev [lindex [get_hw_devices xc7a100t*] 0]
if {$dev eq ""} { error "no xc7a100t on the JTAG chain" }
current_hw_device $dev
set_property PROGRAM.FILE $bit $dev
set_property PROBES.FILE {} $dev
set_property FULL_PROBES.FILE {} $dev
program_hw_devices $dev
refresh_hw_device -update_hw_probes false $dev
puts "done=[get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev]"
close_hw_target
disconnect_hw_server
close_hw_manager
