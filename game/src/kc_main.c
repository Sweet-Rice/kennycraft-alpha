// kc_main.c — frame loop shared by the laptop and the chip.
#include "kc_main.h"
#include "kc_hal.h"
#include "game.h"
#include "render.h"
#include "fixed.h"
#include "chunks.h"
#include "arena.h"
#include "entity.h"
#include "kc_lanes.h"
#include "kc_budget.h"     // its static asserts check the 192 KB budget on every build

#ifndef KC_MAX_STEPS
#define KC_MAX_STEPS 64        // Stage 0 plan says 16 for 1-3 fps; raise as the hardware gets faster
#endif
#ifndef KC_WIDTH
#define KC_WIDTH 160
#endif

#define DT_K 5629500u          // 2^48 / CORE_HZ: (cycles * DT_K) >> 32 = seconds in Q16
#define DT_MAX Q16(0.35)

static uint32_t last_cycles;

void kc_set_resolution(int32_t width) {
    kc_rparams *p = KC_RP;
    p->width = width;
    p->height = width == 160 ? 120 : 240;
    p->sky_k = width == 160 ? 8738 : 4369;            // 16 * 65536 / height
    hal_mmio_w(MMIO_FB_MODE, width == 160 ? 1 : 0);
}

void kc_set_max_steps(int32_t steps) {
    kc_rparams *p = KC_RP;
    p->max_steps = iclamp(steps, 1, 255);
    int32_t d = imin(p->max_steps, 26);              // window edge is >= 24 blocks away
    p->fog_d[0] = d * Q16(0.45);
    p->fog_d[1] = d * Q16(0.65);
    p->fog_d[2] = d * Q16(0.85);
}

void kc_init(void) {
    kc_set_resolution(KC_WIDTH);
    kc_set_max_steps(KC_MAX_STEPS);
    hal_puts("kc: boot\n");
    arena_reset();
    game_init();
    last_cycles = hal_mmio_r(MMIO_CYCLES);
}

// Draw the world: game-side preparation on lane 0, then the kernel on all lanes.
void kc_draw_world(void) {
    entity_prepare();
    while (hal_mmio_r(MMIO_FB_SWAP)) {}               // 1. (D21)
    mask_all(); kc_render_frame(); mask_set(1);
}

// Frame loop, in the order of issue #2, with the swap wait moved down (D21): steps 2-7
// and the lane-0 prep in kc_draw_world never touch the framebuffer, so they overlap
// the vblank wait. Only the kernel and the overlay write the back buffer.
void kc_frame(void) {
    arena_reset();                                     // 2.
    read_keys();                                       // 3.
    uint32_t now = hal_mmio_r(MMIO_CYCLES);
    q16 dt = (q16)(((uint64_t)(now - last_cycles) * DT_K) >> 32);
    last_cycles = now;
    move_player(imin(dt, DT_MAX));                     // 4.
    entity_tick(imin(dt, DT_MAX));
    world_update(qfloor(kc_me.pos[0]), qfloor(kc_me.pos[2]));   // 5.
    pick_and_edit();                                   // 6.
    write_camera();                                    // 7.
    kc_draw_world();                                   // 8. mask_all(); kernel(); mask_set(1);
    game_draw_overlay();
    hal_mmio_w(MMIO_FB_SWAP, 1);                       // 9.
}

#ifndef KC_HOST
int main(void) {
    kc_init();
    for (;;) kc_frame();
}
#endif
