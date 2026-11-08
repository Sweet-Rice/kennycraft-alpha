// t_divstack: runs sw/t_divstack.S (Stage 1 rung 7, built with
// HAS_DIV_STACK = 1) and checks the Tai page walkthrough: then mask 0x13,
// nested if/else, a uniform branch inside the body, else mask 0xEC, the
// restored mask, and DELSE jumping over an empty else body. The stack must
// be empty at the end.
module t_divstack_tb;
    parameter string IMEM_HEX = "";
    parameter string DMEM_HEX = "";
    `include "soc_harness.svh"
    `include "lane_check.svh"

    initial begin
        logic [7:0] t, e, t2, e2;
        t  = FULL & 8'h13;
        e  = FULL & ~t;
        t2 = t & 8'hAA;
        e2 = t & ~8'hAA;

        do_reset();
        run_until_done(5000);
        repeat (10) @(posedge clk);
        expect_no_halt("t_divstack");

        expect_uniform(T3, 32'(FULL), "MASKGET before DIF");
        expect_uniform(A0, 32'(t), "MASKGET in the then body");
        expect_masked(A1, t, 32'h11, 32'h51, "LI in the then body");
        expect_masked(A2, t2, 32'h22, 32'h52, "LI in the nested then");
        expect_masked(A3, e2, 32'h33, 32'h53, "LI in the nested else");
        expect_uniform(A4, 32'(t), "MASKGET after the nested DENDIF");
        expect_masked(A5, t, 32'd1, 32'h55, "uniform branch in the body");
        if (e != 0) expect_uniform(A6, 32'(e), "MASKGET in the else body");
        else        expect_kept(A6, 32'h56, "else body skipped");
        expect_masked(A7, e, 32'h77, 32'h57, "LI in the else body");
        expect_uniform(T4, 32'(FULL), "MASKGET after DENDIF");
        expect_masked(T5, FULL, 32'h66, 32'h0, "then body, all true");
        expect_kept(S9, 32'h5B, "empty else body skipped");
        expect_uniform(S4, 32'(FULL), "MASKGET at the end");
        expect32("stack empty", 32'(`KC_CORE.g_divstack.u_divstack.sp), 32'd0);
        $display("  then %02h (nested %02h / %02h), else %02h", t, t2, e2, e);
        finish_test("t_divstack");
    end
endmodule
