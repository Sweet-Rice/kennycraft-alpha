// render.c — the render kernel. One ray per pixel, branch-free shading.
// On 8 lanes every load and store is lane-serial (an 8-lane LW is ~12 cycles on the
// multi-cycle core, a spill reload the same), so the kernel keeps the per-frame constants and
// the ray in registers: the plain pixel loop touches memory twice, one LBU (face table) and
// the SB to the framebuffer, and has no spills.
#include "render.h"
#include "trace.h"
#include "entity.h"
#include "kc_hal.h"
#include "kc_lanes.h"
#include "kc_tables.h"

const uint8_t kc_face_color[16 * 3] = KC_FACE_COLORS;

// Pixel byte without fog for VTRACE res bits 7:1 (type, face sign, face axis):
// color << 4 | shade << 2. Rebuilt each frame by the lanes, 16 entries each.
// Pixel byte without fog, color << 4 | shade << 2, per VTRACE result bits 7:0 (type, face
// sign, face axis, hit; 0 on a miss): one ANDI + LBU per pixel. Generated with the face and
// shade rule by tools/gen_assets.py (KC_FACE_PIX), so it costs no stores per frame.
// Face: a ray stepping down (neg on y) hits a top face (shade 0), up a bottom face (3);
// x sides shade 1, z sides 2. One flat color per (type, face) from kc_face_color.
static const uint8_t face_pix[256] = KC_FACE_PIX;

static inline uint32_t mulhu32(uint32_t a, uint32_t b) { return (uint32_t)(((uint64_t)a * b) >> 32); }

// All ones when c is 1, 0 when c is 0, through an empty asm like sel() so clang never turns
// its use into a per-lane branch.
static inline uint32_t lane_mask_of(int32_t c) {
    uint32_t m = -(uint32_t)c;
    __asm__("" : "+r"(m));
    return m;
}

// One axis of ray_setup_frac, in registers: tMax and tDelta for direction component d and
// origin fraction frac << 15. Bit-exact with trace.h.
// tDelta = 1/|d| for |d| = ad, 0x7FFF_FFFF for ad = 0. qrcp(0) is Q16_BIG = 0x4000_0000
// (fixed.c, and QRCP is bit-exact with it), so OR-ing in 0x3FFF_FFFF gives exactly TDELTA_INF.
static inline __attribute__((always_inline)) uint32_t axis_td(q16 ad) {
    return (uint32_t)qrcp(ad) | (lane_mask_of(ad == 0) >> 2);
}
typedef struct { uint32_t tmax, td; } kc_axis;
static inline __attribute__((always_inline)) kc_axis axis_setup(uint32_t frac15, q16 d) {
    int32_t  m  = d >> 31;                            // all ones when stepping negative
    uint32_t p  = ~(uint32_t)m;                       // all ones when stepping positive
    q16      ad = (d ^ m) - m;                        // |d|
    kc_axis  a;
    a.td = axis_td(ad);
    // Distance to the first boundary << 15: frac for d < 0, 1 - frac for d >= 0.
    // (x ^ 0x7FFF_FFFF) + 1 = 2^31 - x, i.e. (1.0 - frac) << 15.
    uint32_t f15 = (frac15 ^ (p >> 1)) - p;
    // tMax = qmul(f, td) for f in [0, 1.0] and td in [0, 0x7FFF_FFFF]: one MULHU.
    a.tmax = mulhu32(f15, a.td << 1);
    return a;
}

// The ray of one block, from the frame (cell, fx, fz), the row (ay, ysign) and dx, dz.
static inline __attribute__((always_inline))
kc_ray block_ray(uint32_t cell, uint32_t fx, uint32_t fz, kc_axis ay, uint32_t ysign, q16 dx, q16 dz) {
    kc_axis ax = axis_setup(fx, dx), az = axis_setup(fz, dz);
    kc_ray r = { { cell, ax.tmax, ay.tmax, az.tmax, ax.td, ay.td, az.td,
                   ((uint32_t)dx >> 31) | ysign | (((uint32_t)dz >> 31) << 2) } };
    return r;
}

