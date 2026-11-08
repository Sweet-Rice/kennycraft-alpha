// qrcp_pipe_eq_tb: rtl/core_pipe/qrcp_pipe.sv (core_pipe's pipelined unit)
// against rtl/core/qrcp.sv (checked bit-exact with fixed.c qrcp() by
// tb-qrcp-model and tb-qrcp-unit) on the same inputs: the edge classes (0..5,
// their negations, 0x7FFFFFFF, 0x80000000 and its neighbours, every power of
// two and its negation, each +-1) and +random=N random inputs (+seed=S),
// half of them uniform and half shifted right by a random amount so that
// every normalization shift is exercised. Both units run the core's
// sequence on one x: qrcp.sv load, then phases 0..2; qrcp_pipe s0 with the
// load, then seven cycles. qrcp_pipe's y is taken in its MEM cycle 7 (the
// core's m_done) and must still hold a cycle later; qrcp.sv's y is valid
// from the cycle after phase 2. x is inverted after the load cycle, so both
// must sample x only there.
module qrcp_pipe_eq_tb;
    logic        clk = 1'b0;
    logic        load = 1'b0, en = 1'b0, s0 = 1'b0;
    logic [2:0]  ph = 3'd0;
    logic [31:0] x = 32'd0, y_ref, y_pipe;

    always #10 clk = ~clk;

    qrcp      u_ref  (.clk, .load, .en, .ph, .x, .y(y_ref));
    qrcp_pipe u_pipe (.clk, .s0, .x, .y(y_pipe));

    int count = 0, errors = 0;

    task automatic run(input logic [31:0] vx);
        logic [31:0] got;
        @(negedge clk);
        x    = vx;
        load = 1'b1;                        // EX / MEM cycle 0
        s0   = 1'b1;
        @(negedge clk);
        load = 1'b0;
        s0   = 1'b0;
        x    = ~vx;                         // x is only valid at load / s0
        en   = 1'b1;
        ph   = 3'd0;                        // MEM cycle 1
        @(negedge clk);
        ph   = 3'd1;                        // MEM cycle 2
        @(negedge clk);
        ph   = 3'd2;                        // MEM cycle 3
        @(negedge clk);
        ph   = 3'd3;                        // MEM cycle 4: qrcp.sv's y is valid
        repeat (3) @(negedge clk);
        got  = y_pipe;                      // MEM cycle 7: y is MEM's result
        @(negedge clk);
        if (y_pipe !== got) begin
            if (errors < 10) $display("  FAIL qrcp_pipe(%08h): y changed from %08h to %08h", vx, got, y_pipe);
            errors++;
        end else if (got !== y_ref) begin
            if (errors < 10) $display("  FAIL qrcp_pipe(%08h) = %08h, qrcp = %08h", vx, got, y_ref);
            errors++;
        end
        en   = 1'b0;
        ph   = 3'd0;
        count++;
    endtask

    initial begin
        int          nrand;
        int unsigned seed;
        logic [31:0] v;

        if (!$value$plusargs("random=%d", nrand)) nrand = 1000000;
        if (!$value$plusargs("seed=%h", seed))    seed  = 32'h4B43;
        void'($urandom(seed));

        for (int i = 0; i <= 5; i++) begin
            run(32'(i));
            run(-32'(i));
        end
        run(32'h7FFF_FFFF);
        run(32'h7FFF_FFFE);
        run(32'h8000_0000);
        run(32'h8000_0001);
        run(32'hFFFF_FFFF);
        for (int k = 0; k < 32; k++) begin
            v = 32'd1 << k;
            run(v);
            run(v - 32'd1);
            run(v + 32'd1);
            run(-v);
            run(-v - 32'd1);
            run(-v + 32'd1);
        end
        for (int i = 0; i < nrand; i++) begin
            v = $urandom;
            if (i[0]) v = v >> ($urandom % 32);
            run(v);
        end

        if (errors != 0) $fatal(1, "FAIL: qrcp_pipe, %0d of %0d mismatches", errors, count);
        $display("PASS: qrcp_pipe, %0d inputs identical to rtl/core/qrcp.sv", count);
        $finish;
    end
endmodule
