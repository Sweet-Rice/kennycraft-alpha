// FB_COUNT (2 or 3) 320x240 byte framebuffers (76,800 B each) in true
// dual-clock block RAM (Tai page, Memory & Display; 19 BRAM36 per buffer, 38
// for the pair, 57 for three, D24).
//
// Port A (clk_a, 50 MHz core side) is a word port with byte enables: it
// reads and writes word addr_a (bytes 4 addr_a .. 4 addr_a + 3, pixel 4 addr_a
// + k in byte k) of the buffer picked by sel_a; the display passes the CPU's
// draw buffer there. we_a[k] writes byte k. Port B (clk_b, 25 MHz) is the
// read-only scan-out port on the buffer picked by sel_b, the front buffer: it
// takes a byte index and returns that byte. Port B has one cycle of read
// latency, port A RD_LAT (1 or 3) cycles. A select of FB_COUNT or more picks
// no buffer (writes dropped, reads return 0).
//
// RD_LAT = 3 (the 100 MHz core clock) cuts port A's read path, BRAM
// clock-to-out plus the 57-way bank and buffer mux spread over the BRAM
// columns, into the BRAM output register (DOA_REG, absorbed from rd_a2) and a
// register after the mux (rdata_q): the read issued in cycle t is on rdata_a
// in cycle t + 3. The buffer and bank of each read ride along with it, so
// back-to-back reads to different banks or buffers stay in order. Writes are
// unchanged.
//
// Each buffer is 19 banks of 1024 x 32 with four byte write enables (one
// BRAM36 each, bank = word address bits 14:10; bank 18 holds the last 768
// words). Left to itself Vivado splits a single 19,200-deep array into more
// BRAM36 per buffer. Only the addressed bank of the addressed buffer is
// enabled; the buffer and bank (and on port B the byte within the word) are
// registered with the address so the output mux follows the word that was
// actually read. Writes at addr_a >= 19,200 are dropped. Reads there return
// unspecified data.
module framebuffer #(
    parameter int FB_COUNT = 2,
    parameter int RD_LAT   = 1    // port A read latency: 1, or 3 (registered bank mux)
) (
    // Port A, core side (word address, byte enables)
    input  logic        clk_a,
    input  logic        en_a,
    input  logic [3:0]  we_a,
    input  logic [1:0]  sel_a,
    input  logic [14:0] addr_a,
    input  logic [31:0] wdata_a,
    output logic [31:0] rdata_a,
    // Port B, scan-out side (byte index)
    input  logic        clk_b,
    input  logic [1:0]  sel_b,
    input  logic [16:0] addr_b,
    output logic [7:0]  rdata_b
);
    localparam int FB_WORDS   = 320 * 240 / 4;           // 19,200
    localparam int BANK_WORDS = 1024;
    localparam int BANKS      = (FB_WORDS + BANK_WORDS - 1) / BANK_WORDS;   // 19

    logic [4:0]  bank_a, bank_b;
    logic [4:0]  bank_a_q, bank_b_q;
    logic [1:0]  sel_a_q, sel_b_q;
    logic [1:0]  byte_b_q;
    logic        in_range_a;
    logic [31:0] rd_a [FB_COUNT][BANKS];
    logic [31:0] rd_b [FB_COUNT][BANKS];
    logic [31:0] word_b;

    assign bank_a     = addr_a[14:10];
    assign bank_b     = addr_b[16:12];
    assign in_range_a = (addr_a < 15'(FB_WORDS));

    for (genvar b = 0; b < FB_COUNT; b++) begin : g_buf
        for (genvar k = 0; k < BANKS; k++) begin : g_bank
            (* ram_style = "block" *) logic [31:0] mem [BANK_WORDS];

            logic hit_a, hit_b;
            assign hit_a = en_a && (sel_a == 2'(b)) && (bank_a == 5'(k));
            assign hit_b = (sel_b == 2'(b)) && (bank_b == 5'(k));

            always_ff @(posedge clk_a) begin
                if (hit_a) begin
                    for (int i = 0; i < 4; i++)
                        if (we_a[i] && in_range_a) mem[addr_a[9:0]][i*8 +: 8] <= wdata_a[i*8 +: 8];
                    rd_a[b][k] <= mem[addr_a[9:0]];
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
        byte_b_q <= addr_b[1:0];
    end

    // Bank indices >= 19 only occur for out-of-range addresses; any data will do.
    always_comb begin
        word_b = 32'h0;
        for (int b = 0; b < FB_COUNT; b++)
            if (sel_b_q == 2'(b) && bank_b_q < 5'(BANKS)) word_b = rd_b[b][bank_b_q];
    end

    if (RD_LAT == 1) begin : g_rd1
        always_comb begin
            rdata_a = 32'h0;
            for (int b = 0; b < FB_COUNT; b++)
                if (sel_a_q == 2'(b) && bank_a_q < 5'(BANKS)) rdata_a = rd_a[b][bank_a_q];
        end
    end else if (RD_LAT == 3) begin : g_rd3
        logic [31:0] rd_a2 [FB_COUNT][BANKS];   // BRAM output registers
        logic [4:0]  bank_a_q2;
        logic [1:0]  sel_a_q2;
        logic [31:0] mux_a, rdata_q;

        // sel_a_q / bank_a_q belong to the read latched in rd_a; the q2
        // copies follow it into rd_a2.
        always_ff @(posedge clk_a) begin
            rd_a2     <= rd_a;
            sel_a_q2  <= sel_a_q;
            bank_a_q2 <= bank_a_q;
            rdata_q   <= mux_a;
        end

        always_comb begin
            mux_a = 32'h0;
            for (int b = 0; b < FB_COUNT; b++)
                if (sel_a_q2 == 2'(b) && bank_a_q2 < 5'(BANKS)) mux_a = rd_a2[b][bank_a_q2];
        end

        assign rdata_a = rdata_q;
    end else begin : g_bad_rd_lat
        $error("framebuffer: RD_LAT must be 1 or 3");
    end

    assign rdata_b = word_b[byte_b_q*8 +: 8];
endmodule
