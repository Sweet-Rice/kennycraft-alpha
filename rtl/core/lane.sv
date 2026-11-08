// One SIMD lane of the core (Tai page, GPU Core, What changes from the CPU):
// the replicated datapath that the shared control in core.sv drives with the
// same instruction in every lane.
//
//   register file  32 x 32, 2 read + 1 write ports, distributed RAM
//   ALU            same operands as the CPU: a = rs1 or PC, b = rs2, imm or 4
//   comparator     cmp = the raw branch condition (before funct3[0] inverts)
//   multiplier     Zmmul, registered product (second EXECUTE cycle)
//   QRCP unit      HAS_QRCP = 1: rtl/core/qrcp.sv on rs1, stepped by the core
//   address gen    the ALU sum (rs1 + imm) lands in res as the bus address
//
// res holds the rd value (ALU, LUI immediate, link, product, lane control,
// ray unit or QRCP result) or, for loads and stores, this lane's address.
// Load data arrives from the LSU one access at a time: ld_cap marks the cycle
// in which ld_value is this lane's (already extended) word. It is kept in a holding
// register, and in WB a lane takes ld_value directly when its data arrives in
// that cycle (the last lane of the walk) and the holding register otherwise,
// so every lane writes back together.
module lane
    import kc_isa_pkg::*;
#(
    parameter int ID       = 0,      // this lane's index, returned by LANEID
    parameter bit HAS_QRCP = 1'b0    // QRCP unit (D22)
) (
    input  logic        clk,

    // ID: register read addresses (from the instruction BRAM output)
    input  logic        id_en,
    input  logic [4:0]  rs1_addr,
    input  logic [4:0]  rs2_addr,

    // EX: shared decode
    input  logic        ex_en,
    input  logic        mul_en,       // second EXECUTE cycle: latch the product
    input  logic [3:0]  alu_ctrl,
    input  logic        alu_a_pc,
    input  logic [1:0]  alu_b_sel,
    input  logic [2:0]  funct3,
    input  logic [31:0] pc,
    input  logic [31:0] imm,
    input  logic        res_imm,      // LUI
    input  logic        is_lane,      // custom-0
    input  logic [31:0] lane_y,       // BALLOT / MASKGET result (same in every lane)
    input  logic        ray_en,       // custom-1: latch ray_y (VGET in EX, VTRACE at done)
    input  logic [31:0] ray_y,        // this lane's VTRACE result or VGET field
    input  logic        qr_load,      // QRCP: EX, the unit latches rs1
    input  logic        qr_en,        // QRCP: wait state, the unit steps qr_ph
    input  logic [2:0]  qr_ph,
    input  logic        qr_wr,        // QRCP: latch the unit's result

    output logic [31:0] rs1,          // operands of the instruction in flight
    output logic [31:0] rs2,
    output logic [31:0] alu_y,
    output logic        cmp,
    output logic [31:0] res,

    // Load return
    input  logic        ld_cap,
    input  logic [31:0] ld_value,

    // WB
    input  logic        we,
    input  logic [4:0]  rd,
    input  logic        is_load,
    output logic [31:0] wdata
);

    logic [31:0] rs1_raw, rs2_raw, alu_a, alu_b, mul_y, ld_hold;

    reg_module #(.W(32), .D(32)) u_rf (
        .clk, .we, .wr(rd), .rd1(rs1_addr), .rd2(rs2_addr),
        .d_in(wdata), .d_out1(rs1_raw), .d_out2(rs2_raw)
    );

    always_ff @(posedge clk) begin
        if (id_en) begin
            rs1 <= (rs1_addr == 5'd0) ? 32'd0 : rs1_raw;
            rs2 <= (rs2_addr == 5'd0) ? 32'd0 : rs2_raw;
        end
    end

    assign alu_a = alu_a_pc ? pc : rs1;
    always_comb begin
        unique case (alu_b_sel)
            2'b00:   alu_b = rs2;
            2'b10:   alu_b = 32'd4;
            default: alu_b = imm;
        endcase
    end

    alu #(.W(32)) u_alu (.a(alu_a), .b(alu_b), .op(alu_ctrl), .result(alu_y));

    // BEQ/BNE compare the XOR against 0, BLT/BGE/BLTU/BGEU take the SLT bit.
    assign cmp = funct3[2] ? alu_y[0] : (alu_y == 32'd0);

    mul u_mul (
        .clk, .en(ex_en), .op(funct3[1:0]), .a(rs1), .b(rs2), .result(mul_y)
    );

    logic [31:0] qr_y;

    if (HAS_QRCP) begin : g_qrcp
        qrcp u_qrcp (.clk, .load(qr_load), .en(qr_en), .ph(qr_ph), .x(rs1), .y(qr_y));
    end else begin : g_no_qrcp
        assign qr_y = 32'd0;
        /* verilator lint_off UNUSEDSIGNAL */
        logic unused_qr;
        assign unused_qr = qr_load ^ qr_en ^ (^qr_ph);
        /* verilator lint_on UNUSEDSIGNAL */
    end

    always_ff @(posedge clk) begin
        if (ray_en) begin
            res <= ray_y;
        end else if (qr_wr) begin
            res <= qr_y;
        end else if (ex_en) begin
            if (res_imm)                          res <= imm;
            else if (is_lane && funct3 == F3_LANEID) res <= 32'(ID);
            else if (is_lane)                     res <= lane_y;
            else                                  res <= alu_y;
        end else if (mul_en) begin
            res <= mul_y;
        end
        if (ld_cap) ld_hold <= ld_value;
    end

    assign wdata = !is_load ? res : (ld_cap ? ld_value : ld_hold);

endmodule
