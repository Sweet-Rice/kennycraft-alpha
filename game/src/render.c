// render.c — the render kernel. One ray per pixel, branch-free shading.
#include "render.h"
#include "trace.h"
#include "entity.h"
#include "kc_hal.h"
#include "kc_lanes.h"
#include "kc_tables.h"

const uint8_t kc_face_color[16 * 3] = KC_FACE_COLORS;

uint8_t kc_shade_pixel(int32_t px, int32_t py) {
    const kc_camera *c = KC_CAM;
    const kc_rparams *p = KC_RP;

    // Ray through the pixel center: forward + (x+0.5-W/2)*right_step - (y+0.5-H/2)*up_step
    int32_t sx = 2 * px + 1 - p->width;
    int32_t sy = 2 * py + 1 - p->height;
    q16 d[3];
    for (int i = 0; i < 3; i++)
        d[i] = c->forward[i] + ((c->right_step[i] * sx) >> 1) - ((c->up_step[i] * sy) >> 1);

    // Camera origin is absolute; the window (and VTRACE) work in window-relative coordinates.
    q16 o[3] = { c->origin[0] - Q16_INT(p->corner_x), c->origin[1], c->origin[2] - Q16_INT(p->corner_z) };
    kc_ray r;
    kc_hit h;
    ray_setup(&r, o, d);
    kc_trace(&r, p->max_steps, &h);

    int32_t hit  = (int32_t)HIT_HIT(h.res);
    int32_t ax   = (int32_t)HIT_AXIS(h.res);
    int32_t neg  = (int32_t)HIT_NEG(h.res);
    int32_t type = (int32_t)HIT_TYPE(h.res);

    // Face: ray stepping down (neg on y) hits a top face. One flat color per (type, face).
    int32_t ax_x = ax == 0, ax_y = ax == 1;
    int32_t face  = sel(ax_y, sel(neg, 0, 2), 1);
    int32_t color = kc_face_color[type * 3 + face];
    int32_t shade = sel(ax_y, sel(neg, 0, 3), sel(ax_x, 1, 2));
    int32_t fog   = (h.t >= p->fog_d[0]) + (h.t >= p->fog_d[1]) + (h.t >= p->fog_d[2]);

    int32_t sky_i = (py * p->sky_k) >> 16;
    sky_i = sel(sky_i > 15, 15, sky_i);
    int32_t sky = (COLOR_SKY << 4) | sky_i;

    int32_t world = sel(hit, PIX(color, shade, fog), sky);
    return ent_composite(px, py, o, &r, sel(hit, h.t, 0x7FFFFFFF), (uint8_t)world);
}

void kc_render_frame(void) {
    int32_t W = KC_RP->width, H = KC_RP->height;
#if KC_LANES == 8
    int32_t lane = (int32_t)lane_id();           // called between mask_all() and mask_set(1)
#endif
    for (int32_t ty = 0; ty < H; ty += 8) {
        for (int32_t tx = 0; tx < W; tx += 8) {
            for (int32_t b = 0; b < 8; b++) {          // eight 4x2 blocks per 8x8 tile
                int32_t bx = tx + ((b & 1) << 2);
                int32_t by = ty + ((b >> 1) << 1);
#if KC_LANES == 1
                for (int32_t lane = 0; lane < 8; lane++) {
#endif
                    int32_t px = bx + (lane & 3);
                    int32_t py = by + (lane >> 2);
                    hal_fb_put((uint32_t)(py * FB_STRIDE + px), kc_shade_pixel(px, py));
#if KC_LANES == 1
                }
#endif
            }
        }
    }
}
