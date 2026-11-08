// t_uart: sends a 17-byte burst while sw/t_uart.S sleeps (the 16-byte RX FIFO
// fills, the 17th byte is dropped), then 4 spaced bytes, and checks that
// exactly the 16 + 4 accepted bytes come back, in order, as valid 1 Mbaud
// frames.
module t_uart_tb;
    parameter string IMEM_HEX = "";
    parameter string DMEM_HEX = "";
    `include "soc_harness.svh"

    logic [7:0] sent [$];
    logic [7:0] expected [$];

    initial begin
        do_reset();
        repeat (100) @(posedge clk);

        for (int i = 0; i < 17; i++) begin
            sent.push_back(8'(32'hA0 + i * 7));
            uart_send(sent[i]);
        end
        if (`KC_CORE.pc > 32'h10)
            $fatal(1, "FAIL: program left its sleep loop before the burst ended");
        for (int i = 0; i < 16; i++) expected.push_back(sent[i]);

        // Wait for the 16 echoes (about 16 x 10 us after the sleep ends).
        repeat (30000) @(posedge clk);

        for (int i = 0; i < 4; i++) begin
            logic [7:0] b = 8'(32'h30 + i);
            expected.push_back(b);
            uart_send(b);
            repeat (2000) @(posedge clk);
        end
        repeat (2000) @(posedge clk);

        if (err_led) $fatal(1, "FAIL: core halted, ERR_PC=%08h", dut.u_mmio.err_pc);
        if (uart_rx_q.size() != expected.size())
            $fatal(1, "FAIL: got %0d echoed bytes, expected %0d", uart_rx_q.size(), expected.size());
        foreach (expected[i])
            if (uart_rx_q[i] !== expected[i])
                $fatal(1, "FAIL: echo %0d = %02h, expected %02h", i, uart_rx_q[i], expected[i]);
        $write("  echoed:");
        foreach (uart_rx_q[i]) $write(" %02h", uart_rx_q[i]);
        $display("");
        $display("PASS: t_uart (16-byte burst through the FIFO, 17th dropped, 4 more echoed)");
        $finish;
    end
endmodule
