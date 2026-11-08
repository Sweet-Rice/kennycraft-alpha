// Full-top Verilator test (P3): rtl/top.sv with the 100 MHz board clock, the
// clk_gen Verilator model, ddr_model standing in for the MIG (tb/ddr/
// unisim_sim.sv with KC_EXT_CLOCKS) and the memory images as parameters
// (tb/top/tb.mk builds them from Kennedy's game into $(OBJ)/top_hex/<build>).
//
// It runs the program until FRAMES frame swaps have completed. Frame n is
// the first frame the front buffer shows after FB_SWAP n (the display's front
// buffer changes at a vblank once n swaps have happened): it is captured
// from the VGA pins (640x480 RGB444),
// writes it as <outdir>/frame<N>_vga.ppm, checks that FB_MODE 1 shows every
// framebuffer pixel as a uniform 4x4 block, and writes the 160x120 image as
// <outdir>/frame<N>.ppm (8-bit channels = 4-bit value x 17). UART output is
// echoed with a "uart: " prefix. Fails on the error LED, a VGA timing error
// or a timeout.
//
//   +outdir=DIR   output directory (default .)
//   +frames=N     frames to capture (default 1)
//   +swaps=N      also run until N FB_SWAPs (frame rates; default 0)
//   +timeout_s=N  give up after N s of board time (default 20)
//   +trace_lo=LO +trace_hi=HI  print the first 64 retired instructions whose
//                 PC (hex) is in LO..HI: PC, instruction, active mask, rd,
//                 lanes written
//   +prof=FILE +prof_swap=N  per-PC profile of the core cycles from FB_SWAP N
//                 (default 1) to FB_SWAP N+1, one line per PC that used a
//                 cycle: PC, cycles, retires, active lanes summed over the
//                 retires, cycles in the memory state, and the bus region
//                 (address bits 31:28) of its last data access
//   +wlog=FILE +wlog_swap=N  every world load the LSU issues between FB_SWAP N
//                 (default 0, i.e. from reset) and FB_SWAP N+1: core cycle,
//                 PC, lane, world index, loaded value
//
// LANES / HAS_DIV_STACK / HAS_RAY_UNIT / HAS_QRCP / FB_COUNT pick the core and
// display (tb/top/tb.mk: 1 / 0 / 0 / 0 / 2 for the one-lane game builds,
// 8 / 1 / 0 / 0 / 2 for the 8-lane ones, 8 / 1 / 1 / 1 / 3 for kc_chip8_vtrace).
//
// The build has no --timing: tb/top/t_top_frame.cpp drives the ports, the
// 100 MHz clk (first rising edge at 5 ns), ck_rst (released with the 20th
// rising edge of clk), the MIG's 83.33 MHz ui_clk (first rising edge at
// 6 ns) and the DDR MMCM's LOCKED (high from 500 ns), in 1 ps steps.

