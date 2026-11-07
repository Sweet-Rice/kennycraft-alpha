// Checks shared by the Stage 1 rung 5 to 7 testbenches, `included after
// soc_harness.svh: mismatch counting, per-lane register checks, the error
// state after a halt, case selection with a reset per case, and a monitor of
// the bus accesses that land in a watched address range.

int errors = 0;

localparam logic [31:0] TB_SELECT_ADDR = 32'h1000_00F0;
localparam logic [31:0] TB_MARK_ADDR   = 32'h1000_00F4;
localparam logic [31:0] TB_DONE_ADDR   = 32'h1000_00FC;

// Register numbers of the ABI names the programs use
localparam int RA = 1, T0 = 5, T1 = 6, T2 = 7, S0 = 8, S1 = 9;
localparam int A0 = 10, A1 = 11, A2 = 12, A3 = 13, A4 = 14, A5 = 15, A6 = 16, A7 = 17;
localparam int S2 = 18, S3 = 19, S4 = 20, S5 = 21, S6 = 22, S7 = 23;
localparam int T3 = 28, T4 = 29, T5 = 30, T6 = 31;

localparam logic [7:0] FULL = 8'((1 << ALANES) - 1);   // every lane that can be active

task automatic expect32(input string what, input logic [31:0] got, input logic [31:0] exp);
    if (got !== exp) begin
        $display("  FAIL %-40s got %08h expected %08h", what, got, exp);
        errors++;
    end
endtask

// Lane l's register n
task automatic expect_reg(input int l, input int n, input logic [31:0] exp, input string what);
    expect32($sformatf("lane %0d x%0d %s", l, n, what), lane_x[l][n], exp);
endtask

// Every lane that can be active: x[n] = on[l] ? v_on : v_off
task automatic expect_masked(input int n, input logic [7:0] on, input logic [31:0] v_on,
                             input logic [31:0] v_off, input string what);
    for (int l = 0; l < ALANES; l++) expect_reg(l, n, on[l] ? v_on : v_off, what);
endtask

// Every lane (active or not, all LANES): x[n] = v
task automatic expect_uniform(input int n, input logic [31:0] v, input string what);
    for (int l = 0; l < LANES; l++) expect_reg(l, n, v, what);
endtask

// Lowest set bit of m, 0 when m = 0 (the scalar lane)
function automatic int scalar_lane(input logic [7:0] m);
    for (int i = 0; i < 8; i++) if (m[i]) return i;
    return 0;
endfunction

// Run case k of a program that dispatches on TB_SELECT, from its own reset.
task automatic run_case(input int k, input int max_cycles);
    dmem_wr(TB_SELECT_ADDR, k);
    dmem_wr(TB_MARK_ADDR, 32'd0);
    dmem_wr(TB_DONE_ADDR, 32'd0);
    do_reset();
    run_until_done(max_cycles);
endtask

// After a halt: ERR = err, ERR_PC = pc, the PC stays put, nothing more runs.
task automatic expect_halt(input string what, input logic [2:0] err, input logic [31:0] pc);
    logic [31:0] pc_halt;
    pc_halt = dut.u_core.pc;
    repeat (50) @(posedge clk);
    expect32({what, ": error LED"}, {31'b0, err_led}, 32'd1);
    expect32({what, ": ERR"}, {29'b0, dut.u_mmio.err}, {29'b0, err});
    expect32({what, ": ERR_PC"}, dut.u_mmio.err_pc, pc);
    expect32({what, ": PC frozen"}, dut.u_core.pc, pc_halt);
    expect32({what, ": nothing after it ran"}, dmem_rd(TB_MARK_ADDR), 32'd0);
endtask

task automatic expect_no_halt(input string what);
    expect32({what, ": error LED"}, {31'b0, err_led}, 32'd0);
    expect32({what, ": ERR"}, {29'b0, dut.u_mmio.err}, 32'd0);
    expect32({what, ": done"}, dmem_rd(TB_DONE_ADDR), 32'd1);
endtask

// Bus accesses (bus_req && bus_ready) with watch_lo <= addr < watch_hi
logic [31:0] watch_lo = 32'hFFFF_FFFF, watch_hi = 32'hFFFF_FFFF;
int          watch_hits = 0;

always @(posedge clk)
    if (!rst && dut.u_core.bus_req && dut.u_core.bus_ready &&
        dut.u_core.bus_addr >= watch_lo && dut.u_core.bus_addr < watch_hi)
        watch_hits <= watch_hits + 1;

task automatic finish_test(input string name);
    if (errors != 0) $fatal(1, "FAIL: %s, %0d mismatches", name, errors);
    $display("PASS: %s (LANES = %0d, %0d can be active)", name, LANES, ALANES);
    $finish;
endtask
