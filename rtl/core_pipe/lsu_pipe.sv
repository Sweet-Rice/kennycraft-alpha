// Load/store unit of the pipelined core (rtl/core_pipe/core_pipe.sv): the
// coalescing LSU of rtl/core/lsu.sv (same groups, same order, same byte
// enables and data, see its header) with the bus request and the read data
// registered, so the SoC sees a request that comes straight from flops (no
// lane select reaches a slave's address) and a slave's read data reaches a
// flop before the byte extract. The multi-cycle core keeps rtl/core/lsu.sv.
//
// start (EX) loads the pending set with the active mask. While go (MEM walks
// the LSU) a priority encoder picks the lowest pending lane, nxt, and the
// group that goes with it (rtl/core/lsu.sv). The group is loaded into the
// request register q (address, byte enables, data, its lanes, cur = nxt and
// whether it is the last) whenever q is free or the bus accepts q in this
// cycle, and it leaves pending then. The bus sees q: bus_req = q valid and
// not held, bus_addr / bus_be / bus_wdata = q. The access happens once, on
// bus_req && bus_ready, as the decoder's contract wants. So the first group
// goes out one cycle after MEM starts and every later group back to back:
// G groups take G + 1 cycles, one more than rtl/core/lsu.sv.
//
// done is the cycle the bus accepts q's last group, idle no lane left for
// the bus and no read data in flight (none pending, q empty, no read
// accepted last cycle). idle comes from registers, done from bus_ready.
// hold (the core's vt_block, from q's address) keeps bus_req low; q waits
// with it.
//
// The core's MEM completion reads only registers, so the LSU also gives two
// of next cycle's values for it to register:
//   idle_nx  next cycle's idle: no lane pending, and q empty or a store's
//            last group accepted now (q empties and is not loaded again; a
//            load's accept puts read data in flight instead).
//   fast_nx  next cycle, the bus accepts the last group of a store whose
//            bus lanes all go to dmem or the framebuffer: the lanes left
//            pending are all in one dmem or framebuffer word (they are the
//            group q loads now) and none of the store's bus lanes was outside
//            dmem and the framebuffer (nc). rtl/soc/decoder.sv answers
//            ready = req for both and hold never stops them, so such a store
//            loads one group per cycle and the bus accepts each the cycle
//            after. fast_nx reads the address registers and pending, not the
//            priority encoder.
//
// Loads. The bus returns read data the cycle after an access is accepted;
// rdata_q registers it, so the data reaches the lanes two cycles after the
// accept (ld_cap marks the group's lanes then): G groups of a load take
// G + 3 MEM cycles, two more than rtl/core/lsu.sv. ld_value[i] is lane i's
// byte, halfword or word of rdata_q at lane i's own address, extended per
// funct3. The addresses are core_pipe's MEM-stage registers, stable until
// the load's last data has arrived (MEM holds the load until idle).
//
// Timing. bus_ready reaches pending, q's load enable and the load-capture
// registers; the group logic needs only pending and the address registers.
// bus_rdata (the decoder's region mux of the slaves' outputs) ends at
// rdata_q; the extract and extend start there.
module lsu_pipe
    import kc_isa_pkg::*;
