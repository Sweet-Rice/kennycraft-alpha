// Output palette: 256 x RGB444 (bits 11:8 red, 7:4 green, 3:0 blue) in one
// dual-clock block RAM (Shared page, Pixel byte; memory map 0x6000_0000).
// Written from the 50 MHz core side, one entry per 32-bit store; read on the
// 25 MHz pixel side with one cycle of latency. Entries start at 0 (black),
// or at the contents of INIT_FILE ($readmemh, one 3-digit RGB444 entry per
// line, e.g. game/gen/palette.hex) when it is not empty.
module palette #(
    parameter string INIT_FILE = ""
) (
    input  logic        clk_w,
    input  logic        we,
    input  logic [7:0]  waddr,
    input  logic [11:0] wdata,
    input  logic        clk_r,
    input  logic [7:0]  raddr,
    output logic [11:0] rdata
);
    (* ram_style = "block" *) logic [11:0] mem [256];

    initial begin
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
        else for (int i = 0; i < 256; i++) mem[i] = '0;
    end

    always_ff @(posedge clk_w) begin
        if (we) mem[waddr] <= wdata;
    end

    always_ff @(posedge clk_r) begin
        rdata <= mem[raddr];
    end
endmodule
