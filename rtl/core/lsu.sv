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
// register can take wdata[7:0] for any byte address.
//
// Framebuffer stores merge: the pending lanes whose address is in the same
// word as the current lane's, in the framebuffer region (0x4, a plain memory
// with byte enables), go out together as one access with the union of their
// byte enables; on a byte two lanes write, the highest lane's data wins, as it
// would one access after another. A pass of the render kernel (lanes 0-3 and
// 4-7 on two rows of four pixels) is two accesses instead of eight. Every
// other access (loads, dmem, MMIO, world) stays one per lane. World stores reach both
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
    logic [LANES-1:0] pending;
    logic [LW-1:0]    cur;
    logic             accept;

    always_comb begin
        cur = '0;
        for (int i = LANES - 1; i >= 0; i--)
            if (pending[i]) cur = LW'(i);
    end

    assign accept  = bus_req && bus_ready;

    // Lanes retired by this access: the current lane, plus, for a framebuffer
    // store, the other pending lanes in the same word.
    logic [LANES-1:0] group;
    logic             merge;
    assign merge = is_store && (addr[cur][31:28] == REG_FB);
    always_comb begin
        for (int i = 0; i < LANES; i++)
            group[i] = pending[i] && ((i == int'(cur)) ||
                                      (merge && (addr[i][31:2] == addr[cur][31:2])));
    end

    assign done = accept && ((pending & ~group) == '0);

    always_ff @(posedge clk) begin
        if (rst)          pending <= '0;
        else if (start)   pending <= active;
        else if (accept)  pending <= pending & ~group;
    end

    // ------------------------------------------------------------------
    // Bus side
    // ------------------------------------------------------------------
    logic [31:0] a;

    assign a = addr[cur];

    assign bus_req   = go;
    assign bus_we    = is_store;
    assign bus_addr  = a;

    // Each lane's byte enables and replicated data; the access ORs the group's
    // enables and takes each byte from the highest group lane that writes it.
    logic [3:0]  l_be    [LANES];
    logic [31:0] l_wdata [LANES];

    for (genvar i = 0; i < LANES; i++) begin : g_store
        always_comb begin
            unique case (funct3[1:0])
                2'b00: begin
                    l_be[i]    = 4'b0001 << addr[i][1:0];
                    l_wdata[i] = {4{rs2[i][7:0]}};
                end
                2'b01: begin
                    l_be[i]    = addr[i][1] ? 4'b1100 : 4'b0011;
                    l_wdata[i] = {2{rs2[i][15:0]}};
                end
                default: begin
                    l_be[i]    = 4'b1111;
                    l_wdata[i] = rs2[i];
                end
            endcase
        end
    end

    always_comb begin
        bus_be    = '0;
        bus_wdata = l_wdata[cur];
        for (int i = 0; i < LANES; i++) begin
            if (group[i]) begin
                bus_be = bus_be | l_be[i];
                for (int k = 0; k < 4; k++)
                    if (l_be[i][k]) bus_wdata[k*8 +: 8] = l_wdata[i][k*8 +: 8];   // ascending: highest wins
            end
        end
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
