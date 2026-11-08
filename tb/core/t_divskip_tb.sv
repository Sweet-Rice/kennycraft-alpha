// t_divskip: runs sw/t_divskip.S (Stage 1 rung 7, HAS_DIV_STACK = 1) and
// checks that DIF and DELSE jump over bodies whose mask would be empty
// (false everywhere, M = 0, a nested DIF under an emptied body) and that the
// stack stays balanced.
module t_divskip_tb;
    parameter string IMEM_HEX = "";
    parameter string DMEM_HEX = "";
    `include "soc_harness.svh"
    `include "lane_check.svh"

    initial begin
        do_reset();
        run_until_done(5000);
        repeat (10) @(posedge clk);
        expect_no_halt("t_divskip");

        expect_kept(A0, 32'h50, "1: then body skipped");
        expect_masked(A1, FULL, 32'h11, 32'h51, "1: else body ran");
        expect_uniform(A2, 32'(FULL), "1: MASKGET after DENDIF");
        expect_kept(A3, 32'h53, "2: body skipped to DENDIF");
        expect_uniform(A4, 32'(FULL), "2: MASKGET after DENDIF");
        expect_kept(A5, 32'h55, "3: both bodies skipped under M = 0");
        expect_uniform(A6, 32'd0, "3: M = 0 after DENDIF");
        expect_kept(A7, 32'h57, "4: nested and else bodies skipped");
        expect_uniform(T3, 32'd0, "4: M = 0 after the nested DENDIF");
        expect_uniform(T4, 32'(FULL), "4: MASKGET after the outer DENDIF");
        expect32("stack empty", 32'(`KC_CORE.g_divstack.u_divstack.sp), 32'd0);
        finish_test("t_divskip");
    end
endmodule
