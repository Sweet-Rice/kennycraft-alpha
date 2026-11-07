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
