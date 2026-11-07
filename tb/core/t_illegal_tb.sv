// t_illegal: runs every case of sw/t_illegal.S from its own reset and checks
// that each one halts with ERR.ILLEGAL, the right ERR_PC, the error LED on,
// rd and memory untouched and nothing fetched afterwards. The last case is
// the legal control (no halt, reset cleared ERR/ERR_PC, unmapped reads 0).
module t_illegal_tb;
    parameter string IMEM_HEX = "";
    parameter string DMEM_HEX = "";
    `include "soc_harness.svh"

    localparam int NCASES = 23;   // faulting cases 0..22, control is 23

    localparam logic [31:0] TB_SELECT = 32'h1000_00F0;
    localparam logic [31:0] TB_MARK   = 32'h1000_00F4;
    localparam logic [31:0] TB_DONE   = 32'h1000_00FC;

    function automatic logic [31:0] case_pc(input int k);
        return (k == 15) ? 32'h0000_8000 : (k == 17) ? 32'h0000_0544 : 32'h100 + 32'h40 * k;
    endfunction

    function automatic string case_name(input int k);
        case (k)
            0: return "DIV";        1: return "DIVU";       2: return "REM";
            3: return "REMU";       4: return "ECALL";      5: return "EBREAK";
            6: return "CSR read";   7: return "misaligned LW";
            8: return "misaligned LH";  9: return "misaligned SW";
            10: return "misaligned SH"; 11: return "VGET field 2";
            12: return "VTRACE (no ray unit)"; 13: return "custom-0 funct3 010";
            14: return "DENDIF (Stage 0)";     15: return "fetch outside imem";
            16: return "all-zero word";        17: return "JALR misaligned target";
            18: return "opcode 0x07 (FLW)";    19: return "OP funct7 0x10";
            20: return "LOAD funct3 011 (LD)"; 21: return "BEQ misaligned target";
            22: return "JAL misaligned target";
            default: return "?";
        endcase
    endfunction

    int errors = 0;

    task automatic expect32(input string what, input logic [31:0] got, input logic [31:0] exp);
        if (got !== exp) begin
            $display("  FAIL %-34s got %08h expected %08h", what, got, exp);
            errors++;
        end
    endtask

    initial begin
        logic [31:0] pc_halt;
        for (int k = 0; k <= NCASES; k++) begin
            dmem_wr(TB_SELECT, k);
            dmem_wr(TB_MARK, 32'd0);
            dmem_wr(TB_DONE, 32'd0);
            do_reset();
            run_until_done(2000);

            if (k == NCASES) begin
                expect32("control: halted", {31'b0, err_led}, 32'd0);
                expect32("control: done", dmem_rd(TB_DONE), 32'd1);
                expect32("control: ERR cleared by reset", dmem_rd(32'h1000_00E0), 32'd0);
                expect32("control: ERR_PC cleared by reset", dmem_rd(32'h1000_00E4), 32'd0);
                expect32("control: unmapped load", dmem_rd(32'h1000_00EC), 32'd0);
                expect32("control: imem-region load", dmem_rd(32'h1000_00D8), 32'd0);
                expect32("control: ERR register", {29'b0, dut.u_mmio.err}, 32'd0);
                $display("  case %2d  legal control: FENCE, FENCE.I, not-taken misaligned BNE, ERR cleared by reset, unmapped reads 0", k);
                continue;
            end

            // Halted: let it sit and make sure nothing moves.
            pc_halt = dut.u_core.pc;
            repeat (100) @(posedge clk);
            expect32($sformatf("%s: error LED", case_name(k)), {31'b0, err_led}, 32'd1);
            expect32($sformatf("%s: ERR", case_name(k)), {29'b0, dut.u_mmio.err}, 32'd4);
            expect32($sformatf("%s: ERR_PC", case_name(k)), dut.u_mmio.err_pc, case_pc(k));
            expect32($sformatf("%s: PC frozen", case_name(k)), dut.u_core.pc, pc_halt);
            expect32($sformatf("%s: rd not written", case_name(k)), xreg(12), 32'h55);
            expect32($sformatf("%s: next instr not run", case_name(k)), dmem_rd(TB_MARK), 32'd0);
            $display("  case %2d  %-22s ERR=%0d ERR_PC=%08h", k, case_name(k),
                     dut.u_mmio.err, dut.u_mmio.err_pc);
        end

        if (errors != 0) $fatal(1, "FAIL: t_illegal, %0d mismatches", errors);
        $display("PASS: t_illegal (%0d halting cases + legal control)", NCASES);
        $finish;
    end
endmodule
