// Load/store unit with word coalescing (Tai page, GPU Core, Lane-serial LSU;
// Tai_2 section 2, Loads / Stores / MMIO rows).
//
// start (the EX cycle of a load or store with at least one active lane and no
// misaligned active lane) loads the pending set with the active mask. While go
// is high (the core's MEM state) a priority encoder picks the lowest pending
// lane, cur, and the bus access serves the group of pending lanes that goes
// with it; each bus_req && bus_ready retires that group. done marks the
// accepting cycle of the last group. Inactive lanes make no access.
//
// Coalescing. When cur targets dmem or the framebuffer (word ports without
// side effects) and no pending lane targets MMIO, the group is every pending
// lane in the same physical word as cur: same region, same word index
// (addr[14:2] in dmem, which aliases every 32 KB; addr[16:2] in the
// framebuffer). Otherwise the group is cur alone, so MMIO, world, textures,
// imem, palette and unmapped addresses stay lane-serial, lowest lane first,
// one access per lane. Groups go out in ascending order of their lowest lane.
// That is architecturally the same as one access per lane in ascending order:
// two groups never share a physical word, and no access moves across an MMIO
// access (an FB_SWAP store changes which buffer later framebuffer stores
// reach).
//
// Stores. A group's byte enables are the OR of its lanes' and each byte's
// data comes from the highest lane in the group that writes it, so on equal
// bytes the highest active lane wins, as in lane order. A lane's own byte
// enables and data are replicated across the word (SB repeats the byte four
// times, SH the halfword twice), so a lone lane's access looks as it always
// did and a byte-wide slave or an MMIO register can take wdata[7:0] for any
// byte address. World stores reach both world copies through the SoC
// (world_remap, D17); the LSU issues one access.
//
// Loads. The bus returns read data the cycle after an access is accepted, which
// is the cycle the next group's address goes out, so G groups take G bus
// cycles plus one for the last group's data (the core's WB): G + 1 when every
// slave is ready at once. ld_cap marks the lanes whose word is in bus_rdata
// this cycle; ld_value[i] is lane i's byte, halfword or word of it at that
// lane's own address, extended per funct3.
//
// Timing. The group needs only registered state: pending and the addresses
// (the cores' MEM-stage address registers, stable while go is high). The
// pairwise word compare (eq) depends on the addresses alone, so it settles in
// parallel with the priority encoder; bus_ready reaches only pending and the
// load-capture registers.
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

    // Lanes the bus never serves (core_pipe: the dmem window lanes, which
    // rtl/core_pipe/win_lsu.sv serves; '0 on the multi-cycle core), from
    // the same address registers. idle: no lane left for the bus.
    input  logic [LANES-1:0]  skip,
    output logic              idle,

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
    output logic [31:0]       ld_value [LANES]
);

    localparam int LW = (LANES > 1) ? $clog2(LANES) : 1;

    for (genvar i = 0; i < LANES; i++) begin : g_mis
        assign misaligned[i] = is_misaligned(funct3, ex_addr_lo[i]);
    end

    // ------------------------------------------------------------------
    // Per lane: region class, byte enables and replicated store data
    // ------------------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */
    logic [LANES-1:0] coal;     // unused with LANES = 1: nothing to coalesce
    /* verilator lint_on UNUSEDSIGNAL */
    logic [LANES-1:0] mmio;
    logic [3:0]       be_l [LANES];
    logic [31:0]      wd_l [LANES];

    for (genvar i = 0; i < LANES; i++) begin : g_lane
        assign coal[i] = (addr[i][31:28] == REG_DMEM) || (addr[i][31:28] == REG_FB);
        assign mmio[i] = (addr[i][31:28] == REG_MMIO);

        always_comb begin
            unique case (funct3[1:0])
                2'b00: begin
                    be_l[i] = 4'b0001 << addr[i][1:0];
                    wd_l[i] = {4{rs2[i][7:0]}};
                end
                2'b01: begin
                    be_l[i] = addr[i][1] ? 4'b1100 : 4'b0011;
                    wd_l[i] = {2{rs2[i][15:0]}};
                end
                default: begin
                    be_l[i] = 4'b1111;
                    wd_l[i] = rs2[i];
                end
            endcase
        end
    end

    // eq[c][j]: lane j's access can ride on lane c's. Lane c itself always;
    // another lane when c is in a coalescable region and j is in the same
    // physical word of it (same region, so j is coalescable too).
    logic [LANES-1:0] eq [LANES];

    for (genvar c = 0; c < LANES; c++) begin : g_eq_c
        for (genvar j = 0; j < LANES; j++) begin : g_eq_j
            if (c == j) begin : g_self
                assign eq[c][j] = 1'b1;
            end else begin : g_pair
                assign eq[c][j] = coal[c] &&
                                  (addr[c][31:28] == addr[j][31:28]) &&
                                  (addr[c][14:2] == addr[j][14:2]) &&
                                  ((addr[c][31:28] == REG_DMEM) || (addr[c][16:15] == addr[j][16:15]));
            end
        end
    end

    // ------------------------------------------------------------------
    // Sequencer
    // ------------------------------------------------------------------
    logic [LANES-1:0] pending, pend, cur_bit, group;
    logic [LW-1:0]    cur;
    logic             merge, accept;

    assign pend = pending & ~skip;
    assign idle = (pend == '0);

    always_comb begin
        cur = '0;
        for (int i = LANES - 1; i >= 0; i--)
            if (pend[i]) cur = LW'(i);
    end

    assign cur_bit = LANES'(1) << cur;
    assign merge   = (pend & mmio) == '0;
    assign group   = merge ? (pend & eq[cur]) : cur_bit;
    assign accept  = bus_req && bus_ready;
    assign done    = accept && ((pend & ~group) == '0);

    always_ff @(posedge clk) begin
        if (rst)          pending <= '0;
        else if (start)   pending <= active;
        else if (accept)  pending <= pending & ~group;
    end

    // ------------------------------------------------------------------
    // Bus side: cur's address, the group's merged byte enables and data
    // ------------------------------------------------------------------
    assign bus_req  = go && !idle;
    assign bus_we   = is_store;
    assign bus_addr = addr[cur];

    // Ascending lane order: a higher lane's byte overwrites a lower one's.
    always_comb begin
        bus_be    = '0;
        bus_wdata = wd_l[cur];
        for (int i = 0; i < LANES; i++)
            if (group[i]) begin
                bus_be = bus_be | be_l[i];
                for (int k = 0; k < 4; k++)
                    if (be_l[i][k]) bus_wdata[k*8 +: 8] = wd_l[i][k*8 +: 8];
            end
    end

    // ------------------------------------------------------------------
    // Load return: the group and every lane's address bits of the access
    // in flight
    // ------------------------------------------------------------------
    logic [LANES-1:0] cap_q;
    logic [1:0]       cap_lo_q [LANES];

    always_ff @(posedge clk) begin
        if (rst) cap_q <= '0;
        else     cap_q <= (accept && !is_store) ? group : '0;
        if (accept)
            for (int i = 0; i < LANES; i++) cap_lo_q[i] <= addr[i][1:0];
    end

    assign ld_cap = cap_q;

    for (genvar i = 0; i < LANES; i++) begin : g_ld
        logic [7:0]  byte_v;
        logic [15:0] half_v;

        assign byte_v = bus_rdata[cap_lo_q[i]*8 +: 8];
        assign half_v = cap_lo_q[i][1] ? bus_rdata[31:16] : bus_rdata[15:0];

        always_comb begin
            unique case (funct3)
                F3_LB:   ld_value[i] = {{24{byte_v[7]}}, byte_v};
                F3_LBU:  ld_value[i] = {24'b0, byte_v};
                F3_LH:   ld_value[i] = {{16{half_v[15]}}, half_v};
                F3_LHU:  ld_value[i] = {16'b0, half_v};
                default: ld_value[i] = bus_rdata;   // LW
            endcase
        end
    end

endmodule
