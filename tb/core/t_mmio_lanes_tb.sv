// t_mmio_lanes: runs sw/t_mmio_lanes.S (Stage 1 rung 4): MMIO side effects
// happen once per active lane, in lane order (Tai_2 section 2, MMIO row).
// Expectations follow the lanes that can be active (ALANES).
module t_mmio_lanes_tb;
    parameter string IMEM_HEX = "";
    parameter string DMEM_HEX = "";
    `include "soc_harness.svh"

    int errors = 0;
    logic [7:0] led_writes [$];

    task automatic expect32(input string what, input logic [31:0] got, input logic [31:0] exp);
        if (got !== exp) begin
            $display("  FAIL %-30s got %08h expected %08h", what, got, exp);
            errors++;
        end
    endtask

    always @(posedge clk)
        if (!rst && dut.u_mmio.acc && dut.u_mmio.we && dut.u_mmio.off == 8'h24)
            led_writes.push_back(dut.u_mmio.wdata[7:0]);

    initial begin
        int n2;
        n2 = (ALANES < 2) ? ALANES : 2;

        dmem_wr(32'h1000_00F0, 32'd0);
        do_reset();
        uart_send(8'h41);
        uart_send(8'h42);
        uart_send(8'h43);
        repeat (10) @(posedge clk);
        dmem_wr(32'h1000_00F0, 32'd1);
        run_until_done(20000);
        repeat (20) @(posedge clk);

        expect32("error LED", {31'b0, err_led}, 32'd0);
        for (int i = 0; i < ALANES; i++)
            expect32($sformatf("lane %0d UART_RX under 0x03", i), lane_x[i][10],
                     (i < n2) ? 32'h41 + i : 32'h5A);
        expect32("lane 0 UART_RX after", lane_x[0][11], 32'h41 + n2);
        expect32("RX byte left (C only if 1 lane)", {31'b0, dut.u_uart.rx_avail}, 32'(n2 + 1 < 3));
        expect32("LEDS writes", led_writes.size(), n2);
        foreach (led_writes[k])
            expect32($sformatf("LEDS write %0d", k), 32'(led_writes[k]), 32'h10 + k);
        expect32("LEDS", 32'(leds), 32'h10 + n2 - 1);
        for (int i = 1; i < ALANES; i++)
            expect32($sformatf("lane %0d CYCLES - lane 0", i), lane_x[i][12] - lane_x[0][12], i);
        $display("  UART_RX under 0x03 popped %0d byte(s), LEDS written %0d time(s), CYCLES lane 0 = %0d",
                 n2, led_writes.size(), lane_x[0][12]);

        if (errors != 0) $fatal(1, "FAIL: t_mmio_lanes, %0d mismatches", errors);
        $display("PASS: t_mmio_lanes (LANES = %0d, %0d can be active)", LANES, ALANES);
        $finish;
    end
endmodule
