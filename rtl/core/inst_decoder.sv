// Instruction decoder for the core: RV32I + Zmmul + custom-0 lane control and
// QRCP + custom-1 ray unit + custom-2 divergence stack (Tai_2 section 1).
//
// illegal is exactly kc_isa_pkg::is_illegal: every encoding Tai_2 section 1
// does not define is illegal, plus custom-1/custom-2/QRCP when the build lacks
// the ray unit / divergence stack / QRCP unit (the "unit absent" rule).
// is_ray / is_div / is_qrcp are only ever set when HAS_RAY_UNIT /
// HAS_DIV_STACK / HAS_QRCP = 1. FENCE and FENCE.I decode as no-ops.
//
// alu_ctrl = {sub/sra, funct3} for OP and OP-IMM, and the compare the branch
// needs for BRANCH (XOR for BEQ/BNE, SLT for BLT/BGE, SLTU for BLTU/BGEU).
module inst_decoder
    import kc_isa_pkg::*;
#(
    parameter bit HAS_DIV_STACK = 1'b0,   // custom-2 (DIF, DELSE, DENDIF)
    parameter bit HAS_RAY_UNIT  = 1'b0,   // custom-1 (VSET, VTRACE, VGET)
    parameter bit HAS_QRCP      = 1'b0    // custom-0 funct3 010 (QRCP, D22)
) (
    input  logic [31:0] inst,
    output logic [3:0]  alu_ctrl,
    output logic        alu_a_pc,    // ALU a = PC instead of rs1
    output logic [1:0]  alu_b_sel,   // 00 rs2, 01 imm, 10 constant 4
    output logic [2:0]  imm_sig,     // 000 U, 100 I, 101 S, 110 B, 111 J
    output logic        r_we,
    output logic        res_imm,     // result = immediate (LUI)
    output logic        is_load,
    output logic        is_store,
    output logic        is_mul,
    output logic        is_branch,
    output logic        is_jal,
    output logic        is_jalr,
    output logic        is_lane,     // custom-0 lane control, op in funct3
    output logic        is_div,      // custom-2 DIF / DELSE / DENDIF, op in funct3
    output logic        is_ray,      // custom-1 VSET / VTRACE / VGET, op in funct3
    output logic        is_qrcp,     // QRCP (custom-0 funct3 010), not is_lane
    output logic        uniform_wr,  // writes rd in every lane (BALLOT, MASKGET)
    output logic        illegal
);

    logic [6:0] opc, f7;
    logic [2:0] f3;

    assign opc = instr_opcode(inst);
    assign f3  = instr_funct3(inst);
    assign f7  = instr_funct7(inst);

    always_comb begin
        alu_ctrl  = 4'b0000;   // ADD
        alu_a_pc  = 1'b0;
        alu_b_sel = 2'b01;
        imm_sig   = 3'b000;
        r_we      = 1'b0;
        res_imm   = 1'b0;
        is_load   = 1'b0;
        is_store  = 1'b0;
        is_mul    = 1'b0;
        is_branch = 1'b0;
        is_jal    = 1'b0;
        is_jalr    = 1'b0;
        is_lane    = 1'b0;
        is_div     = 1'b0;
        is_ray     = 1'b0;
        is_qrcp    = 1'b0;
        uniform_wr = 1'b0;
        illegal    = is_illegal(inst, HAS_RAY_UNIT, HAS_DIV_STACK, HAS_QRCP);

        unique case (opc)
            OPC_LUI: begin
                r_we    = 1'b1;
                res_imm = 1'b1;
            end
            OPC_AUIPC: begin
                r_we     = 1'b1;
                alu_a_pc = 1'b1;
            end
            OPC_JAL: begin
                r_we      = 1'b1;
                alu_a_pc  = 1'b1;
                alu_b_sel = 2'b10;
                imm_sig   = 3'b111;
                is_jal    = 1'b1;
            end
            OPC_JALR: begin
                r_we      = 1'b1;
                alu_a_pc  = 1'b1;
                alu_b_sel = 2'b10;
                imm_sig   = 3'b100;
                is_jalr   = 1'b1;
            end
            OPC_BRANCH: begin
                alu_b_sel   = 2'b00;
                imm_sig     = 3'b110;
                is_branch   = 1'b1;
                alu_ctrl[2] = ~(|f3[2:1]);   // BEQ/BNE -> XOR
                alu_ctrl[1:0] = f3[2:1];     // BLT/BGE -> SLT, BLTU/BGEU -> SLTU
            end
            OPC_LOAD: begin
                r_we    = 1'b1;
                imm_sig = 3'b100;
                is_load = 1'b1;
            end
            OPC_STORE: begin
                imm_sig  = 3'b101;
                is_store = 1'b1;
            end
            OPC_OP_IMM: begin
                r_we     = 1'b1;
                imm_sig  = 3'b100;
                alu_ctrl = {f7[5] & (f3 == 3'b101), f3};
            end
            OPC_OP: begin
                r_we      = 1'b1;
                alu_b_sel = 2'b00;
                alu_ctrl  = {f7[5], f3};
                is_mul    = (f7 == F7_MULDIV);
            end
            OPC_CUSTOM0: begin
                is_qrcp    = HAS_QRCP && (f3 == F3_QRCP);
                is_lane    = !is_qrcp;
                r_we       = (f3 == F3_LANEID) || (f3 == F3_BALLOT) || (f3 == F3_MASKGET) ||
                             is_qrcp;
                uniform_wr = (f3 == F3_BALLOT) || (f3 == F3_MASKGET);
            end
            OPC_CUSTOM1: begin
                is_ray = HAS_RAY_UNIT;
                r_we   = HAS_RAY_UNIT && ((f3 == F3_VTRACE) || (f3 == F3_VGET));
            end
            OPC_CUSTOM2: begin
                is_div  = HAS_DIV_STACK;
                imm_sig = 3'b110;           // DIF, DELSE: B-type label
            end
            default: ;   // MISC-MEM (FENCE no-op) and illegal words
        endcase
    end

endmodule
