// t_div_cond: runs sw/t_div_cond.S (Stage 1 rung 7, built with
// HAS_DIV_STACK = 1) and checks that DIF takes a lane when its rs1 is
// nonzero, whatever bit 0 is: then mask 0x6D, else mask 0x92, and a DIF on
// 0x100 in every lane runs its then body and skips the else body.
module t_div_cond_tb;
    parameter string IMEM_HEX = "";
    parameter string DMEM_HEX = "";
    `include "soc_harness.svh"
    `include "lane_check.svh"

    initial begin
        logic [7:0] t, e;
        t = FULL & 8'h6D;
        e = FULL & ~t;

        do_reset();
        run_until_done(5000);
        repeat (10) @(posedge clk);
        expect_no_halt("t_div_cond");

        expect_uniform(A0, 32'(t), "MASKGET in the then body");
        expect_masked(A1, t, 32'h11, 32'h51, "LI in the then body");
        if (e != 0) expect_uniform(A2, 32'(e), "MASKGET in the else body");
        else        expect_kept(A2, 32'h52, "else body skipped");
        expect_masked(A3, e, 32'h33, 32'h53, "LI in the else body");
        expect_uniform(A4, 32'(FULL), "MASKGET after DENDIF");
        expect_masked(T5, FULL, 32'h66, 32'h0, "then body, rs1 = 0x100");
        expect_kept(S9, 32'h5B, "else body skipped, rs1 = 0x100");
        expect_uniform(A5, 32'(FULL), "MASKGET at the end");
        expect32("stack empty", 32'(dut.u_core.g_divstack.u_divstack.sp), 32'd0);
        $display("  then %02h, else %02h", t, e);
        finish_test("t_div_cond");
    end
endmodule
