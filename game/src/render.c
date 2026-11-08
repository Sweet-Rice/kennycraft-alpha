// render.c — the render kernel. One ray per pixel, branch-free shading.
// On 8 lanes every load and store is lane-serial, so the kernel keeps the per-frame
// constants in registers and does as little per-pixel work as it can.
#include "render.h"
#include "trace.h"
#include "entity.h"
#include "kc_hal.h"
#include "kc_lanes.h"
#include "kc_tables.h"

const uint8_t kc_face_color[16 * 3] = KC_FACE_COLORS;

// Pixel byte without fog for VTRACE res bits 7:1 (type, face sign, face axis):
// color << 4 | shade << 2. Rebuilt each frame by the lanes, 16 entries each.
static uint8_t face_pix[128];

static inline uint8_t face_entry(int32_t i) {
    int32_t ax = i & 3, neg = (i >> 2) & 1, type = i >> 3;
    // Face: ray stepping down (neg on y) hits a top face. One flat color per (type, face).
    int32_t ax_x = ax == 0, ax_y = ax == 1;
    int32_t face  = sel(ax_y, sel(neg, 0, 2), 1);
    int32_t shade = sel(ax_y, sel(neg, 0, 3), sel(ax_x, 1, 2));
    return PIX(kc_face_color[type * 3 + face], shade, 0);
}

// with_ents is a compile-time constant: 0 is the plain world loop, 1 adds the entity models
// on 4x2 blocks that an entity's screen rect overlaps. All lanes share a block, so that test
// is uniform.
static inline __attribute__((always_inline)) void frame(int32_t with_ents) {
    const kc_camera *c = KC_CAM;
    const kc_rparams *p = KC_RP;
#if KC_LANES == 8
    int32_t lane = (int32_t)lane_id();           // called between mask_all() and mask_set(1)
    for (int32_t n = 0; n < 16; n++) face_pix[n * 8 + lane] = face_entry(n * 8 + lane);
#else
    for (int32_t n = 0; n < 128; n++) face_pix[n] = face_entry(n);
    for (int32_t lane = 0; lane < 8; lane++) {
#endif
    int32_t lx = lane & 3, ly = lane >> 2;

    // Camera origin is absolute; the window (and VTRACE) work in window-relative coordinates.
    q16 o[3] = { c->origin[0] - Q16_INT(p->corner_x), c->origin[1], c->origin[2] - Q16_INT(p->corner_z) };
    q16 fr[3] = { qfrac(o[0]), qfrac(o[1]), qfrac(o[2]) };
    uint32_t cell = CELL_PACK(qfloor(o[0]), qfloor(o[1]), qfloor(o[2]));
    int32_t W = p->width, H = p->height, cap = p->max_steps;
    q16 fog0 = p->fog_d[0], fog1 = p->fog_d[1], fog2 = p->fog_d[2];
    q16 r4[3] = { 4 * c->right_step[0], 4 * c->right_step[1], 4 * c->right_step[2] };

    // 4x2 blocks in rows: this lane's pixel is (bx + lx, by + ly).
    for (int32_t by = 0; by < H; by += 2) {
        int32_t py = by + ly;
        // Ray through the pixel center: forward + (x+0.5-W/2)*right_step - (y+0.5-H/2)*up_step.
        // Moving 4 pixels right adds exactly 4 * right_step (sx grows by 8, an even multiple).
        int32_t sx = 2 * lx + 1 - W, sy = 2 * py + 1 - H;
        q16 d[3];
        for (int i = 0; i < 3; i++)
            d[i] = c->forward[i] + ((c->right_step[i] * sx) >> 1) - ((c->up_step[i] * sy) >> 1);
        int32_t sky_i = (py * p->sky_k) >> 16;
        int32_t sky = (COLOR_SKY << 4) | sel(sky_i > 15, 15, sky_i);
        uint32_t fb = (uint32_t)(py * FB_STRIDE + lx);

        for (int32_t bx = 0; bx < W; bx += 4) {
            kc_ray r;
            kc_hit h;
            ray_setup_frac(&r, cell, fr, d);
            kc_trace(&r, cap, &h);
            int32_t hit = (int32_t)HIT_HIT(h.res);
            int32_t fog = 3 - ((h.t < fog0) + (h.t < fog1) + (h.t < fog2));
            int32_t pix = face_pix[(h.res >> 1) & 127] | fog;
            int32_t col = sel(hit, pix, sky);
            if (with_ents && ent_block(bx, by))
                col = ent_composite(bx + lx, py, o, &r, sel(hit, h.t, 0x7FFFFFFF), (uint8_t)col);
            hal_fb_put(fb, (uint8_t)col);
            fb += 4;
            d[0] += r4[0]; d[1] += r4[1]; d[2] += r4[2];
        }
    }
#if KC_LANES == 1
    }
#endif
}

void kc_render_frame(void) {
    if (ent_nrects) frame(1); else frame(0);    // uniform: every lane reads the same count
}
