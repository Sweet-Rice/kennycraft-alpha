// Display path: framebuffers -> palette -> Pmod VGA pins (Tai page, Memory &
// Display). The core side is a plain byte port on clk_core; everything else
// runs on clk_pix.
//
// Core-side port (clk_core, 50 MHz), wired to MMIO by the core:
//   fb_we/fb_re/fb_addr/fb_wdata  byte access to the back buffer, region
//                                  0x4000_0000, fb_addr = byte index 0..76799
//   fb_rdata                      read data, valid the cycle after fb_re
//   pal_we/pal_addr/pal_wdata     palette store, region 0x6000_0000
//   swap_req                      1-cycle pulse: store of 1 to FB_SWAP
//   swap_pending                  FB_SWAP read value
//   vblank                        VSYNC read value
//   frame_count                   FRAME_COUNT read value, +1 per vblank
//   fb_mode                       FB_MODE bit 0 (register lives in mmio)
//
// Double buffering. swap_req toggles req_t (ignored while a swap is already
// pending). The pixel side flips front_sel to match req_t at the first pixel
// clock of vblank, so front_sel itself acts as the acknowledge toggle:
// swap_pending = req_t ^ sync(front_sel). It reads 1 from the cycle after
// swap_req until the flip has crossed back, and the core's back buffer is
// ~sync(front_sel), which only changes while swap_pending is still 1.
//
// Clock crossings, all single bits through sync2 two-flop synchronizers:
//   core -> pix  req_t (FB_SWAP), fb_mode
//   pix -> core  front_sel (FB_SWAP completion), vblank (VSYNC),
//                frame_t (FRAME_COUNT, toggles every vblank; the core side
//                counts its edges)
// Pixel data crosses through the dual-clock framebuffer BRAM.
//
// Scan-out pipeline (pixel clock), latency 4 from the timing counters:
//   s0 counters (hx, vy)
//   s1 framebuffer read address, front_sel
//   s2 framebuffer byte (BRAM)
//   s3 palette RGB444 (BRAM)
//   s4 output registers; RGB forced to 0 outside the visible area
// hsync, vsync and the visible flag ride a matching 3-stage delay into s4.
//
// PAL_HEX, when not empty, is the palette's initial contents (palette.sv).
module display #(
    parameter string PAL_HEX = ""
) (
    input  logic        clk_core,
    input  logic        rst_core,
    input  logic        clk_pix,
    input  logic        rst_pix,

    // Core side (clk_core)
    input  logic        fb_we,
    input  logic        fb_re,
    input  logic [16:0] fb_addr,
    input  logic [7:0]  fb_wdata,
    output logic [7:0]  fb_rdata,
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
    // ------------------------------------------------------------------
    // Core-side swap, VSYNC and FRAME_COUNT
    // ------------------------------------------------------------------
    logic req_t;            // clk_core
    logic front_sel;        // clk_pix: 1 = buffer 1 scans out
    logic front_sel_core;
    logic vblank_pix;
    logic frame_t;          // clk_pix
    logic frame_t_core;
    logic frame_t_core_q;

    sync2 u_sync_front  (.clk(clk_core), .rst(rst_core), .d(front_sel),  .q(front_sel_core));
    sync2 u_sync_vblank (.clk(clk_core), .rst(rst_core), .d(vblank_pix), .q(vblank));
    sync2 u_sync_frame  (.clk(clk_core), .rst(rst_core), .d(frame_t),    .q(frame_t_core));

    assign swap_pending = req_t ^ front_sel_core;

    always_ff @(posedge clk_core) begin
        if (rst_core) begin
            req_t          <= 1'b0;
            frame_t_core_q <= 1'b0;
            frame_count    <= '0;
        end else begin
            if (swap_req && !swap_pending) req_t <= !req_t;
            frame_t_core_q <= frame_t_core;
            if (frame_t_core != frame_t_core_q) frame_count <= frame_count + 32'd1;
        end
    end

    // ------------------------------------------------------------------
    // Pixel-side timing, swap and mode
    // ------------------------------------------------------------------
    logic [9:0] hx, vy;
    logic       hsync_n, vsync_n, active, vblank_start;
    logic       req_t_pix;
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

    sync2 u_sync_req  (.clk(clk_pix), .rst(rst_pix), .d(req_t),   .q(req_t_pix));
    sync2 u_sync_mode (.clk(clk_pix), .rst(rst_pix), .d(fb_mode), .q(fb_mode_sync));

    // Swap, FRAME_COUNT toggle and FB_MODE change all happen at the first
    // pixel clock of vblank, never inside a visible frame.
    always_ff @(posedge clk_pix) begin
        if (rst_pix) begin
            front_sel <= 1'b0;
            frame_t   <= 1'b0;
            mode_pix  <= 1'b0;
        end else if (vblank_start) begin
            front_sel <= req_t_pix;
            frame_t   <= !frame_t;
            mode_pix  <= fb_mode_sync;
        end
    end

    // ------------------------------------------------------------------
    // Scan-out pipeline
    // ------------------------------------------------------------------
    logic [16:0] rd_addr_s0, rd_addr_s1;
    logic        front_sel_s1;
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
        rd_addr_s1   <= rd_addr_s0;
        front_sel_s1 <= front_sel;
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

    framebuffer u_fb (
        .clk_a  (clk_core),
        .en_a   (fb_we || fb_re),
        .we_a   (fb_we),
        .sel_a  (!front_sel_core),
        .addr_a (fb_addr),
        .wdata_a(fb_wdata),
        .rdata_a(fb_rdata),
        .clk_b  (clk_pix),
        .sel_b  (front_sel_s1),
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
