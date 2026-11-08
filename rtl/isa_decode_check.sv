// Small decode module used only to check the ISA package against the Tai_2
// encoding table (tb/isa/test_encoding.cpp). Purely combinational.
//
// instr_id numbers the custom instructions in the order of the Tai_2 table
// (1 = LANEID, 3 = QRCP ... 13 = DENDIF); 0 means "not one of the 13
// custom instructions" (base ISA or illegal custom encoding).

module isa_decode_check
    import kc_isa_pkg::*;
(
    input  logic [31:0] instr,
    input  logic        has_ray_unit,
    input  logic        has_div_stack,
    input  logic        has_qrcp,
    output logic [6:0]  opcode,
    output logic [2:0]  funct3,
    output logic [6:0]  funct7,
    output logic [4:0]  rd,
    output logic [4:0]  rs1,
    output logic [4:0]  rs2,
    output logic [31:0] b_imm,
    output logic        is_custom,
    output logic        is_btype,
    output logic [3:0]  instr_id,
    output logic        illegal
);

    assign opcode  = instr_opcode(instr);
    assign funct3  = instr_funct3(instr);
    assign funct7  = instr_funct7(instr);
    assign rd      = instr_rd(instr);
    assign rs1     = instr_rs1(instr);
    assign rs2     = instr_rs2(instr);
    assign b_imm   = imm_b(instr);
    assign illegal = is_illegal(instr, has_ray_unit, has_div_stack, has_qrcp);

    assign is_custom = (opcode == OPC_CUSTOM0) || (opcode == OPC_CUSTOM1)
                    || (opcode == OPC_CUSTOM2);
    assign is_btype  = (opcode == OPC_CUSTOM2)
                    && ((funct3 == F3_DIF) || (funct3 == F3_DELSE));

    always_comb begin
        instr_id = 4'd0;
        if (!illegal) begin
            unique case (opcode)
                OPC_CUSTOM0:
                    unique case (funct3)
                        F3_LANEID:  instr_id = 4'd1;
                        F3_LMASK:   instr_id = 4'd2;
                        F3_QRCP:    instr_id = 4'd3;
                        F3_BALLOT:  instr_id = 4'd4;
                        F3_MASKGET: instr_id = 4'd5;
                        F3_MASKSET: instr_id = 4'd6;
                        F3_MASKALL: instr_id = 4'd7;
                        default:    instr_id = 4'd0;
                    endcase
                OPC_CUSTOM1:
                    unique case (funct3)
                        F3_VSET:    instr_id = 4'd8;
                        F3_VTRACE:  instr_id = 4'd9;
                        F3_VGET:    instr_id = 4'd10;
                        default:    instr_id = 4'd0;
                    endcase
                OPC_CUSTOM2:
                    unique case (funct3)
                        F3_DIF:     instr_id = 4'd11;
                        F3_DELSE:   instr_id = 4'd12;
                        F3_DENDIF:  instr_id = 4'd13;
                        default:    instr_id = 4'd0;
                    endcase
                default:            instr_id = 4'd0;
            endcase
        end
    end

endmodule
