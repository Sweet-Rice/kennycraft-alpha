# Program several bitstreams back to back in one Vivado session (one JTAG
# connection), so the gap between Bad Apple loader passes is only the FPGA
# configuration itself. Same connection logic as fpga/program.tcl.
#
#   vivado -mode batch -source badapple/flash.tcl -tclargs <a.bit> [<b.bit> ...]
#
# After each bitstream it checks DONE and waits 1 s (a loader pass finishes
# in well under that at 100 MHz). Prints "programmed <file> done=1" per file.
if {[llength $argv] < 1} { error "usage: flash.tcl <file.bit> ..." }

open_hw_manager
if {[catch {connect_hw_server -url localhost:3121 -allow_non_jtag}]} {
    connect_hw_server -allow_non_jtag
}
open_hw_target
set dev [lindex [get_hw_devices xc7a100t*] 0]
if {$dev eq ""} { error "no xc7a100t on the JTAG chain" }
current_hw_device $dev
set_property PROBES.FILE {} $dev
set_property FULL_PROBES.FILE {} $dev
foreach f $argv {
    set bit [file normalize $f]
    set_property PROGRAM.FILE $bit $dev
    program_hw_devices $dev
    refresh_hw_device -update_hw_probes false $dev
    set done [get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev]
    puts "programmed [file tail $bit] done=$done"
    if {$done != 1} { error "DONE stayed low after [file tail $bit]" }
    after 1000
}
close_hw_target
disconnect_hw_server
close_hw_manager
