// Standalone display bitstream (KC_TARGET=display_test) for the on-board
// check of the P1 display path. After reset it writes the palette, fills the
// back buffer through the core-side port, reads every byte back and checks
// it, then requests one swap:
//   rows   0..179  eight 40-pixel colour bars (FB_MODE 0, 320x240 buffer):
//                  white, yellow, cyan, green, magenta, red, blue, black
//   rows 180..239  sixteen 20-pixel grey steps, black to white
// Every byte uses all 8 bits, so synthesis keeps the full framebuffer.
// LD4 lights once the swap has completed and the read-back matched.
// uart_rxd_out idles high.
module display_test (
    input  logic       clk,
    input  logic       ck_rst,
    output logic [3:0] vga_r,
    output logic [3:0] vga_g,
    output logic [3:0] vga_b,
    output logic       vga_hs,
    output logic       vga_vs,
    output logic       led,
    output logic       uart_rxd_out
);
    logic clk_core, clk_pix, locked, rst_core, rst_pix;

    clk_gen u_clk (
        .clk     (clk),
        .rst_n   (ck_rst),
        .clk_core(clk_core),
        .clk_pix (clk_pix),
        .locked  (locked),
        .rst_core(rst_core),
        .rst_pix (rst_pix)
    );

    typedef enum logic [2:0] {S_PAL, S_FB, S_CHECK, S_SWAP, S_DONE} state_t;
    state_t      state;
    logic [8:0]  x;
    logic [7:0]  y;
    logic [16:0] addr;
    logic [7:0]  pal_i;
    logic        fb_we, fb_re, pal_we, swap_req, swap_pending;
    logic [7:0]  fb_wdata;
    logic [11:0] pal_wdata;
    logic        vblank;
    logic [31:0] frame_count;
    logic [31:0] fb_word;        // the display's core port is a word port
    logic [1:0]  fb_lane_q;
    logic [7:0]  fb_rdata;
    logic        check_valid;    // fb_rdata holds the byte read last cycle
    logic [7:0]  check_expect;
    logic        read_ok;

    // Palette. Bytes with bit 7 = 0 are colour bars chosen by bits 2:0
    // (bits 6:3 carry noise so every framebuffer bit is exercised); bytes with
    // bit 7 = 1 are grey levels from bits 3:0.
    always_comb begin
        if (pal_i[7]) begin
            pal_wdata = {3{pal_i[3:0]}};
        end else begin
            unique case (pal_i[2:0])
                3'd0: pal_wdata = 12'hFFF;
                3'd1: pal_wdata = 12'hFF0;
                3'd2: pal_wdata = 12'h0FF;
                3'd3: pal_wdata = 12'h0F0;
                3'd4: pal_wdata = 12'hF0F;
                3'd5: pal_wdata = 12'hF00;
                3'd6: pal_wdata = 12'h00F;
                default: pal_wdata = 12'h000;
            endcase
        end
    end

    // Pixel byte for (x, y) of the 320x240 buffer.
    logic [8:0] x_div20;
    assign x_div20  = x / 9'd20;
    assign fb_wdata = (y < 8'd180) ? {1'b0, x[3:0] ^ y[3:0], x_div20[3:1]}
                                   : {1'b1, y[2:0], x_div20[3:0]};

    always_ff @(posedge clk_core) begin
        if (rst_core) begin
            state        <= S_PAL;
            pal_i        <= '0;
            x            <= '0;
            y            <= '0;
            addr         <= '0;
            swap_req     <= 1'b0;
            check_valid  <= 1'b0;
            check_expect <= '0;
            read_ok      <= 1'b1;
        end else begin
            swap_req    <= 1'b0;
            check_valid <= (state == S_CHECK);
            check_expect <= fb_wdata;
            if (check_valid && fb_rdata != check_expect) read_ok <= 1'b0;
            unique case (state)
                S_PAL: begin
                    pal_i <= pal_i + 8'd1;
                    if (pal_i == 8'd255) state <= S_FB;
                end
                S_FB, S_CHECK: begin
                    addr <= addr + 17'd1;
                    if (x == 9'd319) begin
                        x <= '0;
                        y <= y + 8'd1;
                        if (y == 8'd239) begin
                            y     <= '0;
                            addr  <= '0;
                            state <= (state == S_FB) ? S_CHECK : S_SWAP;
                        end
                    end else begin
                        x <= x + 9'd1;
                    end
                end
                S_SWAP: begin
                    swap_req <= 1'b1;
                    state    <= S_DONE;
                end
                default: ;
            endcase
        end
    end

    assign pal_we = (state == S_PAL);
    assign fb_we  = (state == S_FB);
    assign fb_re  = (state == S_CHECK);
    always_ff @(posedge clk_core) if (fb_re) fb_lane_q <= addr[1:0];
    assign fb_rdata = fb_word[fb_lane_q*8 +: 8];

    display u_display (
        .clk_core    (clk_core),
        .rst_core    (rst_core),
        .clk_pix     (clk_pix),
        .rst_pix     (rst_pix),
        .fb_we       (fb_we),
        .fb_re       (fb_re),
        .fb_addr     (addr),
        .fb_be       (4'b0001 << addr[1:0]),
        .fb_wdata    ({4{fb_wdata}}),
        .fb_rdata    (fb_word),
        .pal_we      (pal_we),
        .pal_addr    (pal_i),
        .pal_wdata   (pal_wdata),
        .swap_req    (swap_req),
        .swap_pending(swap_pending),
        .vblank      (vblank),
        .frame_count (frame_count),
        .fb_mode     (1'b0),
        .vga_r       (vga_r),
        .vga_g       (vga_g),
        .vga_b       (vga_b),
        .vga_hs      (vga_hs),
        .vga_vs      (vga_vs)
    );

    assign led          = (state == S_DONE) && !swap_pending && read_ok && locked;
    assign uart_rxd_out = 1'b1;

    logic unused_ok;
    assign unused_ok = ^{vblank, frame_count, x_div20[8:4]};
endmodule
