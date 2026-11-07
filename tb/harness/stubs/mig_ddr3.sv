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
  // Functional MIG replacement: all UI transfers remain handshake-driven.
  assign ui_clk = sys_clk_i;
  assign ui_clk_sync_rst = !sys_rst;
  ddr_model u_model (
    .clk(ui_clk), .rst(ui_clk_sync_rst), .init_calib_complete,
    .app_addr, .app_cmd, .app_en, .app_rdy,
    .app_wdf_data, .app_wdf_end, .app_wdf_wren, .app_wdf_mask, .app_wdf_rdy,
    .app_rd_data, .app_rd_data_end, .app_rd_data_valid
  );
  assign {ddr3_addr, ddr3_ba, ddr3_cas_n, ddr3_ck_n, ddr3_ck_p,
          ddr3_cke, ddr3_ras_n, ddr3_reset_n, ddr3_we_n,
          ddr3_cs_n, ddr3_dm, ddr3_odt} = '0;
  assign ddr3_dq = 'z;
  assign ddr3_dqs_n = 'z;
  assign ddr3_dqs_p = 'z;
  assign {app_sr_active, app_ref_ack, app_zq_ack} = '0;
  wire unused_inputs = &{1'b0, app_sr_req, app_ref_req, app_zq_req, clk_ref_i};
endmodule
