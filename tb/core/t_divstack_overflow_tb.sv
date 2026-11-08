// t_divstack_overflow: runs every case of sw/t_divstack_overflow.S (Stage 1
// rung 7, HAS_DIV_STACK = 1) from its own reset: eight nested DIFs are
// fine, the ninth halts with ERR.DIVSTACK, so do DELSE and DENDIF on an
// empty stack, and a DIF or DELSE that jumps to a misaligned label halts
// with ERR.ILLEGAL. A halt leaves the stack pointer and the mask as they
// were before the faulting instruction.
module t_divstack_overflow_tb;
    parameter string IMEM_HEX = "";
    parameter string DMEM_HEX = "";
    `include "soc_harness.svh"
    `include "lane_check.svh"

    localparam int NCASES = 5;

    function automatic string case_name(input int k);
        case (k)
            1: return "nine nested DIFs";
            2: return "DELSE, empty stack";
            3: return "DENDIF, empty stack";
            4: return "DIF jumps to a misaligned label";
            5: return "DELSE jumps to a misaligned label";
            default: return "?";
        endcase
    endfunction

    function automatic logic [31:0] case_pc(input int k);
        return 32'h100 + 32'h80 * k + ((k == 1) ? 32'h20 : (k == 5) ? 32'h4 : 32'h0);
    endfunction

    function automatic logic [2:0] case_err(input int k);
        return (k >= 4) ? 3'b100 : 3'b010;
    endfunction

    function automatic int case_sp(input int k);
        return (k == 1) ? 8 : (k == 5) ? 1 : 0;
    endfunction

    initial begin
        run_case(0, 5000);
        repeat (10) @(posedge clk);
        expect_no_halt("case 0");
        expect_uniform(A0, 32'(FULL), "case 0: MASKGET after 8 DIF / 8 DENDIF");
        expect32("case 0: stack empty", 32'(`KC_CORE.g_divstack.u_divstack.sp), 32'd0);
        $display("  case  0  control: 8 nested DIF/DENDIF, DIF falling through past a misaligned label");

        for (int k = 1; k <= NCASES; k++) begin
            run_case(k, 2000);
            expect_halt(case_name(k), case_err(k), case_pc(k));
            expect32({case_name(k), ": stack pointer"},
                     32'(`KC_CORE.g_divstack.u_divstack.sp), 32'(case_sp(k)));
            expect32({case_name(k), ": mask"}, 32'(`KC_CORE.mask), 32'(FULL));
            $display("  case %2d  %-34s ERR=%0d ERR_PC=%08h sp=%0d", k, case_name(k),
                     dut.u_mmio.err, dut.u_mmio.err_pc, `KC_CORE.g_divstack.u_divstack.sp);
        end
        finish_test("t_divstack_overflow");
    end
endmodule
