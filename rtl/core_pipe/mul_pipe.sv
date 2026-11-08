// Zmmul multiplier for the pipelined core: MUL, MULH, MULHSU, MULHU (funct3
// 000..011) in one cycle. The same 33 x 33 signed multiply as rtl/core/mul.sv
// (each operand sign- or zero-extended by one bit per its signedness), but
// combinational: core_pipe feeds it MEM's registered operands and writes the
// selected half into the WB register in MEM's single cycle (DSP48E1 cascade
// without the output register, then the hi/lo select).
module mul_pipe (
    input  logic [1:0]  op,       // funct3[1:0]
    input  logic [31:0] a,        // rs1
    input  logic [31:0] b,        // rs2
    output logic [31:0] result
);

    logic               a_signed, b_signed;
    logic signed [32:0] a_x, b_x;
    logic signed [65:0] p;

    assign a_signed = (op != 2'b11);   // MUL, MULH, MULHSU
    assign b_signed = (op[1] == 1'b0); // MUL, MULH
    assign a_x = {a_signed & a[31], a};
    assign b_x = {b_signed & b[31], b};
    assign p   = a_x * b_x;

    // p[65:64] only repeat the sign of the 64-bit product.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [65:0] p_u;
    /* verilator lint_on UNUSEDSIGNAL */
    assign p_u    = p;
    assign result = (op != 2'b00) ? p_u[63:32] : p_u[31:0];

endmodule
