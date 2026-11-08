// Shared harness for the DDR3 chunk store testbenches, `include`d inside each
// test module. Instantiates chunk_engine + ddr_bridge + ddr_model + world_remap
// (LANES = 8) and a behavioral world_mem (D17: two copies, two ports each)
// with the top-level port-A priority VTRACE > core > engine. Provides MMIO,
// world and DDR backdoor tasks. +define+KC_RD_BUF builds the engine with
// RD_BUF = 1 (the pipelined top's LOAD beat buffer).

localparam int LANES         = 8;
localparam int COPIES        = 2;  // copy n serves VTRACE lanes 4n..4n+3
localparam int WORLD_LATENCY = 2;  // VTRACE world read, in core cycles

localparam logic [5:0] OFF_STATUS = 6'h2C;
localparam logic [5:0] OFF_CMD    = 6'h30;
localparam logic [5:0] OFF_DONE   = 6'h34;
localparam logic [5:0] OFF_VALID  = 6'h38;
localparam logic [5:0] OFF_ORIGIN = 6'h3C;

logic clk = 1'b0, ui_clk = 1'b0;
logic rst = 1'b1, ui_rst = 1'b1;
always #10 clk = ~clk;      // 50 MHz core clock
always #6  ui_clk = ~ui_clk; // 83.3 MHz MIG ui_clk

int unsigned cyc = 0;
always @(posedge clk) cyc <= cyc + 1;

// ---- MMIO slice ----
logic        reg_en = 1'b0, reg_we = 1'b0;
logic [5:0]  reg_off = '0;
logic [31:0] reg_wdata = '0, reg_rdata;
logic        reg_stall;

// ---- window / world ----
logic [15:0] slot_valid;
logic [5:0]  win_x, win_z;
logic        vtrace_busy = 1'b0;
logic        tb_core_req = 1'b0, tb_core_we = 1'b0;
logic [16:0] tb_core_addr = '0;
logic [3:0]  tb_core_wdata = '0;
logic        noise_core_req = 1'b0;
logic [16:0] noise_core_addr = '0;
logic        core_world_req, core_we;
logic [16:0] core_addr, core_paddr;
logic [3:0]  core_wdata, core_rdata;
logic        eng_we, eng_re;
logic [16:0] eng_addr;
logic [3:0]  eng_wdata;
logic [16:0] vt_addr  [LANES];
// world_remap sees vt_addr through vt_addr_u. Verilator 5.020 does not wake
// combinational logic when a timed process writes an element of an unpacked
// array, so world_remap's vt_paddr would only follow vt_addr one clock late;
// reading clk here re-evaluates the copy on every clock edge.
logic [16:0] vt_addr_u [LANES];
always_comb
  for (int l = 0; l < LANES; l++) vt_addr_u[l] = clk ? vt_addr[l] : vt_addr[l];
logic [16:0] vt_paddr [LANES];
logic [3:0]  vt_rdata_phys [LANES];
logic [3:0]  vt_rdata [LANES];
logic [3:0]  wmem [COPIES][131072];
logic [3:0]  wa_rdata [COPIES];
logic        vt_phase = 1'b0;  // VTRACE access cycle: 0 = lanes 4n,4n+1; 1 = 4n+2,4n+3

assign core_world_req = tb_core_req | noise_core_req;
assign core_addr      = tb_core_req ? tb_core_addr : noise_core_addr;
assign core_we        = tb_core_req & tb_core_we;
assign core_wdata     = tb_core_wdata;

// ---- bridge <-> engine ----
logic         calib, cmd_valid, cmd_ready, cmd_store;
logic [15:0]  cmd_chunk;
logic         wr_valid, wr_ready, rd_valid, rd_ready;
logic [127:0] wr_data, rd_data;

// ---- MIG UI ----
logic         init_calib_complete, app_en, app_rdy, app_wdf_end, app_wdf_wren, app_wdf_rdy;
logic         app_rd_data_valid, app_rd_data_end;
logic [27:0]  app_addr;
logic [2:0]   app_cmd;
logic [127:0] app_wdf_data, app_rd_data;
logic [15:0]  app_wdf_mask;

