// t_maskgetset: runs sw/t_maskgetset.S (Stage 1 rung 5) and checks MASKGET
// in every lane and MASKSET from the scalar lane (the lowest active lane,
// lane 0 when M = 0), keeping rs1[LANES-1:0] only.
module t_maskgetset_tb;
    parameter string IMEM_HEX = "";
    parameter string DMEM_HEX = "";
    `include "soc_harness.svh"
    `include "lane_check.svh"

    function automatic logic [7:0] s1_low(input int l);
        return 8'(l * 8'h11);
    endfunction

    initial begin
        logic [7:0] m0, m1, m2, m3;
        int sl0, sl1;
        m0  = FULL & 8'hF8;
        sl0 = scalar_lane(m0);
        m1  = s1_low(sl0) & FULL;
        sl1 = scalar_lane(m1);
        m2  = s1_low(sl1) & FULL;
        m3  = 8'(scalar_lane(m2) + 8'h0C) & FULL;

        do_reset();
        run_until_done(5000);
        repeat (10) @(posedge clk);
        expect_no_halt("t_maskgetset");

        expect_uniform(A0, 32'(m0), "MASKGET after MASKSET 0xF8");
        expect_uniform(A1, 32'(m1), "MASKSET from the scalar lane");
        expect_masked(A2, m1, 32'h77, 32'h52, "LI under the woken mask");
        expect_uniform(A3, 32'(m2), "MASKSET from lane 0");
        expect_uniform(A4, 32'(m3), "MASKSET under M = 0 (lane 0)");
        expect_uniform(A5, 32'(FULL), "MASKGET after MASKALL");
        expect_uniform(A6, 32'd0, "MASKSET 0x100 keeps rs1[LANES-1:0]");
        expect_uniform(A7, 32'd1, "MASKSET 1 under M = 0");
        expect32("mask at the end", 32'(`KC_CORE.mask), 32'd1);
        $display("  M: %02h (scalar %0d) -> %02h (scalar %0d) -> %02h -> %02h -> %02h -> 0 -> 1",
                 m0, sl0, m1, sl1, m2, m3, FULL);
        finish_test("t_maskgetset");
    end
endmodule
