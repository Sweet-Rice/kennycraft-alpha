// Shared harness for the tb/core program tests, `included inside a testbench
// module that declares string parameters IMEM_HEX and DMEM_HEX (set with -G
// by tb/core/tb.mk). Provides a 50 MHz clock, kc_soc, behavioral models of
// the display core-side port (framebuffer bytes, palette, swap) and of the
// chunk-engine register port (with a programmable CHUNK_CMD stall), a 1 Mbaud
// UART receiver on uart_tx and sender on uart_rx, a retirement trace
// (+trace), and memory and register peek helpers. The world port is unused
// (EXT_WORLD = 0, internal stub).
//
// LANES (-GLANES=n) sizes the core. lane_x[l][n] is lane l's register n. KC_BASE_CORE (define) builds against
// the Stage 0 core (one register file, no per-lane retire wires) for
// tracediff against the pre-lanes RTL.

parameter int LANES = 1;

`ifdef KC_BASE_CORE
`define KC_RF(l) dut.u_core.u_rf
`else
`define KC_RF(l) dut.u_core.g_lane[l].u_lane.u_rf
`endif

localparam int CLK_NS   = 20;    // 50 MHz core clock
localparam int BIT_CLKS = 50;    // 1 Mbaud: 50 clocks per bit

logic        clk = 1'b0;
logic        rst = 1'b1;
logic        uart_tx;
logic        uart_rx = 1'b1;
logic [7:0]  leds;
logic        err_led;

// Display port
logic        fb_we, fb_re, pal_we, swap_req, fb_mode;
logic [16:0] fb_addr;
logic [7:0]  fb_wdata, fb_rdata = 8'h00;
logic [7:0]  pal_addr;
logic [11:0] pal_wdata;
logic        swap_pending = 1'b0;
logic        vblank       = 1'b0;
logic [31:0] frame_count  = 32'h0;

// Chunk-engine register port
logic        ddr_reg_en, ddr_reg_we;
logic [5:0]  ddr_reg_off;
logic [31:0] ddr_reg_wdata, ddr_reg_rdata;
logic        ddr_reg_stall;

always #(CLK_NS / 2) clk = ~clk;

/* verilator lint_off PINCONNECTEMPTY */
kc_soc #(
    .LANES(LANES),
    .IMEM_HEX(IMEM_HEX),
    .DMEM_HEX(DMEM_HEX)
) dut (
    .clk, .rst,
    .uart_tx, .uart_rx,
    .leds, .err_led,
    .fb_we, .fb_re, .fb_addr, .fb_wdata, .fb_rdata,
    .pal_we, .pal_addr, .pal_wdata,
    .swap_req, .swap_pending, .vblank, .frame_count, .fb_mode,
    .ddr_reg_en, .ddr_reg_we, .ddr_reg_off, .ddr_reg_wdata, .ddr_reg_rdata, .ddr_reg_stall,
    .world_req(), .world_we(), .world_addr(), .world_wdata(),
    .world_ready(1'b0), .world_rdata(8'h00)
);
/* verilator lint_on PINCONNECTEMPTY */

int unsigned cycle = 0;
always @(posedge clk) cycle <= cycle + 1;

// ---------------------------------------------------------------------
// Display model: back framebuffer (1-cycle read latency, writes >= 76800
// dropped), palette, and swap_req counting. Tests drive swap_pending,
// vblank and frame_count themselves.
// ---------------------------------------------------------------------
logic [7:0]  fb_mem [76800];
logic [11:0] pal_mem [256];
int          swap_req_count = 0;

always @(posedge clk) begin
    if (fb_we && fb_addr < 17'd76800) fb_mem[fb_addr] <= fb_wdata;
    if (fb_re) fb_rdata <= (fb_addr < 17'd76800) ? fb_mem[fb_addr] : 8'h00;
    if (pal_we) pal_mem[pal_addr] <= pal_wdata;
    if (swap_req) swap_req_count <= swap_req_count + 1;
end

// ---------------------------------------------------------------------
// Chunk-engine register model: five registers at 0x2C..0x3C, combinational
// read; a CHUNK_CMD write stalls for ddr_cmd_stall cycles before it is taken.
// ---------------------------------------------------------------------
logic [31:0] ddr_regs [5];
int          ddr_cmd_stall  = 0;
int          ddr_stall_left = 0;
int          ddr_stalled_cycles = 0;
logic        ddr_in_cmd = 1'b0;

initial for (int i = 0; i < 5; i++) ddr_regs[i] = 32'h0;

assign ddr_reg_rdata = ddr_regs[3'((ddr_reg_off - 6'h2C) >> 2)];
assign ddr_reg_stall = ddr_reg_en && ddr_reg_we && ddr_reg_off == 6'h30 &&
                       (!ddr_in_cmd || ddr_stall_left != 0);

always @(posedge clk) begin
    if (ddr_reg_en && ddr_reg_we && ddr_reg_off == 6'h30 && !ddr_in_cmd) begin
        ddr_in_cmd     <= 1'b1;
        ddr_stall_left <= ddr_cmd_stall;
    end else if (ddr_in_cmd && ddr_stall_left != 0) begin
        ddr_stall_left <= ddr_stall_left - 1;
    end
    if (ddr_reg_stall) ddr_stalled_cycles <= ddr_stalled_cycles + 1;
    if (ddr_reg_en && ddr_reg_we && !ddr_reg_stall) begin
        ddr_regs[3'((ddr_reg_off - 6'h2C) >> 2)] <= ddr_reg_wdata;
        ddr_in_cmd <= 1'b0;
    end
end

// ---------------------------------------------------------------------
// Peek / poke
// ---------------------------------------------------------------------
function automatic logic [31:0] dmem_rd(input logic [31:0] addr);
    return dut.u_dmem.mem[addr[14:2]];
endfunction

task automatic dmem_wr(input logic [31:0] addr, input logic [31:0] value);
    dut.u_dmem.mem[addr[14:2]] = value;
endtask

logic [31:0] lane_x [LANES][32];

for (genvar l = 0; l < LANES; l++) begin : g_peek
    for (genvar n = 0; n < 32; n++) begin : g_reg
        if (n == 0) begin : g_x0
            assign lane_x[l][n] = 32'd0;
        end else begin : g_xn
            assign lane_x[l][n] = `KC_RF(l).regs[n];
        end
    end
