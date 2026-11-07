// Divergence stack for DIF / DELSE / DENDIF (Tai_2 section 2, Divergence
// stack; Tai page, GPU Core, Divergence). DEPTH entries of {saved, else},
// LANES bits each, plus a pointer sp = 0..DEPTH. Line for line:
//
//   DIF rs1, L:   if (sp == 8) halt(DIVSTACK);
//                 t = M & lanes_where(rs1 != 0);
//                 push({ .saved = M, .else = M & ~t });
//                 M = t;
//                 if (t == 0) PC = L; else PC += 4;
//
//   DELSE L:      if (sp == 0) halt(DIVSTACK);
//                 M = top.else;
//                 if (M == 0) PC = L; else PC += 4;
//
//   DENDIF:       if (sp == 0) halt(DIVSTACK);
//                 M = top.saved;  pop();  PC += 4;
//
// Combinational for the instruction in EX (op = its funct3): err is the
// DIVSTACK halt, mask_d the new M and jump whether PC = L. The stack changes
// on the clock edge only when step is high, which the core raises in EX for a
// custom-2 instruction that does not halt (for any reason). Reset empties it.
module divstack
    import kc_isa_pkg::*;
#(
    parameter int LANES = 8,
    parameter int DEPTH = DIVSTACK_DEPTH
) (
    input  logic             clk,
    input  logic             rst,
    input  logic [2:0]       op,       // F3_DIF, F3_DELSE or F3_DENDIF
    input  logic [LANES-1:0] mask,     // M
    input  logic [LANES-1:0] cond,     // lanes where rs1 != 0 (DIF)
    input  logic             step,     // commit this instruction
    output logic             err,      // halt(DIVSTACK)
    output logic [LANES-1:0] mask_d,   // M after the instruction
    output logic             jump      // PC = L
);

    localparam int SPW = $clog2(DEPTH + 1);   // sp = 0..DEPTH
    localparam int IW  = $clog2(DEPTH);       // entry index (DEPTH a power of 2)

    logic [LANES-1:0] saved [DEPTH];
    logic [LANES-1:0] els   [DEPTH];
    logic [SPW-1:0]   sp;
    logic [LANES-1:0] t, top_saved, top_else;
    logic             full, empty;

    assign full      = (sp == SPW'(DEPTH));
    assign empty     = (sp == '0);
    assign t         = mask & cond;
    assign top_saved = empty ? '0 : saved[IW'(sp - 1'b1)];
    assign top_else  = empty ? '0 : els[IW'(sp - 1'b1)];

    always_comb begin
        unique case (op)
            F3_DIF: begin
                err    = full;
                mask_d = t;
                jump   = (t == '0);
            end
            F3_DELSE: begin
                err    = empty;
                mask_d = top_else;
                jump   = (top_else == '0);
            end
            default: begin                      // F3_DENDIF
                err    = empty;
                mask_d = top_saved;
                jump   = 1'b0;
            end
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            sp <= '0;
        end else if (step && !err) begin
            if (op == F3_DIF) begin
                saved[IW'(sp)] <= mask;
                els[IW'(sp)]   <= mask & ~t;
                sp             <= sp + 1'b1;
            end else if (op == F3_DENDIF) begin
                sp <= sp - 1'b1;
            end
        end
    end

endmodule
