## Constraints for rtl/top.sv only (fpga/arty.xdc is shared with display_test).

set_property -dict { PACKAGE_PIN A9 IOSTANDARD LVCMOS33 } [get_ports uart_txd_in]; #IO_L14N_T2_SRCC_16 Sch=uart_txd_in

## Asynchronous board I/O: the reset button and UART RX go through
## synchronizers, LED, UART TX and VGA pins have no timing relationship with an
## external clock.
set_false_path -from [get_ports {ck_rst uart_txd_in}]
set_false_path -to [get_ports {led uart_rxd_out vga_r[*] vga_g[*] vga_b[*] vga_hs vga_vs}]
