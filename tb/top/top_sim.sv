// Clock-free models of the Xilinx pieces under rtl/top.sv for t_top_frame:
// MMCME2_BASE, BUFG and mig_ddr3 (ddr_model behind the MIG user interface).
// They match tb/ddr/unisim_sim.sv except that no model makes its own clock:
// t_top_frame.cpp drives the MIG's 83.33 MHz ui_clk and the MMCM's LOCKED
// (high from 500 ns) through t_top_frame's ports, so the build needs no
// --timing. The MMCM's CLKOUT0/CLKOUT1 (ddr_clk's clk_sys and clk_ref) only
// reach the MIG's sys_clk_i and clk_ref_i, which the model leaves unused,
// so they stay low.

/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNDRIVEN */
module MMCME2_BASE #(
  parameter string BANDWIDTH        = "OPTIMIZED",
  parameter real   CLKIN1_PERIOD    = 10.0,
  parameter int    DIVCLK_DIVIDE    = 1,
  parameter real   CLKFBOUT_MULT_F  = 5.0,
  parameter real   CLKFBOUT_PHASE   = 0.0,
  parameter real   CLKOUT0_DIVIDE_F = 1.0,
  parameter int    CLKOUT1_DIVIDE   = 1,
  parameter string STARTUP_WAIT     = "FALSE"
) (
  input  logic CLKIN1, CLKFBIN, PWRDWN, RST,
  output logic CLKFBOUT, CLKFBOUTB,
  output logic CLKOUT0, CLKOUT0B, CLKOUT1, CLKOUT1B, CLKOUT2, CLKOUT2B,
  output logic CLKOUT3, CLKOUT3B, CLKOUT4, CLKOUT5, CLKOUT6,
  output logic LOCKED
);
  assign CLKOUT0  = 1'b0;
  assign CLKOUT1  = 1'b0;
  assign LOCKED   = t_top_frame.ddr_mmcm_locked;
  assign CLKFBOUT = CLKIN1;
endmodule

module BUFG (input logic I, output logic O);
  assign O = I;
endmodule

module mig_ddr3 (
  output logic [13:0]  ddr3_addr,
  output logic [2:0]   ddr3_ba,
  output logic         ddr3_cas_n,
  output logic [0:0]   ddr3_ck_n,
  output logic [0:0]   ddr3_ck_p,
  output logic [0:0]   ddr3_cke,
  output logic         ddr3_ras_n,
  output logic         ddr3_reset_n,
  output logic         ddr3_we_n,
  inout  wire  [15:0]  ddr3_dq,
  inout  wire  [1:0]   ddr3_dqs_n,
  inout  wire  [1:0]   ddr3_dqs_p,
  output logic         init_calib_complete,
  output logic [0:0]   ddr3_cs_n,
  output logic [1:0]   ddr3_dm,
  output logic [0:0]   ddr3_odt,
  input  logic [27:0]  app_addr,
  input  logic [2:0]   app_cmd,
  input  logic         app_en,
  input  logic [127:0] app_wdf_data,
  input  logic         app_wdf_end,
  input  logic         app_wdf_wren,
  output logic [127:0] app_rd_data,
  output logic         app_rd_data_end,
  output logic         app_rd_data_valid,
  output logic         app_rdy,
  output logic         app_wdf_rdy,
  input  logic         app_sr_req,
  input  logic         app_ref_req,
  input  logic         app_zq_req,
  output logic         app_sr_active,
  output logic         app_ref_ack,
  output logic         app_zq_ack,
  output logic         ui_clk,
  output logic         ui_clk_sync_rst,
  input  logic [15:0]  app_wdf_mask,
  input  logic         sys_clk_i,
  input  logic         clk_ref_i,
  input  logic         sys_rst
);
  assign ui_clk = t_top_frame.ddr_ui_clk;

  logic [3:0] rs = '1;
  always_ff @(posedge ui_clk) rs <= {rs[2:0], ~sys_rst};
  assign ui_clk_sync_rst = rs[3];

  ddr_model u_model (
    .clk(ui_clk), .rst(ui_clk_sync_rst), .init_calib_complete, .app_addr, .app_cmd, .app_en,
    .app_rdy, .app_wdf_data, .app_wdf_end, .app_wdf_wren, .app_wdf_mask, .app_wdf_rdy,
    .app_rd_data, .app_rd_data_end, .app_rd_data_valid
  );

  assign {ddr3_addr, ddr3_ba, ddr3_cas_n, ddr3_ck_n, ddr3_ck_p, ddr3_cke, ddr3_ras_n,
          ddr3_reset_n, ddr3_we_n, ddr3_cs_n, ddr3_dm, ddr3_odt} = '0;
  assign {app_sr_active, app_ref_ack, app_zq_ack} = '0;
endmodule
/* verilator lint_on UNDRIVEN */
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */
