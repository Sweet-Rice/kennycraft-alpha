// t_div_nested_lmask: runs sw/t_div_nested_lmask.S (Stage 1 rung 7,
// HAS_DIV_STACK = 1) and checks that LMASK and MASKSET inside if/else bodies
// only last until the matching DELSE / DENDIF.
module t_div_nested_lmask_tb;
    parameter string IMEM_HEX = "";
    parameter string DMEM_HEX = "";
    `include "soc_harness.svh"
    `include "lane_check.svh"

    initial begin
        logic [7:0] t, m1, e, ms;
        t  = FULL & 8'h3F;
        m1 = t & 8'hAA;
        e  = FULL & ~t;
        ms = FULL & 8'h0F;

        do_reset();
        run_until_done(5000);
        repeat (10) @(posedge clk);
        expect_no_halt("t_div_nested_lmask");

        expect_masked(A0, m1, 32'h11, 32'h50, "LI after LMASK in the then body");
        expect_kept(A4, 32'h54, "nested body under LMASK x0");
        expect_masked(A3, m1, 32'h33, 32'h53, "LI after the nested DENDIF");
        expect_uniform(T3, 32'(m1), "MASKGET after the nested DENDIF");
        if (e != 0) begin
            expect_uniform(T4, 32'(e), "DELSE ignores the LMASK");
            expect_uniform(T5, 32'(ms), "MASKSET in the else body");
            expect_masked(A1, ms, 32'h22, 32'h51, "LI after MASKSET in the else body");
        end else begin
            expect_kept(T4, 32'h5D, "else body skipped");
            expect_kept(A1, 32'h51, "else body skipped");
        end
        expect_uniform(A2, 32'(FULL), "DENDIF restores the full mask");
        expect32("stack empty", 32'(`KC_CORE.g_divstack.u_divstack.sp), 32'd0);
        $display("  then %02h, after LMASK %02h, else %02h, after MASKSET %02h, end %02h",
                 t, m1, e, ms, FULL);
        finish_test("t_div_nested_lmask");
    end
endmodule
