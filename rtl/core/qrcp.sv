// QRCP unit, one per lane (D22, Tai_2 sections 1 and 2): y = the Q16.16
// reciprocal of x, bit-exact with qrcp() in game/src/fixed.c (main 8760b55),
// which is the normative definition. Each step below is that C, with the
// same truncations; tb/qrcp/qrcp_model.h models these registers and is
// checked against fixed.c over all 2^32 inputs.
//
// The core steps the unit with a shared phase counter (one instruction in
// flight, x = the lane's rs1 register, stable for the whole instruction):
//
//   load        norm_shift: n = leading zeros of x | 2 (0..30); m = (x << n)
//               [31:15] (17 bits); sh = 30 - n; lt4 = x < 4 (signed)
//               rcp_seed: r = SEED[m[15:8]] (16 bits) is a ROM read of the
//               registered m, combinational from here on (no step of its own)
//   en, ph 0    p = m * r                       (e = p[32:16] = mulhu(m << 15, r << 1))
//   en, ph 1    p = (2^17 - e) * r              (p[33:16] = mulhu(r << 16, 2^17 - e))
//   en, ph 2    y = shift back and saturate at Q16_BIG; Q16_BIG when lt4
//
// so y is valid from the cycle after ph 2. Both products are at most 18 x 16
// bits unsigned and share one multiplier (one DSP48E1).
//
// SEED is rcp_seed() evaluated at elaboration: D = 2 (256 + i) + 1 =
// {1, m[15:8], 1}, the linear guess, two Newton steps and the +1 fix-up, in
// 32-bit signed arithmetic like the C. The constants are KC_RCP_K0/K1/N1/N2
// of game/tools/gen_assets.py (the generated kc_tables.h).
//
// The shift back is fixed.c's (r << max(-s, 0)) >> max(s, 0) with s = 15 - n
// = sh - 15. The product's top 18 bits leave bit 31 clear whenever the right
// shift is not 0, so both shifts are one right shift of {r, 15'b0} by sh.
module qrcp (
    input  logic        clk,
    input  logic        load,     // EX: latch the normalized operand
    input  logic        en,       // QRCP wait state: step ph
    input  logic [2:0]  ph,
    input  logic [31:0] x,        // rs1
    output logic [31:0] y
);

    localparam int K0 = 92000;    // KC_RCP_K0
    localparam int K1 = 60;       // KC_RCP_K1
    localparam int N1 = 8;        // KC_RCP_N1
    localparam int N2 = 3;        // KC_RCP_N2
    localparam logic [31:0] Q16_BIG = 32'h4000_0000;

    function automatic logic [15:0] seed_of(input int i);
        int d, yy, e;
        d  = 2 * (256 + i) + 1;
        yy = K0 - K1 * d;
        e  = (1 << 25) - d * yy;  yy += (yy * (e >>> N1)) >>> (25 - N1);
        e  = (1 << 25) - d * yy;  yy += (yy * (e >>> N2)) >>> (25 - N2);
        return 16'(yy + ((unsigned'(d * (2 * yy + 1)) < 32'd67108864) ? 1 : 0));
    endfunction

    logic [15:0] seed_rom [256];
    for (genvar i = 0; i < 256; i++) begin : g_seed
        localparam logic [15:0] V = seed_of(i);
        assign seed_rom[i] = V;
    end

    // norm_shift
    logic [31:0] xo, xn;
    logic [4:0]  n;

    assign xo = x | 32'd2;
    always_comb begin
        n = 5'd30;
        for (int i = 1; i < 32; i++)
            if (xo[i]) n = 5'(31 - i);
    end
    assign xn = x << n;

    logic [16:0] m;
    logic [4:0]  sh;
    logic        lt4;
    logic [15:0] r;
    logic [33:0] p;
    logic [17:0] f, a;

    assign f = 18'h2_0000 - {1'b0, p[32:16]};
    assign r = seed_rom[m[15:8]];
    assign a = (ph == 3'd0) ? {1'b0, m} : f;

    // Shift back and saturate
    logic [46:0] wide;
    logic [31:0] v;

    assign wide = {14'd0, p[33:16], 15'd0} >> sh;
    assign v    = wide[31:0];

    always_ff @(posedge clk) begin
        if (load) begin
            m     <= xn[31:15];
            sh    <= 5'd30 - n;
            lt4   <= $signed(x) < 32'sd4;
        end
        if (en) begin
            unique case (ph)
                3'd0, 3'd1: p <= 34'(a) * 34'(r);
                3'd2:       y <= (lt4 || $signed(v) > $signed(Q16_BIG)) ? Q16_BIG : v;
                default: ;
            endcase
        end
    end

    // xn[14:0] are below the 17 bits fixed.c keeps, p[15:0] below both
    // results, and wide[46:32] is what the C's 32-bit left shift drops.
    /* verilator lint_off UNUSEDSIGNAL */
    logic unused;
    assign unused = ^{xn[14:0], p[15:0], wide[46:32]};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
