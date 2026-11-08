// core_pipe branch target buffer: 64 entries in distributed RAM, indexed by
// pc[7:2], each a tag (the remaining imem bits pc[14:8]), a target
// (pc[14:2]) and a 2-bit saturating counter. Only conditional branches and
// JAL are written. The valid bits are flip-flops cleared at reset (the
// LUTRAM cannot reset); the RAM itself needs none.
//
// Lookup: asynchronous, of the fetch PC. taken = a valid entry whose tag
// matches and whose counter is 2 or 3. The tag ignores pc[31:IW] (IW = 15,
// the imem bits; 28, the I-cache fetch space, with HAS_ICACHE): code is
// read-only for the core, so an entry always describes the same
// instruction, and a fetch outside it halts in EX whatever it predicted.
// hit and ctr go down the pipeline with the instruction for its update.
//
// Update: one write per resolved branch or JAL. A taken one allocates the
// entry (counter 2, weakly taken) or strengthens it; a not-taken one weakens
// a hit and leaves a miss alone. The counter is the one read at fetch, so
// two copies of a branch in flight at once may both start from the older
// value; that only costs prediction quality.
module btb
    import kc_isa_pkg::*;
#(
    parameter bit HAS_ICACHE = 1'b0
) (
    input  logic          clk,
    input  logic          rst,

    input  logic [31:0]   f_pc,
    output logic          f_hit,
    output logic          f_taken,
    output logic [1:0]    f_ctr,
    output logic [31:0]   f_target,

    input  logic          u_we,
    input  logic [31:0]   u_pc,
    input  logic [31:0]   u_target,
    input  logic          u_hit,     // the lookup at fetch hit
    input  logic [1:0]    u_ctr,     // its counter
    input  logic          u_taken
);
    // fetch byte-address bits: imem (15), or the I-cache fetch space (28)
    localparam int IW = HAS_ICACHE ? ICACHE_FETCH_BITS : $clog2(IMEM_BYTES);
    localparam int TW = IW - 8;               // tag bits

    typedef struct packed {
        logic [TW-1:0]   tag;
        logic [IW-3:0]   target;
        logic [1:0]      ctr;
    } entry_t;

    (* ram_style = "distributed" *) entry_t mem [64];
    logic [63:0] valid;
    entry_t      rd, wd;
    logic        wr;

    assign rd       = mem[f_pc[7:2]];
    assign f_hit    = valid[f_pc[7:2]] && (rd.tag == f_pc[IW-1:8]);
    assign f_taken  = f_hit && rd.ctr[1];
    assign f_ctr    = rd.ctr;
    assign f_target = {{(32-IW){1'b0}}, rd.target, 2'b00};

    always_comb begin
        wd.tag    = u_pc[IW-1:8];
        wd.target = u_target[IW-1:2];
        if (!u_hit)               wd.ctr = 2'd2;
        else if (u_taken)         wd.ctr = (u_ctr == 2'd3) ? 2'd3 : u_ctr + 2'd1;
        else                      wd.ctr = (u_ctr == 2'd0) ? 2'd0 : u_ctr - 2'd1;
    end
    assign wr = u_we && (u_taken || u_hit);

    always_ff @(posedge clk)
        if (wr) mem[u_pc[7:2]] <= wd;

    always_ff @(posedge clk) begin
        if (rst)                valid <= '0;
        else if (wr && u_taken) valid[u_pc[7:2]] <= 1'b1;
    end

    /* verilator lint_off UNUSEDSIGNAL */
    logic unused;
    /* verilator lint_on UNUSEDSIGNAL */
    assign unused = (^u_pc[31:IW]) ^ (^u_pc[1:0]) ^ (^u_target[31:IW]) ^ (^u_target[1:0]) ^
                    (^f_pc[31:IW]) ^ (^f_pc[1:0]);
endmodule
