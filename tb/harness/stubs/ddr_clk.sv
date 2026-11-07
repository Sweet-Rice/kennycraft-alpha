// Harness stand-in for rtl/ddr/ddr_clk.sv: clk_sys and clk_ref are clk_in, so
// ui_clk from the mig_ddr3 stub equals clk_core (no unrelated-clock CDC).
module ddr_clk (
    input wire clk_in,
    input wire rst,
    output wire clk_sys,
    output wire clk_ref,
    output wire locked
);
    assign clk_sys = clk_in;
    assign clk_ref = clk_in;
    assign locked = !rst;
endmodule