#(
    parameter int LANES = 1
) (
    input  logic              clk,
    input  logic              rst,

    input  logic              start,
    input  logic [LANES-1:0]  active,
    input  logic              go,
    input  logic              hold,
    input  logic              is_store,
    input  logic [2:0]        funct3,
    input  logic [31:0]       addr  [LANES],
    input  logic [31:0]       rs2   [LANES],
    output logic              done,

    // Lanes the bus never serves (the dmem window lanes, which
    // rtl/core_pipe/win_lsu.sv serves), from the same address registers.
    input  logic [LANES-1:0]  skip,
    output logic              idle,
    output logic              idle_nx,
    output logic              fast_nx,

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

    // ------------------------------------------------------------------
    // Per lane: region class, byte enables and replicated store data
    // ------------------------------------------------------------------
    logic [LANES-1:0] coal;
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

    // eq[c][j]: lane j's access can ride on lane c's (rtl/core/lsu.sv)
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
    // Sequencer: the next group, loaded into q
    // ------------------------------------------------------------------
    logic [LANES-1:0] pending, pend, nxt_bit, group;
    logic [LW-1:0]    nxt;
    logic             merge, accept, load;

    assign pend = pending & ~skip;

    always_comb begin
        nxt = '0;
        for (int i = LANES - 1; i >= 0; i--)
            if (pend[i]) nxt = LW'(i);
    end

    assign nxt_bit = LANES'(1) << nxt;
    assign merge   = (pend & mmio) == '0;
    assign group   = merge ? (pend & eq[nxt]) : nxt_bit;

    // The next group's byte enables (OR of its lanes') and data (each byte
    // from the highest lane in the group that writes it)
    logic [3:0]  g_be;
    logic [31:0] g_wdata;

    always_comb begin
        g_be    = '0;
        g_wdata = wd_l[nxt];
        for (int i = 0; i < LANES; i++)
            if (group[i]) begin
                g_be = g_be | be_l[i];
                for (int k = 0; k < 4; k++)
                    if (be_l[i][k]) g_wdata[k*8 +: 8] = wd_l[i][k*8 +: 8];
            end
    end

    // ------------------------------------------------------------------
    // Request register q: the access on the bus
    // ------------------------------------------------------------------
    logic             q_v, q_last, nc, one;
    logic [LANES-1:0] q_group;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [LW-1:0]    cur;       // q's lowest lane (testbench monitors)
    /* verilator lint_on UNUSEDSIGNAL */
    logic [31:0]      q_addr, q_wdata;
    logic [3:0]       q_be;
    logic             fl_v;      // a read was accepted last cycle: data in flight

    assign bus_req   = q_v && !hold;
    assign bus_we    = is_store;
    assign bus_addr  = q_addr;
    assign bus_be    = q_be;
    assign bus_wdata = q_wdata;

    assign accept  = bus_req && bus_ready;
    assign load    = go && (!q_v || accept);
    assign done    = accept && q_last;
    assign idle    = (pend == '0) && !q_v && !fl_v;
    assign idle_nx = (pend == '0) && (!q_v || (accept && is_store));

    always_comb begin
        one = (pend != '0);
        for (int i = 0; i < LANES; i++)
            if (pend[i] && ((pend & ~eq[i]) != '0)) one = 1'b0;
    end

    assign fast_nx = is_store && go && !nc && ((pend & ~coal) == '0) && one;

    always_ff @(posedge clk) begin
        if (rst) begin
            pending <= '0;
            q_v     <= 1'b0;
            nc      <= 1'b0;
        end else begin
            if (start)     pending <= active;
            else if (load) pending <= pending & ~group;
            if (load)        q_v <= (pend != '0);
            else if (accept) q_v <= 1'b0;
            if (start)                     nc <= 1'b0;
            else if ((pend & ~coal) != '0) nc <= 1'b1;
        end
        if (load) begin
            q_addr  <= addr[nxt];
            q_be    <= g_be;
            q_wdata <= g_wdata;
            q_group <= group;
            q_last  <= (pend & ~group) == '0;
            cur     <= nxt;
        end
    end

    // ------------------------------------------------------------------
    // Load return: q's group's data in bus_rdata the cycle after its access
    // (fl), in rdata_q the cycle after that (ld_cap)
    // ------------------------------------------------------------------
    logic [LANES-1:0] fl_q, cap_q;
    logic [31:0]      rdata_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            fl_v  <= 1'b0;
            fl_q  <= '0;
            cap_q <= '0;
        end else begin
            fl_v  <= accept && !is_store;
            fl_q  <= (accept && !is_store) ? q_group : '0;
            cap_q <= fl_q;
        end
        rdata_q <= bus_rdata;
    end

    assign ld_cap = cap_q;

    for (genvar i = 0; i < LANES; i++) begin : g_ld
        logic [7:0]  byte_v;
        logic [15:0] half_v;

        assign byte_v = rdata_q[addr[i][1:0]*8 +: 8];
        assign half_v = addr[i][1] ? rdata_q[31:16] : rdata_q[15:0];

        always_comb begin
            unique case (funct3)
                F3_LB:   ld_value[i] = {{24{byte_v[7]}}, byte_v};
                F3_LBU:  ld_value[i] = {24'b0, byte_v};
                F3_LH:   ld_value[i] = {{16{half_v[15]}}, half_v};
                F3_LHU:  ld_value[i] = {16'b0, half_v};
                default: ld_value[i] = rdata_q;   // LW
            endcase
        end
    end

endmodule
