// trace.h — ray setup and voxel traversal (Amanatides & Woo DDA).
// kc_trace() has exactly the VTRACE contract from the Interfaces section, so:
//   * the software build of it IS the "C reference for one ray" for the VTRACE testbench,
//   * swapping in the hardware unit (KC_VTRACE=1) changes nothing above this file.
#ifndef KC_TRACE_H
#define KC_TRACE_H
#include <stdint.h>
#include "fixed.h"

// VSET fields. f[0] start cell packed (x 5:0, y 10:6, z 16:11); f[1..3] tMax x,y,z;
// f[4..6] tDelta x,y,z (Q16.16); f[7] step signs (bit0 x, bit1 y, bit2 z; 1 = negative).
typedef struct { uint32_t f[8]; } kc_ray;

// VTRACE result + VGET fields.
typedef struct {
    uint32_t res;    // bit0 hit, 2:1 face axis, 3 face sign, 7:4 type, 15:8 steps
    uint32_t cell;   // VGET 0: hit cell packed like f[0]
    q16      t;      // VGET 1: t at hit
} kc_hit;

#define HIT_HIT(r)   ((r) & 1u)
#define HIT_AXIS(r)  (((r) >> 1) & 3u)
#define HIT_NEG(r)   (((r) >> 3) & 1u)
#define HIT_TYPE(r)  (((r) >> 4) & 15u)
#define HIT_STEPS(r) (((r) >> 8) & 255u)
#define CELL_PACK(x, y, z) (((uint32_t)(x) & 63u) | (((uint32_t)(y) & 31u) << 6) | (((uint32_t)(z) & 63u) << 11))
#define CELL_X(c) ((int32_t)((c) & 63u))
#define CELL_Y(c) ((int32_t)(((c) >> 6) & 31u))
#define CELL_Z(c) ((int32_t)(((c) >> 11) & 63u))

#define TDELTA_INF 0x7FFFFFFF

// Build VSET fields from the start cell (packed like f[0]), the origin's fractional parts
// fr[i] = qfrac(o[i]) and a direction (Q16.16). Branch-free: safe on 8 lanes. Inline, so
// the renderer keeps the fields in registers on their way to VSET.
static inline void ray_setup_frac(kc_ray *r, uint32_t cell, const q16 fr[3], const q16 d[3]) {
    uint32_t signs = 0;
    for (int i = 0; i < 3; i++) {                     // unrolled by -O2; uniform trip count
        int32_t neg = (int32_t)((uint32_t)d[i] >> 31);
        q16 ad = (d[i] ^ -neg) + neg;                 // |d|, branch-free
        q16 td = sel(ad == 0, TDELTA_INF, qrcp(ad)); // tDelta = 1/|d|; a zero component never steps
        q16 f  = sel(neg, fr[i], Q16_ONE - fr[i]);    // distance to the first boundary
        r->f[1 + i] = (uint32_t)qmul(f, td);          // tMax (f <= 1.0, so <= TDELTA_INF)
        r->f[4 + i] = (uint32_t)td;
        signs |= (uint32_t)neg << i;
    }
    r->f[0] = cell;
    r->f[7] = signs;
}

// Build VSET fields from a window-relative origin and a direction (both Q16.16).
// The origin must be inside the window.
static inline void ray_setup(kc_ray *r, const q16 o[3], const q16 d[3]) {
    q16 fr[3] = { qfrac(o[0]), qfrac(o[1]), qfrac(o[2]) };
    ray_setup_frac(r, CELL_PACK(qfloor(o[0]), qfloor(o[1]), qfloor(o[2])), fr, d);
}

// Step the ray up to max_steps (0..255) until it hits a solid block or leaves the window.
// Rules = wiki Tai page, VTRACE "One step" (vtrace.sv must match):
//   x if tMax.x < tMax.y && tMax.x < tMax.z, else y if tMax.y < tMax.z, else z (strict <);
//   tMax additions saturate at 0x7FFF_FFFF; a zero direction component has tDelta 0x7FFF_FFFF;
//   the start cell is never tested; max_steps = 0 returns at once and leaves *h unchanged.
// On a miss (left the window or hit the cap): hit = 0, type = 0, and axis, sign, t and cell
// are those of the last step taken (cell packed from its low bits).
#if KC_VTRACE
// Ray unit, custom-1 (0x2B). funct7 carries the field number. Inline, so a kc_ray and
// kc_hit kept in registers never go through memory (loads/stores are lane-serial).
#define VSET(field, v) __asm__ volatile(".insn r 0x2B, 0, " #field ", x0, %0, x0" :: "r"(v))
static inline void kc_trace(const kc_ray *r, int32_t max_steps, kc_hit *h) {
    VSET(0, r->f[0]); VSET(1, r->f[1]); VSET(2, r->f[2]); VSET(3, r->f[3]);
    VSET(4, r->f[4]); VSET(5, r->f[5]); VSET(6, r->f[6]); VSET(7, r->f[7]);
    uint32_t res, cell, t;
    __asm__ volatile(".insn r 0x2B, 1, 0, %0, %1, x0" : "=r"(res) : "r"(max_steps) : "memory");
    __asm__ volatile(".insn r 0x2B, 2, 0, %0, x0, x0" : "=r"(cell));
    __asm__ volatile(".insn r 0x2B, 2, 1, %0, x0, x0" : "=r"(t));
    h->res = res & 0xFFFFu; h->cell = cell; h->t = (q16)t;
}
#else
void kc_trace(const kc_ray *r, int32_t max_steps, kc_hit *h);
#endif

// Always the software version (used by tests to compare against VTRACE).
void vtrace_ref(const kc_ray *r, int32_t max_steps, kc_hit *h);

#endif
