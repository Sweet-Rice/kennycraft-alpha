// Behavioral stand-in for the MIG 7-series native user interface (D14), used
// by the Verilator testbenches and the instruction simulator. Not synthesizable.
//
// Same app_* ports as mig_ddr3 (rtl/ddr/mig/mig_ddr3.tcl): 28-bit app_addr in
// 16-bit words, 128-bit data, one BL8 beat per command (app_addr[2:0] = 0).
// The array is sparse (associative, keyed by beat = app_addr[26:3]) so the
// full 256 MB fits; never-written beats read as 0. Reads return in order,
// exactly LATENCY cycles after the command is accepted. Writes commit once
// both the command and its app_wdf data have been accepted, in either order.
// init_calib_complete rises CALIB_CYCLES after reset. With STALL != 0 a
// 16-bit LFSR drops app_rdy and app_wdf_rdy about 1 cycle in 4, to exercise
// the handshakes.
module ddr_model #(
  parameter int LATENCY      = 20,
  parameter int CALIB_CYCLES = 64,
  parameter bit STALL        = 1'b1
) (
  input  logic         clk,               // ui_clk
  input  logic         rst,               // ui_clk_sync_rst
  output logic         init_calib_complete,
  input  logic [27:0]  app_addr,
  input  logic [2:0]   app_cmd,
  input  logic         app_en,
  output logic         app_rdy,
  input  logic [127:0] app_wdf_data,
  input  logic         app_wdf_end,
  input  logic         app_wdf_wren,
  input  logic [15:0]  app_wdf_mask,
  output logic         app_wdf_rdy,
  output logic [127:0] app_rd_data,
  output logic         app_rd_data_end,
  output logic         app_rd_data_valid
);
  localparam logic [2:0] CMD_WRITE = 3'b000;
  localparam logic [2:0] CMD_READ  = 3'b001;

  logic [127:0] mem [logic [23:0]];

  // Testbench backdoor, also the model's own write path. The sparse array is
  // updated in place (blocking), so reads later in the same cycle see it.
  function automatic void poke(input logic [23:0] beat, input logic [127:0] d);
    /* verilator lint_off BLKSEQ */
    mem[beat] = d;
    /* verilator lint_on BLKSEQ */
  endfunction

  function automatic logic [127:0] peek(input logic [23:0] beat);
    return (mem.exists(beat) != 0) ? mem[beat] : 128'd0;
  endfunction

  // +ddr_manifest=<file>: each line "<hex DDR3 byte address> <path>" loads
  // that raw binary file at that address (DDR3 byte a = file byte a - base,
  // byte a in bits [8 (a % 16) +: 8] of beat a / 16). Without it, nothing.
  initial begin
    string manifest, path;
    int    mf, bf, c, n;
    logic [31:0]  base, a;
    logic [23:0]  beat;
    logic [127:0] d;
    if ($value$plusargs("ddr_manifest=%s", manifest)) begin
      mf = $fopen(manifest, "r");
      if (mf == 0) $fatal(1, "ddr_model: cannot open %s", manifest);
      while (!$feof(mf)) begin
        n = $fscanf(mf, "%h %s\n", base, path);
        if (n != 2) break;
        bf = $fopen(path, "rb");
        if (bf == 0) $fatal(1, "ddr_model: cannot open %s", path);
        a    = base;
        beat = a[27:4];
        d    = peek(beat);
        c    = $fgetc(bf);
        while (c != -1) begin
          if (a[31:28] != 4'h0) $fatal(1, "ddr_model: %s runs past 256 MB", path);
          if (a[27:4] != beat) begin
            poke(beat, d);
            beat = a[27:4];
            d    = peek(beat);
          end
          d[8 * a[3:0] +: 8] = 8'(c);
          a = a + 1;
          c = $fgetc(bf);
        end
        poke(beat, d);
        $fclose(bf);
        $display("ddr_model: %0s at 0x%07h (%0d bytes)", path, base, a - base);
      end
      $fclose(mf);
    end
  end

  int unsigned cyc;
  int unsigned calib_cnt;
  logic [15:0] lfsr;

  logic [23:0]  wq_addr [$];
  logic [127:0] wq_data [$];
  logic [15:0]  wq_mask [$];
  logic [23:0]  rq_addr [$];
  int unsigned  rq_due  [$];

  assign app_rdy     = init_calib_complete & ~(STALL & (lfsr[1:0] == 2'b00));
  assign app_wdf_rdy = init_calib_complete & ~(STALL & (lfsr[3:2] == 2'b00));

  always_ff @(posedge clk) begin
    if (rst) begin
      cyc                 <= 0;
      calib_cnt           <= 0;
      init_calib_complete <= 1'b0;
      lfsr                <= 16'hACE1;
      app_rd_data_valid   <= 1'b0;
      app_rd_data_end     <= 1'b0;
      app_rd_data         <= '0;
      wq_addr.delete();
      wq_data.delete();
      wq_mask.delete();
      rq_addr.delete();
      rq_due.delete();
    end else begin
      cyc  <= cyc + 1;
      lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
      if (calib_cnt < CALIB_CYCLES) calib_cnt <= calib_cnt + 1;
      else init_calib_complete <= 1'b1;

      if (app_en & app_rdy) begin
        if (app_addr[2:0] != 3'b000) $fatal(1, "ddr_model: unaligned app_addr %h", app_addr);
        if (app_cmd == CMD_WRITE) wq_addr.push_back(app_addr[26:3]);
        else if (app_cmd == CMD_READ) begin
          rq_addr.push_back(app_addr[26:3]);
          rq_due.push_back(cyc + LATENCY);
        end else $fatal(1, "ddr_model: unsupported app_cmd %0d", app_cmd);
      end
      if (app_wdf_wren & app_wdf_rdy) begin
        if (!app_wdf_end) $fatal(1, "ddr_model: app_wdf_end must mark every BL8 beat");
        wq_data.push_back(app_wdf_data);
        wq_mask.push_back(app_wdf_mask);
      end
      // Commit paired writes (the pairs pushed this cycle commit next cycle).
      if (wq_addr.size() != 0 && wq_data.size() != 0) begin
        logic [127:0] old, d;
        logic [15:0]  m;
        old = peek(wq_addr[0]);
        d   = wq_data[0];
        m   = wq_mask[0];
        for (int b = 0; b < 16; b++) if (m[b]) d[8*b +: 8] = old[8*b +: 8];
        poke(wq_addr[0], d);
        void'(wq_addr.pop_front());
        void'(wq_data.pop_front());
        void'(wq_mask.pop_front());
      end

      app_rd_data_valid <= 1'b0;
      app_rd_data_end   <= 1'b0;
      if (rq_addr.size() != 0 && rq_due[0] <= cyc) begin
        app_rd_data       <= peek(rq_addr[0]);
        app_rd_data_valid <= 1'b1;
        app_rd_data_end   <= 1'b1;
        void'(rq_addr.pop_front());
        void'(rq_due.pop_front());
      end
    end
  end
endmodule
