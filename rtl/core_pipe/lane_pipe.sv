// One SIMD lane of the pipelined core (rtl/core_pipe/core_pipe.sv): the
// per-lane datapath of rtl/core/lane.sv cut into the ID / EX / MEM / WB
// stages, with this lane's forwarding. The shared control in core_pipe drives
// every lane with the same instruction in each stage.
//
//   ID   read rs1 / rs2 from the register file, bypassing the WB write of
//        the same cycle (the register file writes on the clock edge)
//   EX   forwarded operands: MEM's result, else WB's, else the ID read, each
//        only when that stage writes rd in this lane (fm*, a register that
//        holds MEM's write enable, and w_we, which carry the lane's mask
//        bit). While EX waits for MEM the operands are
//        recaptured every cycle, so a WB result is not lost when it retires.
//        ALU, comparator, and the result latched into res: the ALU output
//        (or this lane's address for loads and stores), LUI immediate,
//        LANEID, BALLOT / MASKGET, VGET field, or rs1 for MUL and QRCP,
//        which run in MEM on registered operands
//   MEM  res and the store data / multiplier operand rs2. MUL (mul_pipe:
//        the partial products of res and m_rs2 registered in MEM's first
//        cycle, summed in its second), QRCP
//        (qrcp_pipe: seven register stages, y valid in the eighth cycle),
//        the VTRACE result at the ray unit's done, and the LSU's load data
//        (ld_cap / ld_value, held in ld_hold). fwd is MEM's result for
//        forwarding
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

    // EX forwarding (registered selects: fm* already holds this lane's
    // MEM write enable; fw* is the shared rd compare, w_we below)
    input  logic        fm1,          // MEM writes rd in this lane, rd = EX's rs1
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
    input  logic        is_jalr,      // JALR: m_rs2 = ea for MEM's target check

    output logic [31:0] rs1,          // forwarded EX operand rs1
    output logic [31:0] ea,           // rs1 + imm: load/store address, JALR sum
    output logic        cmp,

    // MEM
    input  logic [1:0]  mul_op,       // MEM funct3[1:0]
    input  logic        m_is_load,
    input  logic        m_mul,        // MEM holds a MUL
    input  logic        qr_s0,        // MEM, QRCP cycle 0 (x = res)
    input  logic        m_qr,         // MEM holds a QRCP
    input  logic        vt_wr,        // MEM, VTRACE done: res = vt_y
    input  logic [31:0] vt_y,
    input  logic        ld_cap,
    input  logic [31:0] ld_value,

    output logic [31:0] res,          // MEM: result, or the address for loads and stores
    output logic [31:0] m_rs2,        // MEM: store data (a JALR's ea)
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
    logic [31:0] e_rs1, e_rs2, rs2, fwd, alu_a, alu_b, alu_y, res_oth;
    logic [31:0] sh_in, sh_out, sum;
    logic        lt, ltu, use_alu;

    assign rs1 = fm1 ? fwd : (fw1 && w_we) ? w_res : e_rs1;
    assign rs2 = fm2 ? fwd : (fw2 && w_we) ? w_res : e_rs2;

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

    // The ALU of rtl/core/alu.sv (same op encoding and results), except
    // that the shifter reads rs1 directly: only AUIPC, JAL and JALR (ADD)
    // take pc as operand a, so the pc mux stays off the shift path, and the
    // SLL operand reversal is one LUT on the forwarded rs1.
    assign sh_in = (alu_ctrl[2:0] == 3'b001) ? {<<{rs1}} : rs1;   // SLL : SRL/SRA

    barrel_shifter #(.W(32)) u_sh (
        .a(sh_in), .b(alu_b[4:0]), .sel(alu_ctrl[3] & rs1[31]), .result(sh_out)
    );

    addsub #(.W(32)) u_addsub (
        .a(alu_a), .b(alu_b), .sub(alu_ctrl[3] | alu_ctrl[1]), .sum(sum), .lt(lt), .ltu(ltu)
    );

    always_comb begin
        unique case (alu_ctrl[2:0])
            3'b000: alu_y = sum;                   // ADD, SUB
            3'b001: alu_y = {<<{sh_out}};          // SLL
            3'b010: alu_y = {31'd0, lt};           // SLT
            3'b011: alu_y = {31'd0, ltu};          // SLTU
            3'b100: alu_y = alu_a ^ alu_b;         // XOR
            3'b101: alu_y = sh_out;                // SRL, SRA
            3'b110: alu_y = alu_a | alu_b;         // OR
            3'b111: alu_y = alu_a & alu_b;         // AND
        endcase
    end

    assign use_alu = !(ray_en || stash || res_imm || is_lane);
    assign res_oth = ray_en                 ? ray_y :
                     stash                  ? rs1 :
                     res_imm                ? imm :
                     (funct3 == F3_LANEID)  ? 32'(ID) : lane_y;   // is_lane

    // The load/store address (the ALU's rs1 + imm, which res latches) and
    // the JALR sum, from an adder of its own without the ALU's operand and
    // result muxes: core_pipe's misaligned check, dmem window, coalescing
    // compares and JALR target read it.
    assign ea = rs1 + imm;

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
        // res: the non-ALU results (res_oth, use_alu: decode registers and
        // rs1) are muxed beside the ALU, so alu_y meets one select. vt_wr
        // comes first: it is never high with ex_go (MEM's VTRACE holds EX
        // until the cycle after vt_wr), and adv stays off res's data path.
        if (vt_wr)      res <= vt_y;
        else if (ex_go) res <= use_alu ? alu_y : res_oth;
        if (ex_go) m_rs2 <= is_jalr ? ea : rs2;
        if (ld_cap) ld_hold <= ld_value;
    end

    mul_pipe u_mul (.clk, .op(mul_op), .a(res), .b(m_rs2), .result(mul_y));

    if (HAS_QRCP) begin : g_qrcp
        qrcp_pipe u_qrcp (.clk, .s0(qr_s0), .x(res), .y(qr_y));
    end else begin : g_no_qrcp
        assign qr_y = 32'd0;
        /* verilator lint_off UNUSEDSIGNAL */
        logic unused_qr;
        assign unused_qr = qr_s0;
        /* verilator lint_on UNUSEDSIGNAL */
    end

    assign fwd   = m_qr ? qr_y : res;
    assign wdata = m_is_load ? (ld_cap ? ld_value : ld_hold) : m_mul ? mul_y : fwd;

    // ------------------------------------------------------------------
    // WB: the register file writes w_res on the edge that ends WB
    // ------------------------------------------------------------------
    always_ff @(posedge clk) w_res <= wdata;

endmodule