`ifdef KC_RD_BUF
localparam bit ENG_RD_BUF = 1'b1;
`else
localparam bit ENG_RD_BUF = 1'b0;
`endif

chunk_engine #(.RD_BUF(ENG_RD_BUF)) u_eng (
  .clk, .rst, .reg_en, .reg_we, .reg_off, .reg_wdata, .reg_rdata, .reg_stall,
  .slot_valid, .win_x, .win_z, .vtrace_busy, .core_world_req,
  .eng_we, .eng_re, .eng_addr, .eng_wdata, .eng_rdata(wa_rdata[0]),
  .calib, .cmd_valid, .cmd_ready, .cmd_store, .cmd_chunk,
  .wr_valid, .wr_ready, .wr_data, .rd_valid, .rd_ready, .rd_data
);

ddr_bridge u_bridge (
  .clk, .rst, .calib, .cmd_valid, .cmd_ready, .cmd_store, .cmd_chunk,
  .wr_valid, .wr_ready, .wr_data, .rd_valid, .rd_ready, .rd_data,
  .ui_clk, .ui_rst, .init_calib_complete, .app_addr, .app_cmd, .app_en, .app_rdy,
  .app_wdf_data, .app_wdf_end, .app_wdf_wren, .app_wdf_mask, .app_wdf_rdy,
  .app_rd_data, .app_rd_data_valid
);

ddr_model u_ddr (
  .clk(ui_clk), .rst(ui_rst), .init_calib_complete, .app_addr, .app_cmd, .app_en, .app_rdy,
  .app_wdf_data, .app_wdf_end, .app_wdf_wren, .app_wdf_mask, .app_wdf_rdy,
  .app_rd_data, .app_rd_data_end, .app_rd_data_valid
);

world_remap #(.LANES(LANES)) u_remap (
  .clk, .win_x, .win_z, .slot_valid,
  .core_en(core_world_req), .core_addr, .core_paddr, .core_rdata_phys(wa_rdata[0]), .core_rdata,
  .vt_addr(vt_addr_u), .vt_paddr, .vt_rdata_phys, .vt_rdata
);

// ---- world_mem model: 2 copies, port A (VTRACE / core / engine), port B (VTRACE) ----
// A VTRACE access holds vt_addr for WORLD_LATENCY = 2 cycles. In the first
// cycle ports A and B of copy n read lanes 4n and 4n+1, in the second lanes
// 4n+2 and 4n+3; every lane's data is valid after the second edge (world_remap
// registers slot-valid every cycle, so it applies to the held address).
always @(posedge clk) begin
  for (int c = 0; c < COPIES; c++) begin
    int          la;
    logic [16:0] a;
    logic        we;
    logic [3:0]  d;
    la = 4 * c + (vt_phase ? 2 : 0);
    if (vtrace_busy)         begin a = vt_paddr[la]; we = 1'b0;    d = 4'd0;       end
    else if (core_world_req) begin a = core_paddr;   we = core_we; d = core_wdata; end
    else                     begin a = eng_addr;     we = eng_we;  d = eng_wdata;  end
    wa_rdata[c] <= wmem[c][a];
    if (vtrace_busy) begin
      vt_rdata_phys[la]     <= wmem[c][vt_paddr[la]];
      vt_rdata_phys[la + 1] <= wmem[c][vt_paddr[la + 1]];
    end
    if (we) wmem[c][a] <= d;
  end
  vt_phase <= vtrace_busy && !vt_phase;
end

// The engine must never touch the world while VTRACE or the core own it.
always @(posedge clk) begin
  if (!rst && (eng_we || eng_re) && (vtrace_busy || core_world_req))
    $fatal(1, "engine accessed the world while vtrace_busy=%0d core_world_req=%0d",
           vtrace_busy, core_world_req);
end

// ---- interference: random VTRACE bursts and core world reads ----
// vt_release > 0 drops vtrace_busy after that many core cycles, at the end of
// a VTRACE access. Interference VTRACE addresses change once per access.
bit interfere = 0;
int vt_release = 0;
bit vt_drop = 0;
initial for (int l = 0; l < LANES; l++) vt_addr[l] = '0;
always @(negedge clk) begin
  if (vt_release > 0) begin
    vt_release--;
    if (vt_release == 0) vt_drop = 1;
  end
  if (vt_drop && !vt_phase) begin
    vtrace_busy = 1'b0;
    vt_drop     = 0;
  end
  if (interfere && !rst) begin
    if (!vtrace_busy && !tb_core_hold && ($urandom % 64) == 0) begin
      vtrace_busy = 1'b1;
      vt_release  = 1 + int'($urandom % 200);
    end
    noise_core_req  = !vtrace_busy && ($urandom % 5) == 0;
    noise_core_addr = 17'($urandom);
    if (!vt_phase)
      for (int l = 0; l < LANES; l++) vt_addr[l] = 17'($urandom);
  end else begin
    noise_core_req = 1'b0;
  end
end

// ---- tasks ----
task automatic do_reset();
  rst = 1'b1; ui_rst = 1'b1;
  repeat (10) @(posedge clk);
  @(negedge ui_clk) ui_rst = 1'b0;
  @(negedge clk) rst = 1'b0;
endtask

task automatic mmio_wr(input logic [5:0] off, input logic [31:0] d, output int stalled);
  stalled = 0;
  @(negedge clk);
  reg_en = 1'b1; reg_we = 1'b1; reg_off = off; reg_wdata = d;
  #1;
  while (reg_stall) begin
    stalled++;
    @(negedge clk); #1;
  end
  @(negedge clk);
  reg_en = 1'b0; reg_we = 1'b0;
endtask

task automatic mmio_w(input logic [5:0] off, input logic [31:0] d);
  int s;
  mmio_wr(off, d, s);
endtask

task automatic mmio_rd(input logic [5:0] off, output logic [31:0] d);
  @(negedge clk);
  reg_en = 1'b1; reg_we = 1'b0; reg_off = off;
  #1 d = reg_rdata;
  @(negedge clk);
  reg_en = 1'b0;
endtask

task automatic wait_calib();
  logic [31:0] s;
  int n = 0;
  do begin
    mmio_rd(OFF_STATUS, s);
    if (++n > 100000) $fatal(1, "no calibration");
  end while (!s[0]);
endtask

function automatic logic [31:0] cmd_word(input bit store, input int cx, input int cz);
  return {store, 15'd0, 8'(cz), 8'(cx)};
endfunction

int unsigned issued = 0;

// Queue a command, return its ticket (commands issued so far, Chunk API).
task automatic chunk_cmd(input bit store, input int cx, input int cz, output int unsigned ticket,
                         output int stalled);
  mmio_wr(OFF_CMD, cmd_word(store, cx, cz), stalled);
  issued++;
  ticket = issued;
endtask

task automatic chunk_wait(input int unsigned ticket, input int timeout = 2000000);
  logic [31:0] d;
  int n = 0;
  do begin
    mmio_rd(OFF_DONE, d);
    if (++n > timeout) $fatal(1, "chunk_wait(%0d) timed out, CHUNK_DONE=%0d", ticket, d);
  end while (d < ticket);
endtask

task automatic chunk_sync(input bit store, input int cx, input int cz);
  int unsigned t;
  int s;
  chunk_cmd(store, cx, cz, t, s);
  chunk_wait(t);
endtask

// physical world address of block (x, y, z) of chunk (cx, cz)
function automatic logic [16:0] phys(input int cx, input int cz, input int x, input int y, input int z);
  return {5'(y), 2'(cz), 4'(z), 2'(cx), 4'(x)};
endfunction

// DDR beat index (128-bit) of chunk c, beat b
function automatic logic [23:0] beat_idx(input int cx, input int cz, input int b);
  return {8'(cz), 8'(cx), 8'(b)};
endfunction

function automatic logic [3:0] ddr_block(input int cx, input int cz, input int i);
  logic [127:0] d;
  d = u_ddr.peek(beat_idx(cx, cz, i / 32));
  return d[4 * (i % 32) +: 4];
endfunction

// Window-relative core access through world_remap (1-cycle world read).
// Like the real core, it never overlaps a VTRACE burst: tb_core_hold keeps
// the interference from starting one, and an access waits out a running one.
bit tb_core_hold = 0;

task automatic core_begin();
  tb_core_hold = 1;
  @(negedge clk);
  while (vtrace_busy) @(negedge clk);
endtask

task automatic core_rd(input logic [16:0] rel, output logic [3:0] d);
  core_begin();
  tb_core_req = 1'b1; tb_core_we = 1'b0; tb_core_addr = rel;
  @(posedge clk); #1 d = core_rdata;
  @(negedge clk) tb_core_req = 1'b0;
  tb_core_hold = 0;
endtask

task automatic core_wr(input logic [16:0] rel, input logic [3:0] d);
  core_begin();
  tb_core_req = 1'b1; tb_core_we = 1'b1; tb_core_addr = rel; tb_core_wdata = d;
  @(negedge clk) tb_core_req = 1'b0; tb_core_we = 1'b0;
  tb_core_hold = 0;
endtask

function automatic logic [16:0] rel_addr(input int x, input int y, input int z);
  return {5'(y), 6'(z), 6'(x)};
endfunction

// Check both copies of chunk (cx, cz)'s slot against its DDR3 image.
task automatic check_slot_vs_ddr(input int cx, input int cz, input string what);
  for (int i = 0; i < 8192; i++) begin
    logic [3:0] exp;
    logic [16:0] pa;
    exp = ddr_block(cx, cz, i);
    pa  = phys(cx, cz, i % 16, i / 256, (i / 16) % 16);
    for (int c = 0; c < COPIES; c++)
      if (wmem[c][pa] !== exp)
        $fatal(1, "%s: chunk (%0d,%0d) block %0d copy %0d = %h, DDR3 has %h",
               what, cx, cz, i, c, wmem[c][pa], exp);
  end
endtask

// Procedural "pre-existing" world: block type at absolute (ax, y, az).
function automatic logic [3:0] world_f(input int ax, input int y, input int az);
  int h;
  h = ax * 7 + az * 13 + y * 5 + (ax >> 4) * 3 + (az >> 4) * 11 + ((ax ^ az) >> 2);
  return 4'(h ^ (h >> 4));
endfunction

// Write chunk (cx, cz) of world_f into DDR3 through the model backdoor.
task automatic ddr_put_world_chunk(input int cx, input int cz);
  for (int b = 0; b < 256; b++) begin
    logic [127:0] d;
    for (int n = 0; n < 32; n++) begin
      int i;
      i = b * 32 + n;
      d[4*n +: 4] = world_f(cx * 16 + i % 16, i / 256, cz * 16 + (i / 16) % 16);
    end
    u_ddr.poke(beat_idx(cx, cz, b), d);
  end
endtask
