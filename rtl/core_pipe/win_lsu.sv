// Lane-parallel access to the dmem window (kc_isa_pkg DWIN_*, rtl/mem/
// dmem_win.sv) for core_pipe's MEM stage, next to the bus LSU (rtl/core/
// lsu.sv), which skips the window lanes.
//
// start (EX, as the bus LSU's) loads pending with the active lanes whose
// address is in the window. While go (MEM holds a load or store with an
// active lane) the pending lanes are served in one of two modes, chosen at
// start from EX's addresses (ex_addr):
//
//   fast: every active window lane i is in bank DWIN_BANKS - 1 - i, the bank
//   of its own crt0 stack (lane i's 1 KB stack ends at 0x8000 - 1024 i), so
//   no two lanes share a bank. Every pending lane is served in MEM's first
//   cycle: bank DWIN_BANKS - 1 - i takes lane i's word, its store bytes and
//   its byte enables straight from MEM's address and store-data registers.
//   slow: anything else. Each MEM cycle picks the lanes to serve (S), and
//   their bank accesses happen in the next cycle (A) from registers: each
//   bank takes the word of its lowest pending lane, every pending lane on
//   that word is served, and a lane on another word of the same bank waits
//   for a later S. So a slow load or store takes one cycle more than the
//   words its busiest bank serves.
//
// served[i]: lane i's bank access happens this cycle (a load's value[i] is
// valid). fin (a register, so MEM's completion, core_pipe m_done, never sees
// the bank resolution) is high when the window part ends this cycle: from
// start in fast mode (or with no window lane), else in the A cycle of the
// last served lanes (the S cycle before left no pending lane).
//
// sb[i][j]: lanes i and j are both in the window and in the same bank;
// conf[i][j]: sb and different words. start computes both from ex_addr. In
// S a pending lane is served unless it conflicts with the lowest pending
// lane of its bank (lo: the bank-word rule, without the address compare).
//
// Equivalence with one access per lane in ascending lane order: lanes on
// different words never interact, and lanes on the same word are served in
// the same cycle with, for stores, each byte from the highest lane that
// writes it (as in rtl/core/lsu.sv). The window holds no MMIO, so no access
// crosses an MMIO access; the window is its own memory, so the bus LSU's
// lanes and these never touch the same word. A slow store's last writes land
// at the end of its A cycle, before the next instruction's MEM, and a slow
// load reads in its A cycle, so window accesses stay in program order.
//
// Loads. The banks read asynchronously: value[i] is lane i's byte, halfword
// or word from bank addr[12:10], extended per funct3, valid while served[i].
//
// Timing. The bank address is always a register (a_addr): at start lane
// DWIN_BANKS - 1 - b's word, the fast mode's; after that S's pick. The load
// path is its fanout to the LUT RAMs, the read, the bank select by MEM's
// address register and the extension. The write enables and data are the
// fast mode's (MEM's registers through the byte enable decode) or S's
// registered pick, selected by the fast register. S runs on registers only
// (pending, sb, conf and the MEM-stage registers) into registers. ex_addr
// feeds only sb, conf, pending, fast, fin's start value and a_addr.
module win_lsu
    import kc_isa_pkg::*;