module t_top_frame #(
    parameter int    LANES         = 1,
    parameter bit    HAS_DIV_STACK = 1'b0,
    parameter string IMEM_HEX = "kc_imem.hex",
    parameter string DMEM_HEX = "kc_dmem.hex",
    parameter string TEX_HEX  = "textures.hex",
    parameter string PAL_HEX  = "palette.hex",
    parameter bit    HAS_RAY_UNIT  = 1'b0,
    parameter bit    HAS_QRCP      = 1'b0,
    parameter int    FB_COUNT      = 2,
    parameter bit    PIPELINED     = 1'b0   // core_pipe instead of core (P8)
) (
    input logic clk,
    input logic ck_rst,
    input logic ddr_ui_clk,        // mig_ddr3's ui_clk (tb/ddr/unisim_sim.sv)
    input logic ddr_mmcm_locked    // ddr_clk's MMCME2_BASE LOCKED
);
    localparam int W = 640, H = 480;
    localparam longint TIMEOUT_NS = 64'd20_000_000_000;  // 20 s of board time

    logic        uart_rxd_out, led, vga_hs, vga_vs;
    logic [3:0]  vga_r, vga_g, vga_b;
    logic [13:0] ddr3_addr;
    logic [2:0]  ddr3_ba;
    logic        ddr3_cas_n, ddr3_ras_n, ddr3_reset_n, ddr3_we_n;
    logic [0:0]  ddr3_ck_n, ddr3_ck_p, ddr3_cke, ddr3_cs_n, ddr3_odt;
    logic [1:0]  ddr3_dm;
    wire  [15:0] ddr3_dq;
    wire  [1:0]  ddr3_dqs_n, ddr3_dqs_p;

    top #(.LANES(LANES), .HAS_DIV_STACK(HAS_DIV_STACK),
          .IMEM_HEX(IMEM_HEX), .DMEM_HEX(DMEM_HEX), .TEX_HEX(TEX_HEX), .PAL_HEX(PAL_HEX),
          .HAS_RAY_UNIT(HAS_RAY_UNIT), .HAS_QRCP(HAS_QRCP), .FB_COUNT(FB_COUNT),
          .PIPELINED(PIPELINED)) dut (
        .clk, .ck_rst, .uart_rxd_out, .uart_txd_in(1'b1), .led,
        .vga_r, .vga_g, .vga_b, .vga_hs, .vga_vs,
        .ddr3_addr, .ddr3_ba, .ddr3_cas_n, .ddr3_ck_n, .ddr3_ck_p, .ddr3_cke,
        .ddr3_ras_n, .ddr3_reset_n, .ddr3_we_n, .ddr3_dq, .ddr3_dqs_n, .ddr3_dqs_p,
        .ddr3_cs_n, .ddr3_dm, .ddr3_odt
    );

    string outdir = ".";
    int    frames = 1;

    // ------------------------------------------------------------------
    // UART TX monitor: 1 Mbaud = 100 board clocks per bit. From the falling
    // edge of the start bit, bit i is sampled at the (150 + 100 i)th rising
    // edge of clk and the stop bit at the 950th.
    // ------------------------------------------------------------------
    string      line = "";
    bit         uart_busy = 0;
    int         uart_clks = 0;
    logic [7:0] uart_b;

    always @(negedge uart_rxd_out) if (!uart_busy) begin
        uart_busy = 1;
        uart_clks = 0;
    end

    always @(posedge clk) if (uart_busy) begin
        uart_clks++;
        if (uart_clks >= 150 && uart_clks < 950 && uart_clks % 100 == 50) begin
            uart_b[(uart_clks - 150) / 100] = uart_rxd_out;
        end else if (uart_clks == 950) begin
            if (!uart_rxd_out) $fatal(1, "UART framing error");
            if (uart_b == 8'h0A) begin
                $display("uart: %s", line);
                $fflush();   // progress shows up even when stdout is a pipe
                line = "";
            end else if (uart_b != 8'h0D) begin
                line = {line, string'(uart_b)};
            end
            uart_busy = 0;
        end
    end

    // ------------------------------------------------------------------
    // VGA capture from the pins (pixel clock = clk_gen's clk_pix)
    // ------------------------------------------------------------------
    logic [11:0] cap [H][W];
    bit  armed = 0, capturing = 0, captured = 0;
    bit  seen_vs = 0, seen_hs = 0;
    int  hcnt = 0, lcnt = 0;
    logic hs_q = 1'b1, vs_q = 1'b1;

    always @(posedge dut.clk_pix) if (!dut.rst_pix) begin
        int row, col;
        if (vs_q && !vga_vs) begin
            if (seen_vs && capturing) captured = 1;
            capturing = armed && !captured;
            if (capturing) armed = 0;
            seen_vs = 1;
            lcnt = -1;
        end
        if (hs_q && !vga_hs) begin
            if (seen_hs && hcnt != 800) $fatal(1, "line period %0d clocks, expected 800", hcnt);
            seen_hs = 1;
            hcnt = 0;
            lcnt++;
        end
        if (seen_vs) begin
            // Visible line r starts 34 hsync falls after the vsync fall and
            // 144 clocks after its own hsync fall (display_tb).
            row = lcnt - 34;
            col = hcnt - 144;
            if (row >= 0 && row < H && col >= 0 && col < W) begin
                if (capturing) cap[row][col] = {vga_r, vga_g, vga_b};
            end else if ({vga_r, vga_g, vga_b} != 12'h000) begin
                $fatal(1, "RGB %03h outside the visible area (line %0d, clock %0d)",
                       {vga_r, vga_g, vga_b}, lcnt, hcnt);
            end
        end
        hcnt++;
        hs_q = vga_hs;
        vs_q = vga_vs;
    end

    task automatic write_frames(input int n);
        int fd;
        fd = $fopen($sformatf("%s/frame%0d_vga.ppm", outdir, n), "w");
        if (fd == 0) $fatal(1, "cannot write to %s", outdir);
        $fwrite(fd, "P3\n%0d %0d\n255\n", W, H);
        for (int r = 0; r < H; r++)
            for (int c = 0; c < W; c++)
                $fwrite(fd, "%0d %0d %0d\n", 17 * cap[r][c][11:8], 17 * cap[r][c][7:4], 17 * cap[r][c][3:0]);
        $fclose(fd);

        for (int r = 0; r < H; r++)
            for (int c = 0; c < W; c++)
                if (cap[r][c] !== cap[r & ~3][c & ~3])
                    $fatal(1, "frame %0d: pixel (%0d,%0d) = %03h, its 4x4 block starts with %03h",
                           n, c, r, cap[r][c], cap[r & ~3][c & ~3]);

        fd = $fopen($sformatf("%s/frame%0d.ppm", outdir, n), "w");
        $fwrite(fd, "P3\n160 120\n255\n");
        for (int r = 0; r < H; r += 4)
            for (int c = 0; c < W; c += 4)
                $fwrite(fd, "%0d %0d %0d\n", 17 * cap[r][c][11:8], 17 * cap[r][c][7:4], 17 * cap[r][c][3:0]);
        $fclose(fd);
    endtask

    // ------------------------------------------------------------------
    // Run
    // ------------------------------------------------------------------
    // Every FB_SWAP with its core cycle (CYCLES) and the cycles since the
    // previous one, logged here rather than in the capture loop so fast
    // frame rates are not missed while a frame is being captured.
    int          swaps = 0;
    logic [31:0] last_swap = '0;
    always @(posedge dut.swap_req) begin
        swaps++;
        if (swaps == 1)
            $display("t_top_frame: FB_SWAP %0d at core cycle %0d", swaps, dut.u_soc.u_mmio.cycles);
        else
            $display("t_top_frame: FB_SWAP %0d at core cycle %0d, %0d cycles after FB_SWAP %0d",
                     swaps, dut.u_soc.u_mmio.cycles, dut.u_soc.u_mmio.cycles - last_swap, swaps - 1);
        last_swap = dut.u_soc.u_mmio.cycles;
        $fflush();
        check_pass();
    end

    // Optional retire trace (+trace_lo / +trace_hi), from the core's retire wires.
    logic [31:0] trace_lo = 32'd1, trace_hi = 32'd0;
    int          traced = 0;
    initial begin
        void'($value$plusargs("trace_lo=%h", trace_lo));
        void'($value$plusargs("trace_hi=%h", trace_hi));
    end
    always @(posedge dut.clk_core)
        if (dut.u_soc.g_core.u_core.retire_valid && traced < 64 &&
            dut.u_soc.g_core.u_core.retire_pc >= trace_lo && dut.u_soc.g_core.u_core.retire_pc <= trace_hi) begin
            traced++;
            $display("t_top_frame: retire pc %08h inst %08h mask %02h rd x%0d lanes written %02h",
                     dut.u_soc.g_core.u_core.retire_pc, dut.u_soc.g_core.u_core.retire_inst,
                     8'(dut.u_soc.g_core.u_core.retire_mask), dut.u_soc.g_core.u_core.retire_rd_addr,
                     8'(dut.u_soc.g_core.u_core.retire_lane_we));
        end

    // Optional per-PC profile (+prof) and world-load log (+wlog), for frame
    // cycle breakdowns and lane-by-lane DDA walks.
    localparam int PROF_WORDS = 8192;   // imem: 32 KB
    int          prof_fd = 0, prof_swap = 1, wlog_fd = 0, wlog_swap = 0;
    longint      prof_cyc [PROF_WORDS], prof_ret [PROF_WORDS], prof_lanes [PROF_WORDS],
                 prof_mem [PROF_WORDS];
    logic [3:0]  prof_region [PROF_WORDS];
    // World reads accepted on the bus whose data has not reached the lanes
    // yet (ld_cap): the cycle after the access on the multi-cycle core, two
    // cycles after on core_pipe, whose LSU registers the read data
    logic [31:0] wq_cyc [$], wq_pc [$], wq_addr [$];
    int          wq_lane [$];
    initial begin
        string fn;
        void'($value$plusargs("prof_swap=%d", prof_swap));
        void'($value$plusargs("wlog_swap=%d", wlog_swap));
        if ($value$plusargs("prof=%s", fn)) begin
            prof_fd = $fopen(fn, "w");
            if (prof_fd == 0) $fatal(1, "cannot write %s", fn);
        end
        if ($value$plusargs("wlog=%s", fn)) begin
            wlog_fd = $fopen(fn, "w");
            if (wlog_fd == 0) $fatal(1, "cannot write %s", fn);
        end
    end
    always @(posedge dut.clk_core) begin
        int i;
        i = int'(dut.u_soc.g_core.u_core.pc[14:2]);
        if (prof_fd != 0 && swaps == prof_swap) begin
            prof_cyc[i]++;
            if (dut.u_soc.g_core.u_core.retire_valid) begin
                prof_ret[i]++;
                prof_lanes[i] += longint'($countones(dut.u_soc.g_core.u_core.retire_mask));
            end
            if (dut.u_soc.g_core.u_core.u_lsu.go) begin
                prof_mem[i]++;
                prof_region[i] = dut.u_soc.g_core.u_core.bus_addr[31:28];
            end
        end else if (prof_fd != 0 && swaps > prof_swap) begin
            for (int p = 0; p < PROF_WORDS; p++)
                if (prof_cyc[p] != 0)
                    $fwrite(prof_fd, "%08h %0d %0d %0d %0d %0h\n", p * 4, prof_cyc[p], prof_ret[p],
                            prof_lanes[p], prof_mem[p], prof_region[p]);
            $fclose(prof_fd);
            prof_fd = 0;
            $display("t_top_frame: profile of FB_SWAP %0d to %0d written", prof_swap, prof_swap + 1);
        end
        if (wlog_fd != 0) begin
            if (wq_lane.size() != 0 && dut.u_soc.g_core.u_core.ld_cap[wq_lane[0]]) begin
                $fwrite(wlog_fd, "%0d %08h %0d %05h %0d\n", wq_cyc[0], wq_pc[0], wq_lane[0],
                        wq_addr[0][16:0], dut.u_soc.g_core.u_core.ld_value[wq_lane[0]]);
                void'(wq_cyc.pop_front());
                void'(wq_pc.pop_front());
                void'(wq_lane.pop_front());
                void'(wq_addr.pop_front());
            end
            if (swaps > wlog_swap) begin
                $fclose(wlog_fd);
                wlog_fd = 0;
            end else if (swaps == wlog_swap && dut.u_soc.g_core.u_core.bus_req && dut.u_soc.g_core.u_core.bus_ready &&
                         !dut.u_soc.g_core.u_core.bus_we && dut.u_soc.g_core.u_core.bus_addr[31:28] == 4'h2) begin
                wq_cyc.push_back(dut.u_soc.u_mmio.cycles);
                wq_pc.push_back(dut.u_soc.g_core.u_core.pc);
                wq_lane.push_back(int'(dut.u_soc.g_core.u_core.u_lsu.cur));
                wq_addr.push_back(dut.u_soc.g_core.u_core.bus_addr);
            end
        end
    end

    // The program never comes back to address 0 (crt0's _start) once it has
    // left it: a second retire at PC 0 fails the test and prints the last 32
    // retired instructions, every lane's ra and sp, CYCLES and the reset.
    localparam int RING = 32;
    logic [31:0] ring_pc [RING], ring_inst [RING], ring_wdata [RING];
    logic [7:0]  ring_mask [RING], ring_we [RING];
    logic [4:0]  ring_rd [RING];
    int          ring_n = 0, boots = 0;
    logic [31:0] lane_ra [LANES], lane_sp [LANES];
    for (genvar g = 0; g < LANES; g++) begin : g_peek
        assign lane_ra[g] = dut.u_soc.g_core.u_core.g_lane[g].u_lane.u_rf.regs[1];
        assign lane_sp[g] = dut.u_soc.g_core.u_core.g_lane[g].u_lane.u_rf.regs[2];
    end
    always @(posedge dut.clk_core) if (dut.u_soc.g_core.u_core.retire_valid) begin
        if (dut.u_soc.g_core.u_core.retire_pc == 32'h0) begin
            boots++;
            if (boots > 1) begin
                $display("t_top_frame: PC 0 retired again at core cycle %0d (rst_core %b); last %0d retires:",
                         dut.u_soc.u_mmio.cycles, dut.rst_core, RING);
                for (int i = ring_n - RING; i < ring_n; i++)
                    if (i >= 0)
                        $display("t_top_frame:   pc %08h inst %08h mask %02h rd x%0d lanes written %02h lane0 wdata %08h",
                                 ring_pc[i % RING], ring_inst[i % RING], ring_mask[i % RING],
                                 ring_rd[i % RING], ring_we[i % RING], ring_wdata[i % RING]);
                for (int l = 0; l < LANES; l++)
                    $display("t_top_frame:   lane %0d ra %08h sp %08h", l, lane_ra[l], lane_sp[l]);
                $fatal(1, "core jumped back to address 0");
            end
        end
        ring_pc[ring_n % RING]    = dut.u_soc.g_core.u_core.retire_pc;
        ring_inst[ring_n % RING]  = dut.u_soc.g_core.u_core.retire_inst;
        ring_mask[ring_n % RING]  = 8'(dut.u_soc.g_core.u_core.retire_mask);
        ring_rd[ring_n % RING]    = dut.u_soc.g_core.u_core.retire_rd_addr;
        ring_we[ring_n % RING]    = 8'(dut.u_soc.g_core.u_core.retire_lane_we);
        ring_wdata[ring_n % RING] = dut.u_soc.g_core.u_core.retire_rd_wdata;
        ring_n++;
    end
    always @(posedge dut.rst_core)
        if (boots > 0) $display("t_top_frame: rst_core asserted at time %0t", $time);

    // Frame n (1..frames) is captured from the first change of the front
    // buffer (at the first pixel clock of vblank) once n FB_SWAPs have
    // happened. With FB_COUNT = 2 that is the flip the game waits for with
    // FB_SWAP; with FB_COUNT = 3 it is the promote of the ready buffer, which
    // FB_SWAP no longer waits for. PASS once every
    int     min_swaps = 0, frame_n = 1;
    bit     frames_done = 0, frame_wait = 0;
    longint timeout_ns = TIMEOUT_NS;
    initial begin
        int timeout_s;
        void'($value$plusargs("outdir=%s", outdir));
        void'($value$plusargs("frames=%d", frames));
        void'($value$plusargs("swaps=%d", min_swaps));
        if ($value$plusargs("timeout_s=%d", timeout_s)) timeout_ns = longint'(timeout_s) * 1_000_000_000;
    end

    function automatic void check_pass();
        if (frames_done && swaps >= min_swaps) begin
            $display("t_top_frame: PASS");
            $finish;
        end
    endfunction

    always @(posedge ck_rst) begin
        frames_done = frames < 1;
        check_pass();
    end

    always @(dut.u_display.front) if (!frames_done && !frame_wait && swaps >= frame_n) begin
        armed = 1; captured = 0;
        frame_wait = 1;
    end

    always @(posedge captured) if (frame_wait) begin
        frame_wait = 0;
        write_frames(frame_n);
        $display("t_top_frame: frame %0d captured from the VGA pins -> %s/frame%0d.ppm",
                 frame_n, outdir, frame_n);
        $fflush();
        frame_n++;
        if (frame_n > frames) begin
            frames_done = 1;
            check_pass();
        end
    end

    always @(posedge led) $fatal(1, "error LED: core halted, ERR_PC %08h", dut.u_soc.err_pc);

    // clk falls at every multiple of 10 ns, so this fires at timeout_ns.
    always @(negedge clk) if ($time >= timeout_ns) $fatal(1, "timeout");
endmodule
