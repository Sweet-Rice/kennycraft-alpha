// t_laneid: runs sw/t_laneid.S (Stage 1 rung 3) and checks every lane's
// registers against Tai_2 sections 1 and 2 for this LANES: LANEID per lane,
// per-lane ALU and MUL under MASKALL, active-only writes under a partial
// mask, MASKGET in every lane, MASKSET from the scalar lane.
module t_laneid_tb;
    parameter string IMEM_HEX = "";
    parameter string DMEM_HEX = "";
    `include "soc_harness.svh"

    int errors = 0;

    task automatic expect32(input string what, input logic [31:0] got, input logic [31:0] exp);
        if (got !== exp) begin
            $display("  FAIL %-28s got %08h expected %08h", what, got, exp);
            errors++;
        end
    endtask

    initial begin
        logic [7:0] full, m1, m2, m3;
        int sl;
        full = 8'((1 << ALANES) - 1);
        m1   = 8'hA5 & full;
        m2   = 8'hA4 & full;
        sl   = 0;
        for (int i = ALANES - 1; i >= 0; i--) if (m2[i]) sl = i;
        m3   = 8'((sl << 4) | 1) & full;

        do_reset();
        run_until_done(5000);
        repeat (10) @(posedge clk);

        expect32("error LED", {31'b0, err_led}, 32'd0);
        for (int l = 0; l < ALANES; l++) begin
            expect32($sformatf("lane %0d LANEID", l),         lane_x[l][10], 32'(l));
            expect32($sformatf("lane %0d 3*lane+7", l),       lane_x[l][11], 32'(3 * l + 7));
            expect32($sformatf("lane %0d lane*lane", l),      lane_x[l][14], 32'(l * l));
            expect32($sformatf("lane %0d lane<<4|1", l),      lane_x[l][16], 32'((l << 4) | 1));
            expect32($sformatf("lane %0d li under 0xA5", l),  lane_x[l][12], m1[l] ? 32'h99 : 32'h55);
            expect32($sformatf("lane %0d LANEID under 0xA5", l), lane_x[l][13], m1[l] ? 32'(l) : 32'h66);
            expect32($sformatf("lane %0d MASKGET (uniform)", l), lane_x[l][15], 32'(m1));
            expect32($sformatf("lane %0d MASKSET scalar", l), lane_x[l][17], 32'(m3));
        end
        expect32("mask at the end", 32'(dut.u_core.mask), 32'd1);
        $display("  active lanes %0d: MASKGET under 0xA5 = %02h, MASKSET from scalar lane %0d -> %02h",
                 ALANES, m1, sl, m3);

        if (errors != 0) $fatal(1, "FAIL: t_laneid, %0d mismatches", errors);
        $display("PASS: t_laneid (LANES = %0d, %0d can be active)", LANES, ALANES);
        $finish;
    end
endmodule
