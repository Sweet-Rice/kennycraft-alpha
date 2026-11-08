// Display path: framebuffers -> palette -> Pmod VGA pins (Tai page, Memory &
// Display). The core side is a word port with byte enables on clk_core;
// everything else runs on clk_pix.
//
// Core-side port (clk_core, 50 MHz), wired to MMIO by the core:
//   fb_we/fb_re/fb_be/fb_addr/fb_wdata
//                                 word access to the CPU's draw buffer,
//                                 region 0x4000_0000, fb_addr = word index
//                                 0..19199 (pixel 4 fb_addr + k in byte k),
//                                 fb_be[k] writes byte k on fb_we
//   fb_rdata                      read word, valid the cycle after fb_re
//   pal_we/pal_addr/pal_wdata     palette store, region 0x6000_0000
//   swap_req                      1-cycle pulse: store of 1 to FB_SWAP
//   swap_pending                  FB_SWAP read value
//   vblank                        VSYNC read value
//   frame_count                   FRAME_COUNT read value, +1 per vblank
//   fb_mode                       FB_MODE bit 0 (register lives in mmio)
//
// FB_COUNT = 2, double buffering. swap_req toggles req_t (ignored while a
// swap is already pending). The pixel side flips front_sel to match req_t at
// the first pixel clock of vblank, so front_sel itself acts as the
// acknowledge toggle: swap_pending = req_t ^ sync(front_sel). It reads 1 from
// the cycle after swap_req until the flip has crossed back, and the core's
// draw (back) buffer is ~sync(front_sel), which only changes while
// swap_pending is still 1.
//
// FB_COUNT = 3, triple buffering (D24, mailbox). Buffers 0..2 each have one
// role: front (scanned out), ready (optional: a finished frame waiting for
// vblank), draw (the CPU's), or free. The pixel side owns front and ready;
// the core side owns draw (draw_sel_core). An accepted swap_req toggles
// req_t; the pixel side takes the message at its next clock: the draw buffer
// d becomes ready (an older ready frame is dropped and becomes free), and the
// new draw buffer is the one that is neither d nor the front buffer before
// that clock, ~(d ^ front) for 2-bit indices. It holds that index in
// next_draw and acknowledges by toggling ack_t (= req_t as last seen); the
// core loads draw_sel_core from next_draw when the acknowledge arrives and
// swap_pending = req_t ^ (acknowledge as loaded) drops in the same cycle,
// about 10 core cycles after swap_req. At the first pixel clock of vblank a
// ready buffer becomes front (a message arriving at that very clock is ready
// first and is promoted at once); the old front becomes free. So the front
// and ready buffers only ever take values the core has given up (d), and
// the core only ever gets a buffer that is neither front nor ready when it
// is handed out: scan-out never reads the CPU's buffer and the CPU never
// writes the front or ready buffer, as long as it leaves the framebuffer
// alone while FB_SWAP reads 1 (the same contract as FB_COUNT = 2, D21).
//
// Clock crossings. Single bits go through sync2 two-flop synchronizers:
//   core -> pix  req_t (FB_SWAP request toggle), fb_mode
//   pix -> core  FB_COUNT = 2: front_sel (FB_SWAP completion);
//                FB_COUNT = 3: ack_t (FB_SWAP acknowledge toggle);
//                vblank (VSYNC), frame_t (FRAME_COUNT, toggles every vblank;
//                the core side counts its edges)
// FB_COUNT = 3 also moves two 2-bit indices, each qualified by a toggle
// handshake instead of a synchronizer of its own:
//   core -> pix  draw_sel_core, read only in the pixel clock that takes a
//                message (synchronized req_t differs from ack_t). It last
//                changed in the cycle the previous acknowledge landed, before
//                req_t could toggle again, so it has been stable for at least
//                the two-flop delay of req_t.
//   pix -> core  next_draw, written in the same pixel clock that toggles
//                ack_t and then held until the next message, which the core
//                cannot send before it has loaded next_draw: stable for at
//                least the two-flop delay of ack_t when the core loads it.
// Pixel data crosses through the dual-clock framebuffer BRAM.
//
// Scan-out pipeline (pixel clock), latency 4 from the timing counters:
//   s0 counters (hx, vy)
//   s1 framebuffer read address, front buffer index
//   s2 framebuffer byte (BRAM)
//   s3 palette RGB444 (BRAM)
//   s4 output registers; RGB forced to 0 outside the visible area
// hsync, vsync and the visible flag ride a matching 3-stage delay into s4.
//
// PAL_HEX, when not empty, is the palette's initial contents (palette.sv).
// FB_COUNT (2 or 3) is the number of framebuffers.
module display #(
    parameter string PAL_HEX  = "",
    parameter int    FB_COUNT = 2
) (
    input  logic        clk_core,
    input  logic        rst_core,
    input  logic        clk_pix,
    input  logic        rst_pix,

    // Core side (clk_core)
    input  logic        fb_we,
    input  logic        fb_re,
    input  logic [3:0]  fb_be,
    input  logic [14:0] fb_addr,
    input  logic [31:0] fb_wdata,
    output logic [31:0] fb_rdata,
    input  logic        pal_we,
    input  logic [7:0]  pal_addr,
    input  logic [11:0] pal_wdata,
    input  logic        swap_req,
    output logic        swap_pending,
    output logic        vblank,
    output logic [31:0] frame_count,
    input  logic        fb_mode,

    // Pmod VGA pins (clk_pix)
    output logic [3:0]  vga_r,
    output logic [3:0]  vga_g,
    output logic [3:0]  vga_b,
    output logic        vga_hs,
    output logic        vga_vs
);
    if (FB_COUNT != 2 && FB_COUNT != 3) begin : g_bad_fb_count
        $error("display: FB_COUNT must be 2 or 3");
    end

    logic [1:0] draw_sel_core;  // clk_core: the CPU's draw buffer (port A)
    logic [1:0] front;          // clk_pix: the buffer that scans out

    // ------------------------------------------------------------------
    // Core-side VSYNC and FRAME_COUNT
    // ------------------------------------------------------------------
    logic vblank_pix;
    logic frame_t;          // clk_pix
    logic frame_t_core;
    logic frame_t_core_q;

    sync2 u_sync_vblank (.clk(clk_core), .rst(rst_core), .d(vblank_pix), .q(vblank));
    sync2 u_sync_frame  (.clk(clk_core), .rst(rst_core), .d(frame_t),    .q(frame_t_core));

    always_ff @(posedge clk_core) begin
        if (rst_core) begin
            frame_t_core_q <= 1'b0;
            frame_count    <= '0;
        end else begin
            frame_t_core_q <= frame_t_core;
            if (frame_t_core != frame_t_core_q) frame_count <= frame_count + 32'd1;
        end
    end

    // ------------------------------------------------------------------
    // Pixel-side timing and mode
    // ------------------------------------------------------------------
    logic [9:0] hx, vy;
    logic       hsync_n, vsync_n, active, vblank_start;
    logic       fb_mode_sync;
    logic       mode_pix;   // FB_MODE in use for the current frame

    vga_timing u_timing (
        .clk_pix     (clk_pix),
        .rst         (rst_pix),
        .hx          (hx),
        .vy          (vy),
        .hsync_n     (hsync_n),
        .vsync_n     (vsync_n),
        .active      (active),
        .vblank      (vblank_pix),
        .vblank_start(vblank_start)
    );

    sync2 u_sync_mode (.clk(clk_pix), .rst(rst_pix), .d(fb_mode), .q(fb_mode_sync));

    // Swap, FRAME_COUNT toggle and FB_MODE change all happen at the first
    // pixel clock of vblank, never inside a visible frame.
    always_ff @(posedge clk_pix) begin
        if (rst_pix) begin
            frame_t   <= 1'b0;
            mode_pix  <= 1'b0;
        end else if (vblank_start) begin
            frame_t   <= !frame_t;
            mode_pix  <= fb_mode_sync;
        end
    end

    // ------------------------------------------------------------------
    // Buffer roles and FB_SWAP
    // ------------------------------------------------------------------
    logic req_t;            // clk_core: toggles on an accepted swap_req
    logic req_t_pix;

    sync2 u_sync_req (.clk(clk_pix), .rst(rst_pix), .d(req_t), .q(req_t_pix));

    if (FB_COUNT == 2) begin : g_double
        logic front_sel;        // clk_pix: 1 = buffer 1 scans out
        logic front_sel_core;

        sync2 u_sync_front (.clk(clk_core), .rst(rst_core), .d(front_sel), .q(front_sel_core));

        assign swap_pending  = req_t ^ front_sel_core;
        assign draw_sel_core = {1'b0, !front_sel_core};
        assign front         = {1'b0, front_sel};

        always_ff @(posedge clk_core) begin
            if (rst_core)                       req_t <= 1'b0;
            else if (swap_req && !swap_pending) req_t <= !req_t;
        end

        always_ff @(posedge clk_pix) begin
            if (rst_pix)           front_sel <= 1'b0;
            else if (vblank_start) front_sel <= req_t_pix;
        end
    end else begin : g_triple
        logic       ack_t;          // clk_pix: req_t as last taken
        logic       ack_t_core;
        logic       ack_q;          // clk_core: ack_t as loaded with next_draw
        logic [1:0] draw_q;         // clk_core
        logic [1:0] front_q;        // clk_pix
        logic [1:0] ready_q;        // clk_pix, valid while ready_v
        logic       ready_v;
        logic [1:0] next_draw;      // clk_pix: draw buffer handed to the core
        logic       msg;            // clk_pix: a swap to take this clock

        sync2 u_sync_ack (.clk(clk_core), .rst(rst_core), .d(ack_t), .q(ack_t_core));

        assign swap_pending  = req_t ^ ack_q;
        assign draw_sel_core = draw_q;
        assign front         = front_q;
        assign msg           = req_t_pix != ack_t;

        always_ff @(posedge clk_core) begin
            if (rst_core) begin
                req_t  <= 1'b0;
                ack_q  <= 1'b0;
                draw_q <= 2'd1;
            end else begin
                if (swap_req && !swap_pending) req_t <= !req_t;
                ack_q <= ack_t_core;
                // next_draw crossing: see the header.
                if (ack_t_core != ack_q) draw_q <= next_draw;
            end
        end

        always_ff @(posedge clk_pix) begin
            if (rst_pix) begin
                ack_t     <= 1'b0;
                front_q   <= 2'd0;
                ready_q   <= 2'd0;
                ready_v   <= 1'b0;
                next_draw <= 2'd1;
            end else begin
                ack_t <= req_t_pix;
                // draw_sel_core crossing: read only when msg (see the header).
                if (msg) next_draw <= ~(draw_q ^ front_q);
                if (vblank_start && (msg || ready_v)) begin
                    front_q <= msg ? draw_q : ready_q;
                    ready_v <= 1'b0;
                end else if (msg) begin
                    ready_q <= draw_q;
                    ready_v <= 1'b1;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Scan-out pipeline
    // ------------------------------------------------------------------
    logic [16:0] rd_addr_s0, rd_addr_s1;
    logic [1:0]  front_s1;
    logic [7:0]  pixel_s2;
    logic [11:0] rgb_s3;
    logic [2:0]  active_d, hsync_d, vsync_d;   // [0] = s1, [1] = s2, [2] = s3

    // FB_MODE 0: (vy >> 1) * 320 + (hx >> 1). FB_MODE 1: (vy >> 2) * 320 + (hx >> 2).
    // row * 320 = (row << 8) + (row << 6).
    logic [8:0] row, col;
    assign row = mode_pix ? {1'b0, vy[9:2]} : vy[9:1];
    assign col = mode_pix ? {1'b0, hx[9:2]} : hx[9:1];
    assign rd_addr_s0 = {row, 8'b0} + {2'b0, row, 6'b0} + {8'b0, col};

    // hx[0] and vy[0] never select a framebuffer byte (both modes scale by at least 2).
    logic unused_lsbs;
    assign unused_lsbs = ^{hx[0], vy[0]};

    always_ff @(posedge clk_pix) begin
        rd_addr_s1 <= rd_addr_s0;
        front_s1   <= front;
    end

    // Syncs idle high and the visible flag low in reset, so no pulse leaves
    // the pins while the delay line fills.
    always_ff @(posedge clk_pix) begin
        if (rst_pix) begin
            active_d <= '0;
            hsync_d  <= '1;
            vsync_d  <= '1;
        end else begin
            active_d <= {active_d[1:0], active};
            hsync_d  <= {hsync_d[1:0], hsync_n};
            vsync_d  <= {vsync_d[1:0], vsync_n};
        end
    end

    framebuffer #(.FB_COUNT(FB_COUNT)) u_fb (
        .clk_a  (clk_core),
        .en_a   (fb_we || fb_re),
        .we_a   (fb_we ? fb_be : 4'b0),
        .sel_a  (draw_sel_core),
        .addr_a (fb_addr),
        .wdata_a(fb_wdata),
        .rdata_a(fb_rdata),
        .clk_b  (clk_pix),
        .sel_b  (front_s1),
        .addr_b (rd_addr_s1),
        .rdata_b(pixel_s2)
    );

    palette #(.INIT_FILE(PAL_HEX)) u_pal (
        .clk_w(clk_core),
        .we   (pal_we),
        .waddr(pal_addr),
        .wdata(pal_wdata),
        .clk_r(clk_pix),
        .raddr(pixel_s2),
        .rdata(rgb_s3)
    );

    always_ff @(posedge clk_pix) begin
        if (rst_pix) begin
            vga_r  <= '0;
            vga_g  <= '0;
            vga_b  <= '0;
            vga_hs <= 1'b1;
            vga_vs <= 1'b1;
        end else begin
            vga_r  <= active_d[2] ? rgb_s3[11:8] : 4'h0;
            vga_g  <= active_d[2] ? rgb_s3[7:4]  : 4'h0;
            vga_b  <= active_d[2] ? rgb_s3[3:0]  : 4'h0;
            vga_hs <= hsync_d[2];
            vga_vs <= vsync_d[2];
        end
    end
endmodule
