/* qrcp_model.h: C model of rtl/core/qrcp.sv, stage by stage, with the
   hardware's register widths. tb/qrcp/qrcp_check.c compares it with the
   normative qrcp() of game/src/fixed.c (D22, Tai_2 section 1).

   EX   n = leading zeros of (x | 2) (fixed.c norm_shift), m = (x << n)[31:15]
        (17 bits), s = 15 - n, small = x < 4 (signed)
   Q0   r = SEED[m[15:8]] (16 bits; fixed.c rcp_seed, D = {1, m[15:8], 1})
   Q1   p = m * r                                 (17 x 16 -> 33 bits)
   Q2   f = 2^17 - p[32:16] (18 bits), p = f * r  (18 x 16 -> 34 bits)
   Q3   y = saturate(shift(p[33:16], s)); small -> Q16_BIG
   Q4   the core latches y into rd */
#ifndef QRCP_MODEL_H
#define QRCP_MODEL_H
#include <stdint.h>

/* fixed.c rcp_seed for index i = m[15:8]: the ROM in rtl/core/qrcp.sv is this
   function evaluated at elaboration for i = 0..255 (constants from the
   generated kc_tables.h, as in fixed.c). */
static inline uint32_t qrcp_model_seed(uint32_t i) {
    int32_t D = (int32_t)(2 * (256 + i) + 1);
    int32_t Y = KC_RCP_K0 - KC_RCP_K1 * D;
    int32_t E = (1 << 25) - D * Y;  Y += (Y * (E >> KC_RCP_N1)) >> (25 - KC_RCP_N1);
    E = (1 << 25) - D * Y;          Y += (Y * (E >> KC_RCP_N2)) >> (25 - KC_RCP_N2);
    return (uint32_t)Y + ((uint32_t)(D * (2 * Y + 1)) < (1u << 26));
}

static inline int32_t qrcp_model(int32_t x) {
    /* EX: leading-zero count of x | 2 (at most 30), normalize, take 17 bits */
    uint32_t ux = (uint32_t)x, y = ux | 2u, n = 0;
    while (!(y & 0x80000000u)) { y <<= 1; n++; }
    uint32_t m     = ((ux << n) >> 15) & 0x1FFFFu;
    int32_t  s     = 15 - (int32_t)n;                     /* -15..15 */
    int      small = x < 4;

    /* Q0: seed ROM */
    uint32_t r = qrcp_model_seed((m >> 8) & 0xFFu) & 0xFFFFu;

    /* Q1, Q2: one multiplier, two products */
    uint64_t p1 = (uint64_t)m * r;                        /* < 2^33 */
    uint32_t e  = (uint32_t)(p1 >> 16) & 0x1FFFFu;
    uint32_t f  = (0x20000u - e) & 0x3FFFFu;              /* 1..2^17 */
    uint64_t p2 = (uint64_t)f * r;                        /* < 2^34 */
    uint32_t rn = (uint32_t)(p2 >> 16) & 0x3FFFFu;

    /* Q3: shift back (left by max(-s, 0), arithmetic right by max(s, 0)) and saturate */
    uint32_t rs = s > 0 ? (uint32_t)s : 0u, ls = s < 0 ? (uint32_t)-s : 0u;
    int32_t  v  = (int32_t)(rn << ls) >> rs;
    if (v > (1 << 30)) v = 1 << 30;
    return small ? (1 << 30) : v;
}

#endif
