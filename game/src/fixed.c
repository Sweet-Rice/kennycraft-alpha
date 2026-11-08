// fixed.c — reciprocal and sine without tables in data memory (both bit-identical to the
// old 256-entry 1/x table and 257-entry quarter-wave sine table). Constants come from
// tools/gen_assets.py, which checks them against the old tables, into gen/kc_tables.h.
#include "fixed.h"
#include "kc_tables.h"

// Branch-free on purpose: the kernel calls it per lane, and a per-lane branch would trip
// the divergent-branch detector. Comparisons become set-less-than + shifts, never jumps.

// Count of left shifts that puts the top bit of x at bit 31, clamped to 30 (x = 0 or 1
// give 30: the old shift ladder normalized at most 15 bits up). Binary search, 5 steps.
static inline uint32_t norm_shift(uint32_t x, uint32_t *xn) {
    uint32_t y = x | 2u, n = 0, k;
    k = (uint32_t)(y < 0x10000u)    << 4; y <<= k; n += k;
    k = (uint32_t)(y < 0x1000000u)  << 3; y <<= k; n += k;
    k = (uint32_t)(y < 0x10000000u) << 2; y <<= k; n += k;
    k = (uint32_t)(y < 0x40000000u) << 1; y <<= k; n += k;
    k = (~y) >> 31;                              n += k;
    *xn = x << n;
    return n;
}

// round(2^24 / (t + 0.5)) for t = 256 + (m >> 8 & 255): what the old table held.
// D = 2t + 1; linear seed, two Newton steps (result is low by at most 1), then a +1 fix-up.
static inline uint32_t rcp_seed(uint32_t m) {
#if KC_RCP_TABLE
    return kc_rcp_table[(m >> 8) & 0xFF];
#else
    int32_t D = (int32_t)(((m >> 7) & 0x1FFu) | 0x201u);
    int32_t Y = KC_RCP_K0 - KC_RCP_K1 * D;
    int32_t E = (1 << 25) - D * Y;  Y += (Y * (E >> KC_RCP_N1)) >> (25 - KC_RCP_N1);
    E = (1 << 25) - D * Y;          Y += (Y * (E >> KC_RCP_N2)) >> (25 - KC_RCP_N2);
    return (uint32_t)Y + ((uint32_t)(D * (2 * Y + 1)) < (1u << 26));
#endif
}

static inline uint32_t mulhu(uint32_t a, uint32_t b) { return (uint32_t)(((uint64_t)a * b) >> 32); }

// x = m * 2^s with m in [2^16, 2^17); returns r ~= 2^32 / m (about 16 good bits).
// Same result as table lookup + qmul Newton step: all values are positive and every
// product fits mulhu (m < 2^17, r < 2^16, 2^17 - e < 2^17).
static inline q16 rcp_norm(uint32_t x, int32_t *s_out) {
    uint32_t xn;
    int32_t n = (int32_t)norm_shift(x, &xn);
    uint32_t m = xn >> 15;
    uint32_t r = rcp_seed(m);                                   // ~9 bits
    uint32_t e = mulhu(m << 15, r << 1);                        // (m * r) >> 16, ~1.0
    *s_out = 15 - n;
    return (q16)mulhu(r << 16, (2u << 16) - e);                 // Newton: ~16 bits
}

int32_t idiv(int64_t num, int32_t den) {
    int32_t s;
    q16 r = rcp_norm((uint32_t)den, &s);
    return (int32_t)((num * r) >> (32 + s));
}

#if !KC_QRCP_HW   // else fixed.h maps qrcp() onto the QRCP instruction
// For x >= 4, s is in [-14, 14]: shift right by s or left by -s, saturating at Q16_BIG.
q16 qrcp(q16 x) {
    int32_t s;
    q16 r = rcp_norm((uint32_t)x, &s);
    int32_t rs = s & ~(s >> 31);                                // max(s, 0)
    q16 res = (q16)((uint32_t)r << (rs - s)) >> rs;
    res = sel(res > Q16_BIG, Q16_BIG, res);
    return sel(x < 4, Q16_BIG, res);
}
#endif

// Quarter-wave sine as an odd degree-9 polynomial in Q29, rounded to Q16. Matches
// round(65536 * sin(i * 2pi / 1024)) exactly for i = 0..256. Lane 0 only (game code).
static q16 sin_quarter(int32_t i) {
    int64_t u = (int64_t)i << 21, u2 = (u * u) >> 29;
    int64_t p = KC_SIN_C4;
    p = KC_SIN_C3 + ((p * u2) >> 29);
    p = KC_SIN_C2 + ((p * u2) >> 29);
    p = KC_SIN_C1 + ((p * u2) >> 29);
    p = KC_SIN_C0 + ((p * u2) >> 29);
    return (q16)(((u * p >> 29) + (1 << 12)) >> 13);
}

q16 qsin(int32_t ang) {
    ang &= ANG_FULL - 1;
    int32_t quad = ang >> 8, i = ang & 255;
    q16 v = sin_quarter((quad & 1) ? 256 - i : i);
    return (quad & 2) ? -v : v;
}
