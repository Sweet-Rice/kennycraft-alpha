// Display path testbench (P1 Done checks).
//
// Drives the core-side port of `display` like the core would, watches only
// the VGA pins like a monitor would, and rebuilds each 640x480 frame from
// hsync/vsync edges. Checks:
//   - VGA timing on the pins: 800-clock lines, 96-clock hsync, 2-line vsync,
//     420,000-clock frames, black outside the visible area.
//   - Two consecutive frames in FB_MODE 0 and in FB_MODE 1 match the expected
//     image pixel for pixel. Every captured frame is written as a PPM next to
//     its expected PPM; the make rule also `cmp`s them.
//   - A swap requested in the middle of a visible frame leaves that frame on
//     the old buffer, shows the new buffer from the next frame, flips the
//     front select exactly at the first pixel clock of vblank, and keeps
//     swap_pending at 1 until then.
//   - Core-side reads of the back buffer return what was written, 1 cycle later,
//     and byte enables write only their bytes (word port, fb_be).
// Any failure ends the run with $fatal (nonzero exit).

module display_tb;
    localparam int W = 640;
    localparam int H = 480;
    localparam int FB_BYTES = 320 * 240;

    // ------------------------------------------------------------------
    // Clocks: 50 MHz core, 25 MHz pixel, deliberately not phase aligned.
    // ------------------------------------------------------------------
    logic clk_core = 1'b0;
    logic clk_pix  = 1'b0;
    always #10 clk_core = !clk_core;
    initial begin
        #3;
        forever #20 clk_pix = !clk_pix;
    end

    logic        rst_core = 1'b1, rst_pix = 1'b1;
    logic        fb_we = 1'b0, fb_re = 1'b0;
    logic [3:0]  fb_be = '0;
    logic [14:0] fb_addr = '0;
    logic [31:0] fb_wdata = '0;
    logic [31:0] fb_rdata;
    logic        pal_we = 1'b0;
    logic [7:0]  pal_addr = '0;
    logic [11:0] pal_wdata = '0;
    logic        swap_req = 1'b0;
    logic        swap_pending;
    logic        vblank;
    logic [31:0] frame_count;
    logic        fb_mode = 1'b0;
    logic [3:0]  vga_r, vga_g, vga_b;
    logic        vga_hs, vga_vs;

    display dut (.*);

    string outdir = "obj_dir/display";

    // ------------------------------------------------------------------
    // Reference model
    // ------------------------------------------------------------------
    function automatic logic [11:0] pal_entry(input logic [7:0] i);
        return {i[7:4], i[3:0], i[7:4] ^ i[3:0]};
    endfunction

    function automatic logic [7:0] pattern(input int id, input int col, input int row);
        if (id == 0) return 8'(col + 2 * row + ((col * row) >> 3));
        else         return 8'(~((col * 5) ^ (row * 3)));
    endfunction

    function automatic logic [11:0] expected_rgb(input int id, input bit mode, input int x, input int y);
        int col, row;
        col = mode ? x >> 2 : x >> 1;
        row = mode ? y >> 2 : y >> 1;
        return pal_entry(pattern(id, col, row));
    endfunction

    // ------------------------------------------------------------------
    // Monitor: rebuild frames from the pins (sampled on the pixel clock)
    // ------------------------------------------------------------------
    logic [11:0] cap [H][W];
    int  frames_done = 0;     // completed visible frames
    int  mon_row = -1;        // visible row being received, -1 outside
    bit  seen_vs = 0, seen_hs = 0, seen_vs_twice = 0;
    int  hcnt = 0, lcnt = 0, vclk = 0, hs_low = 0, vs_low = 0;
    logic hs_q = 1'b1, vs_q = 1'b1;

    always @(posedge clk_pix) if (!rst_pix) begin
        logic [11:0] rgb;
        int row, col;
        rgb = {vga_r, vga_g, vga_b};

        if (vs_q && !vga_vs) begin
            if (seen_vs && vclk != 800 * 525)
                $fatal(1, "frame period %0d clocks, expected 420000", vclk);
            seen_vs_twice = seen_vs;
            seen_vs = 1;
            vclk = 0;
            lcnt = -1;
        end
        if (!vs_q && vga_vs && seen_vs_twice && vs_low != 2 * 800)
            $fatal(1, "vsync low for %0d clocks, expected 1600", vs_low);

        if (hs_q && !vga_hs) begin
            if (seen_hs && hcnt != 800)
                $fatal(1, "line period %0d clocks, expected 800", hcnt);
            seen_hs = 1;
            hcnt = 0;
            lcnt++;
        end
        if (!hs_q && vga_hs && seen_hs && hs_low != 96)
            $fatal(1, "hsync low for %0d clocks, expected 96", hs_low);

        hs_low = vga_hs ? 0 : hs_low + 1;
        vs_low = vga_vs ? 0 : vs_low + 1;

        if (seen_vs) begin
            // Visible line r starts 2 + 33 - 1 = 34 hsync falls after the vsync
            // fall and 96 + 48 = 144 clocks after its own hsync fall.
            row = lcnt - 34;
            col = hcnt - 144;
            if (row >= 0 && row < H && col >= 0 && col < W) begin
                cap[row][col] = rgb;
                mon_row = row;
                if (row == H - 1 && col == W - 1) begin
                    frames_done++;
                    mon_row = -1;
                end
            end else if (rgb != 12'h000) begin
                $fatal(1, "RGB %03h outside the visible area (line %0d, clock %0d)", rgb, lcnt, hcnt);
            end
        end

        hcnt++;
        vclk++;
        hs_q = vga_hs;
        vs_q = vga_vs;
    end

    // The front buffer may only change at the first pixel clock of vblank.
    logic [1:0] fs_q = 2'd0;
    logic [9:0] hx_q = '0, vy_q = '0;
    int flips = 0;
    always @(posedge clk_pix) begin
        if (dut.front != fs_q) begin
            flips++;
            if (!(hx_q == 10'd0 && vy_q == 10'd480))
                $fatal(1, "front buffer changed at hx=%0d vy=%0d, not at the start of vblank", hx_q, vy_q);
        end
        fs_q = dut.front;
        hx_q = dut.hx;
        vy_q = dut.vy;
    end

    // ------------------------------------------------------------------
    // Core-side helpers (drive on the falling edge, DUT samples on the rising)
    // ------------------------------------------------------------------
    // One byte at byte index addr: only its byte enable, junk in the other
    // byte lanes of fb_wdata.
    task automatic fb_write_byte(input int addr, input logic [7:0] data);
        fb_we = 1'b1; fb_addr = 15'(addr / 4); fb_be = 4'b0001 << (addr % 4);
        fb_wdata = {4{8'h5A}};
        fb_wdata[(addr % 4) * 8 +: 8] = data;
        @(negedge clk_core);
        fb_we = 1'b0;
    endtask

    task automatic fb_read_word(input int waddr, output logic [31:0] data);
        @(negedge clk_core);
        fb_re = 1'b1; fb_addr = 15'(waddr);
        @(negedge clk_core);
        fb_re = 1'b0;
        data = fb_rdata;
    endtask

    // Odd rows go in byte by byte, even rows a word (four pixels) at a time.
    task automatic fb_fill(input int id);
        @(negedge clk_core);
        for (int r = 0; r < 240; r++) begin
            for (int c = 0; c < 320; c += 4) begin
                if (r % 2 == 1) begin
                    for (int k = 0; k < 4; k++) fb_write_byte(r * 320 + c + k, pattern(id, c + k, r));
                end else begin
                    fb_we = 1'b1; fb_be = 4'b1111; fb_addr = 15'((r * 320 + c) / 4);
                    fb_wdata = {pattern(id, c + 3, r), pattern(id, c + 2, r), pattern(id, c + 1, r), pattern(id, c, r)};
                    @(negedge clk_core);
                end
            end
        end
        fb_we = 1'b0;
    endtask

    task automatic fb_check_readback(input int id);
        int addr;
        logic [31:0] w;
        for (int k = 0; k < 2000; k++) begin
            addr = (k * 7919 + 13) % FB_BYTES;
            fb_read_word(addr / 4, w);
            if (w[(addr % 4) * 8 +: 8] !== pattern(id, addr % 320, addr / 320))
                $fatal(1, "fb read addr %0d = %02h, expected %02h", addr, w[(addr % 4) * 8 +: 8],
                       pattern(id, addr % 320, addr / 320));
        end
    endtask

    // Byte enables: a word, then single bytes and a halfword over it.
    task automatic fb_check_be();
        logic [31:0] w;
        @(negedge clk_core);
        fb_we = 1'b1; fb_be = 4'b1111; fb_addr = 15'd100; fb_wdata = 32'hA1B2_C3D4;
        @(negedge clk_core);
        fb_write_byte(401, 8'h11);
        fb_write_byte(403, 8'h33);
        fb_read_word(100, w);
        if (w !== 32'h33B2_11D4) $fatal(1, "fb byte enables: word %08h, expected 33b211d4", w);
        @(negedge clk_core);
        fb_we = 1'b1; fb_be = 4'b0011; fb_addr = 15'd100; fb_wdata = 32'hFFFF_7766;
        @(negedge clk_core);
        fb_we = 1'b0;
        fb_read_word(100, w);
        if (w !== 32'h33B2_7766) $fatal(1, "fb halfword enable: word %08h, expected 33b27766", w);
    endtask

    task automatic pal_fill();
        @(negedge clk_core);
        for (int i = 0; i < 256; i++) begin
            pal_we = 1'b1; pal_addr = 8'(i); pal_wdata = pal_entry(8'(i));
            @(negedge clk_core);
        end
        pal_we = 1'b0;
    endtask

    task automatic request_swap();
        @(negedge clk_core);
        swap_req = 1'b1;
        @(negedge clk_core);
        swap_req = 1'b0;
        if (swap_pending !== 1'b1) $fatal(1, "swap_pending not set the cycle after swap_req");
    endtask

    task automatic wait_swap_done();
        while (swap_pending) @(negedge clk_core);
    endtask

    task automatic wait_frames(input int n);
        int target;
        target = frames_done + n;
        wait (frames_done == target);
    endtask

    task automatic write_ppm(input string name, input int id, input bit mode, input bit expected);
        int fd;
        logic [11:0] p;
        fd = $fopen({outdir, "/", name, ".ppm"}, "w");
        if (fd == 0) $fatal(1, "cannot open %s/%s.ppm", outdir, name);
        $fwrite(fd, "P3\n%0d %0d\n15\n", W, H);
        for (int y = 0; y < H; y++) begin
            for (int x = 0; x < W; x++) begin
                p = expected ? expected_rgb(id, mode, x, y) : cap[y][x];
                $fwrite(fd, "%0d %0d %0d\n", p[11:8], p[7:4], p[3:0]);
            end
        end
        $fclose(fd);
    endtask

    // Compare the frame that just completed, write it and its expected PPM.
    task automatic check_frame(input string name, input int id, input bit mode);
        int bad;
        bad = 0;
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++)
                if (cap[y][x] !== expected_rgb(id, mode, x, y)) begin
                    if (bad < 5)
                        $display("  %s mismatch at (%0d,%0d): got %03h expected %03h",
                                 name, x, y, cap[y][x], expected_rgb(id, mode, x, y));
                    bad++;
                end
        write_ppm(name, 0, 1'b0, 1'b0);
        write_ppm({name, "_expected"}, id, mode, 1'b1);
        if (bad != 0) $fatal(1, "%s: %0d of %0d pixels differ", name, bad, W * H);
        $display("%s: %0d x %0d pixels match (pattern %0d, FB_MODE %0d)", name, W, H, id, mode);
    endtask

    // ------------------------------------------------------------------
    // Test sequence
    // ------------------------------------------------------------------
    initial begin
        int f0;
        logic [31:0] fc0;
        void'($value$plusargs("outdir=%s", outdir));

        repeat (8) @(posedge clk_pix);
        @(negedge clk_core) rst_core = 1'b0;
        @(negedge clk_pix)  rst_pix  = 1'b0;

        // Palette, then pattern 0 into the back buffer (buffer 1) and show it.
        pal_fill();
        fb_check_be();
        fb_fill(0);
        fb_check_readback(0);
        if (dut.front !== 2'd0) $fatal(1, "front buffer should start as buffer 0");
        request_swap();
        wait_swap_done();
        if (dut.front !== 2'd1) $fatal(1, "swap did not select buffer 1");

        // FB_MODE 0: two consecutive frames.
        wait_frames(1); check_frame("mode0_frame1", 0, 1'b0);
        wait_frames(1); check_frame("mode0_frame2", 0, 1'b0);

        // FB_MODE 1: takes effect at the next vblank; skip one frame, then two.
        fb_mode = 1'b1;
        wait_frames(2); check_frame("mode1_frame1", 0, 1'b1);
        wait_frames(1); check_frame("mode1_frame2", 0, 1'b1);

        // Swap requested mid-frame.
        fb_mode = 1'b0;
        fb_fill(1);              // back buffer is now buffer 0
        fb_check_readback(1);
        wait_frames(1);          // FB_MODE 0 is back from the next frame on
        wait (mon_row == 240);
        f0  = frames_done;
        fc0 = frame_count;
        request_swap();
        wait (frames_done == f0 + 1);
        if (swap_pending !== 1'b1) $fatal(1, "swap completed before the end of the visible frame");
        check_frame("swap_frame_before", 0, 1'b0);
        wait (frames_done == f0 + 2);
        if (swap_pending !== 1'b0) $fatal(1, "swap still pending one frame later");
        if (frame_count !== fc0 + 32'd1)
            $fatal(1, "frame_count advanced by %0d across one vblank", frame_count - fc0);
        check_frame("swap_frame_after", 1, 1'b0);

        if (flips != 2) $fatal(1, "front buffer changed %0d times, expected 2", flips);
        if (frame_count < 32'd8) $fatal(1, "frame_count %0d too low", frame_count);
        $display("display_tb: PASS (%0d frames, frame_count %0d)", frames_done, frame_count);
        $finish;
    end

    initial begin
        #500ms;
        $fatal(1, "timeout");
    end
endmodule
