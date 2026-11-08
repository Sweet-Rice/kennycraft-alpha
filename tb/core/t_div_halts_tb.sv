// t_div_halts: runs every case of sw/t_div_halts.S (Stage 1 rung 7,
// HAS_DIV_STACK = 1) from its own reset. Case 0 must not halt: inside a DIF
// body a branch and a JALR that disagree only in lanes outside the body mask
// are uniform. Cases 1..3 diverge within the body mask and halt with
// ERR.DIVERGE at the branch or JALR (slot + 4), case 3 although its target
// is misaligned. Cases 4 and 5 halt with ERR.DIVSTACK although their labels
// are misaligned, and cases 6..10 (custom-2 funct3 011..111) with
// ERR.ILLEGAL. A halt leaves the stack pointer and the mask as they were.
// With one lane that can be active nothing diverges, so cases 1..3 are left
// out.
module t_div_halts_tb;
    parameter string IMEM_HEX = "";
    parameter string DMEM_HEX = "";
    `include "soc_harness.svh"
    `include "lane_check.svh"

    localparam int NCASES = 10;

    function automatic string case_name(input int k);
        case (k)
            1: return "divergent branch in a DIF body";
            2: return "divergent JALR in a DIF body";
            3: return "divergent branch, misaligned target";
            4: return "DELSE, empty stack, misaligned label";
            5: return "ninth DIF, t = 0, misaligned label";
            default: return $sformatf("custom-2 funct3 %03b", 3'(k - 3));
        endcase
    endfunction

    function automatic logic [31:0] case_pc(input int k);
        return 32'h100 + 32'h80 * k + ((k <= 3) ? 32'h4 : (k == 5) ? 32'h20 : 32'h0);
    endfunction

    function automatic logic [2:0] case_err(input int k);
        return (k <= 3) ? 3'b001 : (k <= 5) ? 3'b010 : 3'b100;
    endfunction

    function automatic int case_sp(input int k);
        return (k <= 3) ? 1 : (k == 5) ? 8 : 0;
    endfunction

    initial begin
        logic [7:0] body;
        body = FULL & 8'h13;

        run_case(0, 5000);
        repeat (10) @(posedge clk);
        expect_no_halt("case 0");
        expect_masked(A3, body, 32'd1, 32'h53, "branch uniform over the body");
        expect_masked(A1, body, xreg(T4), 32'h51, "JALR links in the body");
        expect_masked(A2, body, 32'd1, 32'h52, "JALR target of the body");
        expect_uniform(A0, 32'(FULL), "MASKGET after DENDIF");
        expect32("case 0: stack empty", 32'(`KC_CORE.g_divstack.u_divstack.sp), 32'd0);
        $display("  case  0  control: branch and JALR disagree outside body %02h only", body);

        for (int k = 1; k <= NCASES; k++) begin
            if (k <= 3 && ALANES == 1) continue;
            run_case(k, 2000);
            expect_halt(case_name(k), case_err(k), case_pc(k));
            expect32({case_name(k), ": stack pointer"},
                     32'(`KC_CORE.g_divstack.u_divstack.sp), 32'(case_sp(k)));
            expect32({case_name(k), ": mask"}, 32'(`KC_CORE.mask),
                     32'((k <= 3) ? body : FULL));
            if (k == 2) expect_kept(RA, 32'h77, "case 2: ra not linked");
            $display("  case %2d  %-38s ERR=%0d ERR_PC=%08h sp=%0d", k, case_name(k),
                     dut.u_mmio.err, dut.u_mmio.err_pc, `KC_CORE.g_divstack.u_divstack.sp);
        end
        finish_test("t_div_halts");
    end
endmodule
