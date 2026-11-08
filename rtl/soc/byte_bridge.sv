// Splits one 32-bit bus access into byte accesses for a byte-wide region
// (world, textures). Both sides use the same handshake: req is
// held until ready, the access happens once in the req && ready cycle, and
// read data is valid the cycle after.
//
// The enabled byte lanes go out lowest first at addresses {addr[AW-1:2], lane}.
// The word access is ready in the cycle its last byte is accepted, so its
// read data, assembled from every lane, is valid one cycle later like any
// other region. Disabled lanes read as 0. An LW costs four byte accesses.
module byte_bridge #(
    parameter int AW = 17
) (
    input  logic          clk,
    input  logic          rst,

    input  logic          req,
    input  logic          we,
    input  logic [AW-1:2] addr,
    input  logic [3:0]    be,
    input  logic [31:0]   wdata,
    output logic          ready,
    output logic [31:0]   rdata,

    output logic          b_req,
    output logic          b_we,
    output logic [AW-1:0] b_addr,
    output logic [7:0]    b_wdata,
    input  logic          b_ready,
    input  logic [7:0]    b_rdata
);

    logic [3:0]  done;       // lanes already accepted for the current access
    logic [3:0]  left;
    logic [1:0]  lane;
    logic        last;
    logic        cap_q;      // a byte read was accepted last cycle
    logic [1:0]  cap_lane_q;
    logic [31:0] collect;

    assign left = be & ~done;

    always_comb begin
        lane = 2'd0;
        for (int i = 3; i >= 0; i--)
            if (left[i]) lane = 2'(i);
    end

    // Accepting `lane` finishes the access when no higher lane is left.
    assign last = ((left >> lane) >> 1) == 4'b0;

    assign b_req   = req && (left != 4'b0);
    assign b_we    = we;
    assign b_addr  = {addr, lane};
    assign b_wdata = wdata[lane*8 +: 8];

    // be == 0 never happens from the LSU; accept it at once so the bus cannot hang.
    assign ready = req && ((b_ready && last) || (be == 4'b0));

    always_ff @(posedge clk) begin
        if (rst) begin
            done  <= '0;
            cap_q <= 1'b0;
        end else begin
            cap_q <= b_req && b_ready && !we;
            if (ready)                done <= '0;
            else if (b_req && b_ready) done <= done | (4'b1 << lane);
        end
        if (b_req && b_ready) cap_lane_q <= lane;
        if (req && done == 4'b0) collect <= '0;
        if (cap_q) collect[cap_lane_q*8 +: 8] <= b_rdata;
    end

    always_comb begin
        rdata = collect;
        if (cap_q) rdata[cap_lane_q*8 +: 8] = b_rdata;
    end

endmodule
