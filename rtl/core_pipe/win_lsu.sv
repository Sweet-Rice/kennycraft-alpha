// Lane-parallel access to the dmem window (kc_isa_pkg DWIN_*, rtl/mem/
// dmem_win.sv) for core_pipe's MEM stage, next to the bus LSU (rtl/core/
// lsu.sv), which skips the window lanes.
//
// start (EX, as the bus LSU's) loads pending with the active mask. While go
// (MEM holds a load or store with an active lane) every pending lane whose
// address is in the window (need) is a candidate. Each bank takes the word of
// its lowest needing lane, and every needing lane on that word is served this
// cycle; a lane on another word of the same bank waits for a later cycle.
// fin is high when no needing lane is left after this cycle.
//
// Equivalence with one access per lane in ascending lane order: lanes on
// different words never interact, and lanes on the same word are served in
// the same cycle with, for stores, each byte from the highest lane that
// writes it (as in rtl/core/lsu.sv). The window holds no MMIO, so no access
// crosses an MMIO access; the window is its own memory, so the bus LSU's
// lanes and these never touch the same word.
//
// Loads. The banks read asynchronously: value[i] is lane i's byte, halfword
// or word, extended per funct3, in the cycle the lane is served (served[i]).
//
// Timing. Everything here comes from registers: pending and the MEM-stage
// address and store-data registers. The bank address is an 8:1 mux selected
// by a priority encoder over the lanes' bank bits.
module win_lsu
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

    output logic [LANES-1:0]  win,        // lane's address is in the window
    output logic [LANES-1:0]  served,
    output logic              fin,
    output logic [31:0]       value [LANES],

    output logic [3:0]        b_we    [DWIN_BANKS],
    output logic [7:0]        b_addr  [DWIN_BANKS],
    output logic [31:0]       b_wdata [DWIN_BANKS],
    input  logic [31:0]       b_rdata [DWIN_BANKS]
);

    logic [LANES-1:0] pending, need;
    logic [2:0]       bank [LANES];
    logic [7:0]       idx  [LANES];
    logic [3:0]       be_l [LANES];
    logic [31:0]      wd_l [LANES];

    for (genvar i = 0; i < LANES; i++) begin : g_lane
        assign win[i]  = is_dwin(addr[i]);
        assign need[i] = go && pending[i] && win[i];
        assign bank[i] = addr[i][12:10];
        assign idx[i]  = addr[i][9:2];

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

    // Each bank's word: that of its lowest needing lane
    always_comb begin
        for (int b = 0; b < DWIN_BANKS; b++) begin
            b_addr[b] = '0;
            for (int i = LANES - 1; i >= 0; i--)
                if (need[i] && bank[i] == 3'(b)) b_addr[b] = idx[i];
        end
    end

    for (genvar i = 0; i < LANES; i++) begin : g_served
        assign served[i] = need[i] && (idx[i] == b_addr[bank[i]]);
    end

    assign fin = (need & ~served) == '0;

    // Stores: per bank, the OR of the served lanes' byte enables, each byte
    // from the highest served lane that writes it.
    always_comb begin
        for (int b = 0; b < DWIN_BANKS; b++) begin
            b_we[b]    = '0;
            b_wdata[b] = '0;
            for (int i = 0; i < LANES; i++)
                if (is_store && served[i] && bank[i] == 3'(b)) begin
                    b_we[b] = b_we[b] | be_l[i];
                    for (int k = 0; k < 4; k++)
                        if (be_l[i][k]) b_wdata[b][k*8 +: 8] = wd_l[i][k*8 +: 8];
                end
        end
    end

    always_ff @(posedge clk) begin
        if (rst)        pending <= '0;
        else if (start) pending <= active;
        else if (go)    pending <= pending & ~served;
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
