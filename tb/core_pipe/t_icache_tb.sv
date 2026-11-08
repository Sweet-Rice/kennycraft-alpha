// t_icache: rtl/mem/icache.sv against a reference memory. A random fetch
// stream (sequential runs, jumps across lines and aliasing indices, req low
// cycles, address changes while a refill is in flight) is presented each
// cycle; every ack must return the reference word of the address presented
// the cycle before, the refill port must carry one request per line at a
// time, and every address re-presented until acked must be acked within a
// bound. Refill grant and data latencies are random.
module t_icache_tb;
    localparam int CLK_NS = 10;
    localparam int CYCLES = 200000;

    logic         clk = 1'b0;
    logic         rst = 1'b1;
    logic         req;
    logic [31:0]  addr;
    logic [31:0]  rdata;
    logic         ack;
    logic         rf_req, rf_gnt, rf_valid;
    logic [27:4]  rf_addr;
    logic [127:0] rf_data;

    always #(CLK_NS / 2) clk = ~clk;

    icache dut (.*);

    // Reference: word at byte address a is a hash of a
    function automatic logic [31:0] ref_word(input logic [27:2] a);
        return {a[17:2], a[27:12]} ^ 32'h9E37_79B9 ^ {6'd0, a};
    endfunction

    // Refill side: grant after 0..3 cycles, data 1..20 cycles after grant
    int          gnt_wait, dat_wait;
    logic        busy = 1'b0;
    logic [27:4] line;
    int          errors = 0, acks = 0, refills = 0;

    always_comb begin
        rf_gnt   = rf_req && !busy && (gnt_wait == 0);
        rf_valid = busy && (dat_wait == 0);
        for (int k = 0; k < 4; k++) rf_data[32*k +: 32] = ref_word({line, 2'(k)});
    end

    always @(posedge clk) begin
        if (rst) begin
            busy     <= 1'b0;
            gnt_wait <= $urandom_range(3);
        end else if (rf_gnt) begin
            busy     <= 1'b1;
            line     <= rf_addr;
            dat_wait <= $urandom_range(20, 1);
            refills++;
        end else if (rf_valid) begin
            busy     <= 1'b0;
            gnt_wait <= $urandom_range(3);
        end else begin
            if (busy && dat_wait > 0)        dat_wait <= dat_wait - 1;
            if (!busy && rf_req && gnt_wait > 0) gnt_wait <= gnt_wait - 1;
        end
        if (rf_req && busy) begin
            $display("  FAIL rf_req while a refill is in flight");
            errors++;
        end
    end

    // Fetch side. pa / preq: what was presented last cycle. A pending fetch
    // is re-presented until acked (like the core), but with probability
    // 1/16 the stream moves on anyway (an address change mid-miss).
    logic [27:2] cur, pa;
    logic        preq;
    int          wait_n;

    assign addr = {4'd0, cur, 2'b00};

    always @(posedge clk) begin
        if (!rst) begin
            if (ack) begin
                acks++;
                if (!preq) begin
                    $display("  FAIL ack for a req = 0 cycle");
                    errors++;
                end else if (rdata !== ref_word(pa)) begin
                    $display("  FAIL addr %08h: got %08h expected %08h", {pa, 2'b00}, rdata, ref_word(pa));
                    errors++;
                end
            end
            wait_n = (preq && !ack && pa == cur) ? wait_n + 1 : 0;
            if (wait_n > 64) begin
                $display("  FAIL addr %08h never acked", {cur, 2'b00});
                errors++;
                wait_n = 0;
            end
        end
        pa   <= cur;
        preq <= req;
        if (!rst && ((ack && pa == cur) || !preq || $urandom_range(15) == 0)) begin
            unique case ($urandom_range(15))
                0:       cur <= $urandom;                              // anywhere
                1, 2:    cur <= {cur[27:16], 14'($urandom)};           // same 64 KB
                3:       cur <= cur ^ 26'h1000;                         // aliasing index
                4:       cur <= cur - 26'($urandom_range(8));          // backwards
                default: cur <= cur + 26'd1;                            // sequential
            endcase
        end
        req <= rst ? 1'b0 : ($urandom_range(15) != 0);
    end

    initial begin
        cur    = 26'h0040;
        req    = 1'b0;
        wait_n = 0;
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (CYCLES) @(posedge clk);
        if (acks < CYCLES / 16) begin
            $display("  FAIL only %0d acks in %0d cycles", acks, CYCLES);
            errors++;
        end
        if (errors == 0) $display("PASS: t_icache (%0d acks, %0d refills)", acks, refills);
        else             $display("FAIL: t_icache (%0d errors)", errors);
        $finish;
    end
endmodule
