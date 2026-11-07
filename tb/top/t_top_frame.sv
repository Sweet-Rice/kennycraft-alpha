// Full-top Verilator test (P3): rtl/top.sv with the 100 MHz board clock, the
// clk_gen Verilator model, ddr_model standing in for the MIG (tb/ddr/
// unisim_sim.sv) and the memory images as parameters (tb/top/tb.mk builds
// them from Kennedy's game into $(OBJ)/top_hex/<build>).
//
// It runs the program until FRAMES frame swaps have completed. After each
// swap it captures the next whole frame from the VGA pins (640x480 RGB444),
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
//
// LANES / HAS_DIV_STACK pick the core (tb/top/tb.mk: 1 / 0 for the one-lane
// game builds, 8 / 1 for the 8-lane ones).

module t_top_frame #(
    parameter int    LANES         = 1,
    parameter bit    HAS_DIV_STACK = 1'b0,
    parameter string IMEM_HEX = "kc_imem.hex",
    parameter string DMEM_HEX = "kc_dmem.hex",
    parameter string TEX_HEX  = "textures.hex",
    parameter string PAL_HEX  = "palette.hex"
);
    localparam int W = 640, H = 480;
    localparam longint TIMEOUT_NS = 64'd20_000_000_000;  // 20 s of board time

    logic clk = 1'b0, ck_rst = 1'b0;
    always #5 clk = ~clk;

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
          .IMEM_HEX(IMEM_HEX), .DMEM_HEX(DMEM_HEX), .TEX_HEX(TEX_HEX), .PAL_HEX(PAL_HEX)) dut (
        .clk, .ck_rst, .uart_rxd_out, .uart_txd_in(1'b1), .led,
        .vga_r, .vga_g, .vga_b, .vga_hs, .vga_vs,
        .ddr3_addr, .ddr3_ba, .ddr3_cas_n, .ddr3_ck_n, .ddr3_ck_p, .ddr3_cke,
        .ddr3_ras_n, .ddr3_reset_n, .ddr3_we_n, .ddr3_dq, .ddr3_dqs_n, .ddr3_dqs_p,
        .ddr3_cs_n, .ddr3_dm, .ddr3_odt
    );

    string outdir = ".";
    int    frames = 1;

    // ------------------------------------------------------------------
    // UART TX monitor: 1 Mbaud = 100 board clocks per bit
    // ------------------------------------------------------------------
    string line = "";
    initial begin
        forever begin
            logic [7:0] b;
            @(negedge uart_rxd_out);
            repeat (150) @(posedge clk);
            for (int i = 0; i < 8; i++) begin
                b[i] = uart_rxd_out;
                repeat (100) @(posedge clk);
            end
            if (!uart_rxd_out) $fatal(1, "UART framing error");
            if (b == 8'h0A) begin
                $display("uart: %s", line);
                $fflush();   // progress shows up even when stdout is a pipe
                line = "";
            end else if (b != 8'h0D) begin
                line = {line, string'(b)};
            end
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
    end

    // Optional retire trace (+trace_lo / +trace_hi), from the core's retire wires.
    logic [31:0] trace_lo = 32'd1, trace_hi = 32'd0;
    int          traced = 0;
    initial begin
        void'($value$plusargs("trace_lo=%h", trace_lo));
        void'($value$plusargs("trace_hi=%h", trace_hi));
    end
    always @(posedge dut.clk_core)
        if (dut.u_soc.u_core.retire_valid && traced < 64 &&
            dut.u_soc.u_core.retire_pc >= trace_lo && dut.u_soc.u_core.retire_pc <= trace_hi) begin
            traced++;
            $display("t_top_frame: retire pc %08h inst %08h mask %02h rd x%0d lanes written %02h",
                     dut.u_soc.u_core.retire_pc, dut.u_soc.u_core.retire_inst,
                     8'(dut.u_soc.u_core.retire_mask), dut.u_soc.u_core.retire_rd_addr,
                     8'(dut.u_soc.u_core.retire_lane_we));
        end

    initial begin
        int min_swaps = 0;
        void'($value$plusargs("outdir=%s", outdir));
        void'($value$plusargs("frames=%d", frames));
        void'($value$plusargs("swaps=%d", min_swaps));
        repeat (20) @(posedge clk);
        ck_rst = 1'b1;
        for (int n = 1; n <= frames; n++) begin
            wait (swaps >= n);
            @(negedge dut.swap_pending);
            armed = 1; captured = 0;
            wait (captured);
            write_frames(n);
            $display("t_top_frame: frame %0d captured from the VGA pins -> %s/frame%0d.ppm",
                     n, outdir, n);
            $fflush();
        end
        wait (swaps >= min_swaps);
        $display("t_top_frame: PASS");
        $finish;
    end

    always @(posedge led) $fatal(1, "error LED: core halted, ERR_PC %08h", dut.u_soc.err_pc);

    initial begin
        longint timeout_ns = TIMEOUT_NS;
        int     timeout_s;
        if ($value$plusargs("timeout_s=%d", timeout_s)) timeout_ns = longint'(timeout_s) * 1_000_000_000;
        #(timeout_ns);
        $fatal(1, "timeout");
    end
endmodule
