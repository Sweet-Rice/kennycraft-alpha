// D-cache for the DDR3 region 0x8 (HAS_DDR_MEM = 1): 32 KB, direct-mapped,
// write-back, write-allocate, 16-byte lines (one 128-bit MIG beat).
//
// Bus side: the decoder's handshake (rtl/soc/decoder.sv). req is held until
// ready; the access happens in the req && ready cycle; load data is valid the
// cycle after. addr is the DDR3 byte address (bus address [27:0]):
// index = addr[14:4] (2,048 lines), tag = addr[27:15].
//
//   cycle 0  req: the data and tag BRAMs read the line at the index
//   cycle 1  look: tag compare. Hit: ready; a store writes its bytes into the
//            data BRAM and marks the line dirty; a load's word is on rdata
//            the next cycle (the BRAM reads the same line again in cycle 1).
//            Miss: a dirty victim is copied to wb and written back, then the
//            line is read, written into the BRAMs (clean) and the access
//            starts over at cycle 0.
// So a hit costs 2 cycles (ready in the second), a clean miss 2 + the DDR3
// read + 2, a dirty miss adds the write-back's issue.
//
// Reset clears every tag (valid = 0), one line per cycle (2,048 cycles); req
// waits for it. Line port: see rtl/soc/line_arb.sv.
module dcache (
    input  logic         clk,
    input  logic         rst,

    input  logic         req,
    input  logic         we,
    input  logic [27:0]  addr,
    input  logic [3:0]   be,
    input  logic [31:0]  wdata,
    output logic         ready,
    output logic [31:0]  rdata,

    output logic         lp_req,
    output logic         lp_we,
    output logic [27:4]  lp_addr,
    output logic [127:0] lp_wdata,
    input  logic         lp_gnt,
    input  logic         lp_valid,
    input  logic [127:0] lp_rdata
);

    localparam int LINES = 2048;
    localparam int IW    = 11;      // index bits, addr[14:4]
    localparam int TW    = 13;      // tag bits, addr[27:15]

    typedef enum logic [2:0] {S_INIT, S_IDLE, S_LOOK, S_WB, S_RF, S_RFV, S_RFW} state_t;
    state_t st;

    logic [IW-1:0] init_idx;
    logic [IW-1:0] idx;
    logic [TW-1:0] tag;
    assign idx = addr[14:4];
    assign tag = addr[27:15];

    // Tag entry {valid, dirty, tag}
    logic          t_we;
    logic [IW-1:0] t_addr;
    logic [TW+1:0] t_wdata, t_rdata;
    logic [15:0]   d_we;
    logic [127:0]  d_wdata, d_rdata;

    memory_arr #(.W(TW + 2), .D(LINES), .NBE(1)) u_tag (
        .clk, .we(t_we), .addr(t_addr), .wdata(t_wdata), .rdata(t_rdata)
    );
    memory_arr #(.W(128), .D(LINES), .NBE(16)) u_data (
        .clk, .we(d_we), .addr(idx), .wdata(d_wdata), .rdata(d_rdata)
    );

    logic hit, dirty;
    assign hit   = t_rdata[TW+1] && (t_rdata[TW-1:0] == tag);
    assign dirty = t_rdata[TW+1] && t_rdata[TW];

    assign ready = (st == S_LOOK) && req && hit;

    logic [127:0] wb;
    logic [TW-1:0] wb_tag;
    logic [1:0]   word_q;

    assign t_addr = (st == S_INIT) ? init_idx : idx;

    always_comb begin
        t_we    = '0;
        t_wdata = '0;
        d_we    = '0;
        d_wdata = {4{wdata}};
        unique case (st)
            S_INIT: t_we = 1'b1;
            S_LOOK: if (req && hit && we) begin
                t_we = 1'b1;
                t_wdata = {1'b1, 1'b1, tag};
                d_we    = 16'(be) << (4 * addr[3:2]);
            end
            S_RFW: begin
                t_we = 1'b1;
                t_wdata = {1'b1, 1'b0, tag};
                d_we    = '1;
                d_wdata = wb;
            end
            default: ;
        endcase
    end

    assign lp_req   = (st == S_WB) || (st == S_RF);
    assign lp_we    = (st == S_WB);
    assign lp_addr  = (st == S_WB) ? {wb_tag, idx} : addr[27:4];
    assign lp_wdata = wb;

    // A load's word: the data BRAM reads the accepted line again in the
    // ready cycle, so its output holds it the cycle after.
    assign rdata = d_rdata[word_q*32 +: 32];

    always_ff @(posedge clk) begin
        if (rst) begin
            st       <= S_INIT;
            init_idx <= '0;
        end else begin
            unique case (st)
                S_INIT: begin
                    init_idx <= init_idx + 1'b1;
                    if (init_idx == IW'(LINES - 1)) st <= S_IDLE;
                end
                S_IDLE: if (req) st <= S_LOOK;
                S_LOOK: begin
                    if (!req || hit) st <= S_IDLE;
                    else if (dirty)  st <= S_WB;
                    else             st <= S_RF;
                end
                S_WB:  if (lp_gnt) st <= S_RF;
                S_RF:  if (lp_gnt) st <= S_RFV;
                S_RFV: if (lp_valid) st <= S_RFW;
                S_RFW: st <= S_IDLE;
                default: st <= S_IDLE;
            endcase
        end
        if (st == S_LOOK) begin
            wb     <= d_rdata;
            wb_tag <= t_rdata[TW-1:0];
        end
        if (st == S_RFV && lp_valid) wb <= lp_rdata;
        if (ready) word_q <= addr[3:2];
    end

    /* verilator lint_off UNUSEDSIGNAL */
    logic unused;
    /* verilator lint_on UNUSEDSIGNAL */
    assign unused = ^addr[1:0];

endmodule
