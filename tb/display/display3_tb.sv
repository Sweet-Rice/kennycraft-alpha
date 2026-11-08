// Triple buffering testbench: `display` with FB_COUNT = 3 (D24).
//
// Drives the core-side port like the core would and rebuilds each 640x480
// frame from the VGA pins (same monitor as display_tb). Checks:
//   - Reset roles: front 0, draw 1, FB_SWAP reads 0.
//   - FB_SWAP read value: 1 the cycle after an accepted swap, back to 0 within
//     PENDING_MAX core cycles wherever the swap lands (no vblank wait), and a
//     swap_req while it reads 1 is ignored.
//   - Vblank promote: a swap mid-frame leaves that frame on the old front,
//     the ready buffer becomes front exactly at the first pixel clock of
//     vblank, and the next frame matches the swapped image pixel for pixel.
//   - Mailbox replace: two swaps before one vblank; the second frame is
//     shown, the first never is, and the CPU gets the replaced buffer back.
//   - Randomized swap timing (tagged frames): the CPU draws a frame tag into
//     column 0 of every row, then swaps at random times, in bursts faster
//     than the refresh, and right around the flip (message one clock
//     before, at, and after the first pixel clock of vblank; each case must
//     occur). Every frame on the pins shows one tag in every row (no
//     tearing), shown tags never go back, and at each vblank the front shows
//     the newest frame swapped at least SWAP_SETTLE before it, or a newer one.
//   - Invariant checker, at every clock of both domains: the three roles are
//     distinct; while FB_SWAP reads 0 the draw buffer is neither the front nor
//     the ready buffer; every core write goes to a buffer that is neither the
//     front, the one in the scan-out pipeline, nor the ready buffer; the front
//     changes only at the first pixel clock of vblank.
// Any failure ends the run with $fatal (nonzero exit).

