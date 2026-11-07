module fixture_top (
    input logic clk,
    input logic rst_n,
    input logic uart_rx,
    output wire uart_tx,
    output wire [3:0] leds
);
    logic fb_we, pal_we, swap_req, swap_pending;
    logic [16:0] fb_addr;
    logic [7:0] fb_wdata, pal_addr;
    logic [11:0] pal_wdata;
    wire fb_mode = 1'b0;
    logic [7:0] palette_index;
    logic [8:0] x;
    logic [7:0] y, frame;
    logic [9:0] wait_cycles;
    typedef enum logic [1:0] {PALETTE, PIXELS, SWAP, WAIT_SWAP} state_t;
    state_t state;
    assign uart_tx = uart_rx;
    assign leds = frame[3:0];

    always_comb begin
        fb_we = rst_n && state == PIXELS;
        fb_addr = {9'b0, y} * 17'd320 + {8'b0, x};
        fb_wdata = x[7:0] + y + frame;
        pal_we = rst_n && state == PALETTE;
        pal_addr = palette_index;
        pal_wdata = {palette_index[7:4], palette_index[3:0], 4'h8};
        swap_req = rst_n && state == SWAP;
        swap_pending = rst_n && state == WAIT_SWAP;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= PALETTE;
            palette_index <= 0;
            x <= 0;
            y <= 0;
            frame <= 0;
            wait_cycles <= 0;
        end else begin
            case (state)
                PALETTE: begin
                    if (palette_index == 255) state <= PIXELS;
                    else palette_index <= palette_index + 1'b1;
                end
                PIXELS: begin
                    if (x == 319) begin
                        x <= 0;
                        if (y == 239) begin
                            y <= 0;
                            state <= SWAP;
                        end else y <= y + 1'b1;
                    end else x <= x + 1'b1;
                end
                SWAP: begin
                    wait_cycles <= 0;
                    state <= WAIT_SWAP;
                end
                WAIT_SWAP: begin
                    if (wait_cycles == 999) begin
                        frame <= frame + 1'b1;
                        state <= PIXELS;
                    end else wait_cycles <= wait_cycles + 1'b1;
                end
                default: state <= PALETTE;
            endcase
        end
    end
endmodule
