// One SIMD lane of the pipelined core (rtl/core_pipe/core_pipe.sv): the
// per-lane datapath of rtl/core/lane.sv cut into the ID / EX / MEM / WB
// stages, with this lane's forwarding. The shared control in core_pipe drives
// every lane with the same instruction in each stage.
//
//   ID   read rs1 / rs2 from the register file, bypassing the WB write of
//        the same cycle (the register file writes on the clock edge)
//   EX   forwarded operands: MEM's result, else WB's, else the ID read, each
//        only when that stage writes rd in this lane (m_we / w_we, which
//        carry the lane's mask bit). While EX waits for MEM the operands are
//        recaptured every cycle, so a WB result is not lost when it retires.
//        ALU, comparator, and the result latched into res: the ALU output
//        (or this lane's address for loads and stores), LUI immediate,
//        LANEID, BALLOT / MASKGET, VGET field, or rs1 for MUL and QRCP,
//        which run in MEM on registered operands
//   MEM  res and the store data / multiplier operand rs2. MUL (the product
//        of res and m_rs2, combinational, in MEM's one cycle), QRCP
//        (qrcp_pipe: two steps, y valid in the third cycle), the VTRACE
//        result at the ray unit's done, and the LSU's load data (ld_cap /
//        ld_value, held in ld_hold). fwd is MEM's result for forwarding
//        (never a load's or a MUL's: the core stalls load-use and mul-use
//        instead); wdata is the value written back (the last load lane's
//        data arrives directly in MEM's last cycle)
//   WB   the register file write of the previous MEM's wdata
module lane_pipe
    import kc_isa_pkg::*;
#(
    parameter int ID       = 0,      // this lane's index, returned by LANEID
    parameter bit HAS_QRCP = 1'b0    // QRCP unit (D22)
) (
    input  logic        clk,

    // ID
    input  logic [4:0]  rs1_addr,
    input  logic [4:0]  rs2_addr,
    input  logic        d_wb1,        // WB's rd = rs1_addr (shared compare)
    input  logic        d_wb2,
    input  logic        adv,          // the pipe advances: EX takes ID's operands

    // EX forwarding (shared rd compares; this lane's write enables below)
    input  logic        fm1,          // MEM's rd = EX's rs1, MEM writes rd
    input  logic        fm2,
    input  logic        fw1,          // WB's rd = EX's rs1
    input  logic        fw2,

    // EX
    input  logic        ex_go,        // EX moves to MEM: latch res, rs2
    input  logic [3:0]  alu_ctrl,
    input  logic        alu_a_pc,
    input  logic [1:0]  alu_b_sel,
    input  logic [2:0]  funct3,
    input  logic [31:0] pc,
    input  logic [31:0] imm,
    input  logic        res_imm,      // LUI
    input  logic        is_lane,      // custom-0 lane control
    input  logic [31:0] lane_y,       // BALLOT / MASKGET result (same in every lane)
    input  logic        ray_en,       // VGET: res = ray_y
    input  logic [31:0] ray_y,        // this lane's VGET field
    input  logic        stash,        // MUL, QRCP: res = rs1 for MEM

    output logic [31:0] rs1,          // forwarded EX operand rs1
    output logic [31:0] alu_y,
    output logic        cmp,

    // MEM
    input  logic [1:0]  mul_op,       // MEM funct3[1:0]
    input  logic        m_is_load,
    input  logic        m_mul,        // MEM holds a MUL
    input  logic        qr_s0,        // MEM, QRCP cycle 0 (x = res)
    input  logic        qr_s1,        // MEM, QRCP cycle 1
    input  logic        m_qr,         // MEM holds a QRCP
    input  logic        vt_wr,        // MEM, VTRACE done: res = vt_y
    input  logic [31:0] vt_y,
    input  logic        ld_cap,
    input  logic [31:0] ld_value,
    input  logic        m_we,         // MEM writes rd in this lane

    output logic [31:0] res,          // MEM: result, or the address for loads and stores
    output logic [31:0] m_rs2,        // MEM: store data
    output logic [31:0] wdata,        // MEM: value to write back

    // WB
    input  logic        w_we,
    input  logic [4:0]  w_rd
);

    // ------------------------------------------------------------------
    // ID: register read with the WB bypass
    // ------------------------------------------------------------------
    logic [31:0] rf1, rf2, d_rs1, d_rs2, w_res;

    reg_module #(.W(32), .D(32)) u_rf (
        .clk, .we(w_we), .wr(w_rd), .rd1(rs1_addr), .rd2(rs2_addr),
        .d_in(w_res), .d_out1(rf1), .d_out2(rf2)
    );

    assign d_rs1 = (rs1_addr == 5'd0) ? 32'd0 : (d_wb1 && w_we) ? w_res : rf1;
    assign d_rs2 = (rs2_addr == 5'd0) ? 32'd0 : (d_wb2 && w_we) ? w_res : rf2;

    // ------------------------------------------------------------------
    // EX
    // ------------------------------------------------------------------
    logic [31:0] e_rs1, e_rs2, rs2, fwd, alu_a, alu_b;

    assign rs1 = (fm1 && m_we) ? fwd : (fw1 && w_we) ? w_res : e_rs1;
    assign rs2 = (fm2 && m_we) ? fwd : (fw2 && w_we) ? w_res : e_rs2;

    always_ff @(posedge clk) begin
        e_rs1 <= adv ? d_rs1 : rs1;
        e_rs2 <= adv ? d_rs2 : rs2;
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

    // Branch compare on the forwarded operands, beside the ALU (same result
    // as the ALU's XOR / SLT / SLTU that the multi-cycle core tests):
    // BEQ/BNE equal, BLT/BGE signed less, BLTU/BGEU unsigned less.
    assign cmp = !funct3[2] ? (rs1 == rs2) :
                 funct3[1]  ? (rs1 < rs2) : ($signed(rs1) < $signed(rs2));

    // ------------------------------------------------------------------
    // MEM
    // ------------------------------------------------------------------
    logic [31:0] mul_y, qr_y, ld_hold;

    always_ff @(posedge clk) begin
        if (ex_go) begin
            if (ray_en)                              res <= ray_y;
            else if (stash)                          res <= rs1;
            else if (res_imm)                        res <= imm;
            else if (is_lane && funct3 == F3_LANEID) res <= 32'(ID);
            else if (is_lane)                        res <= lane_y;
            else                                     res <= alu_y;
            m_rs2 <= rs2;
        end else if (vt_wr) begin
            res <= vt_y;
        end
        if (ld_cap) ld_hold <= ld_value;
    end

    mul_pipe u_mul (.op(mul_op), .a(res), .b(m_rs2), .result(mul_y));

    if (HAS_QRCP) begin : g_qrcp
        qrcp_pipe u_qrcp (.clk, .s0(qr_s0), .s1(qr_s1), .x(res), .y(qr_y));
    end else begin : g_no_qrcp
        assign qr_y = 32'd0;
        /* verilator lint_off UNUSEDSIGNAL */
        logic unused_qr;
        assign unused_qr = qr_s0 ^ qr_s1;
        /* verilator lint_on UNUSEDSIGNAL */
    end

    assign fwd   = m_qr ? qr_y : res;
    assign wdata = m_is_load ? (ld_cap ? ld_value : ld_hold) : m_mul ? mul_y : fwd;

    // ------------------------------------------------------------------
    // WB: the register file writes w_res on the edge that ends WB
    // ------------------------------------------------------------------
    always_ff @(posedge clk) w_res <= wdata;

endmodule