// One ray in flight. With the ray unit, VTRACE x0 starts the walk and returns at once; VGET
// waits for the walk, and so do VSET and VTRACE, so the kernel builds the next block's ray in
// registers while the walk runs and sets it only after reading this walk's result. Without
// the ray unit (laptop, Stage 0/1) the same calls run the software walk in ray_start, so the
// laptop checks this loop's order too.
#if KC_VTRACE
typedef struct { int32_t unused; } kc_inflight;
static inline __attribute__((always_inline)) void ray_set(kc_inflight *q, const kc_ray *r) {
    (void)q;
    KC_VSET(0, r->f[0]); KC_VSET(1, r->f[1]); KC_VSET(2, r->f[2]); KC_VSET(3, r->f[3]);
    KC_VSET(4, r->f[4]); KC_VSET(5, r->f[5]); KC_VSET(6, r->f[6]); KC_VSET(7, r->f[7]);
}
static inline __attribute__((always_inline)) void ray_start(kc_inflight *q, int32_t cap) {
    (void)q; kc_vtrace_start(cap);
}
static inline __attribute__((always_inline)) uint32_t ray_result(kc_inflight *q, q16 *t) {
    (void)q; uint32_t res = kc_vget_res(); *t = kc_vget_t(); return res;
}
#else
typedef struct { kc_ray staged; kc_hit h; } kc_inflight;
static inline void ray_set(kc_inflight *q, const kc_ray *r) { q->staged = *r; }
static inline void ray_start(kc_inflight *q, int32_t cap) { kc_trace(&q->staged, cap, &q->h); }
static inline uint32_t ray_result(kc_inflight *q, q16 *t) { *t = q->h.t; return q->h.res; }
#endif

