// qrcp_unit_tb: rtl/core/qrcp.sv alone against golden vectors from
// tb/qrcp/qrcp_check.c (x and fixed.c qrcp(x), one "x expected" hex pair per
// line: every edge class plus random inputs). Each vector runs the core's
// sequence: load in EX, then phases 0..2 in the wait state; y is read in
// phase 3, where the core latches it into rd. x is inverted right after the
// load cycle, so the unit must sample x only at load (rs1 need not stay
// stable while QRCP runs). Between vectors the unit idles a cycle, so no
// state can leak from one input to the next.
module qrcp_unit_tb;
    logic        clk = 1'b0;
    logic        load = 1'b0, en = 1'b0;
    logic [2:0]  ph = 3'd0;
    logic [31:0] x = 32'd0, y;

    always #10 clk = ~clk;

    qrcp dut (.clk, .load, .en, .ph, .x, .y);

    initial begin
        string       path;
        int          fd, nread, count = 0, errors = 0;
        logic [31:0] vx, want;

        if (!$value$plusargs("vectors=%s", path)) $fatal(1, "FAIL: need +vectors=<file>");
        fd = $fopen(path, "r");
        if (fd == 0) $fatal(1, "FAIL: cannot open %s", path);

        forever begin
            nread = $fscanf(fd, "%h %h\n", vx, want);
            if (nread != 2) break;
            @(negedge clk);
            x    = vx;
            load = 1'b1;                    // EX
            @(negedge clk);
            load = 1'b0;
            x    = ~vx;                     // x is only valid at load
            en   = 1'b1;
            for (int k = 0; k < 3; k++) begin
                ph = 3'(k);
                @(negedge clk);
            end
            ph = 3'd3;                      // the core latches y here
            if (y !== want) begin
                if (errors < 10) $display("  FAIL qrcp(%08h) = %08h, expected %08h", vx, y, want);
                errors++;
            end
            @(negedge clk);
            en = 1'b0;
            ph = 3'd0;
            count++;
        end
        $fclose(fd);

        if (count == 0) $fatal(1, "FAIL: no vectors in %s", path);
        if (errors != 0) $fatal(1, "FAIL: qrcp unit, %0d of %0d mismatches", errors, count);
        $display("PASS: qrcp unit, %0d vectors bit-exact with fixed.c qrcp()", count);
        $finish;
    end
endmodule
