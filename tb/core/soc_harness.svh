// Shared harness for the tb/core program tests, `included inside a testbench
// module that declares string parameters IMEM_HEX and DMEM_HEX (set with -G
// by tb/core/tb.mk). Provides a 50 MHz clock, kc_soc, behavioral models of
// the display core-side port (framebuffer bytes, palette, swap) and of the
// chunk-engine register port (with a programmable CHUNK_CMD stall), a 1 Mbaud
// UART receiver on uart_tx and sender on uart_rx, a retirement trace
// (+trace), and memory and register peek helpers. The world port is unused
// (EXT_WORLD = 0, internal stub).
//
// LANES (-GLANES=n) sizes the core. LANE0_ONLY = 1 pins mask bits
// LANES-1..1 to 0, so only lane 0 can ever be active (Stage 1 rung 2:
// LANES = 8 with the mask stuck at lane 0 must trace like LANES = 1).
// lane_x[l][n] is lane l's register n. KC_BASE_CORE (define) builds against
// the Stage 0 core (one register file, no per-lane retire wires) for
// tracediff against the pre-lanes RTL. HAS_RAY_UNIT = 1 builds the core with
// custom-1 and connects rtl/vtrace/vtrace.sv (WORLD_LATENCY = 2) to it, with
// an all-air world: every ray walks until it leaves the world or hits its cap.
// HAS_QRCP = 1 builds the core with QRCP (D22). PIPELINED = 1 builds the
// 5-stage core_pipe instead of the multi-cycle core; `KC_CORE is the core
// instance either way.

parameter int LANES      = 1;
parameter bit LANE0_ONLY = 1'b0;
localparam int ALANES    = LANE0_ONLY ? 1 : LANES;   // lanes that can be active
parameter bit HAS_DIV_STACK = 1'b0;   // custom-2 in the core, see below
parameter bit HAS_RAY_UNIT  = 1'b0;   // custom-1 and the ray unit
parameter bit HAS_QRCP      = 1'b0;   // QRCP (custom-0 funct3 010)
parameter bit PIPELINED     = 1'b0;   // core_pipe (P8)

`define KC_CORE dut.g_core.u_core

`ifdef KC_BASE_CORE
`define KC_RF(l) `KC_CORE.u_rf
`else
`define KC_RF(l) `KC_CORE.g_lane[l].u_lane.u_rf
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

// Ray unit port
logic             vt_cfg_we, vt_start, vt_done, vt_busy;
logic [2:0]       vt_cfg_field;
logic [LANES-1:0] vt_lane_mask;
logic [31:0]      vt_cfg_data [LANES];
logic [7:0]       vt_max_steps;
logic [15:0]      vt_result   [LANES];
logic [16:0]      vt_hit_cell [LANES];
logic [31:0]      vt_t_hit    [LANES];

if (HAS_RAY_UNIT) begin : g_vtrace
    logic [16:0] vt_world_addr [LANES];
    logic [3:0]  vt_world_data [LANES];

    always_comb for (int l = 0; l < LANES; l++) vt_world_data[l] = 4'd0;

    vtrace #(.LANES(LANES), .WORLD_LATENCY(2)) u_vtrace (
        .clk, .rst,
        .cfg_we(vt_cfg_we), .cfg_field(vt_cfg_field), .lane_mask(vt_lane_mask),
        .cfg_data(vt_cfg_data), .start(vt_start), .max_steps(vt_max_steps),
        .busy(vt_busy), .done(vt_done),
        .result(vt_result), .hit_cell(vt_hit_cell), .t_hit(vt_t_hit),
        .world_addr(vt_world_addr), .world_phase(), .world_data(vt_world_data)
    );   // world_data is all air here, so world_phase needs no model
end else begin : g_no_vtrace
    assign vt_done = 1'b0;
    assign vt_busy = 1'b0;
    always_comb for (int l = 0; l < LANES; l++) begin
        vt_result[l]   = '0;
        vt_hit_cell[l] = '0;
        vt_t_hit[l]    = '0;
    end
end

/* verilator lint_off PINCONNECTEMPTY */
kc_soc #(
    .LANES(LANES),
    .HAS_DIV_STACK(HAS_DIV_STACK),
    .HAS_RAY_UNIT(HAS_RAY_UNIT),
    .HAS_QRCP(HAS_QRCP),
    .PIPELINED(PIPELINED),
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
    .world_ready(1'b0), .world_rdata(8'h00),
    .vt_cfg_we, .vt_cfg_field, .vt_lane_mask, .vt_cfg_data, .vt_start, .vt_max_steps,
    .vt_done, .vt_busy, .vt_result, .vt_hit_cell, .vt_t_hit
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

// The core only updates the mask on a rising edge and only samples it on the
// next one, so clearing bits LANES-1..1 at every falling edge pins them to 0
// for every observable cycle. (A force on the core's mask does not take
// effect in Verilator 5.020.)
if (LANE0_ONLY && LANES > 1) begin : g_lane0_only
    always @(negedge clk) `KC_CORE.mask <= LANES'(`KC_CORE.mask[0]);
end

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
    $fatal(1, "FAIL: timeout after %0d cycles at pc=%08h", max_cycles, `KC_CORE.pc);
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
        if (`KC_CORE.retire_valid) begin
            if (`KC_CORE.retire_rd_we)
                $display("trace %0d pc=%08h inst=%08h m=%0h x%0d=%08h", cycle,
                         `KC_CORE.retire_pc, `KC_CORE.retire_inst, `KC_CORE.retire_mask,
                         `KC_CORE.retire_rd_addr, `KC_CORE.retire_rd_wdata);
            else
                $display("trace %0d pc=%08h inst=%08h m=%0h", cycle, `KC_CORE.retire_pc,
                         `KC_CORE.retire_inst, `KC_CORE.retire_mask);
`ifndef KC_BASE_CORE
            for (int l = 1; l < LANES; l++)
                if (`KC_CORE.retire_lane_we[l])
                    $display("trace %0d   lane%0d x%0d=%08h", cycle, l,
                             `KC_CORE.retire_rd_addr, `KC_CORE.retire_lane_wdata[l]);
`endif
        end
        if (`KC_CORE.err_set != 0)
            $display("trace %0d pc=%08h halt err=%b", cycle, `KC_CORE.err_pc, `KC_CORE.err_set);
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
