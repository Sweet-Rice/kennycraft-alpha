// FB_COUNT (2 or 3) 320x240 byte framebuffers (76,800 B each) in true
// dual-clock block RAM (Tai page, Memory & Display; 19 BRAM36 per buffer, 38
// for the pair, 57 for three, D24).
//
// Port A (clk_a, 50 MHz core side) reads and writes the buffer picked by
// sel_a; the display passes the CPU's draw buffer there. It is a word port:
// addr_a[16:2] picks the word, we_a are its byte write enables and rdata_a
// is the whole word, so one access writes up to four pixels. Port B (clk_b,
// 25 MHz) is the read-only scan-out port on the buffer picked by sel_b, the
// front buffer. Both ports have one cycle of read latency. A select of
// FB_COUNT or more picks no buffer (writes dropped, reads return 0).
//
// Each buffer is 19 banks of 4096 bytes, each a 1024 x 32 array with byte
// write enables (one BRAM36 each, bank = addr[16:12], word = addr[11:2],
// byte lane = addr[1:0]; bank 18 holds the last 3,072 bytes). In memory
// order a bank is still 4096 bytes, byte i at word i / 4, lane i % 4. Left to itself Vivado splits a single
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
    input  logic [3:0]  we_a,
    input  logic [1:0]  sel_a,
    input  logic [16:0] addr_a,
    input  logic [31:0] wdata_a,
    output logic [31:0] rdata_a,
    // Port B, scan-out side
    input  logic        clk_b,
    input  logic [1:0]  sel_b,
    input  logic [16:0] addr_b,
    output logic [7:0]  rdata_b
);
    localparam int FB_BYTES   = 320 * 240;               // 76,800
    localparam int BANK_BYTES = 4096;
    localparam int BANK_WORDS = BANK_BYTES / 4;
    localparam int BANKS      = (FB_BYTES + BANK_BYTES - 1) / BANK_BYTES;   // 19

    logic [4:0]  bank_a, bank_b;
    logic [4:0]  bank_a_q, bank_b_q;
    logic [1:0]  sel_a_q, sel_b_q, lane_b_q;
    logic        in_range_a;
    logic [31:0] rd_a [FB_COUNT][BANKS];
    logic [31:0] rd_b [FB_COUNT][BANKS];

    assign bank_a     = addr_a[16:12];
    assign bank_b     = addr_b[16:12];
    assign in_range_a = (addr_a < 17'(FB_BYTES));

    for (genvar b = 0; b < FB_COUNT; b++) begin : g_buf
        for (genvar k = 0; k < BANKS; k++) begin : g_bank
            (* ram_style = "block" *) logic [31:0] mem [BANK_WORDS];

            logic hit_a, hit_b;
            assign hit_a = en_a && (sel_a == 2'(b)) && (bank_a == 5'(k));
            assign hit_b = (sel_b == 2'(b)) && (bank_b == 5'(k));

            always_ff @(posedge clk_a) begin
                if (hit_a) begin
                    for (int i = 0; i < 4; i++)
                        if (we_a[i] && in_range_a) mem[addr_a[11:2]][i*8 +: 8] <= wdata_a[i*8 +: 8];
                    rd_a[b][k] <= mem[addr_a[11:2]];
                end
            end

            always_ff @(posedge clk_b) begin
                if (hit_b) rd_b[b][k] <= mem[addr_b[11:2]];
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
        lane_b_q <= addr_b[1:0];
    end

    // Bank indices >= 19 only occur for out-of-range addresses; any data will do.
    logic [31:0] word_b;
    always_comb begin
        rdata_a = '0;
        word_b  = '0;
        for (int b = 0; b < FB_COUNT; b++) begin
            if (sel_a_q == 2'(b) && bank_a_q < 5'(BANKS)) rdata_a = rd_a[b][bank_a_q];
            if (sel_b_q == 2'(b) && bank_b_q < 5'(BANKS)) word_b  = rd_b[b][bank_b_q];
        end
    end
    assign rdata_b = word_b[lane_b_q*8 +: 8];
endmodule
