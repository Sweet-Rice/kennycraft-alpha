// Chunk copy engine and the DDR3 chunk MMIO registers (D14, Shared page,
// Interfaces: MMIO 0x2C..0x3C and Chunks). Runs on the 50 MHz core clock.
//
// MMIO slice (driven by rtl/soc/mmio.sv for offsets 0x2C..0x3C):
//   0x2C DDR_STATUS  R    bit 0 calibrated, bit 1 busy, bit 2 queue full
//   0x30 CHUNK_CMD   W    bit 31 op (0 LOAD, 1 STORE), 15:8 cz, 7:0 cx.
//                         Queue depth 8; a write while full raises reg_stall
//                         until there is room. Reads return 0.
//   0x34 CHUNK_DONE  R    finished commands, wraps at 2^32
//   0x38 SLOT_VALID  R/W  bit s = slot s (s = sz * 4 + sx) holds a chunk
//   0x3C WIN_ORIGIN  R/W  bits 5:0 x, 13:8 z (window corner mod 64)
// A write happens on the edge where reg_en & reg_we & !reg_stall. reg_rdata is
// combinational and reads have no side effects.
// Commands run one at a time, in order. CHUNK_DONE counts a LOAD once all
// 8,192 blocks are in the world, and a STORE once the whole slot has been read
// out (the slot may then be reused); the STORE's last beats reach DDR3 through
// ddr_bridge right after, ahead of any later command's DDR3 access.
//
// DDR3 chunk format (only this engine reads or writes it): chunk (cx, cz) is
// 4096 bytes at (cz * 256 + cx) * 4096. Block i = (y * 16 + z) * 16 + x
// (y-major, then z, then x) is the nibble at byte i / 2, low nibble for even i.
// So 128-bit beat b holds blocks 32b .. 32b + 31, block 32b + n in bits
// [4n + 3 : 4n].
//
// World port: one physical address for both world_mem copies (copy n serves
// VTRACE lanes 4n..4n+3).
//   LOAD  writes block i of chunk (cx, cz) to {y, cz[1:0], z, cx[1:0], x}
//         in every copy (eng_we), one block per cycle.
//   STORE reads the same addresses from copy 0 (eng_re, data on eng_rdata one
//         cycle later) and writes the beats back to DDR3.
// The engine only drives eng_we / eng_re in a cycle where vtrace_busy and
// core_world_req are both 0, so the top level gives port A of each copy to
// VTRACE, then the core, then the engine. It bypasses world_remap.
//
// RD_BUF = 1 (the pipelined core's builds, 100 MHz) takes LOAD beats into a
// two-entry beat buffer before writing them out, so the rdata FIFO's read
// enable (rd_ready) comes from registers instead of grant, i.e. the core's
// world request decode: a beat is popped into a free entry the cycle the
// FIFO shows it, and nibbles are written from the oldest full entry. The
// order and data of the world writes are unchanged; each LOAD writes its
// first block one cycle later than with RD_BUF = 0.
module chunk_engine #(
  parameter int QDEPTH = 8,
  parameter bit RD_BUF = 1'b0
) (
  input  logic         clk,
  input  logic         rst,
  // MMIO slice
  input  logic         reg_en,
  input  logic         reg_we,
  input  logic [5:0]   reg_off,
  input  logic [31:0]  reg_wdata,
  output logic [31:0]  reg_rdata,
  output logic         reg_stall,
  // window state for world_remap
  output logic [15:0]  slot_valid,
  output logic [5:0]   win_x,
  output logic [5:0]   win_z,
  // physical world port
  input  logic         vtrace_busy,
  input  logic         core_world_req,
  output logic         eng_we,
  output logic         eng_re,
  output logic [16:0]  eng_addr,
  output logic [3:0]   eng_wdata,
  input  logic [3:0]   eng_rdata,
  // ddr_bridge (core clock side)
  input  logic         calib,
  output logic         cmd_valid,
  input  logic         cmd_ready,
  output logic         cmd_store,
  output logic [15:0]  cmd_chunk,
  output logic         wr_valid,
  input  logic         wr_ready,
  output logic [127:0] wr_data,
  input  logic         rd_valid,
  output logic         rd_ready,
  input  logic [127:0] rd_data
);
  localparam logic [5:0] OFF_STATUS = 6'h2C;
  localparam logic [5:0] OFF_CMD    = 6'h30;
  localparam logic [5:0] OFF_DONE   = 6'h34;
  localparam logic [5:0] OFF_VALID  = 6'h38;
  localparam logic [5:0] OFF_ORIGIN = 6'h3C;
  localparam int QW = $clog2(QDEPTH);

  // ---- command queue {op, cz, cx} ----
  logic [16:0] q_mem [QDEPTH];
  logic [QW:0] q_count;
  logic [QW-1:0] q_head, q_tail;
  logic q_full, q_empty, q_push, q_pop;

  assign q_full  = (q_count == (QW+1)'(QDEPTH));
  assign q_empty = (q_count == '0);

  logic wr_access;
  assign wr_access = reg_en & reg_we & ~reg_stall;
  assign reg_stall = reg_en & reg_we & (reg_off == OFF_CMD) & q_full;
  assign q_push    = wr_access & (reg_off == OFF_CMD);

  always_ff @(posedge clk) begin
    if (rst) begin
      q_count <= '0;
      q_head  <= '0;
      q_tail  <= '0;
    end else begin
      if (q_push) begin
        q_mem[q_tail] <= {reg_wdata[31], reg_wdata[15:0]};
        q_tail        <= q_tail + 1'b1;
      end
      if (q_pop) q_head <= q_head + 1'b1;
      q_count <= q_count + (QW+1)'(q_push) - (QW+1)'(q_pop);
    end
  end

  // ---- registers ----
  logic [31:0] chunk_done;

  always_ff @(posedge clk) begin
    if (rst) begin
      slot_valid <= '0;
      win_x      <= '0;
      win_z      <= '0;
    end else if (wr_access) begin
      if (reg_off == OFF_VALID) slot_valid <= reg_wdata[15:0];
      if (reg_off == OFF_ORIGIN) begin
        win_x <= reg_wdata[5:0];
        win_z <= reg_wdata[13:8];
      end
    end
  end

  // ---- copy FSM ----
  typedef enum logic [2:0] {S_IDLE, S_ISSUE, S_LOAD, S_STORE, S_DONE} state_t;
  state_t      st;
  logic        cur_store;
  logic [7:0]  cur_cx, cur_cz;
  logic [7:0]  beat;        // current 128-bit beat
  logic [4:0]  nib;         // LOAD: next nibble to write; STORE: next nibble to read
  logic [5:0]  got;         // STORE: nibbles captured for this beat
  logic        re_d;        // STORE: a read was issued last cycle
  logic [4:0]  re_nib_d;
  logic [127:0] sbuf;
  logic        issued_last; // STORE: nibble 31 of this beat has been issued

  logic grant;
  assign grant = ~vtrace_busy & ~core_world_req;

  assign q_pop     = (st == S_IDLE) & ~q_empty & calib;
  assign cmd_valid = (st == S_ISSUE);
  assign cmd_store = cur_store;
  assign cmd_chunk = {cur_cz, cur_cx};
  // block index i = {beat, nib} = {y[4:0], z[3:0], x[3:0]}
  assign eng_addr  = {beat[7:3], cur_cz[1:0], beat[2:0], nib[4], cur_cx[1:0], nib[3:0]};
  assign eng_re    = (st == S_STORE) & grant & ~issued_last;
  assign wr_valid  = (st == S_STORE) & got[5];
  assign wr_data   = sbuf;

  if (!RD_BUF) begin : g_rd_direct
    assign eng_wdata = rd_data[{nib, 2'b00} +: 4];
    assign eng_we    = (st == S_LOAD) & rd_valid & grant;
    assign rd_ready  = eng_we & (nib == 5'd31);
  end else begin : g_rd_buf
    logic [127:0] bbuf [2];   // beat buffer entries
    logic [1:0]   bv;         // entry holds a beat not yet written out
    logic         bfill;      // entry the next beat goes to
    logic         bcur;       // entry being written out
    logic         bpop;

    assign bpop      = (st == S_LOAD) & rd_valid & ~bv[bfill];
    assign rd_ready  = bpop;
    assign eng_wdata = bbuf[bcur][{nib, 2'b00} +: 4];
    assign eng_we    = (st == S_LOAD) & bv[bcur] & grant;

    always_ff @(posedge clk) begin
      if (rst) begin
        bv    <= '0;
        bfill <= 1'b0;
        bcur  <= 1'b0;
      end else begin
        if (bpop) begin
          bv[bfill] <= 1'b1;
          bfill     <= ~bfill;
        end
        if (eng_we && nib == 5'd31) begin
          bv[bcur] <= 1'b0;
          bcur     <= ~bcur;
        end
      end
      if (bpop) bbuf[bfill] <= rd_data;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      st          <= S_IDLE;
      cur_store   <= 1'b0;
      cur_cx      <= '0;
      cur_cz      <= '0;
      beat        <= '0;
      nib         <= '0;
      got         <= '0;
      re_d        <= 1'b0;
      re_nib_d    <= '0;
      issued_last <= 1'b0;
      sbuf        <= '0;
      chunk_done  <= '0;
    end else begin
      re_d     <= eng_re;
      re_nib_d <= nib;
      case (st)
        S_IDLE: if (q_pop) begin
          cur_store   <= q_mem[q_head][16];
          cur_cz      <= q_mem[q_head][15:8];
          cur_cx      <= q_mem[q_head][7:0];
          beat        <= '0;
          nib         <= '0;
          got         <= '0;
          issued_last <= 1'b0;
          st          <= S_ISSUE;
        end
        S_ISSUE: if (cmd_ready) st <= cur_store ? S_STORE : S_LOAD;
        S_LOAD: if (eng_we) begin
          nib <= nib + 5'd1;
          if (nib == 5'd31) begin
            beat <= beat + 8'd1;
            if (beat == 8'hFF) st <= S_DONE;
          end
        end
        S_STORE: begin
          if (eng_re) begin
            if (nib == 5'd31) issued_last <= 1'b1;
            else              nib <= nib + 5'd1;
          end
          if (re_d) begin
            sbuf[{re_nib_d, 2'b00} +: 4] <= eng_rdata;
            got <= got + 6'd1;
          end
          if (wr_valid & wr_ready) begin
            got         <= '0;
            nib         <= '0;
            issued_last <= 1'b0;
            beat        <= beat + 8'd1;
            if (beat == 8'hFF) st <= S_DONE;
          end
        end
        S_DONE: begin
          chunk_done <= chunk_done + 32'd1;
          st         <= S_IDLE;
        end
        default: st <= S_IDLE;
      endcase
    end
  end

  // ---- read mux ----
  logic busy;
  assign busy = (st != S_IDLE) | ~q_empty;

  always_comb begin
    unique case (reg_off)
      OFF_STATUS: reg_rdata = {29'd0, q_full, busy, calib};
      OFF_DONE:   reg_rdata = chunk_done;
      OFF_VALID:  reg_rdata = {16'd0, slot_valid};
      OFF_ORIGIN: reg_rdata = {18'd0, win_z, 2'b00, win_x};
      default:    reg_rdata = 32'd0;
    endcase
  end

  logic unused;
  assign unused = ^reg_wdata[30:16];  // no register field there
endmodule
