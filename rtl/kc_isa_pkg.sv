// KennyCraft ISA package. Interfaces v1.0.
//
// Source of truth: wiki Tai_2 section 1 (ISA v1.0) and section 2 (masking
// semantics v1.0), plus the Shared page Interfaces section (memory map, MMIO).
// Every module and testbench imports these names instead of typing opcodes.
// Never change a value here without a decision in the Shared page change
// request list: these encodings are frozen.

// A constants package is never fully used by one importer, and the field
// helpers read only part of the instruction word on purpose, so UNUSEDPARAM
// and UNUSEDSIGNAL are waived for this file only; every importer still lints
// clean under -Wall.
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off UNUSEDSIGNAL */
package kc_isa_pkg;

    // ------------------------------------------------------------------
    // Instruction fields (R-type layout, Tai_2 section 1)
    // ------------------------------------------------------------------
    // funct7 [31:25] · rs2 [24:20] · rs1 [19:15] · funct3 [14:12]
    // rd [11:7] · opcode [6:0]

    // ------------------------------------------------------------------
    // Base opcodes (RV32I + Zmmul)
    // ------------------------------------------------------------------
    localparam logic [6:0] OPC_LOAD     = 7'h03;
    localparam logic [6:0] OPC_MISC_MEM = 7'h0F;  // FENCE, FENCE.I: no-op
    localparam logic [6:0] OPC_OP_IMM   = 7'h13;
    localparam logic [6:0] OPC_AUIPC    = 7'h17;
    localparam logic [6:0] OPC_STORE    = 7'h23;
    localparam logic [6:0] OPC_OP       = 7'h33;  // ALU + Zmmul
    localparam logic [6:0] OPC_LUI      = 7'h37;
    localparam logic [6:0] OPC_BRANCH   = 7'h63;
    localparam logic [6:0] OPC_JALR     = 7'h67;
    localparam logic [6:0] OPC_JAL      = 7'h6F;
    localparam logic [6:0] OPC_SYSTEM   = 7'h73;  // ECALL, EBREAK, CSR*: illegal

    // OP funct7 values
    localparam logic [6:0] F7_BASE      = 7'b0000000;
    localparam logic [6:0] F7_ALT       = 7'b0100000;  // SUB, SRA
    localparam logic [6:0] F7_MULDIV    = 7'b0000001;  // Zmmul (funct3 0-3); DIV/REM (4-7) illegal

    // Zmmul funct3 (opcode OPC_OP, funct7 F7_MULDIV)
    localparam logic [2:0] F3_MUL       = 3'b000;
    localparam logic [2:0] F3_MULH      = 3'b001;
    localparam logic [2:0] F3_MULHSU    = 3'b010;
    localparam logic [2:0] F3_MULHU     = 3'b011;
    localparam logic [2:0] F3_DIV       = 3'b100;  // illegal
    localparam logic [2:0] F3_DIVU      = 3'b101;  // illegal
    localparam logic [2:0] F3_REM       = 3'b110;  // illegal
    localparam logic [2:0] F3_REMU      = 3'b111;  // illegal

    // Load/store funct3 (alignment rules use these)
    localparam logic [2:0] F3_LB        = 3'b000;
    localparam logic [2:0] F3_LH        = 3'b001;
    localparam logic [2:0] F3_LW        = 3'b010;
    localparam logic [2:0] F3_LBU       = 3'b100;
    localparam logic [2:0] F3_LHU       = 3'b101;
    localparam logic [2:0] F3_SB        = 3'b000;
    localparam logic [2:0] F3_SH        = 3'b001;
    localparam logic [2:0] F3_SW        = 3'b010;

    // ------------------------------------------------------------------
    // Custom opcodes
    // ------------------------------------------------------------------
    localparam logic [6:0] OPC_CUSTOM0  = 7'h0B;  // lane control, R-type, funct7 = 0
    localparam logic [6:0] OPC_CUSTOM1  = 7'h2B;  // ray unit, R-type (Stage 2)
    localparam logic [6:0] OPC_CUSTOM2  = 7'h5B;  // divergence, B-type / R-type

    // custom-0 (0x0B) funct3. 100 is reserved (illegal); QRCP (010) is
    // legal only in a build with HAS_QRCP = 1 (D22).
    localparam logic [2:0] F3_LANEID    = 3'b000;
    localparam logic [2:0] F3_LMASK     = 3'b001;
    localparam logic [2:0] F3_QRCP      = 3'b010;
    localparam logic [2:0] F3_BALLOT    = 3'b011;
    localparam logic [2:0] F3_MASKGET   = 3'b101;
    localparam logic [2:0] F3_MASKSET   = 3'b110;
    localparam logic [2:0] F3_MASKALL   = 3'b111;

    // custom-1 (0x2B) funct3. 011 to 111 are illegal.
    localparam logic [2:0] F3_VSET      = 3'b000;  // funct7 = field 0..7
    localparam logic [2:0] F3_VTRACE    = 3'b001;  // funct7 = 0
    localparam logic [2:0] F3_VGET      = 3'b010;  // funct7 = field 0..2

    // custom-2 (0x5B) funct3. 011 to 111 are illegal.
    localparam logic [2:0] F3_DIF       = 3'b000;  // B-type
    localparam logic [2:0] F3_DELSE     = 3'b001;  // B-type, rs1 = rs2 = x0
    localparam logic [2:0] F3_DENDIF    = 3'b010;  // R-type, all fields 0

    // ------------------------------------------------------------------
    // VSET fields (funct7 of VSET)
    // ------------------------------------------------------------------
    localparam logic [6:0] VSET_START_CELL = 7'd0;  // x 5:0, y 10:6, z 16:11
    localparam logic [6:0] VSET_TMAX_X     = 7'd1;  // Q16.16
    localparam logic [6:0] VSET_TMAX_Y     = 7'd2;
    localparam logic [6:0] VSET_TMAX_Z     = 7'd3;
    localparam logic [6:0] VSET_TDELTA_X   = 7'd4;  // Q16.16
    localparam logic [6:0] VSET_TDELTA_Y   = 7'd5;
    localparam logic [6:0] VSET_TDELTA_Z   = 7'd6;
    localparam logic [6:0] VSET_STEP_SIGN  = 7'd7;  // bit 0 x, 1 y, 2 z; 1 = negative

    // VGET fields (funct7 of VGET). Field 2 is the VTRACE result, for the
    // asynchronous VTRACE (rd = x0 starts the walk without waiting; VGET waits
    // for it). Field 3 is reserved for the fog stretch; 3 and up are illegal.
    localparam logic [6:0] VGET_HIT_CELL   = 7'd0;  // packed like VSET_START_CELL
    localparam logic [6:0] VGET_T_HIT      = 7'd1;  // Q16.16
    localparam logic [6:0] VGET_RESULT     = 7'd2;  // {16'b0, VTRACE result}
    localparam int unsigned VGET_NUM_FIELDS = 3;

    // ------------------------------------------------------------------
    // ERR register bit positions (MMIO ERR, Tai_2 section 2 Errors)
    // ------------------------------------------------------------------
    localparam int unsigned ERR_DIVERGE  = 0;
    localparam int unsigned ERR_DIVSTACK = 1;
    localparam int unsigned ERR_ILLEGAL  = 2;
    localparam int unsigned ERR_WIDTH    = 3;

    // Divergence stack depth (Tai_2 section 2)
    localparam int unsigned DIVSTACK_DEPTH = 8;

    // ------------------------------------------------------------------
    // Memory map (Shared page, Memory map). Region = address bits 31:28.
    // Regions 0x8 to 0xF are unmapped: loads return 0, stores dropped.
    // ------------------------------------------------------------------
    localparam logic [31:0] IMEM_BASE    = 32'h0000_0000;
    localparam int unsigned IMEM_BYTES   = 32 * 1024;
    localparam logic [31:0] DMEM_BASE    = 32'h1000_0000;
    localparam int unsigned DMEM_BYTES   = 32 * 1024;
    localparam logic [31:0] WORLD_BASE   = 32'h2000_0000;
    localparam logic [31:0] TEX_BASE     = 32'h3000_0000;
    localparam logic [31:0] FB_BASE      = 32'h4000_0000;
    localparam logic [31:0] MMIO_BASE    = 32'h5000_0000;
    localparam logic [31:0] PAL_BASE     = 32'h6000_0000;
    localparam logic [31:0] GPU_BASE     = 32'h7000_0000;
    localparam int unsigned GPU_BYTES    = 32'h0001_1000;  // 68 KB; offsets past it unmapped

    localparam logic [3:0]  REG_IMEM     = 4'h0;
    localparam logic [3:0]  REG_DMEM     = 4'h1;
    localparam logic [3:0]  REG_WORLD    = 4'h2;
    localparam logic [3:0]  REG_TEX      = 4'h3;
    localparam logic [3:0]  REG_FB       = 4'h4;
    localparam logic [3:0]  REG_MMIO     = 4'h5;
    localparam logic [3:0]  REG_PAL      = 4'h6;
    localparam logic [3:0]  REG_GPU      = 4'h7;

    // ------------------------------------------------------------------
    // MMIO offsets from MMIO_BASE
    // ------------------------------------------------------------------
    localparam logic [7:0] MMIO_FB_SWAP     = 8'h00;
    localparam logic [7:0] MMIO_FRAME_COUNT = 8'h04;
    localparam logic [7:0] MMIO_VSYNC       = 8'h08;
    localparam logic [7:0] MMIO_CYCLES      = 8'h0C;
    localparam logic [7:0] MMIO_UART_RX     = 8'h10;
    localparam logic [7:0] MMIO_UART_STATUS = 8'h14;  // bit 0 RX avail, bit 1 TX busy
    localparam logic [7:0] MMIO_UART_TX     = 8'h18;
    localparam logic [7:0] MMIO_ERR         = 8'h1C;  // write 1 to clear
    localparam logic [7:0] MMIO_ERR_PC      = 8'h20;
    localparam logic [7:0] MMIO_LEDS        = 8'h24;
    localparam logic [7:0] MMIO_FB_MODE     = 8'h28;
    localparam logic [7:0] MMIO_DDR_STATUS  = 8'h2C;  // bit 0 calib, 1 busy, 2 queue full
    localparam logic [7:0] MMIO_CHUNK_CMD   = 8'h30;
    localparam logic [7:0] MMIO_CHUNK_DONE  = 8'h34;
    localparam logic [7:0] MMIO_SLOT_VALID  = 8'h38;
    localparam logic [7:0] MMIO_WIN_ORIGIN  = 8'h3C;

    // ------------------------------------------------------------------
    // Field helpers
    // ------------------------------------------------------------------
    function automatic logic [6:0] instr_opcode(input logic [31:0] instr);
        return instr[6:0];
    endfunction

    function automatic logic [2:0] instr_funct3(input logic [31:0] instr);
        return instr[14:12];
    endfunction

    function automatic logic [6:0] instr_funct7(input logic [31:0] instr);
        return instr[31:25];
    endfunction

    function automatic logic [4:0] instr_rd(input logic [31:0] instr);
        return instr[11:7];
    endfunction

    function automatic logic [4:0] instr_rs1(input logic [31:0] instr);
        return instr[19:15];
    endfunction

    function automatic logic [4:0] instr_rs2(input logic [31:0] instr);
        return instr[24:20];
    endfunction

    // Standard B-type immediate, sign-extended, bit 0 always 0 (DIF, DELSE).
    function automatic logic [31:0] imm_b(input logic [31:0] instr);
        return {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};
    endfunction

    // ------------------------------------------------------------------
    // Illegal instruction check (Tai_2 section 1)
    // ------------------------------------------------------------------
    // Whitelist: every encoding that Tai_2 section 1 does not explicitly
    // define is illegal. Legal words are exactly:
    //   - RV32I: LUI, AUIPC, JAL; JALR with funct3 000; BEQ/BNE/BLT/BGE/
    //     BLTU/BGEU; LB/LH/LW/LBU/LHU; SB/SH/SW; the OP-IMM and OP ALU
    //     operations with their defined funct7 (SLLI/SRLI funct7 0000000,
    //     SRAI 0100000, SUB/SRA 0100000)
    //   - Zmmul: OP with funct7 0000001 and funct3 000..011
    //   - FENCE, FENCE.I (MISC-MEM funct3 000/001), executed as no-ops
    //   - custom-0: funct7 0 and funct3 000, 001, 011, 101, 110, 111, plus
    //     QRCP (funct3 010) with rs2 = 0 only when has_qrcp
    //   - custom-1 (only when has_ray_unit): VSET with funct7 0..7, VTRACE
    //     with funct7 0, VGET with funct7 0..2
    //   - custom-2 (only when has_div_stack): funct3 000..010
    // So DIV/DIVU/REM/REMU, the whole SYSTEM opcode (ECALL, EBREAK, CSR*),
    // every other opcode (including 16-bit compressed words) and every
    // reserved funct3/funct7 are illegal. Fields marked 0 in the custom
    // encoding table (rd/rs1/rs2, custom-2 funct7) are ignored, as Tai_2
    // states, and never make an instruction illegal, except QRCP's rs2,
    // which Tai_2 requires to be 0.
    //
    // The remaining illegal cases depend on runtime state, not on the
    // instruction word: misaligned data accesses (is_misaligned() below),
    // fetches outside instruction memory (is_fetch_outside_imem() below), and
    // taken branches, JAL and JALR whose target is not 4-aligned, which the
    // core catches at the jump itself (D16).
    //
    // The interface is LANES-independent: one 32-bit word in, one bit out.
    function automatic logic is_illegal(input logic [31:0] instr,
                                        input logic        has_ray_unit  = 1'b0,
                                        input logic        has_div_stack = 1'b1,
                                        input logic        has_qrcp      = 1'b0);
        logic [6:0] opc;
        logic [2:0] f3;
        logic [6:0] f7;
        logic       ill;
        opc = instr[6:0];
        f3  = instr[14:12];
        f7  = instr[31:25];
        unique case (opc)
            OPC_LUI, OPC_AUIPC, OPC_JAL:
                ill = 1'b0;
            OPC_JALR:
                ill = (f3 != 3'b000);
            OPC_BRANCH:
                ill = (f3 == 3'b010) || (f3 == 3'b011);
            OPC_LOAD:
                ill = (f3 == 3'b011) || (f3 == 3'b110) || (f3 == 3'b111);
            OPC_STORE:
                ill = (f3 > 3'b010);
            OPC_OP_IMM:
                unique case (f3)
                    3'b001:  ill = (f7 != F7_BASE);                     // SLLI
                    3'b101:  ill = (f7 != F7_BASE) && (f7 != F7_ALT);   // SRLI, SRAI
                    default: ill = 1'b0;
                endcase
            OPC_OP:
                unique case (f7)
                    F7_BASE:   ill = 1'b0;
                    F7_ALT:    ill = (f3 != 3'b000) && (f3 != 3'b101);  // SUB, SRA
                    F7_MULDIV: ill = f3[2];                             // DIV/REM
                    default:   ill = 1'b1;
                endcase
            OPC_MISC_MEM:
                ill = (f3[2:1] != 2'b00);                               // FENCE, FENCE.I
            OPC_CUSTOM0:
                ill = (f3 == 3'b100) || (f7 != 7'd0) ||
                      ((f3 == F3_QRCP) && (!has_qrcp || (instr[24:20] != 5'd0)));
            OPC_CUSTOM1: begin
                unique case (f3)
                    F3_VSET:   ill = (f7 > VSET_STEP_SIGN);
                    F3_VTRACE: ill = (f7 != 7'd0);
                    F3_VGET:   ill = (f7 >= 7'(VGET_NUM_FIELDS));
                    default:   ill = 1'b1;
                endcase
                if (!has_ray_unit) ill = 1'b1;
            end
            OPC_CUSTOM2:
                ill = (f3 > F3_DENDIF) || !has_div_stack;
            default:                                                    // SYSTEM and everything undefined
                ill = 1'b1;
        endcase
        return ill;
    endfunction

    // Misaligned data access: LW/SW not 4-aligned, LH/LHU/SH not 2-aligned.
    // funct3 is the load/store funct3, addr_lo the low two address bits.
    function automatic logic is_misaligned(input logic [2:0] funct3,
                                           input logic [1:0] addr_lo);
        unique case (funct3[1:0])
            2'b01:   return addr_lo[0];         // LH, LHU, SH
            2'b10:   return addr_lo != 2'b00;   // LW, SW
            default: return 1'b0;               // LB, LBU, SB
        endcase
    endfunction

    // Fetch outside instruction memory (0x0000_0000 to 0x0000_7FFF).
    function automatic logic is_fetch_outside_imem(input logic [31:0] pc);
        return pc >= (IMEM_BASE + IMEM_BYTES);
    endfunction

endpackage
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */
