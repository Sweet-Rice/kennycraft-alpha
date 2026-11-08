// trace.c — ray setup + voxel DDA. Branch-free per lane; the only loop condition is a
// BALLOT, so the same code runs on 1 lane (laptop, Stage 0) and 8 lanes (Stage 1).
#include "trace.h"
#include "kc_hal.h"
#include "kc_lanes.h"

#if KC_LANES == 1
uint32_t kc_soft_mask = 1;
#endif

#define TDELTA_INF 0x7FFFFFFF

// a + b for a, b in [0, 0x7FFF_FFFF], saturating at 0x7FFF_FFFF. Branch-free.
static inline q16 sat_add(q16 a, q16 b) {
    uint32_t s = (uint32_t)a + (uint32_t)b;           // fits in 32 unsigned bits
    return sel((int32_t)(s >> 31), TDELTA_INF, (q16)s);
}

void ray_setup(kc_ray *r, const q16 o[3], const q16 d[3]) {
    uint32_t signs = 0;
    for (int i = 0; i < 3; i++) {                     // unrolled by -O2; uniform trip count
        int32_t neg = (int32_t)((uint32_t)d[i] >> 31);
        q16 ad = sel(neg, -d[i], d[i]);
        q16 td = sel(ad == 0, TDELTA_INF, qrcp(ad)); // tDelta = 1/|d|; a zero component never steps
        q16 fr = qfrac(o[i]);
        fr = sel(neg, fr, Q16_ONE - fr);              // distance to the first boundary
        r->f[1 + i] = (uint32_t)qmul(fr, td);         // tMax (fr <= 1.0, so <= TDELTA_INF)
        r->f[4 + i] = (uint32_t)td;
        signs |= (uint32_t)neg << i;
    }
    r->f[0] = CELL_PACK(qfloor(o[0]), qfloor(o[1]), qfloor(o[2]));
    r->f[7] = signs;
}

// All-ones if c (0 or 1), else 0. The empty asm keeps clang from turning the masked
// selects below back into branches (same reason as sel()).
static inline uint32_t lane_mask(int32_t c) {
    uint32_t m = -(uint32_t)c;
    __asm__("" : "+r"(m));
    return m;
}

// Walk state: the window index with mirrored axes. An axis stepping negative is stored
// flipped (x' = 63 - x, y' = 31 - y, z' = 63 - z), so every step adds +1 to one field and
// leaving the window is exactly "that field wrapped to 0". An x or z wrap carries into the
// next field; the ray stops there, and the post-loop code takes the carry back out.
#define FM_X 0x0003Fu                   // field masks in WIN_INDEX layout
#define FM_Z 0x00FC0u
#define FM_Y 0x1F000u
#define STEP1 (1u << 20)                // step count lives in bits 20..27 of the walk index
#ifdef KC_HOST
#define WALK_BASE 0u
static inline int32_t walk_read(uint32_t a) { return hal_win_get(a & 63, (a >> 12) & 31, (a >> 6) & 63); }
#else
#define WALK_BASE 0x20000000u           // KC_WORLD, so the masked walk index is the address
static inline int32_t walk_read(uint32_t a) { return *(volatile uint8_t *)(a & (WALK_BASE | 0x1FFFFu)) & 15; }
#endif

void vtrace_ref(const kc_ray *r, int32_t max_steps, kc_hit *h) {
    uint32_t c0 = r->f[0], sg = r->f[7];
    q16 tmx = (q16)r->f[1], tmy = (q16)r->f[2], tmz = (q16)r->f[3];
    q16 tdz = (q16)r->f[6];
    uint32_t dxz = r->f[4] ^ r->f[6], dyz = r->f[5] ^ r->f[6];
    uint32_t flip = (-(sg & 1) & FM_X) | (-((sg >> 1) & 1) & FM_Y) | (-((sg >> 2) & 1) & FM_Z);
    uint32_t idx = WALK_BASE | (WIN_INDEX(CELL_X(c0), CELL_Y(c0), CELL_Z(c0)) ^ flip);
    uint32_t lim = WALK_BASE + ((uint32_t)max_steps << 20);   // idx < lim <=> steps < max_steps

    // Per-step results go to memory while the lane is live (D20: once LMASK freezes a lane,
    // clang may already have reused the registers for the next step's values). volatile so
    // the stores stay in the loop; LMASK drops them for frozen lanes.
    volatile struct { uint32_t idx, fm, t; int32_t typ; } s = { 0, FM_X, 0, 0 };

    // D20: BALLOT before LMASK, so the loop never ends with M = 0. A cap of 0 never enters.
    uint32_t saved = mask_get();
    int32_t alive = max_steps > 0;
    while (ballot((uint32_t)alive)) {                // uniform: "any lane still walking?"
        lmask((uint32_t)alive);                      // finished lanes freeze their registers
        // Wiki (Tai, VTRACE "One step"): strict compares, so ties go to z, then y.
        int32_t cx = (tmx < tmy) & (tmx < tmz);
        int32_t cy = (uint32_t)cx < (uint32_t)(tmy < tmz);
        uint32_t mx = lane_mask(cx), my = lane_mask(cy);
        uint32_t t  = (uint32_t)tmz ^ (((uint32_t)tmx ^ (uint32_t)tmz) & mx) ^ (((uint32_t)tmy ^ (uint32_t)tmz) & my);
        uint32_t sum = t + ((uint32_t)tdz ^ (dxz & mx) ^ (dyz & my));
        uint32_t d  = ((sum | (uint32_t)((int32_t)sum >> 31)) & TDELTA_INF) - t;  // saturate at 0x7FFF_FFFF
        uint32_t dx = d & mx, dy = d & my;
        tmx += (q16)dx; tmy += (q16)dy; tmz += (q16)(d - dx - dy);
        uint32_t fm = FM_Z ^ ((FM_X ^ FM_Z) & mx) ^ ((FM_Y ^ FM_Z) & my);
        idx += (fm & -fm) + STEP1;
        int32_t typ = walk_read(idx ^ flip);         // always a legal address
        s.idx = idx; s.fm = fm; s.t = t; s.typ = typ;
        alive = ((uint32_t)typ < (uint32_t)((idx & fm) != 0)) & (idx < lim);  // air, inside, under cap
    }
    mask_set(saved);

    uint32_t i = s.idx, fm = s.fm;
    int32_t typ = s.typ;
    int32_t oob = (i & fm) == 0;
    int32_t hit = (typ != 0) & (oob ^ 1);
    i -= ((fm & -fm) << 6) & -(uint32_t)oob;         // undo an x/z wrap's carry (y's is harmless)
    i ^= flip;
    int32_t ax = (fm == FM_Y) | ((fm == FM_Z) << 1);
    uint32_t res = (uint32_t)hit | ((uint32_t)ax << 1) | (((sg >> ax) & 1) << 3)
                 | ((uint32_t)(typ & -hit) << 4) | (((s.idx >> 20) & 255u) << 8);
    int32_t ran = max_steps > 0;                     // max_steps 0 leaves *h unchanged
    h->res  = (uint32_t)sel(ran, (int32_t)res, (int32_t)h->res);
    h->cell = (uint32_t)sel(ran, (int32_t)CELL_PACK(i & 63, (i >> 12) & 31, (i >> 6) & 63), (int32_t)h->cell);
    h->t    = sel(ran, (int32_t)s.t, h->t);
}

#if KC_VTRACE
// Ray unit, custom-1 (0x2B). funct7 carries the field number.
#define VSET(field, v) __asm__ volatile(".insn r 0x2B, 0, " #field ", x0, %0, x0" :: "r"(v))
void kc_trace(const kc_ray *r, int32_t max_steps, kc_hit *h) {
    VSET(0, r->f[0]); VSET(1, r->f[1]); VSET(2, r->f[2]); VSET(3, r->f[3]);
    VSET(4, r->f[4]); VSET(5, r->f[5]); VSET(6, r->f[6]); VSET(7, r->f[7]);
    uint32_t res, cell, t;
    __asm__ volatile(".insn r 0x2B, 1, 0, %0, %1, x0" : "=r"(res) : "r"(max_steps) : "memory");
    __asm__ volatile(".insn r 0x2B, 2, 0, %0, x0, x0" : "=r"(cell));
    __asm__ volatile(".insn r 0x2B, 2, 1, %0, x0, x0" : "=r"(t));
    h->res = res & 0xFFFFu; h->cell = cell; h->t = (q16)t;
}
#else
void kc_trace(const kc_ray *r, int32_t max_steps, kc_hit *h) { vtrace_ref(r, max_steps, h); }
#endif
