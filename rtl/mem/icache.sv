// Instruction cache for fetches from DDR3 (HAS_DDR_MEM = 1): 16 KB,
// direct-mapped, 16-byte lines (one 128-bit beat of the DDR3 line port),
// read-only. Line index addr[13:4], tag addr[27:14]. Every line is invalid
// at reset; there is no invalidate (code is in DDR3 before its first fetch).
//
// Fetch side, like the imem BRAM: addr (and req, 1 for a fetch the cache
// serves) in cycle t; rdata and ack in cycle t+1. ack = 1: rdata is the word
// at addr. ack = 0: no word, the core presents the address again.
//
// Hit path. The data (1024 x 128) and tag (1024 x 14) arrays are block RAMs
// read with addr[13:4] in cycle t (memory_arr's pattern, read-first); the
// valid bits are flip-flops (reset), read into v_q at the same edge. In t+1
// ack = req_q && v_q && tag == a_q[27:14] (BRAM clock-to-out, one 14-bit
// compare) and rdata is the 32-bit word a_q[3:2] of the line (a 4:1 mux).
// No extra register: a hit costs nothing over the imem BRAM.
//
// Miss. The first miss seen while idle latches its line address and starts
// a refill: rf_req (rf_addr stable) until rf_gnt, then the one rf_valid beat
// writes the line, its tag and its valid bit. Misses seen while a refill is
// in flight start nothing (ack = 0); the refill always finishes, whatever
// the core presents meanwhile. A read in the cycle the line is written sees
// the old line and its old valid bit, a consistent miss; that miss (fill_q,
// the cycle after the write) starts no second refill.
module icache (
    input  logic          clk,
    input  logic          rst,

    input  logic          req,
    input  logic [31:0]   addr,
    output logic [31:0]   rdata,
    output logic          ack,

    output logic          rf_req,
    output logic [27:4]   rf_addr,
    input  logic          rf_gnt,
    input  logic          rf_valid,
    input  logic [127:0]  rf_data
);
    localparam int LINES = 1024;
    localparam int TW    = 14;   // addr[27:14]

    typedef enum logic [1:0] {S_IDLE, S_REQ, S_WAIT} state_t;
    state_t state;

    (* ram_style = "block" *) logic [127:0]  dmem [LINES];
    (* ram_style = "block" *) logic [TW-1:0] tmem [LINES];
    logic [LINES-1:0] valid;

    logic [9:0]    ridx, widx;
    logic [127:0]  line_q;
    logic [TW-1:0] tag_q;
    logic          v_q, req_q, fill_q;
    logic [27:2]   a_q;
    logic          wr;

    assign ridx = addr[13:4];
    assign widx = rf_addr[13:4];
    assign wr   = (state == S_WAIT) && rf_valid;

    always_ff @(posedge clk) begin
        line_q <= dmem[ridx];
        if (wr) dmem[widx] <= rf_data;
    end

    always_ff @(posedge clk) begin
        tag_q <= tmem[ridx];
        if (wr) tmem[widx] <= rf_addr[27:14];
    end

    always_ff @(posedge clk) begin
        if (rst)     valid <= '0;
        else if (wr) valid[widx] <= 1'b1;
    end

    always_ff @(posedge clk) begin
        v_q <= valid[ridx];
        a_q <= addr[27:2];
        if (rst) begin
            req_q  <= 1'b0;
            fill_q <= 1'b0;
        end else begin
            req_q  <= req;
            fill_q <= wr;
        end
    end

    assign ack = req_q && v_q && (tag_q == a_q[27:14]);

    always_comb begin
        unique case (a_q[3:2])
            2'd0:    rdata = line_q[31:0];
            2'd1:    rdata = line_q[63:32];
            2'd2:    rdata = line_q[95:64];
            default: rdata = line_q[127:96];
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
        end else begin
            unique case (state)
                S_IDLE: if (req_q && !ack && !fill_q) begin
                    state   <= S_REQ;
                    rf_addr <= a_q[27:4];
                end
                S_REQ:  if (rf_gnt)   state <= S_WAIT;
                S_WAIT: if (rf_valid) state <= S_IDLE;
                default:              state <= S_IDLE;
            endcase
        end
    end

    assign rf_req = (state == S_REQ);

    /* verilator lint_off UNUSEDSIGNAL */
    logic unused;
    /* verilator lint_on UNUSEDSIGNAL */
    assign unused = (^addr[31:28]) ^ (^addr[1:0]);
endmodule
