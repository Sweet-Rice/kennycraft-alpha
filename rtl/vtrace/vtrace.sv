// VTRACE ray unit (Tai page, VTRACE Ray Unit; Shared page, Interfaces, Ray unit).
//
// Hardware Amanatides & Woo voxel traversal for LANES rays at once, v1
// multi-cycle. VSET (cfg_we) loads one field of each lane in lane_mask:
//   0 start cell {z[5:0], y[4:0], x[5:0]} in bits 16:0
//   1-3 tMax x, y, z (Q16.16)    4-6 tDelta x, y, z (Q16.16)
//   7 step signs, bit 0 x, 1 y, 2 z, 1 = stepping negative
// The walk updates cell and tMax in place. VSET writes a shadow copy of the
// field and marks it dirty; the next walk starts from the dirty fields' new
// values and the others' current ones (a VTRACE without VSET resumes where
// the last walk stopped, as before). So VSET may run during a walk: the core
// can set up the next ray while this one walks (asynchronous VTRACE).
//
// One step (wiki "One step", ties as written there: x only on a strict
// minimum, then y if tMaxY < tMaxZ, else z; tMax compares are signed):
//   step   (an edge) move the cell one block on the chosen axis, tMax +=
//          tDelta (saturating at 0x7FFF_FFFF), record axis, sign, t = old
//          tMax and the step count. world_addr follows the cell, so it is
//          held until the next step.
//   WAIT   WORLD_LATENCY cycles with world_addr held. world_phase is the
//          index of the WAIT cycle (0, 1): world_mem reads lanes 4n, 4n + 1
//          in phase 0 and 4n + 2, 4n + 3 in phase 1.
//   check  world_data is valid the cycle after the last WAIT: outside
//          0..63 / 0..31 / 0..63 finishes the lane with hit = 0, a non-air
//          block finishes it with hit = 1 and the block type.
// The steps are pipelined: at the end of a step's last WAIT the live lanes
// latch their cell and step record (k_*) and take the next step at once, so
// the check of step k runs in the first WAIT cycle of step k + 1, while the
// world memory reads cell k + 1. A lane that finishes there reports step k
// (the k_* record and cell); its step k + 1 is dropped. That is
// WORLD_LATENCY = 2 cycles per step with two world copies (D17), the world
// memory busy in every cycle of the walk. After the step that reaches
// max_steps no step is taken and S_CHECK checks it alone. The walk ends at
// the first check that leaves no lane walking, or at that last check: a walk
// of N steps (the most any lane takes) has its last check in cycle
// N * WORLD_LATENCY + 1 after start and done in the next.
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
  output logic             world_phase,  // WAIT cycle index (world_mem two-phase read)
  input  logic [3:0]       world_data [LANES]
);
  localparam int WL_W = (WORLD_LATENCY > 1) ? $clog2(WORLD_LATENCY) : 1;

  typedef enum logic [1:0] { S_IDLE, S_WAIT, S_CHECK } state_t;

  state_t           state;
  logic [WL_W-1:0]  wait_cnt;
  logic [7:0]       step_cnt;   // steps taken so far in this walk
  logic [7:0]       cap;        // max_steps latched at start
  logic             pend;       // the previous step's cell is checked this walk
  logic [LANES-1:0] live;       // lane still walking
  logic [LANES-1:0] live_next;  // live after the check of the pending step

  // The check of the pending step happens in the first WAIT cycle of the next
  // (speculative) step, or in S_CHECK after the last step.
  wire launch    = (state == S_IDLE) && start && (max_steps != 8'd0) && (lane_mask != '0);
  wire checking  = ((state == S_WAIT) && pend && (wait_cnt == '0)) || (state == S_CHECK);
  wire [LANES-1:0] live_now = checking ? live_next : live;
  wire last_wait = (state == S_WAIT) && (wait_cnt == WL_W'(WORLD_LATENCY - 1));
  // every lane finished at this check (a step still in flight is dropped)
  wire finish    = checking && ((live_next == '0) || (state == S_CHECK));
  // end of a step's last WAIT: the live lanes take the next step at once,
  // before their current cell is checked, unless the cap is reached
  wire spec      = last_wait && !finish && (step_cnt != cap);
  wire [LANES-1:0] stepping = launch ? lane_mask : spec ? live_now : '0;
  wire [LANES-1:0] latching = last_wait ? live_now : '0;   // cell + record -> checked
  wire [7:0]       step_num = launch ? 8'd1 : step_cnt + 8'd1;

  assign busy        = (state != S_IDLE);
  assign world_phase = (state == S_WAIT) && (wait_cnt != '0);

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= S_IDLE;
      done  <= 1'b0;
      live  <= '0;
      pend  <= 1'b0;
    end else begin
      done <= 1'b0;
      if (checking) live <= live_next;
      unique case (state)
        S_IDLE: begin
          if (start) begin
            if (launch) begin
              live     <= lane_mask;
              cap      <= max_steps;
              step_cnt <= 8'd1;
              wait_cnt <= '0;
              pend     <= 1'b0;
              state    <= S_WAIT;
            end else begin
              done <= 1'b1;
            end
          end
        end
        S_WAIT: begin
          if (finish) begin
            done  <= 1'b1;
            state <= S_IDLE;
          end else if (last_wait) begin
            pend     <= 1'b1;
            wait_cnt <= '0;
            if (spec) step_cnt <= step_num;   // the live lanes step on this edge
            else      state    <= S_CHECK;    // cap reached: check the last step
          end else begin
            wait_cnt <= wait_cnt + 1'b1;
          end
        end
        S_CHECK: begin
          done  <= 1'b1;
          state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
    end
  end

  for (genvar l = 0; l < LANES; l++) begin : g_lane
    logic signed [6:0]  cx, cy, cz;        // cell, signed so leaving is visible
    logic signed [31:0] tmx, tmy, tmz;     // tMax, Q16.16
    logic signed [31:0] tdx, tdy, tdz;     // tDelta, Q16.16
    logic [2:0]         neg;               // step signs, 1 = negative
    // VSET shadow and its dirty bits (one per field), taken at the next launch
    logic [16:0]        q_cell;
    logic [31:0]        q_tmx, q_tmy, q_tmz, q_tdx, q_tdy, q_tdz;
    logic [2:0]         q_neg;
    logic [7:0]         dirty;
    // the values the walk steps from: at launch the dirty fields' new ones
    wire                take = launch;
    wire signed [6:0]   ex = (take && dirty[0]) ? {1'b0, q_cell[5:0]}   : cx;
    wire signed [6:0]   ey = (take && dirty[0]) ? {2'b0, q_cell[10:6]}  : cy;
    wire signed [6:0]   ez = (take && dirty[0]) ? {1'b0, q_cell[16:11]} : cz;
    wire signed [31:0]  etmx = (take && dirty[1]) ? q_tmx : tmx;
    wire signed [31:0]  etmy = (take && dirty[2]) ? q_tmy : tmy;
    wire signed [31:0]  etmz = (take && dirty[3]) ? q_tmz : tmz;
    wire signed [31:0]  etdx = (take && dirty[4]) ? q_tdx : tdx;
    wire signed [31:0]  etdy = (take && dirty[5]) ? q_tdy : tdy;
    wire signed [31:0]  etdz = (take && dirty[6]) ? q_tdz : tdz;
    wire [2:0]          eneg = (take && dirty[7]) ? q_neg : neg;
    // the step that produced the current cell
    logic               s_sign;
    logic [1:0]         s_axis;
    logic [7:0]         s_steps;
    logic [31:0]        s_t;
    // the step whose cell is being read / checked
    logic signed [6:0]  kx, ky, kz;
    logic               k_sign;
    logic [1:0]         k_axis;
    logic [7:0]         k_steps;
    logic [31:0]        k_t;
    // results
    logic               r_hit, r_sign;
    logic [1:0]         r_axis;
    logic [3:0]         r_type;
    logic [7:0]         r_steps;
    logic [31:0]        r_t;
    logic [16:0]        r_cell;

    // ---- step: pick the axis with the smallest tMax ----
    wire                sel_x = (etmx < etmy) && (etmx < etmz);
    wire                sel_y = !sel_x && (etmy < etmz);
    wire                sel_z = !sel_x && !sel_y;
    wire signed [31:0]  tm    = sel_x ? etmx : sel_y ? etmy : etmz;
    wire signed [31:0]  td    = sel_x ? etdx : sel_y ? etdy : etdz;
    wire signed [32:0]  sum   = 33'(tm) + 33'(td);
    // saturate at 0x7FFF_FFFF on positive overflow
    wire signed [31:0]  tm_n  = (sum[32:31] == 2'b01) ? 32'sh7FFF_FFFF : sum[31:0];
    wire [1:0]          axis  = sel_x ? 2'd0 : sel_y ? 2'd1 : 2'd2;
    wire                sgn   = eneg[axis];
    wire signed [6:0]   delta = sgn ? -7'sd1 : 7'sd1;

    // ---- check of the latched step ----
    wire oob   = kx[6] | ky[6] | ky[5] | kz[6];
    wire solid = (world_data[l] != 4'd0);
    assign live_next[l] = live[l] && !oob && !solid;

    always_ff @(posedge clk) begin
      if (rst) dirty <= '0;
      else if (cfg_we && lane_mask[l]) dirty[cfg_field] <= 1'b1;
      else if (stepping[l] && launch) dirty <= '0;
      if (cfg_we && lane_mask[l]) begin
        unique case (cfg_field)
          3'd0: q_cell <= cfg_data[l][16:0];
          3'd1: q_tmx  <= cfg_data[l];
          3'd2: q_tmy  <= cfg_data[l];
          3'd3: q_tmz  <= cfg_data[l];
          3'd4: q_tdx  <= cfg_data[l];
          3'd5: q_tdy  <= cfg_data[l];
          3'd6: q_tdz  <= cfg_data[l];
          3'd7: q_neg  <= cfg_data[l][2:0];
        endcase
      end
      if (latching[l]) begin               // before the step below overwrites them
        kx <= cx; ky <= cy; kz <= cz;
        k_axis <= s_axis; k_sign <= s_sign; k_t <= s_t; k_steps <= s_steps;
      end
      if (stepping[l]) begin
        // launch: take every field (the dirty ones are new), then step
        cx <= ex; cy <= ey; cz <= ez; tmx <= etmx; tmy <= etmy; tmz <= etmz;
        tdx <= etdx; tdy <= etdy; tdz <= etdz; neg <= eneg;
        if (sel_x) begin cx <= ex + delta; tmx <= tm_n; end
        if (sel_y) begin cy <= ey + delta; tmy <= tm_n; end
        if (sel_z) begin cz <= ez + delta; tmz <= tm_n; end
        s_axis  <= axis;
        s_sign  <= sgn;
        s_t     <= tm;
        s_steps <= step_num;
      end
      if (checking && live[l]) begin
        r_hit   <= !oob && solid;
        r_type  <= oob ? 4'd0 : world_data[l];
        r_axis  <= k_axis;
        r_sign  <= k_sign;
        r_t     <= k_t;
        r_steps <= k_steps;
        r_cell  <= {kz[5:0], ky[4:0], kx[5:0]};
      end
    end

    assign result[l]     = {r_steps, r_type, r_sign, r_axis, r_hit};
    assign hit_cell[l]   = r_cell;
    assign t_hit[l]      = r_t;
    assign world_addr[l] = {cy[4:0], cz[5:0], cx[5:0]};

    // cfg_data bits above the field widths are ignored
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_cfg = ^cfg_data[l][31:17];
    /* verilator lint_on UNUSEDSIGNAL */
  end
endmodule
