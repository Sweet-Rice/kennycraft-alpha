// t_ballot: runs sw/t_ballot.S (Stage 1 rung 5) and checks that BALLOT
// writes {0, M & (rs1 != 0)} into every lane, active or not.
module t_ballot_tb;
    parameter string IMEM_HEX = "";
    parameter string DMEM_HEX = "";
    `include "soc_harness.svh"
    `include "lane_check.svh"

    initial begin
        logic [7:0] m2;
        m2 = FULL & 8'h0F;

        do_reset();
        run_until_done(5000);
        repeat (10) @(posedge clk);
        expect_no_halt("t_ballot");

        expect_uniform(A0, 32'(FULL & 8'hAA), "BALLOT(odd), full mask");
        expect_uniform(A1, 32'(FULL & 8'hFE), "BALLOT(lane<<29), full mask");
        expect_uniform(A2, 32'(m2 & 8'hFE), "BALLOT(lane), M = 0x0F");
        expect_uniform(A3, 32'd0, "BALLOT(x0)");
        expect_uniform(A4, 32'd0, "BALLOT under M = 0");
        expect_uniform(A5, 32'd1, "BALLOT(1), M = 1");
        expect32("mask at the end", 32'(dut.u_core.mask), 32'd1);
        finish_test("t_ballot");
    end
endmodule
