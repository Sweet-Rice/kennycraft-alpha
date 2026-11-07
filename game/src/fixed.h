// fixed.h — Q16.16 math in plain int32 (D4). No floats, no division.
// Chip-safe: compiles for rv32i_zmmul (64-bit products become MUL + MULH).
#ifndef KC_FIXED_H
#define KC_FIXED_H
#include <stdint.h>

typedef int32_t q16;

#define Q16_ONE    65536
#define Q16_HALF   32768
#define Q16(x)     ((q16)((x) * 65536))   // compile-time constants only
#define Q16_INT(i) ((q16)((int32_t)(i) * 65536))
#define Q16_BIG    (1 << 30)               // "infinity" for tDelta of axis-parallel rays

// Q16 * Q16 -> Q16. Uses a 64-bit product (MUL + MULH on the chip).
static inline q16 qmul(q16 a, q16 b) { return (q16)(((int64_t)a * b) >> 16); }

static inline int32_t qfloor(q16 a) { return a >> 16; }          // arithmetic shift = floor
static inline q16     qfrac(q16 a)  { return a & 0xFFFF; }
static inline int32_t iabs(int32_t a) { return a < 0 ? -a : a; }
static inline int32_t imin(int32_t a, int32_t b) { return a < b ? a : b; }
static inline int32_t imax(int32_t a, int32_t b) { return a > b ? a : b; }
static inline int32_t iclamp(int32_t v, int32_t lo, int32_t hi) { return v < lo ? lo : (v > hi ? hi : v); }

// Branch-free select: c must be 0 or 1. Use in the kernel so per-lane values never
// need a divergent branch (Risks table: "Replace GPU_IF with sel()").
// The empty asm hides the mask from the optimizer; without it clang recognizes the pattern
// as a select and lowers it to a branch (RV32I has no conditional move).
static inline int32_t sel(int32_t c, int32_t a, int32_t b) {
    int32_t m = -c;
    __asm__("" : "+r"(m));
    return b ^ ((a ^ b) & m);
}

// 1/x for x in Q16.16 (x > 0). Computed seed + one Newton step, no divide, no table.
// Returns Q16_BIG for x too small. Defined in fixed.c.
q16 qrcp(q16 x);

// num / den for den >= 1 without a divide instruction (~16 significant bits). Branch-free.
// den MUST be positive: a negative den is read as a huge unsigned value.
int32_t idiv(int64_t num, int32_t den);
// a / b for Q16 values, b > 0.
static inline q16 qdiv(q16 a, q16 b) { return idiv((int64_t)a << 16, b); }

// Angles: 1024 units per full turn. Quarter-wave polynomial, Q16.16.
#define ANG_FULL 1024
q16 qsin(int32_t ang);
static inline q16 qcos(int32_t ang) { return qsin(ang + ANG_FULL / 4); }

// Integer hash for terrain and textures (same on laptop and chip).
static inline uint32_t hash32(uint32_t x) {
    x ^= x >> 16; x *= 0x7feb352dU;
    x ^= x >> 15; x *= 0x846ca68bU;
    x ^= x >> 16; return x;
}
static inline uint32_t hash2(int32_t x, int32_t z, uint32_t seed) {
    return hash32((uint32_t)x * 0x9E3779B1U ^ hash32((uint32_t)z + seed));
}

#endif
