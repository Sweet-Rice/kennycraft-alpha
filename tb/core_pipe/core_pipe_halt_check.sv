// core_pipe_halt_check: bound into every core_pipe instance of the
// tb-core-pipe-* builds. While the core is halted, the err_pc port and pc
// must hold the faulting instruction's PC (err_pc at err_set) on every
// cycle, as the multi-cycle core holds them in S_HALT; imem_addr must not
// move. The halt line in the trace (tracediff against the multi-cycle core)
// checks err_pc in the err_set cycle itself. Prints one summary line per run
// that halted.
module core_pipe_halt_check (
    input logic        clk,
    input logic        rst,
    input logic        err_any,
    input logic        halted,
    input logic [31:0] err_pc,
    input logic [31:0] pc,
    input logic [31:0] imem_addr
);
    logic [31:0] fault_pc, fetch_q;
    int          halts = 0, cycles = 0;

    always @(posedge clk) begin
        if (rst) begin
            halts  <= 0;
            cycles <= 0;
        end else begin
            if (err_any) begin
                fault_pc <= err_pc;
                halts    <= halts + 1;
            end
            fetch_q <= imem_addr;
            if (halted) begin
                cycles <= cycles + 1;
                if (err_pc !== fault_pc || pc !== fault_pc)
                    $fatal(1, "FAIL: core_pipe halted at %08h, but err_pc = %08h, pc = %08h",
                           fault_pc, err_pc, pc);
                if (cycles > 0 && imem_addr !== fetch_q)
                    $fatal(1, "FAIL: core_pipe halted at %08h, but imem_addr moved %08h -> %08h",
                           fault_pc, fetch_q, imem_addr);
            end
        end
    end

    // Reported whenever a reset ends a halted run, and at the end
    logic was_rst = 1'b0;
    always @(posedge clk) begin
        was_rst <= rst;
        if (rst && !was_rst && cycles > 0) report();
    end
    final if (cycles > 0) report();

    function automatic void report();
        $display("core_pipe halt check: err_pc and pc held at %08h for %0d halted cycles",
                 fault_pc, cycles);
    endfunction
endmodule

bind core_pipe core_pipe_halt_check u_halt_check (
    .clk, .rst, .err_any(err_set != '0), .halted, .err_pc, .pc, .imem_addr
);
