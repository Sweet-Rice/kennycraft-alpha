// Chip twin of one golden camera shot from game/host/main_host.c (cmd_shots):
// boot, set the resolution, teleport relative to the spawn point, run
// world_update until the window is ready, then draw one frame and swap. The
// harness PNG of that first swap is compared with the plain C reference's
// .fb for the same shot (scripts/golden.py). Only the first host shot starts
// from a fresh boot, so only it is reproduced this way.
//
// KC_SHOT_W, KC_SHOT_DX/DY/DZ (blocks), KC_SHOT_YAW/PITCH (1024 per turn)
// select the pose; kc_main.c is compiled with main renamed so this main runs.
#include "kc_main.h"
#include "kc_hal.h"
#include "game.h"
#include "chunks.h"
#include "arena.h"

int main(void) {
    kc_init();
    kc_set_resolution(KC_SHOT_W);
    kc_me.pos[0] += Q16_INT(KC_SHOT_DX);
    kc_me.pos[1] += Q16_INT(KC_SHOT_DY);
    kc_me.pos[2] += Q16_INT(KC_SHOT_DZ);
    kc_me.yaw = Q16_INT(KC_SHOT_YAW);
    kc_me.pitch = Q16_INT(KC_SHOT_PITCH);
    kc_me.vel_y = 0;
    int frames = 0;
    do {
        world_update(qfloor(kc_me.pos[0]), qfloor(kc_me.pos[2]));
        frames++;
    } while (!world_ready() && frames < 200);
    arena_reset();
    write_camera();
    kc_draw_world();
    game_draw_overlay();
    hal_mmio_w(MMIO_FB_SWAP, 1);
    for (;;) {}
}
