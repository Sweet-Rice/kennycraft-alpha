// t_pipe_stress: runs tb/core_pipe/sw/t_pipe_stress.S (back-to-back hazards,
// P8) on the Stage 2 core (LANES = 8, divergence stack, ray unit, QRCP) and
// checks, in every lane: the program's own fast-against-slow check (s11 = 0)
// and the results that do not need a model of the ray unit or QRCP (load-use,
// BALLOT, LMASK + MASKGET under the odd-lane mask, DIF/DELSE, the presets
// that the lanes outside the 0x5A mask keep across QRCP). Built for both
// cores; tracediff-core-pipe-t_pipe_stress compares their retire traces,
// the only pipelined trace coverage of VSET/VTRACE/VGET with forwarding.
module t_pipe_stress_tb;
    parameter string IMEM_HEX = "";
    parameter string DMEM_HEX = "";
    `include "soc_harness.svh"

    localparam logic [31:0] SCRATCH = 32'h1000_1000;

    int errors = 0;

    task automatic expect32(input string what, input logic [31:0] got, input logic [31:0] exp);
        if (got !== exp) begin
            $display("  FAIL %-28s got %08h expected %08h", what, got, exp);
            errors++;
        end
    endtask

    function automatic logic [31:0] res(input int l, input int k);
        return dmem_rd(SCRATCH + 32'(4 * l) + 32'(256 + 32 * k));
    endfunction

    initial begin
        logic [7:0] full, odd, qm;
        full = 8'((1 << ALANES) - 1);
        odd  = 8'hAA & full;
        qm   = 8'h5A & full;

        do_reset();
        run_until_done(20000);
        repeat (10) @(posedge clk);

        expect32("error LED", {31'b0, err_led}, 32'd0);
        for (int l = 0; l < ALANES; l++) begin
            expect32($sformatf("lane %0d fast == slow (s11)", l), lane_x[l][27], 32'd0);
            expect32($sformatf("lane %0d load-use +1", l), res(l, 0), 32'(l + 8));
            expect32($sformatf("lane %0d load + load", l), res(l, 1), 32'(2 * (l + 7)));
            expect32($sformatf("lane %0d BALLOT", l), res(l, 11), 32'(odd));
            expect32($sformatf("lane %0d MASKGET + 1 (odd lanes)", l), res(l, 12),
                     odd[l] ? 32'(odd) + 32'd1 : 32'h5A);
            expect32($sformatf("lane %0d DIF/DELSE", l), res(l, 13), ((l + 7) & 2) != 0 ? 32'd5 : 32'd9);
            if (!qm[l]) begin
                expect32($sformatf("lane %0d QRCP outside 0x5A", l), res(l, 21), 32'h5A5A_0000 | 32'(l));
                expect32($sformatf("lane %0d QRCP use outside 0x5A", l), res(l, 22), 32'h5A5A_0000 | 32'(l));
            end
        end
        expect32("mask at the end", 32'(`KC_CORE.mask), 32'd1);
        // lane 1 is active under the partial mask 0x5A
        $display("  lane 1: VTRACE/VGET mix %08h, partial-mask VTRACE + VGET %08h, QRCP chain %08h",
                 res(1, 8), res(1, 10), res(1, 7));

        if (errors != 0) $fatal(1, "FAIL: t_pipe_stress, %0d mismatches", errors);
        $display("PASS: t_pipe_stress (LANES = %0d, PIPELINED = %0d)", LANES, PIPELINED);
        $finish;
    end
endmodule
