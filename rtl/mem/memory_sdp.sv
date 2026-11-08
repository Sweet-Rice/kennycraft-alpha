// Simple dual-port block RAM: one write port, one read port, one clock.
//
// W bits wide, D words deep, split into NBE write lanes of W/NBE bits each.
// Reads return mem[raddr] one cycle after raddr is presented. A read of the
// word written in the same cycle returns the old contents (read-first), the
// mode a 7-series block RAM guarantees for a same-clock address collision.
module memory_sdp #(
    parameter int W   = 32,
    parameter int D   = 1024,
    parameter int NBE = W / 8
) (
    input  logic                 clk,
    input  logic [NBE-1:0]       we,
    input  logic [$clog2(D)-1:0] waddr,
    input  logic [W-1:0]         wdata,
    input  logic [$clog2(D)-1:0] raddr,
    output logic [W-1:0]         rdata
);

    localparam int LW = W / NBE;

    (* ram_style = "block" *) logic [W-1:0] mem [D];

    always_ff @(posedge clk) begin
        rdata <= mem[raddr];
        for (int i = 0; i < NBE; i++)
            if (we[i]) mem[waddr][i*LW +: LW] <= wdata[i*LW +: LW];
    end

endmodule
