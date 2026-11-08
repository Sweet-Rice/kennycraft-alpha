// Zmmul multiplier for the pipelined core: MUL, MULH, MULHSU, MULHU (funct3
// 000..011) in two cycles. The same 33 x 33 signed multiply as rtl/core/mul.sv
// (each operand sign- or zero-extended by one bit per its signedness), as four
// partial products of 17-bit low and 16-bit high halves:
//
//   a_x * b_x = (ah 2^17 + al)(bh 2^17 + bl)
//             = ah bh 2^34 + (ah bl + al bh) 2^17 + al bl
//
// (al, bl unsigned, ah, bh signed). core_pipe holds a and b (MEM's registers)
// and op for both of MUL's MEM cycles:
//   cycle 0  the four products, each one DSP48E1 (17 x 17 at most), into
//            their output registers (pp_*, every cycle, no enable)
//   cycle 1  result: the products summed (a 3:2 carry-save step, then one
//            47-bit adder above bit 17) and the selected half
module mul_pipe (
    input  logic        clk,
    input  logic [1:0]  op,       // funct3[1:0]
    input  logic [31:0] a,        // rs1
    input  logic [31:0] b,        // rs2
    output logic [31:0] result
);

    logic              a_signed, b_signed;
    logic        [16:0] al, bl;
    logic signed [15:0] ah, bh;

    assign a_signed = (op != 2'b11);   // MUL, MULH, MULHSU
    assign b_signed = (op[1] == 1'b0); // MUL, MULH
    assign al = a[16:0];
    assign bl = b[16:0];
    assign ah = {a_signed & a[31], a[31:17]};
    assign bh = {b_signed & b[31], b[31:17]};

    // Cycle 0
    logic        [33:0] pp_ll;
    logic signed [33:0] pp_lh, pp_hl;
    /* verilator lint_off UNUSEDSIGNAL */
    logic signed [31:0] pp_hh;   // bits 31:30 fall above bit 63
    /* verilator lint_on UNUSEDSIGNAL */

    always_ff @(posedge clk) begin
        pp_ll <= al * bl;
        pp_lh <= $signed({1'b0, al}) * bh;
        pp_hl <= ah * $signed({1'b0, bl});
        pp_hh <= ah * bh;
    end

    // Cycle 1: u = product >> 17, mod 2^47 (bits 63:17)
    logic [46:0] x, y, z, w, s, c, u;

    assign x = {30'b0, pp_ll[33:17]};
    assign y = {{13{pp_lh[33]}}, pp_lh};
    assign z = {{13{pp_hl[33]}}, pp_hl};
    assign w = {pp_hh[29:0], 17'b0};
    assign s = x ^ y ^ z;
    assign c = {(x[45:0] & y[45:0]) | (x[45:0] & z[45:0]) | (y[45:0] & z[45:0]), 1'b0};
    assign u = s + c + w;

    assign result = (op != 2'b00) ? u[46:15] : {u[14:0], pp_ll[16:0]};

endmodule
