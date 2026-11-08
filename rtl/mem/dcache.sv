// D-cache for the DDR3 region 0x8 (HAS_DDR_MEM = 1): 32 KB, direct-mapped,
// write-back, write-allocate, 16-byte lines (one 128-bit MIG beat).
//
// Bus side: the decoder's handshake (rtl/soc/decoder.sv). req is held until
// ready; the access happens in the req && ready cycle; load data is valid the
// cycle after. addr is the DDR3 byte address (bus address [27:0]):
// index = addr[14:4] (2,048 lines), tag = addr[27:15].
//
// The tag and data BRAMs are simple dual-port (rtl/mem/memory_sdp.sv): writes
// go to the request's index, reads come from rd_idx. In S_IDLE the read port
// takes pf_addr, the core's guess of the address its bus request register
// holds next cycle (rtl/core_pipe/lsu_pipe.sv), so a request whose line was
// read that way finds its tag and line on the BRAM outputs in its first
// cycle (pf_ok: rd_idx last cycle = its index):
//
//   hit   ready in the first cycle. A store writes its bytes into the data
//         BRAM and marks the line dirty; a load's word is registered and on
//         rdata the next cycle. So a hit costs 1 cycle.
//   miss  a dirty victim is copied to wb and written back, then the line is
//         read and written into the BRAMs (clean, S_RFW); the access is then
//         back in S_IDLE with its line on the read port (the refill's write
//         is forwarded, below) and hits.
//   !pf_ok  (the guess was wrong) S_RD reads the request's index, then
//         S_IDLE decides as above: 2 cycles for a hit.
//
// The read port is read-first: a read of the index written in the same cycle
// returns the old entry. The last cycle's write (index, tag word, data bytes)
// is registered and merged into the BRAM outputs when its index is the one
// read (t_eff, d_eff), so a request right behind a store or a refill of the
// same line sees it.
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

    // The likely address of next cycle's request (a hint, any value is safe)
    input  logic [14:4]  pf_addr,

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

    typedef enum logic [2:0] {S_INIT, S_IDLE, S_RD, S_WB, S_RF, S_RFV, S_RFW} state_t;
    state_t st;

    logic [IW-1:0] init_idx;
    logic [IW-1:0] idx;
    logic [TW-1:0] tag;
    assign idx = addr[14:4];
    assign tag = addr[27:15];

    // Tag entry {valid, dirty, tag}
    logic          t_we;
    logic [IW-1:0] t_waddr, rd_idx;
    logic [TW+1:0] t_wdata, t_rdata;
    logic [15:0]   d_we;
    logic [127:0]  d_wdata, d_rdata;

    assign t_waddr = (st == S_INIT) ? init_idx : idx;
    assign rd_idx  = (st == S_IDLE) ? pf_addr : idx;

    memory_sdp #(.W(TW + 2), .D(LINES), .NBE(1)) u_tag (
        .clk, .we(t_we), .waddr(t_waddr), .wdata(t_wdata), .raddr(rd_idx), .rdata(t_rdata)
    );
    memory_sdp #(.W(128), .D(LINES), .NBE(16)) u_data (
        .clk, .we(d_we), .waddr(idx), .wdata(d_wdata), .raddr(rd_idx), .rdata(d_rdata)
    );

    // Last cycle's read index and write, for pf_ok and the forwarding
    logic [IW-1:0] rd_idx_q, w_idx_q;
    logic          t_we_q;
    logic [TW+1:0] t_wdata_q;
    logic [15:0]   d_we_q;
    logic [127:0]  d_wdata_q;
    logic          col;
    logic [TW+1:0] t_eff;
    logic [127:0]  d_eff;

    assign col   = (w_idx_q == rd_idx_q);
    assign t_eff = (col && t_we_q) ? t_wdata_q : t_rdata;
    always_comb begin
        for (int b = 0; b < 16; b++)
            d_eff[b*8 +: 8] = (col && d_we_q[b]) ? d_wdata_q[b*8 +: 8] : d_rdata[b*8 +: 8];
    end

    logic pf_ok, hit, dirty;
    assign pf_ok = (st == S_IDLE) && (rd_idx_q == idx);
    assign hit   = t_eff[TW+1] && (t_eff[TW-1:0] == tag);
    assign dirty = t_eff[TW+1] && t_eff[TW];

    assign ready = req && pf_ok && hit;

    logic [127:0]  wb;
    logic [TW-1:0] wb_tag;
    logic [31:0]   rdata_q;

    always_comb begin
        t_we    = '0;
        t_wdata = '0;
        d_we    = '0;
        d_wdata = {4{wdata}};
        unique case (st)
            S_INIT: t_we = 1'b1;
            S_IDLE: if (ready && we) begin
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

    assign rdata = rdata_q;

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
                S_IDLE: if (req) begin
                    if (!pf_ok)      st <= S_RD;
                    else if (!hit)   st <= dirty ? S_WB : S_RF;
                end
                S_RD:  st <= S_IDLE;
                S_WB:  if (lp_gnt) st <= S_RF;
                S_RF:  if (lp_gnt) st <= S_RFV;
                S_RFV: if (lp_valid) st <= S_RFW;
                S_RFW: st <= S_IDLE;
                default: st <= S_IDLE;
            endcase
        end
        rd_idx_q  <= rd_idx;
        w_idx_q   <= t_waddr;
        t_we_q    <= t_we;
        t_wdata_q <= t_wdata;
        d_we_q    <= d_we;
        d_wdata_q <= d_wdata;
        if (st == S_IDLE) begin
            wb     <= d_eff;
            wb_tag <= t_eff[TW-1:0];
        end
        if (st == S_RFV && lp_valid) wb <= lp_rdata;
        if (ready) rdata_q <= d_eff[addr[3:2]*32 +: 32];
    end

    /* verilator lint_off UNUSEDSIGNAL */
    logic unused;
    /* verilator lint_on UNUSEDSIGNAL */
    assign unused = ^addr[1:0];

endmodule
