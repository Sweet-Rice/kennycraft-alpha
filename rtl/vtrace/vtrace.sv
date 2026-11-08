// VTRACE ray unit (Tai page, VTRACE Ray Unit; Shared page, Interfaces, Ray unit).
//
// Hardware Amanatides & Woo voxel traversal for LANES rays at once, v1
// multi-cycle. VSET (cfg_we) loads one field of each lane in lane_mask:
//   0 start cell {z[5:0], y[4:0], x[5:0]} in bits 16:0
//   1-3 tMax x, y, z (Q16.16)    4-6 tDelta x, y, z (Q16.16)
//   7 step signs, bit 0 x, 1 y, 2 z, 1 = stepping negative
// The walk updates cell and tMax in place.
//
// One step (wiki "One step", ties as written there: x only on a strict
// minimum, then y if tMaxY < tMaxZ, else z; tMax compares are signed) moves
// the cell one block on the chosen axis, adds tDelta to that tMax (saturating
// at 0x7FFF_FFFF), and records axis, sign, t = old tMax and the step count.
// world_addr follows the cell. Checking step p: a cell outside 0..63 / 0..31 /
// 0..63 finishes the lane with hit = 0, a non-air block finishes it with
// hit = 1 and the block type.
//
// Schedule. A step period is WORLD_LATENCY cycles (cnt = 0 .. WORLD_LATENCY - 1),
// which is the world bandwidth floor: with two copies (D17) each copy's two
// ports read 4 lanes in 2 cycles. Step 1 is taken on the start edge, step p + 1
// on the edge that ends step p's period, before step p's data has been seen.
// Step p's world_data is valid in cycle cnt = 0 of step p + 1, where step p is
// checked. A lane finishing there takes its speculative step p + 1 back on that
// edge and never steps again, so its results are exactly step p's. At
// WORLD_LATENCY = 1 that edge is also the one that takes step p + 2: a
// finishing lane reverts instead of stepping. The walk ends at the check of
// step N when every lane is finished or N = max_steps. No step beyond
// max_steps is taken, not even speculatively, so a cap miss keeps the last
// step's results and has nothing to revert. Busy is high for
// N * WORLD_LATENCY + 1 cycles, the last being step N's check.
//
// Revert by delta rather than a copy of the previous step: the speculative
// step's axis and sign (r_axis, r_sign) say which cell coordinate to move back,
// and its t (r_t) is that axis's old tMax. Only step p's axis and t (p_axis,
// p_t) and whether step p's cell is outside the world (p_oob; the cell
// registers already hold step p + 1 when step p is checked) are kept: 35 flops
// per lane instead of about 150 for cell, three tMax and the result fields.
//
// world_mem (WORLD_LATENCY = 2) toggles its port phase every busy cycle from
// the first: lanes 4n, 4n + 1 are read in cnt = 0, 4n + 2, 4n + 3 in cnt = 1.
//
// Timing (WORLD_LATENCY > 1, same schedule and results). A lane's tMax only
// changes on a step edge (cnt = WORLD_LATENCY - 1 or the start edge), a check
// edge (revert) or a VSET, so its axis select (sel_x, sel_y) is a register
// loaded every cycle with the compares of the tMax the next cycle holds: the
// VSET data in place of the field it writes, and on a revert the reverted
// step's axis (r_axis, the select of the state the revert restores). It is
// stale only in the cycle after a step edge, and the next edge is never a
// step edge. The step is then select -> mux -> 33-bit add -> saturate ->
// tMax, without the three 32-bit compares.
//
// The start cell is never tested. start with max_steps = 0 or an empty
// lane_mask raises done the next cycle and changes nothing. Lanes outside
// lane_mask keep their state and results. On a miss (left the world or step
// cap) the result keeps the last step's axis, sign, t and cell, block type 0;
// hit_cell packs the low bits of the cell, so x = 64 reads as 0 and -1 as 63.
// done is a one-cycle pulse in the first cycle after the walk with busy low;
// the results are stable from then until the next start.
module vtrace #(parameter int LANES = 8, parameter int WORLD_LATENCY = 2) (
  input  logic             clk,
  input  logic             rst,
  // VSET: write one field for all active lanes
  input  logic             cfg_we,
  input  logic [2:0]       cfg_field,
  input  logic [LANES-1:0] lane_mask,
  input  logic [31:0]      cfg_data   [LANES],
  // VTRACE
  input  logic             start,       // one-cycle pulse
  input  logic [7:0]       max_steps,
  output logic             busy,
  output logic             done,        // one-cycle pulse
  // results, valid after done, read by VTRACE rd and VGET
  output logic [15:0]      result     [LANES],
  output logic [16:0]      hit_cell   [LANES],
  output logic [31:0]      t_hit      [LANES],
  // world read ports, one per lane. world_addr is held for WORLD_LATENCY
  // cycles and world_data is valid WORLD_LATENCY cycles after it (2 with two
  // world copies, D17; 1 with four)
  output logic [16:0]      world_addr [LANES],
  input  logic [3:0]       world_data [LANES]
);
  localparam int WL_W = (WORLD_LATENCY > 1) ? $clog2(WORLD_LATENCY) : 1;

  logic             run;        // walk in progress
  logic [WL_W-1:0]  cnt;        // cycle within the step period
  logic [7:0]       step_cnt;   // steps taken so far, the newest one unchecked
  logic [7:0]       cap;        // max_steps latched at start
  logic             chk_on;     // past the first period: a step awaits its check
  logic             spec;       // the newest step is one past the step checked now
  logic [LANES-1:0] live;       // lane still walking
  logic [LANES-1:0] fin;        // lane finishes at this check

  wire launch     = !run && start && (max_steps != 8'd0) && (lane_mask != '0);
  wire do_check   = run && chk_on && (cnt == '0);
  wire period_end = run && (cnt == WL_W'(WORLD_LATENCY - 1));
  wire [LANES-1:0] live_next = live & ~fin;
  // the check of step_cnt itself (spec = 0) is the check of max_steps
  wire finish     = do_check && ((live_next == '0) || !spec);
  // At WORLD_LATENCY > 1 the check is never in the period's last cycle, so the
  // step edge depends only on registers.
  wire step_ok    = period_end && (step_cnt != cap) && ((WORLD_LATENCY > 1) || !finish);
  // lanes that take a step on this edge, and the step number they record
  wire [LANES-1:0] stepping = launch  ? lane_mask
                            : step_ok ? ((WORLD_LATENCY > 1) ? live : live_next) : '0;
  wire [LANES-1:0] revert   = spec ? fin : '0;
  wire [7:0]       step_num = launch ? 8'd1 : step_cnt + 8'd1;
  wire [7:0]       chk_num  = step_cnt - 8'd1;   // the step checked while spec

  assign busy = run;

  always_ff @(posedge clk) begin
    if (rst) begin
      run  <= 1'b0;
      done <= 1'b0;
      live <= '0;
    end else begin
      done <= 1'b0;
      if (!run) begin
        if (start) begin
          if (launch) begin
            live     <= lane_mask;
            cap      <= max_steps;
            step_cnt <= 8'd1;
            cnt      <= '0;
            chk_on   <= 1'b0;
            spec     <= 1'b0;
            run      <= 1'b1;
          end else begin
            done <= 1'b1;
          end
        end
      end else begin
        if (do_check) live <= live_next;
        if (finish) begin
          done <= 1'b1;
          run  <= 1'b0;
        end else if (period_end) begin
          cnt    <= '0;
          chk_on <= 1'b1;
          spec   <= step_ok;
          if (step_ok) step_cnt <= step_num;
        end else begin
          cnt <= cnt + 1'b1;
        end
      end
    end
  end

  for (genvar l = 0; l < LANES; l++) begin : g_lane
    logic signed [6:0]  cx, cy, cz;        // cell, signed so leaving is visible
    logic signed [31:0] tmx, tmy, tmz;     // tMax, Q16.16
    logic signed [31:0] tdx, tdy, tdz;     // tDelta, Q16.16
    logic [2:0]         neg;               // step signs, 1 = negative
    logic               r_hit, r_sign;
    logic [1:0]         r_axis;
    logic [3:0]         r_type;
    logic [7:0]         r_steps;
    logic [31:0]        r_t;
    logic [1:0]         p_axis;            // step before the newest: axis, t
    logic [31:0]        p_t;
    logic               p_oob;             // ... and its cell outside the world

    // ---- step: pick the axis with the smallest tMax ----
    logic               sel_x, sel_y;
    wire                sel_z = !sel_x && !sel_y;
    wire signed [31:0]  tm    = sel_x ? tmx : sel_y ? tmy : tmz;
    wire signed [31:0]  td    = sel_x ? tdx : sel_y ? tdy : tdz;
    wire signed [32:0]  sum   = 33'(tm) + 33'(td);
    // saturate at 0x7FFF_FFFF on positive overflow
    wire signed [31:0]  tm_n  = (sum[32:31] == 2'b01) ? 32'sh7FFF_FFFF : sum[31:0];
    wire [1:0]          axis  = sel_x ? 2'd0 : sel_y ? 2'd1 : 2'd2;
    wire                sgn   = neg[axis];
    wire signed [6:0]   delta = sgn ? -7'sd1 : 7'sd1;
    // undo the newest step: move back along r_axis
    wire signed [6:0]   undo  = r_sign ? 7'sd1 : -7'sd1;

    wire                cfg_l = cfg_we && lane_mask[l];

    if (WORLD_LATENCY > 1) begin : g_sel_q
      // the tMax of the next cycle, unless a step or revert writes it
      wire signed [31:0] nx = (cfg_l && cfg_field == 3'd1) ? $signed(cfg_data[l]) : tmx;
      wire signed [31:0] ny = (cfg_l && cfg_field == 3'd2) ? $signed(cfg_data[l]) : tmy;
      wire signed [31:0] nz = (cfg_l && cfg_field == 3'd3) ? $signed(cfg_data[l]) : tmz;
      wire               nsx = (nx < ny) && (nx < nz);

      always_ff @(posedge clk) begin
        if (revert[l]) begin
          sel_x <= (r_axis == 2'd0);
          sel_y <= (r_axis == 2'd1);
        end else begin
          sel_x <= nsx;
          sel_y <= !nsx && (ny < nz);
        end
      end
    end else begin : g_sel_c
      assign sel_x = (tmx < tmy) && (tmx < tmz);
      assign sel_y = !sel_x && (tmy < tmz);
    end

    // ---- check ----
    wire oob_now = cx[6] | cy[6] | cy[5] | cz[6];
    wire oob     = spec ? p_oob : oob_now;
    wire solid   = (world_data[l] != 4'd0);
    assign fin[l] = do_check && live[l] && (oob || solid);

    // Write enables and data, revert over step over VSET
    wire rv_sel = revert[l];
    wire st_x   = stepping[l] && sel_x;
    wire st_y   = stepping[l] && sel_y;
    wire st_z   = stepping[l] && sel_z;
    wire rv_x   = revert[l] && (r_axis == 2'd0);
    wire rv_y   = revert[l] && (r_axis == 2'd1);
    wire rv_z   = revert[l] && r_axis[1];
    wire cfg_c  = cfg_l && (cfg_field == 3'd0);

    always_ff @(posedge clk) begin
      if (cfg_l) begin
        unique case (cfg_field)
          3'd4:    tdx <= cfg_data[l];
          3'd5:    tdy <= cfg_data[l];
          3'd6:    tdz <= cfg_data[l];
          3'd7:    neg <= cfg_data[l][2:0];
          default: ;
        endcase
      end
      if (cfg_c || st_x || rv_x) cx <= rv_sel ? cx + undo : st_x ? cx + delta : {1'b0, cfg_data[l][5:0]};
      if (cfg_c || st_y || rv_y) cy <= rv_sel ? cy + undo : st_y ? cy + delta : {2'b0, cfg_data[l][10:6]};
      if (cfg_c || st_z || rv_z) cz <= rv_sel ? cz + undo : st_z ? cz + delta : {1'b0, cfg_data[l][16:11]};
      if ((cfg_l && cfg_field == 3'd1) || st_x || rv_x) tmx <= rv_sel ? r_t : st_x ? tm_n : $signed(cfg_data[l]);
      if ((cfg_l && cfg_field == 3'd2) || st_y || rv_y) tmy <= rv_sel ? r_t : st_y ? tm_n : $signed(cfg_data[l]);
      if ((cfg_l && cfg_field == 3'd3) || st_z || rv_z) tmz <= rv_sel ? r_t : st_z ? tm_n : $signed(cfg_data[l]);
      if (stepping[l] || revert[l]) begin
        r_axis  <= rv_sel ? p_axis      : axis;
        r_sign  <= rv_sel ? neg[p_axis] : sgn;
        r_t     <= rv_sel ? p_t         : tm;
        r_steps <= rv_sel ? chk_num     : step_num;
      end
      if (stepping[l]) begin
        p_axis  <= r_axis;
        p_t     <= r_t;
        p_oob   <= oob_now;
      end
      if (do_check && live[l]) begin
        r_hit  <= !oob && solid;
        r_type <= oob ? 4'd0 : world_data[l];
      end
    end

    assign result[l]     = {r_steps, r_type, r_sign, r_axis, r_hit};
    assign hit_cell[l]   = {cz[5:0], cy[4:0], cx[5:0]};
    assign t_hit[l]      = r_t;
    assign world_addr[l] = {cy[4:0], cz[5:0], cx[5:0]};

    // cfg_data bits above the field widths are ignored
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_cfg = ^cfg_data[l][31:17];
    /* verilator lint_on UNUSEDSIGNAL */
  end
endmodule
