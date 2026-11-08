// datapath_tb: the imported core's directed tests, moved onto kc_soc and the
// Stage 0 memory map (reset vector 0, dmem at 0x1000_0000, UART_TX at
// 0x5000_0018, 1 Mbaud at 50 MHz). Each program is poked into imem and runs
// from a clean reset:
//   1. arithmetic       addi, add, sub, register writeback
//   2. control flow     taken branch, not-taken branch, jal link address
//   3. memory + UART    sw, lw, sb, lbu, and a store to UART_TX
module datapath_tb;
    parameter string IMEM_HEX = "";
    parameter string DMEM_HEX = "";
    `include "soc_harness.svh"

    int errors = 0;

    task automatic clear_all();
        for (int i = 1; i < 32; i++)   `KC_RF(0).regs[i] = '0;
        for (int i = 0; i < 8192; i++) dut.u_imem.mem[i]       = 32'h0000_0013;  // nop
        for (int i = 0; i < 8192; i++) dut.u_dmem.mem[i]       = '0;
    endtask

    task automatic check(input string name, input logic [31:0] got, input logic [31:0] exp);
        if (got !== exp) begin
            $display("    FAIL  %-22s = %h, expected %h", name, got, exp);
            errors++;
        end else begin
            $display("    ok    %-22s = %h", name, got);
        end
    endtask

    initial begin
        // -----------------------------------------------------------------
        // 1. Arithmetic
        //   addi x1, x0, 5 / addi x2, x0, 10 / add x3, x1, x2 / sub x6, x2, x1
        //   jal x0, 0
        // -----------------------------------------------------------------
        $display("=== 1. arithmetic ===");
        clear_all();
        dut.u_imem.mem[0] = 32'h00500093;
        dut.u_imem.mem[1] = 32'h00A00113;
        dut.u_imem.mem[2] = 32'h002081B3;
        dut.u_imem.mem[3] = 32'h40110333;
        dut.u_imem.mem[4] = 32'h0000006F;
        do_reset();
        repeat (40) @(posedge clk);
        @(negedge clk);
        check("x1", xreg(1), 32'd5);
        check("x2", xreg(2), 32'd10);
        check("x3 (x1+x2)", xreg(3), 32'd15);
        check("x6 (x2-x1)", xreg(6), 32'd5);
        check("final pc", `KC_CORE.pc, 32'h0000_0010);
        check("error led", {31'b0, err_led}, 32'd0);

        // -----------------------------------------------------------------
        // 2. Control flow
        //   addi x1, x0, 7 / addi x2, x0, 7 / beq x1, x2, +12 (taken -> 0x14)
        //   addi x9, x0, 99 / addi x9, x0, 98 (skipped) / addi x3, x0, 1
        //   bne x1, x2, +8 (not taken) / addi x4, x0, 2
        //   jal x5, +8 (x5 = 0x24 -> 0x28) / addi x9, x0, 97 (skipped)
        //   addi x7, x0, 3 / jal x0, 0
        // -----------------------------------------------------------------
        $display("=== 2. control flow ===");
        clear_all();
        dut.u_imem.mem[0]  = 32'h00700093;
        dut.u_imem.mem[1]  = 32'h00700113;
        dut.u_imem.mem[2]  = 32'h00208663;
        dut.u_imem.mem[3]  = 32'h06300493;
        dut.u_imem.mem[4]  = 32'h06200493;
        dut.u_imem.mem[5]  = 32'h00100193;
        dut.u_imem.mem[6]  = 32'h00209463;
        dut.u_imem.mem[7]  = 32'h00200213;
        dut.u_imem.mem[8]  = 32'h008002EF;
        dut.u_imem.mem[9]  = 32'h06100493;
        dut.u_imem.mem[10] = 32'h00300393;
        dut.u_imem.mem[11] = 32'h0000006F;
        do_reset();
        repeat (100) @(posedge clk);
        @(negedge clk);
        check("x1", xreg(1), 32'd7);
        check("x3 (after beq)", xreg(3), 32'd1);
        check("x4 (bne not taken)", xreg(4), 32'd2);
        check("x5 (jal link)", xreg(5), 32'h0000_0024);
        check("x7 (after jal)", xreg(7), 32'd3);
        check("x9 (never written)", xreg(9), 32'd0);
        check("final pc", `KC_CORE.pc, 32'h0000_002C);
        check("error led", {31'b0, err_led}, 32'd0);

        // -----------------------------------------------------------------
        // 3. Memory and UART
        //   lui x1, 0x10000 / addi x1, x1, 256    x1 = 0x1000_0100 (dmem word 0x40)
        //   addi x2, x0, 42 / sw x2, 0(x1) / lw x3, 0(x1)
        //   addi x4, x0, -1 / sb x4, 4(x1) / lbu x5, 4(x1)
        //   lui x6, 0x50000 / addi x7, x0, 72 / sb x7, 24(x6)   'H' to UART_TX
        //   jal x0, 0
        // -----------------------------------------------------------------
        $display("=== 3. memory and uart ===");
        clear_all();
        uart_rx_q.delete();
        dut.u_imem.mem[0]  = 32'h100000B7;
        dut.u_imem.mem[1]  = 32'h10008093;
        dut.u_imem.mem[2]  = 32'h02A00113;
        dut.u_imem.mem[3]  = 32'h0020A023;
        dut.u_imem.mem[4]  = 32'h0000A183;
        dut.u_imem.mem[5]  = 32'hFFF00213;
        dut.u_imem.mem[6]  = 32'h00408223;
        dut.u_imem.mem[7]  = 32'h0040C283;
        dut.u_imem.mem[8]  = 32'h50000337;
        dut.u_imem.mem[9]  = 32'h04800393;
        dut.u_imem.mem[10] = 32'h00730C23;
        dut.u_imem.mem[11] = 32'h0000006F;
        do_reset();
        repeat (1000) @(posedge clk);                 // one UART frame is 500 clocks
        @(negedge clk);
        check("x1 (base)", xreg(1), 32'h1000_0100);
        check("x2", xreg(2), 32'd42);
        check("x3 (lw)", xreg(3), 32'd42);
        check("x4", xreg(4), 32'hFFFF_FFFF);
        check("x5 (lbu)", xreg(5), 32'd255);
        check("x6 (mmio base)", xreg(6), 32'h5000_0000);
        check("dmem[0x40] (sw)", dut.u_dmem.mem[32'h40], 32'd42);
        check("dmem[0x41] (sb)", dut.u_dmem.mem[32'h41], 32'h0000_00FF);
        check("uart frames", uart_rx_q.size(), 32'd1);
        if (uart_rx_q.size() == 1) check("uart byte", {24'b0, uart_rx_q[0]}, 32'h0000_0048);
        check("final pc", `KC_CORE.pc, 32'h0000_002C);
        check("error led", {31'b0, err_led}, 32'd0);

        $display("");
        if (errors == 0) $display("=== PASS ===");
        else             $fatal(1, "=== %0d FAILURES ===", errors);
        $finish;
    end
endmodule
