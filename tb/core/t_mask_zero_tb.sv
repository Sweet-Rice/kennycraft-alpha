// t_mask_zero: runs sw/t_mask_zero.S (Stage 1 rung 5) and checks the mask
// loop (lane l iterates l + 1 times, BALLOT writes 0 everywhere at the end,
// no halt) and that with M = 0 no load or store reaches the bus, a
// misaligned load does not halt, UART_TX sends nothing and JAL writes no
// link, then that MASKSET restores the saved mask.
module t_mask_zero_tb;
    parameter string IMEM_HEX = "";
    parameter string DMEM_HEX = "";
    `include "soc_harness.svh"
    `include "lane_check.svh"

    localparam logic [31:0] W = 32'h1000_2000;

    initial begin
        dmem_wr(W, 32'hCAFE_F00D);
        watch_lo = W;
        watch_hi = W + 32'h10;
        do_reset();
        run_until_done(20000);
        repeat (2000) @(posedge clk);   // a UART byte would take 500 cycles
        expect_no_halt("t_mask_zero");

        for (int l = 0; l < ALANES; l++) expect_reg(l, A2, 32'(l + 1), "iterations");
        expect_uniform(T0, 32'd0, "BALLOT at the loop exit");
        expect_uniform(S1, 32'd0, "MASKGET after the loop");
        expect_uniform(S2, 32'(FULL), "MASKGET after MASKSET(saved)");
        expect_masked(A3, 8'h00, 32'h0, 32'h33, "LW under M = 0");
        expect_masked(A4, 8'h00, 32'h0, 32'h44, "misaligned LW under M = 0");
        expect_masked(RA, 8'h00, 32'h0, 32'h77, "JAL link under M = 0");
        expect32("SW under M = 0", dmem_rd(W), 32'hCAFE_F00D);
        expect32("bus accesses to the watched words", 32'(watch_hits), 32'd0);
        expect32("UART bytes", 32'(uart_rx_q.size()), 32'd0);
        expect32("mask at the end", 32'(dut.u_core.mask), 32'd1);
        finish_test("t_mask_zero");
    end
endmodule
