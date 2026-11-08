// t_mask: runs sw/t_mask.S (Stage 1 rung 5) and checks LMASK: which lanes
// wrote rd after each LMASK, MASKGET in every lane, and that LMASK never
// wakes an inactive lane.
module t_mask_tb;
    parameter string IMEM_HEX = "";
    parameter string DMEM_HEX = "";
    `include "soc_harness.svh"
    `include "lane_check.svh"

    initial begin
        logic [7:0] nz, odd, hi, m1, m2, m3;
        nz  = FULL & 8'hFE;
        odd = FULL & 8'hAA;
        hi  = FULL & 8'hF0;
        m1  = nz;
        m2  = m1 & odd;
        m3  = m2 & hi;

        do_reset();
        run_until_done(5000);
        repeat (10) @(posedge clk);
        expect_no_halt("t_mask");

        expect_masked(A0, m1, 32'hA0, 32'h11, "LI after LMASK(lane<<29)");
        expect_masked(A1, m2, 32'hA1, 32'h22, "LI after LMASK(odd)");
        expect_masked(A2, m3, 32'hA2, 32'h33, "LI after LMASK(lane>=4)");
        expect_masked(A3, 8'h00, 32'hA3, 32'h44, "LI after LMASK(x0)");
        expect_masked(A4, FULL, 32'hA4, 32'h55, "LI after MASKALL");
        expect_uniform(T0, 32'(m1), "MASKGET M1");
        expect_uniform(T1, 32'(m2), "MASKGET M2");
        expect_uniform(T2, 32'(m3), "MASKGET M3");
        expect_uniform(T3, 32'd0, "MASKGET after LMASK(x0)");
        expect_uniform(T4, 32'd0, "MASKGET, LMASK cannot wake");
        expect_uniform(T5, 32'(FULL), "MASKGET after MASKALL");
        expect32("mask at the end", 32'(`KC_CORE.mask), 32'd1);
        $display("  M: %02h -> %02h -> %02h -> 0 -> 0 -> %02h", m1, m2, m3, FULL);
        finish_test("t_mask");
    end
endmodule