// with_ents is a compile-time constant: 0 is the plain world loop, 1 adds the entity models
// on 4x2 blocks that an entity's screen rect overlaps. All lanes share a block, so that test
// is uniform.
static inline __attribute__((always_inline)) void frame(int32_t with_ents, int32_t by0, int32_t by1) {
    const kc_camera *c = KC_CAM;
    const kc_rparams *p = KC_RP;
#if KC_LANES == 8
    int32_t lane = (int32_t)lane_id();           // called between mask_all() and mask_set(1)
#else
    for (int32_t lane = 0; lane < 8; lane++) {
#endif
    int32_t lx = lane & 3, ly = lane >> 2;

    // Camera origin is absolute; the window (and VTRACE) work in window-relative coordinates.
    q16 o[3] = { c->origin[0] - Q16_INT(p->corner_x), c->origin[1], c->origin[2] - Q16_INT(p->corner_z) };
    uint32_t fx = (uint32_t)qfrac(o[0]) << 15, fy = (uint32_t)qfrac(o[1]) << 15;
    uint32_t fz = (uint32_t)qfrac(o[2]) << 15;
    uint32_t cell = CELL_PACK(qfloor(o[0]), qfloor(o[1]), qfloor(o[2]));
    int32_t W = p->width, H = p->height, cap = p->max_steps;
    // Fog level = (t >= fog_d[0]) + (t >= fog_d[1]) + (t >= fog_d[2]) = sum of (fog_d - 1 < t):
    // one SLT each. fog_d > 0 (kc_set_max_steps); the empty asm stops clang folding the - 1
    // back into SLT + XORI.
    // Fog dithering: blocks are 4x2 at even coordinates, so a pixel's checkerboard parity
    // (x + y) & 1 is fixed per lane. Odd lanes reach each fog level a quarter band sooner, so
    // each hard fog ring becomes a thin checkerboard strip, at no per-pixel cost.
    q16 dth = sel((lx ^ ly) & 1, (p->fog_d[1] - p->fog_d[0]) >> 2, 0);
    q16 f0 = p->fog_d[0] - 1 - dth, f1 = p->fog_d[1] - 1 - dth, f2 = p->fog_d[2] - 1 - dth;
    __asm__("" : "+r"(f0), "+r"(f1), "+r"(f2));
    q16 r4x = 4 * c->right_step[0], r4z = 4 * c->right_step[2];
    // 4x2 blocks entirely under the hotbar (kc_rparams hud_*) are overwritten by the overlay
    // every frame, so they are not traced: block columns [skip_x0, skip_x1) of the block rows
    // inside [hud_y0, hud_y1). The skip test is uniform (all lanes share the block).
    int32_t skip_x0 = (p->hud_x0 + 3) & ~3, skip_x1 = p->hud_x1 & ~3;
    int32_t hud_y0 = p->hud_y0, hud_y1 = p->hud_y1;

    // 4x2 blocks in rows: this lane's pixel is (bx + lx, by + ly).
    for (int32_t by = by0; by < by1; by += 2) {
        int32_t py = by + ly;
        // Columns some entity covers in this block row (entity_prepare): one load per row,
        // then a register compare per block.
        int32_t ex0 = with_ents ? ent_span[by >> 1][0] : 0, ex1 = with_ents ? ent_span[by >> 1][1] : -1;
        // Ray through the pixel center: forward + (x+0.5-W/2)*right_step - (y+0.5-H/2)*up_step.
        // Moving 4 pixels right adds exactly 4 * right_step (sx grows by 8, an even multiple).
        int32_t sx = 2 * lx + 1 - W, sy = 2 * py + 1 - H;
        q16 d[3];
        for (int i = 0; i < 3; i++)
            d[i] = c->forward[i] + ((c->right_step[i] * sx) >> 1) - ((c->up_step[i] * sy) >> 1);
        // The camera never rolls (game.c view_vectors: right.y = 0), so right_step[1] = 0: the
        // y component, and so its tDelta, tMax and step sign, is the same for the whole row.
        kc_axis ay = axis_setup(fy, d[1]);
        uint32_t ysign = ((uint32_t)d[1] >> 31) << 1;
        int32_t sky_i = (py * p->sky_k) >> 16;
        int32_t sky = (COLOR_SKY << 4) | sel(sky_i > 15, 15, sky_i);
        // Covered rows run the block loop over two ranges, [0, skip_x0) and [skip_x1, W),
        // others over [0, W) and an empty second range: no per-block test.
        int32_t row_skip = (by >= hud_y0) & (by + 2 <= hud_y1) & (skip_x0 < skip_x1);
        int32_t end = sel(row_skip, skip_x0, W), start1 = sel(row_skip, skip_x1, W);

        // Software pipeline over the row: block bx walks while the next block's ray is built in
        // registers. The row's first block is started before the loop and its last block is
        // shaded after it, so the loop itself needs no flags. Every row has a first block:
        // the hotbar is centered, so skip_x0 > 0.
        int32_t bx = 0;
        uint32_t fb = (uint32_t)(py * FB_STRIDE + lx);
        q16 dx = d[0], dz = d[2];
        kc_inflight q;
        kc_ray r = block_ray(cell, fx, fz, ay, ysign, dx, dz);
        ray_set(&q, &r);
        ray_start(&q, cap);
        q16 t;
        uint32_t res;
        for (;;) {
            // Next block in row order, jumping over the hotbar's blocks. Uniform.
            int32_t nbx = bx + 4;
            uint32_t nfb = fb + 4u;
            // With entities, the loop's call leaves too few registers: read these per block
            // (the call may write memory, so they stay in the loop) with one uniform load
            // instead of a per-lane spill reload.
            q16 ndx = dx + (with_ents ? 4 * c->right_step[0] : r4x);
            q16 ndz = dz + (with_ents ? 4 * c->right_step[2] : r4z);
            if (nbx >= end) {
                if (end == W) break;
                int32_t n = start1 - nbx;                 // a multiple of 4: d stays exact
                nbx = start1; end = W; nfb += (uint32_t)n;
                ndx += c->right_step[0] * n; ndz += c->right_step[2] * n;
                if (nbx >= W) break;
            }
            kc_ray rn = block_ray(cell, fx, fz, ay, ysign, ndx, ndz);  // during the walk
            res = ray_result(&q, &t);                     // waits for block bx's walk
            ray_set(&q, &rn);
            ray_start(&q, cap);                           // block nbx walks from here
            int32_t hit = (int32_t)(res & 1u);
            q16 g0 = f0, g1 = f1, g2 = f2;
            if (with_ents) {
                g0 = p->fog_d[0] - 1 - dth; g1 = p->fog_d[1] - 1 - dth; g2 = p->fog_d[2] - 1 - dth;
                __asm__("" : "+r"(g0), "+r"(g1), "+r"(g2));
            }
            int32_t fog = (g0 < t) + (g1 < t) + (g2 < t);
            int32_t col = sel(hit, face_pix[res & 255u] | fog, sky);
            if (with_ents && (bx + 3 >= ex0) & (bx <= ex1) &&
                ((ent_bits[by >> 1][bx >> 7] >> ((bx >> 2) & 31)) & 1u) &&
                ballot(sel(hit, t, 0x7FFFFFFF) > (q16)ent_bits[by >> 1][3])) {
                // Recomputed here rather than kept from the VSET: keeping the ray alive across
                // the loop spills the rest of it on every block, entity or not.
                // Only the tDeltas and step signs, in registers (no kc_ray through memory).
                q16 mx = dx >> 31, mz = dz >> 31;
                uint32_t sg = ((uint32_t)dx >> 31) | ysign | (((uint32_t)dz >> 31) << 2);
                col = ent_composite(bx, by, (q16)axis_td((dx ^ mx) - mx), (q16)ay.td,
                                    (q16)axis_td((dz ^ mz) - mz), sg, sel(hit, t, 0x7FFFFFFF), (uint8_t)col);
            }
            hal_fb_put(fb, (uint8_t)col);
            bx = nbx; fb = nfb; dx = ndx; dz = ndz;
        }
        res = ray_result(&q, &t);                         // the row's last block
        {
            int32_t hit = (int32_t)(res & 1u);
            int32_t fog = (f0 < t) + (f1 < t) + (f2 < t);
            int32_t col = sel(hit, face_pix[res & 255u] | fog, sky);
            if (with_ents && (bx + 3 >= ex0) & (bx <= ex1) &&
                ((ent_bits[by >> 1][bx >> 7] >> ((bx >> 2) & 31)) & 1u) &&
                ballot(sel(hit, t, 0x7FFFFFFF) > (q16)ent_bits[by >> 1][3])) {
                // Recomputed here rather than kept from the VSET: keeping the ray alive across
                // the loop spills the rest of it on every block, entity or not.
                // Only the tDeltas and step signs, in registers (no kc_ray through memory).
                q16 mx = dx >> 31, mz = dz >> 31;
                uint32_t sg = ((uint32_t)dx >> 31) | ysign | (((uint32_t)dz >> 31) << 2);
                col = ent_composite(bx, by, (q16)axis_td((dx ^ mx) - mx), (q16)ay.td,
                                    (q16)axis_td((dz ^ mz) - mz), sg, sel(hit, t, 0x7FFFFFFF), (uint8_t)col);
            }
            hal_fb_put(fb, (uint8_t)col);
        }
    }
#if KC_LANES == 1
    }
#endif
}

// Separate functions, so the plain loop gets its own register allocation: inlined into one
// function, the entity loop's extra live values made clang spill 9 values per block in the
// plain loop too (+28% frame time with no entities on screen).
// Pixel rows [by0, by1), even.
__attribute__((noinline)) static void frame_plain(int32_t by0, int32_t by1) { frame(0, by0, by1); }
__attribute__((noinline)) static void frame_ents(int32_t by0, int32_t by1)  { frame(1, by0, by1); }

// Only the block rows some entity box covers run the entity loop. Uniform: every lane reads
// the same rows.
void kc_render_frame(void) {
    int32_t H = KC_RP->height, r0 = ent_row0 * 2, r1 = ent_row1 * 2;
    if (r0 >= r1) { frame_plain(0, H); return; }
    if (r0 > 0) frame_plain(0, r0);
    frame_ents(r0, r1);
    if (r1 < H) frame_plain(r1, H);
}
