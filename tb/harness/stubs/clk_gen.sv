// Harness stand-in for rtl/display/clk_gen.sv (P1 issue #1 contract): clk_core
// is the harness clk, clk_pix is half rate. Reset follows rst_n combinationally
// and locked is 1, so the real reset synchronizers are not simulated.
module clk_gen (
    input wire clk,
    input wire rst_n,
    output wire clk_core,
    output logic clk_pix,
    output wire locked,
    output wire rst_core,
    output wire rst_pix
);
    assign clk_core = clk;
    assign locked = 1'b1;
    assign rst_core = !rst_n;
    assign rst_pix = !rst_n;
    always_ff @(posedge clk) begin
        if (!rst_n) clk_pix <= 1'b0;
        else clk_pix <= !clk_pix;
    end
endmodule
