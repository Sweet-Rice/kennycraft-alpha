// t_dwin: runs tb/core_pipe/sw/t_dwin.S (loads and stores in the dmem window,
// kc_isa_pkg DWIN_*) on the Stage 2 core and checks the memory it leaves
// behind through dmem_rd, which reads the window from dmem_win's banks on
// core_pipe and from the dmem BRAM on the multi-cycle core. Built for both
// cores; tracediff-core-pipe-t_dwin compares their retire traces, which hold
// every loaded value.
module t_dwin_tb;
    parameter string IMEM_HEX = "";
    parameter string DMEM_HEX = "";
    `include "soc_harness.svh"

    localparam logic [31:0] RES = 32'h1000_1000;

    int errors = 0;

    task automatic expect32(input string what, input logic [31:0] got, input logic [31:0] exp);
        if (got !== exp) begin
            $display("  FAIL %-34s got %08h expected %08h", what, got, exp);
            errors++;
        end
    endtask

    initial begin
        logic [31:0] slot;

        do_reset();
        run_until_done(20000);
        repeat (10) @(posedge clk);

        expect32("error LED", {31'b0, err_led}, 32'd0);
        for (int l = 0; l < ALANES; l++) begin
            slot = 32'h1000_8000 - 32'(1024 * l) - 32'd64;
            expect32($sformatf("lane %0d slot word", l), dmem_rd(slot), 32'h8182_8384 + 32'(l));
            expect32($sformatf("lane %0d SH + SB word", l), dmem_rd(slot + 4),
                     {16'(32'h8384 + l), 8'h00, 8'(l)});
            expect32($sformatf("lane %0d same-bank word", l), dmem_rd(32'h1000_6400 + 32'(4 * l)),
                     32'(l * 256 + 32'h5A));
            expect32($sformatf("lane %0d alias store", l), dmem_rd(slot + 16), 32'(l + 32'h77));
            expect32($sformatf("lane %0d checksum s10", l), dmem_rd(RES + 32'(4 * l)), lane_x[l][26]);
            if (l % 2 == 0)
                expect32($sformatf("lane %0d mixed (window)", l), dmem_rd(slot + 12), 32'(l + 32'h300));
            else
                expect32($sformatf("lane %0d mixed (BRAM)", l), dmem_rd(32'h1000_2000 + 32'(4 * l)),
                         32'(l + 32'h300));
        end
        expect32("consecutive SB, lanes 0-3", dmem_rd(32'h1000_6800), 32'h4342_4140);
        expect32("consecutive SB, lanes 4-7", dmem_rd(32'h1000_6804), 32'h4746_4544);
        expect32("same byte + same half", dmem_rd(32'h1000_6C00), 32'h075A_4700);
        expect32("SB under 0xA5", dmem_rd(32'h1000_6C10), 32'h0000_0007);
        expect32("edge word below the window", dmem_rd(32'h1000_5FFC), 32'h0000_012A);
        expect32("edge word in the window", dmem_rd(32'h1000_6000), 32'h0000_012A);
        expect32("initial contents", dmem_rd(32'h1000_6E00), 32'h1357_9BDF);
        expect32("mask at the end", 32'(`KC_CORE.mask), 32'd1);

        if (errors != 0) $fatal(1, "FAIL: t_dwin, %0d mismatches", errors);
        $display("PASS: t_dwin (LANES = %0d, PIPELINED = %0d)", LANES, PIPELINED);
        $finish;
    end
endmodule