#(
    parameter int LANES = 1
) (
    input  logic              clk,
    input  logic              rst,

    input  logic              start,
    input  logic [LANES-1:0]  active,
    input  logic [31:0]       ex_addr [LANES],   // EX: the addresses start loads
    input  logic              go,
    input  logic              is_store,
    input  logic [2:0]        funct3,
    input  logic [31:0]       addr  [LANES],
    input  logic [31:0]       rs2   [LANES],

    output logic [LANES-1:0]  ex_win,     // EX: lane's ex_addr is in the window
    output logic [LANES-1:0]  win,        // lane's address is in the window
    output logic [LANES-1:0]  served,
    output logic              fin,        // register
    output logic [31:0]       value [LANES],

    output logic [3:0]        b_we    [DWIN_BANKS],
    output logic [7:0]        b_addr  [DWIN_BANKS],
    output logic [31:0]       b_wdata [DWIN_BANKS],
    input  logic [31:0]       b_rdata [DWIN_BANKS]
);

    logic [LANES-1:0] pending, pend_go, need, lo, blk, rem, srv_s, a_srv, ex_own;
    logic [LANES-1:0] sb_ex [LANES], conf_ex [LANES];
    logic [LANES-1:0] sb    [LANES], conf    [LANES];
    logic             fast, fast_ex;
    logic [2:0]       bank [LANES];
    logic [7:0]       idx  [LANES];
    logic [3:0]       be_l [LANES];
    logic [31:0]      wd_l [LANES];
    logic [7:0]       s_addr  [DWIN_BANKS], a_addr  [DWIN_BANKS], f_addr  [DWIN_BANKS];
    logic [3:0]       s_we    [DWIN_BANKS], a_we    [DWIN_BANKS], f_we    [DWIN_BANKS];
    logic [31:0]      s_wdata [DWIN_BANKS], a_wdata [DWIN_BANKS], f_wdata [DWIN_BANKS];

    for (genvar i = 0; i < LANES; i++) begin : g_lane
        assign win[i]     = is_dwin(addr[i]);
        assign pend_go[i] = go && pending[i];
        assign need[i]    = pend_go[i] && !fast;
        assign bank[i]    = addr[i][12:10];
        assign idx[i]     = addr[i][9:2];

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

    // ------------------------------------------------------------------
    // EX: window lanes, the fast mode check (each active window lane in its
    // own stack's bank), and the same-bank and conflict matrices
    // (symmetric, so each pair is compared once)
    // ------------------------------------------------------------------
    for (genvar i = 0; i < LANES; i++) begin : g_ex_win
        assign ex_win[i] = is_dwin(ex_addr[i]);
        assign ex_own[i] = !(active[i] && ex_win[i]) ||
                           (ex_addr[i][12:10] == 3'(DWIN_BANKS - 1 - i));
    end
    assign fast_ex = &ex_own;

    for (genvar i = 0; i < LANES; i++) begin : g_conf_i
        assign sb_ex[i][i]   = 1'b0;
        assign conf_ex[i][i] = 1'b0;
        for (genvar j = i + 1; j < LANES; j++) begin : g_conf_j
            logic sb_p, conf_p;
            assign sb_p          = ex_win[i] && ex_win[j] &&
                                   (ex_addr[i][12:10] == ex_addr[j][12:10]);
            assign conf_p        = sb_p && (ex_addr[i][9:2] != ex_addr[j][9:2]);
            assign sb_ex[i][j]   = sb_p;
            assign sb_ex[j][i]   = sb_p;
            assign conf_ex[i][j] = conf_p;
            assign conf_ex[j][i] = conf_p;
        end
    end

    // ------------------------------------------------------------------
    // S (slow mode): lo, the lowest pending lane of each bank, whose word
    // the bank takes. A pending lane that conflicts with it waits (blk, rem).
    // ------------------------------------------------------------------
    for (genvar i = 0; i < LANES; i++) begin : g_lo
        localparam logic [LANES-1:0] BELOW = LANES'((64'd1 << i) - 64'd1);
        assign lo[i] = need[i] && ((need & sb[i] & BELOW) == '0);
    end

    for (genvar i = 0; i < LANES; i++) begin : g_served
        assign blk[i]   = (lo & conf[i]) != '0;
        assign srv_s[i] = need[i] && !blk[i];
        assign rem[i]   = need[i] && blk[i];
    end

    // Each bank's word, and for stores the OR of the served lanes' byte
    // enables, each byte from the highest served lane that writes it
    always_comb begin
        for (int b = 0; b < DWIN_BANKS; b++) begin
            s_addr[b]  = '0;
            s_we[b]    = '0;
            s_wdata[b] = '0;
            for (int i = LANES - 1; i >= 0; i--)
                if (need[i] && bank[i] == 3'(b)) s_addr[b] = idx[i];
            for (int i = 0; i < LANES; i++)
                if (is_store && srv_s[i] && bank[i] == 3'(b)) begin
                    s_we[b] = s_we[b] | be_l[i];
                    for (int k = 0; k < 4; k++)
                        if (be_l[i][k]) s_wdata[b][k*8 +: 8] = wd_l[i][k*8 +: 8];
                end
        end
    end

    // ------------------------------------------------------------------
    // Fast mode: bank b takes its own lane's word (a_addr from start) and
    // that lane's store bytes
    // ------------------------------------------------------------------
    for (genvar b = 0; b < DWIN_BANKS; b++) begin : g_fast
        localparam int L = DWIN_BANKS - 1 - b;
        if (L < LANES) begin : g_own
            assign f_addr[b]  = ex_addr[L][9:2];
            assign f_we[b]    = (is_store && pend_go[L]) ? be_l[L] : 4'b0000;
            assign f_wdata[b] = wd_l[L];
        end else begin : g_none
            assign f_addr[b]  = '0;
            assign f_we[b]    = '0;
            assign f_wdata[b] = '0;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            pending <= '0;
            fast    <= 1'b1;
            fin     <= 1'b1;
            a_srv   <= '0;
            for (int b = 0; b < DWIN_BANKS; b++) a_we[b] <= '0;
        end else begin
            a_srv <= srv_s;
            a_we  <= s_we;
            if (start) begin
                pending <= active & ex_win;
                fast    <= fast_ex;
                fin     <= fast_ex;
            end else if (go) begin
                pending <= fast ? '0 : (pending & ~srv_s);
                if (!fast) fin <= (rem == '0);
            end
        end
        a_wdata <= s_wdata;
        for (int b = 0; b < DWIN_BANKS; b++)
            a_addr[b] <= start ? f_addr[b] : s_addr[b];
        if (start) begin
            sb   <= sb_ex;
            conf <= conf_ex;
        end
    end

    assign served = fast ? pend_go : a_srv;

    for (genvar b = 0; b < DWIN_BANKS; b++) begin : g_port
        assign b_addr[b]  = a_addr[b];
        assign b_we[b]    = fast ? f_we[b]    : a_we[b];
        assign b_wdata[b] = fast ? f_wdata[b] : a_wdata[b];
    end

    for (genvar i = 0; i < LANES; i++) begin : g_ld
        logic [31:0] word;
        logic [7:0]  byte_v;
        logic [15:0] half_v;

        assign word   = b_rdata[bank[i]];
        assign byte_v = word[addr[i][1:0]*8 +: 8];
        assign half_v = addr[i][1] ? word[31:16] : word[15:0];

        always_comb begin
            unique case (funct3)
                F3_LB:   value[i] = {{24{byte_v[7]}}, byte_v};
                F3_LBU:  value[i] = {24'b0, byte_v};
                F3_LH:   value[i] = {{16{half_v[15]}}, half_v};
                F3_LHU:  value[i] = {16'b0, half_v};
                default: value[i] = word;   // LW
            endcase
        end
    end

endmodule