end

function automatic logic [31:0] xreg(input int n);
    return lane_x[0][n];
endfunction

task automatic do_reset();
    rst = 1'b1;
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;
endtask

// Run until the program writes TB_DONE (0x1000_00FC) or the core halts.
task automatic run_until_done(input int max_cycles);
    for (int i = 0; i < max_cycles; i++) begin
        @(posedge clk);
        if (dmem_rd(32'h1000_00FC) != 0 || err_led) return;
    end
    $fatal(1, "FAIL: timeout after %0d cycles at pc=%08h", max_cycles, dut.u_core.pc);
endtask

// ---------------------------------------------------------------------
// Retirement trace from the core's retire_* wires: +trace prints one line
// per retired instruction (cycle, PC, instruction, active mask, lane 0's rd
// write if any), one line per other lane that wrote rd, and one per halt.
// tb/core/tracediff.py compares these lines between two builds.
// ---------------------------------------------------------------------
bit trace_on = 1'b0;
initial trace_on = $test$plusargs("trace");

always @(posedge clk) begin
    if (trace_on && !rst) begin
        if (dut.u_core.retire_valid) begin
            if (dut.u_core.retire_rd_we)
                $display("trace %0d pc=%08h inst=%08h m=%0h x%0d=%08h", cycle,
                         dut.u_core.retire_pc, dut.u_core.retire_inst, dut.u_core.retire_mask,
                         dut.u_core.retire_rd_addr, dut.u_core.retire_rd_wdata);
            else
                $display("trace %0d pc=%08h inst=%08h m=%0h", cycle, dut.u_core.retire_pc,
                         dut.u_core.retire_inst, dut.u_core.retire_mask);
`ifndef KC_BASE_CORE
            for (int l = 1; l < LANES; l++)
                if (dut.u_core.retire_lane_we[l])
                    $display("trace %0d   lane%0d x%0d=%08h", cycle, l,
                             dut.u_core.retire_rd_addr, dut.u_core.retire_lane_wdata[l]);
`endif
        end
        if (dut.u_core.err_set != 0)
            $display("trace %0d pc=%08h halt err=%b", cycle, dut.u_core.err_pc, dut.u_core.err_set);
    end
end

// ---------------------------------------------------------------------
// UART: receiver on uart_tx (checks start and stop bits, samples mid-bit)
// and sender on uart_rx, both at exactly 50 clocks per bit.
// ---------------------------------------------------------------------
logic [7:0] uart_rx_q [$];

initial begin
    logic [7:0] b;
    forever begin
        @(negedge uart_tx);
        repeat (BIT_CLKS / 2) @(posedge clk);
        if (uart_tx !== 1'b0) $fatal(1, "FAIL: UART start bit glitch");
        for (int i = 0; i < 8; i++) begin
            repeat (BIT_CLKS) @(posedge clk);
            b[i] = uart_tx;
        end
        repeat (BIT_CLKS) @(posedge clk);
        if (uart_tx !== 1'b1) $fatal(1, "FAIL: UART stop bit missing");
        uart_rx_q.push_back(b);
    end
end

task automatic uart_send(input logic [7:0] b);
    @(posedge clk);
    uart_rx = 1'b0;
    repeat (BIT_CLKS) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
        uart_rx = b[i];
        repeat (BIT_CLKS) @(posedge clk);
    end
    uart_rx = 1'b1;
    repeat (BIT_CLKS - 1) @(posedge clk);
endtask
