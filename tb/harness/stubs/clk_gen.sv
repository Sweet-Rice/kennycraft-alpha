// P1 issue #1 contract: core clock is the harness input; pixel is half rate.
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