module display3_tb;
    localparam int W = 640;
    localparam int H = 480;
    localparam int FB_BYTES = 320 * 240;
    localparam int PENDING_MAX = 14;           // core cycles FB_SWAP may read 1
    localparam realtime SWAP_SETTLE = 200ns;   // swap accepted -> taken by the pixel side
    localparam int RAND_SWAPS = 120;

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
    logic [16:0] fb_addr = '0;
    logic [7:0]  fb_wdata = '0;
    logic [7:0]  fb_rdata;
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

    display #(.FB_COUNT(3)) dut (.*);

    // ------------------------------------------------------------------
    // Reference model
    // ------------------------------------------------------------------
    function automatic logic [11:0] pal_entry(input logic [7:0] i);
        return {i[7:4], i[3:0], i[7:4] ^ i[3:0]};
    endfunction

    function automatic logic [7:0] pattern(input int id, input int col, input int row);
        return 8'((col + 2 * row + ((col * row) >> 3)) ^ (id * 8'h5B));
    endfunction

    function automatic logic [11:0] expected_rgb(input int id, input int x, input int y);
        return pal_entry(pattern(id, x >> 1, y >> 1));
    endfunction

    // ------------------------------------------------------------------
    // Monitor: rebuild frames from the pins (sampled on the pixel clock)
    // ------------------------------------------------------------------
    logic [11:0] cap [H][W];
    int  frames_done = 0;     // completed visible frames
    int  mon_row = -1;        // visible row being received, -1 outside
    bit  seen_vs = 0, seen_hs = 0;
    int  hcnt = 0, lcnt = 0;
    logic hs_q = 1'b1, vs_q = 1'b1;

    always @(posedge clk_pix) if (!rst_pix) begin
        logic [11:0] rgb;
        int row, col;
        rgb = {vga_r, vga_g, vga_b};
        if (vs_q && !vga_vs) begin
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
            row = lcnt - 34;
            col = hcnt - 144;
            if (row >= 0 && row < H && col >= 0 && col < W) begin
                cap[row][col] = rgb;
                mon_row = row;
                if (row == H - 1 && col == W - 1) begin
                    frames_done++;
                    mon_row = -1;
                    frame_end();
                end
            end else if (rgb != 12'h000) begin
                $fatal(1, "RGB %03h outside the visible area (line %0d, clock %0d)", rgb, lcnt, hcnt);
            end
        end
        hcnt++;
        hs_q = vga_hs;
        vs_q = vga_vs;
    end

    // ------------------------------------------------------------------
    // Invariant checker
    // ------------------------------------------------------------------
    int promotes = 0;

    function automatic void check_roles(input string where);
        logic [1:0] dr, fr, rd;
        logic       rv;
        dr = dut.draw_sel_core;
        fr = dut.front;
        rd = dut.g_triple.ready_q;
        rv = dut.g_triple.ready_v;
        if (dr > 2'd2 || fr > 2'd2 || (rv && rd > 2'd2))
            $fatal(1, "%s: buffer index out of range (draw %0d front %0d ready %0d/%0b)", where, dr, fr, rd, rv);
        if (rv && rd == fr) $fatal(1, "%s: ready buffer %0d is the front buffer", where, rd);
        if (!swap_pending && dr == fr) $fatal(1, "%s: draw buffer %0d is the front buffer", where, dr);
        if (!swap_pending && rv && dr == rd) $fatal(1, "%s: draw buffer %0d is the ready buffer", where, dr);
    endfunction

    always @(posedge clk_core) if (!rst_core && !rst_pix) begin
        check_roles("core clock");
        if (fb_we) begin
            if (dut.draw_sel_core == dut.front || dut.draw_sel_core == dut.front_s1)
                $fatal(1, "core write to buffer %0d while it scans out (front %0d, s1 %0d)",
                       dut.draw_sel_core, dut.front, dut.front_s1);
            if (dut.g_triple.ready_v && dut.draw_sel_core == dut.g_triple.ready_q)
                $fatal(1, "core write to the ready buffer %0d", dut.draw_sel_core);
        end
    end

    logic [1:0] fs_q = 2'd0;
    logic [9:0] hx_q = '0, vy_q = '0;
    always @(posedge clk_pix) if (!rst_pix) begin
        check_roles("pixel clock");
        if (dut.front != fs_q) begin
            promotes++;
            if (!(hx_q == 10'd0 && vy_q == 10'd480))
                $fatal(1, "front changed at hx=%0d vy=%0d, not at the start of vblank", hx_q, vy_q);
        end
        fs_q = dut.front;
        hx_q = dut.hx;
        vy_q = dut.vy;
    end

    // Coverage of swap messages around the flip and of mailbox replacement,
    // sampled half a pixel clock before the edge that acts on them.
    int  cov_before = 0, cov_at = 0, cov_after = 0, cov_replace = 0;
    bit  msg_q = 0, vbs_q = 0;
    always @(negedge clk_pix) if (!rst_pix) begin
        if (dut.vblank_start && msg_q) cov_before++;
        if (dut.vblank_start && dut.g_triple.msg) cov_at++;
        if (vbs_q && dut.g_triple.msg) cov_after++;
        if (!dut.vblank_start && dut.g_triple.msg && dut.g_triple.ready_v) cov_replace++;
        msg_q = dut.g_triple.msg;
        vbs_q = dut.vblank_start;
    end

    // ------------------------------------------------------------------
    // Tagged frames (randomized phase)
    // ------------------------------------------------------------------
    bit          tag_mode = 0;
    int          tag_of_buf [3] = '{0, 0, 0};   // frame tag drawn into each buffer
    int          last_shown = 0, shown_frames = 0;
    int          sw_tag [$];
    realtime     sw_time [$];

    // A frame's tag is its byte in column 0 of every row, colour pal_entry(tag).
    function automatic void frame_end();
        logic [11:0] c0;
        int          tag;
        if (!tag_mode || tag_of_buf[dut.front] == 0) return;
        c0 = cap[0][0];
        for (int y = 0; y < H; y++)
            if (cap[y][0] !== c0 || cap[y][1] !== c0)
                $fatal(1, "torn frame: row %0d shows %03h, row 0 shows %03h", y, cap[y][0], c0);
        tag = int'(c0[11:4]);
        if (pal_entry(8'(tag)) !== c0) $fatal(1, "frame colour %03h is no tag", c0);
        if (tag < last_shown) $fatal(1, "frame %0d shown after frame %0d", tag, last_shown);
        last_shown = tag;
        shown_frames++;
    endfunction

    // At each first pixel clock of vblank: the front shows the newest frame
    // swapped at least SWAP_SETTLE earlier, or a newer one already swapped.
    always @(posedge clk_pix) if (!rst_pix && tag_mode && dut.vblank_start) begin
        int      must, may, shown;
        realtime t;
        t = $realtime;
        must = 0; may = 0;
        foreach (sw_tag[i]) begin
            if (sw_time[i] <= t - SWAP_SETTLE) must = sw_tag[i];
            if (sw_time[i] < t) may = sw_tag[i];
        end
        @(negedge clk_pix);
        shown = tag_of_buf[dut.front];
        if (shown < must || shown > may)
            $fatal(1, "after vblank the front shows frame %0d, expected %0d..%0d", shown, must, may);
    end

    // ------------------------------------------------------------------
    // Core-side helpers (drive on the falling edge, DUT samples on the rising)
    // ------------------------------------------------------------------
    task automatic fb_fill(input int id);
        @(negedge clk_core);
        for (int r = 0; r < 240; r++) begin
            for (int c = 0; c < 320; c++) begin
                fb_we = 1'b1; fb_addr = 17'(r * 320 + c); fb_wdata = pattern(id, c, r);
                @(negedge clk_core);
            end
        end
        fb_we = 1'b0;
    endtask

    task automatic fb_tag(input int tag);
        @(negedge clk_core);
        for (int r = 0; r < 240; r++) begin
            fb_we = 1'b1; fb_addr = 17'(r * 320); fb_wdata = 8'(tag);
            @(negedge clk_core);
            fb_we = 1'b0;
            repeat ($urandom_range(0, 1)) @(negedge clk_core);
        end
    endtask

    task automatic pal_fill();
        @(negedge clk_core);
        for (int i = 0; i < 256; i++) begin
            pal_we = 1'b1; pal_addr = 8'(i); pal_wdata = pal_entry(8'(i));
            @(negedge clk_core);
        end
        pal_we = 1'b0;
    endtask

    // One accepted swap: FB_SWAP reads 1 the next cycle and 0 again within
    // PENDING_MAX cycles; a second swap_req meanwhile is ignored. Returns the
    // buffer that was swapped.
    task automatic swap(input int tag, output logic [1:0] swapped);
        int n;
        logic [1:0] d;
        @(negedge clk_core);
        if (swap_pending) $fatal(1, "swap issued while FB_SWAP reads 1");
        d = dut.draw_sel_core;
        swapped = d;
        tag_of_buf[d] = tag;
        swap_req = 1'b1;
        sw_tag.push_back(tag);
        sw_time.push_back($realtime);
        @(negedge clk_core);
        if (swap_pending !== 1'b1) $fatal(1, "FB_SWAP did not read 1 the cycle after the swap");
        // A swap_req while pending must not toggle the request again.
        swap_req = ($urandom_range(0, 3) == 0);
        @(negedge clk_core);
        swap_req = 1'b0;
        n = 2;
        while (swap_pending) begin
            @(negedge clk_core);
            n++;
            if (n > PENDING_MAX) $fatal(1, "FB_SWAP read 1 for more than %0d core cycles", PENDING_MAX);
        end
        if (dut.draw_sel_core == d) $fatal(1, "draw buffer still %0d after the swap", d);
        if (dut.g_triple.req_t !== dut.g_triple.ack_q) $fatal(1, "request and acknowledge disagree");
    endtask

    task automatic wait_frames(input int n);
        int target;
        target = frames_done + n;
        wait (frames_done == target);
    endtask

    task automatic check_frame(input string name, input int id);
        int bad;
        bad = 0;
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++)
                if (cap[y][x] !== expected_rgb(id, x, y)) begin
                    if (bad < 5)
                        $display("  %s mismatch at (%0d,%0d): got %03h expected %03h",
                                 name, x, y, cap[y][x], expected_rgb(id, x, y));
                    bad++;
                end
        if (bad != 0) $fatal(1, "%s: %0d of %0d pixels differ", name, bad, W * H);
        $display("%s: %0d x %0d pixels match (pattern %0d)", name, W, H, id);
    endtask

    // ------------------------------------------------------------------
    // Test sequence
    // ------------------------------------------------------------------
    initial begin
        int f0, p0, k;
        logic [1:0] b1, b2, b3;

        repeat (8) @(posedge clk_pix);
        @(negedge clk_core) rst_core = 1'b0;
        @(negedge clk_pix)  rst_pix  = 1'b0;
        repeat (4) @(negedge clk_core);
        if (dut.front !== 2'd0 || dut.draw_sel_core !== 2'd1 || swap_pending !== 1'b0)
            $fatal(1, "reset roles: front %0d draw %0d FB_SWAP %0b", dut.front, dut.draw_sel_core, swap_pending);
        pal_fill();

        // Vblank promote: swap in the middle of a visible frame.
        fb_fill(1);
        wait_frames(1);
        wait (mon_row == 240);
        f0 = frames_done;
        swap(1, b1);
        if (dut.front !== 2'd0) $fatal(1, "front changed before vblank");
        if (!dut.g_triple.ready_v || dut.g_triple.ready_q !== b1) $fatal(1, "swapped buffer is not ready");
        if (dut.draw_sel_core !== 2'd2) $fatal(1, "draw buffer %0d after the first swap, expected 2", dut.draw_sel_core);
        wait (frames_done == f0 + 1);
        if (dut.front !== 2'd0) $fatal(1, "promoted inside the visible frame");
        wait (frames_done == f0 + 2);
        if (dut.front !== b1) $fatal(1, "ready buffer not promoted at vblank");
        check_frame("promote_frame", 1);
        $display("vblank promote: buffer %0d shown from the next frame", b1);

        // Mailbox: two swaps before one vblank; the first frame is never shown.
        wait (mon_row == 20);
        f0 = frames_done;
        p0 = promotes;
        fb_fill(2);
        swap(2, b2);
        fb_fill(3);
        if (frames_done != f0 || mon_row < 0) $fatal(1, "mailbox test missed its frame");
        swap(3, b3);
        if (dut.draw_sel_core !== b2) $fatal(1, "replaced buffer %0d not handed back (draw %0d)", b2, dut.draw_sel_core);
        if (dut.g_triple.ready_q !== b3 || !dut.g_triple.ready_v) $fatal(1, "replacement is not ready");
        wait (frames_done == f0 + 2);
        if (promotes != p0 + 1) $fatal(1, "%0d promotes for one vblank", promotes - p0);
        if (dut.front !== b3) $fatal(1, "front %0d, expected the replacement %0d", dut.front, b3);
        check_frame("mailbox_frame", 3);
        $display("mailbox replace: buffer %0d dropped, buffer %0d shown", b2, b3);

        // Randomized swaps, tagged frames.
        tag_mode = 1;
        tag_of_buf = '{0, 0, 0};
        sw_tag.delete();
        sw_time.delete();
        for (int t = 1; t <= RAND_SWAPS; t++) begin
            fb_tag(t);
            case ($urandom_range(0, 3))
                0, 1: begin   // around the flip: k pixel clocks before or after its first clock
                    if ($urandom_range(0, 1) == 0) begin
                        k = $urandom_range(0, 6);
                        wait (dut.vy == 10'd479 && dut.hx == 10'(800 - 1 - k));
                    end else begin
                        k = $urandom_range(0, 24);
                        wait (dut.vy == 10'd480 && dut.hx == 10'(k));
                    end
                end
                2: repeat ($urandom_range(0, 3000)) @(negedge clk_core);       // faster than refresh
                default: repeat ($urandom_range(0, 1_000_000)) @(negedge clk_core);
            endcase
            swap(t, b1);
        end
        wait_frames(2);
        if (last_shown != RAND_SWAPS) $fatal(1, "last frame shown %0d, expected %0d", last_shown, RAND_SWAPS);
        $display("random: %0d swaps, %0d tagged frames shown, %0d promotes", RAND_SWAPS, shown_frames, promotes);
        $display("coverage: message before flip %0d, at flip %0d, after flip %0d, mailbox replace %0d",
                 cov_before, cov_at, cov_after, cov_replace);
        if (cov_before == 0 || cov_at == 0 || cov_after == 0 || cov_replace == 0)
            $fatal(1, "swap timing coverage incomplete");
        $display("display3_tb: PASS (%0d frames, frame_count %0d)", frames_done, frame_count);
        $finish;
    end

    initial begin
        #5s;
        $fatal(1, "timeout");
    end
endmodule
