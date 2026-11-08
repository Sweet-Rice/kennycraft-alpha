// Behavioral Verilator models of the Xilinx pieces under fpga/ddr_test and
// rtl/ddr/ddr_clk.sv: MMCME2_BASE (CLKOUT0/1 and LOCKED only), BUFG, and
// mig_ddr3 (the generated MIG, modeled as rtl/ddr/ddr_model.sv behind the same
// ports with its own 83.33 MHz ui_clk). Used by lint-ddr, tb-ddr-ddr_test and
// tb/top.
//
// With KC_EXT_CLOCKS defined (tb/top/t_top_frame, built without --timing) no
// model makes its own clock: the MIG's ui_clk and the MMCM's LOCKED come from
// t_top_frame's ddr_ui_clk and ddr_mmcm_locked ports, which its C++ main
// drives, and CLKOUT0/CLKOUT1 stay low. That MMCM is only ddr_clk's, whose
// outputs reach nothing but the MIG model's unused sys_clk_i and clk_ref_i;
// any other configuration is a fatal error.

/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off STMTDLY */
/* verilator lint_off REALCVT */
/* verilator lint_off MULTIDRIVEN */
/* verilator lint_off BLKSEQ */
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
  localparam real VCO = CLKIN1_PERIOD * DIVCLK_DIVIDE / CLKFBOUT_MULT_F;  // ns
  localparam real H0  = VCO * CLKOUT0_DIVIDE_F / 2.0;
  localparam real H1  = VCO * CLKOUT1_DIVIDE / 2.0;
`ifdef KC_EXT_CLOCKS
  initial if (CLKOUT0_DIVIDE_F != 6.0 || CLKOUT1_DIVIDE != 5)
    $fatal(1, "unisim_sim: KC_EXT_CLOCKS does not model MMCM %m");
  assign CLKOUT0 = 1'b0;
  assign CLKOUT1 = 1'b0;
  assign LOCKED  = t_top_frame.ddr_mmcm_locked;
`else
  initial begin CLKOUT0 = 1'b0; CLKOUT1 = 1'b0; LOCKED = 1'b0; #500 LOCKED = 1'b1; end
  always #(H0) CLKOUT0 = ~CLKOUT0;
  always #(H1) CLKOUT1 = ~CLKOUT1;
`endif
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
`ifdef KC_EXT_CLOCKS
  assign ui_clk = t_top_frame.ddr_ui_clk;
`else
  initial ui_clk = 1'b0;
  always #6 ui_clk = ~ui_clk;
`endif

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
/* verilator lint_on MULTIDRIVEN */
/* verilator lint_on REALCVT */
/* verilator lint_on STMTDLY */
/* verilator lint_on UNDRIVEN */
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */
