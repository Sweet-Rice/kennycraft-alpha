// FB_COUNT (2 or 3) 320x240 byte framebuffers (76,800 B each) in true
// dual-clock block RAM (Tai page, Memory & Display; 19 BRAM36 per buffer, 38
// for the pair, 57 for three, D24).
//
// Port A (clk_a, 50 MHz core side) reads and writes the buffer picked by
// sel_a; the display passes the CPU's draw buffer there. Port B (clk_b,
// 25 MHz) is the read-only scan-out port on the buffer picked by sel_b, the
// front buffer. Both ports have one cycle of read latency. A select of
// FB_COUNT or more picks no buffer (writes dropped, reads return 0).
//
// Each buffer is 19 banks of 4096 x 8 (one BRAM36 each, bank = addr[16:12];
// bank 18 holds the last 3,072 bytes). Left to itself Vivado splits a single
// 76,800-deep array into 24 BRAM36 per buffer. Only the addressed bank of the
// addressed buffer is enabled; the buffer and bank are registered with the
// address so the output mux follows the bank that was actually read.
// Writes at addr_a >= 76,800 are dropped. Reads there return unspecified data.
module framebuffer #(
    parameter int FB_COUNT = 2
) (
    // Port A, core side
    input  logic        clk_a,
    input  logic        en_a,
    input  logic        we_a,
    input  logic [1:0]  sel_a,
    input  logic [16:0] addr_a,
    input  logic [7:0]  wdata_a,
    output logic [7:0]  rdata_a,
    // Port B, scan-out side
    input  logic        clk_b,
    input  logic [1:0]  sel_b,
    input  logic [16:0] addr_b,
    output logic [7:0]  rdata_b
);
    localparam int FB_BYTES   = 320 * 240;               // 76,800
    localparam int BANK_BYTES = 4096;
    localparam int BANKS      = (FB_BYTES + BANK_BYTES - 1) / BANK_BYTES;   // 19

    logic [4:0] bank_a, bank_b;
    logic [4:0] bank_a_q, bank_b_q;
    logic [1:0] sel_a_q, sel_b_q;
    logic       in_range_a;
    logic [7:0] rd_a [FB_COUNT][BANKS];
    logic [7:0] rd_b [FB_COUNT][BANKS];

    assign bank_a     = addr_a[16:12];
    assign bank_b     = addr_b[16:12];
    assign in_range_a = (addr_a < 17'(FB_BYTES));

    for (genvar b = 0; b < FB_COUNT; b++) begin : g_buf
        for (genvar k = 0; k < BANKS; k++) begin : g_bank
            (* ram_style = "block" *) logic [7:0] mem [BANK_BYTES];

            logic hit_a, hit_b;
            assign hit_a = en_a && (sel_a == 2'(b)) && (bank_a == 5'(k));
            assign hit_b = (sel_b == 2'(b)) && (bank_b == 5'(k));

            always_ff @(posedge clk_a) begin
                if (hit_a) begin
                    if (we_a && in_range_a) mem[addr_a[11:0]] <= wdata_a;
                    rd_a[b][k] <= mem[addr_a[11:0]];
                end
            end

            always_ff @(posedge clk_b) begin
                if (hit_b) rd_b[b][k] <= mem[addr_b[11:0]];
            end
        end
    end

    always_ff @(posedge clk_a) begin
        if (en_a) begin
            sel_a_q  <= sel_a;
            bank_a_q <= bank_a;
        end
    end

    always_ff @(posedge clk_b) begin
        sel_b_q  <= sel_b;
        bank_b_q <= bank_b;
    end

    // Bank indices >= 19 only occur for out-of-range addresses; any data will do.
    always_comb begin
        rdata_a = 8'h00;
        rdata_b = 8'h00;
        for (int b = 0; b < FB_COUNT; b++) begin
            if (sel_a_q == 2'(b) && bank_a_q < 5'(BANKS)) rdata_a = rd_a[b][bank_a_q];
            if (sel_b_q == 2'(b) && bank_b_q < 5'(BANKS)) rdata_b = rd_b[b][bank_b_q];
        end
    end
endmodule
