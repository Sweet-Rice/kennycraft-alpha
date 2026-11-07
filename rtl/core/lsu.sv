// Lane-serial load/store unit (Tai page, GPU Core, Lane-serial LSU; Tai_2
// section 2, Loads / Stores / MMIO rows).
//
// start (the EX cycle of a load or store with at least one active lane and no
// misaligned active lane) loads the pending set with the active mask. While go
// is high (the core's MEM state) a priority encoder picks the lowest pending
// lane and drives its address, byte enables and store data on the bus; each
// bus_req && bus_ready retires that lane. Lanes go out in ascending order, so
// on equal store addresses the highest active lane wins, and inactive lanes
// make no access. done marks the accepting cycle of the last pending lane.
//
// The bus returns read data the cycle after an access is accepted, which is
// the cycle the next lane's address goes out, so N active lanes take N bus
// cycles plus one for the last lane's data (the core's WB): N + 1 when every
// slave is ready at once. ld_cap is a one-hot of the lane whose word is in
// bus_rdata this cycle and ld_value is that word, byte/halfword extended.
//
// Store side: byte enables and data replicated across the word (SB repeats the
// byte four times, SH the halfword twice), so a byte-wide slave or an MMIO
// register can take wdata[7:0] for any byte address. World stores reach both
// world copies through the SoC (world_remap, D17); the LSU issues one access.
module lsu
    import kc_isa_pkg::*;
#(
    parameter int LANES = 1
) (
    input  logic              clk,
    input  logic              rst,

    input  logic              start,
    input  logic [LANES-1:0]  active,
    input  logic              go,
    input  logic              is_store,
    input  logic [2:0]        funct3,
    input  logic [31:0]       addr  [LANES],
    input  logic [31:0]       rs2   [LANES],
    output logic              done,

    // Misaligned check for the EX cycle, per lane, on the address computed
    // there (Tai_2 section 1: LW/SW 4-aligned, LH/LHU/SH 2-aligned).
    input  logic [1:0]        ex_addr_lo [LANES],
    output logic [LANES-1:0]  misaligned,

    output logic              bus_req,
    output logic              bus_we,
    output logic [31:0]       bus_addr,
    output logic [3:0]        bus_be,
    output logic [31:0]       bus_wdata,
    input  logic              bus_ready,
    input  logic [31:0]       bus_rdata,

    output logic [LANES-1:0]  ld_cap,
    output logic [31:0]       ld_value
);

    localparam int LW = (LANES > 1) ? $clog2(LANES) : 1;

    for (genvar i = 0; i < LANES; i++) begin : g_mis
        assign misaligned[i] = is_misaligned(funct3, ex_addr_lo[i]);
    end

    // ------------------------------------------------------------------
    // Sequencer
    // ------------------------------------------------------------------
    logic [LANES-1:0] pending, cur_bit;
    logic [LW-1:0]    cur;
    logic             accept;

    always_comb begin
        cur = '0;
        for (int i = LANES - 1; i >= 0; i--)
            if (pending[i]) cur = LW'(i);
    end

    assign cur_bit = LANES'(1) << cur;
    assign accept  = bus_req && bus_ready;
    assign done    = accept && ((pending & ~cur_bit) == '0);

    always_ff @(posedge clk) begin
        if (rst)          pending <= '0;
        else if (start)   pending <= active;
        else if (accept)  pending <= pending & ~cur_bit;
    end

    // ------------------------------------------------------------------
    // Bus side
    // ------------------------------------------------------------------
    logic [31:0] a, d;

    assign a = addr[cur];
    assign d = rs2[cur];

    assign bus_req   = go;
    assign bus_we    = is_store;
    assign bus_addr  = a;

    always_comb begin
        unique case (funct3[1:0])
            2'b00: begin
                bus_be    = 4'b0001 << a[1:0];
                bus_wdata = {4{d[7:0]}};
            end
            2'b01: begin
                bus_be    = a[1] ? 4'b1100 : 4'b0011;
                bus_wdata = {2{d[15:0]}};
            end
            default: begin
                bus_be    = 4'b1111;
                bus_wdata = d;
            end
        endcase
    end

    // ------------------------------------------------------------------
    // Load return: capture lane and address bits of the access in flight
    // ------------------------------------------------------------------
    logic          cap_q;
    logic [LW-1:0] cap_lane_q;
    logic [1:0]    cap_lo_q;

    always_ff @(posedge clk) begin
        if (rst) cap_q <= 1'b0;
        else     cap_q <= accept && !is_store;
        if (accept) begin
            cap_lane_q <= cur;
            cap_lo_q   <= a[1:0];
        end
    end

    assign ld_cap = cap_q ? (LANES'(1) << cap_lane_q) : '0;

    logic [7:0]  byte_v;
    logic [15:0] half_v;

    assign byte_v = bus_rdata[cap_lo_q*8 +: 8];
    assign half_v = cap_lo_q[1] ? bus_rdata[31:16] : bus_rdata[15:0];

    always_comb begin
        unique case (funct3)
            F3_LB:   ld_value = {{24{byte_v[7]}}, byte_v};
            F3_LBU:  ld_value = {24'b0, byte_v};
            F3_LH:   ld_value = {{16{half_v[15]}}, half_v};
            F3_LHU:  ld_value = {16'b0, half_v};
            default: ld_value = bus_rdata;   // LW
        endcase
    end

endmodule
