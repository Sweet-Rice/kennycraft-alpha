// game.h — KennyCraft game logic. Runs on lane 0 (mask = 0x01). Chip-safe C:
// no floats, no division, no malloc, fixed-size state.
#ifndef KC_GAME_H
#define KC_GAME_H
#include <stdint.h>
#include "fixed.h"

// Key codes (Interfaces, Key byte): bit 7 = down, bits 6:0 = code.
#define KEY_W 0x77
#define KEY_A 0x61
#define KEY_S 0x73
#define KEY_D 0x64
#define KEY_SPACE 0x20
#define KEY_LEFT  0x10
#define KEY_RIGHT 0x11
#define KEY_UP    0x12
#define KEY_DOWN  0x13
#define KEY_BREAK 0x6A   // J
#define KEY_PLACE 0x6B   // K
#define KEY_E     0x65   // talk to the villager in front of you (CR6 INTERACT)
#define KEY_Y     0x79   // accept the quote on the HUD (CR6 CONFIRM)
#define KEY_N     0x6E   // decline it
#define KEY_P     0x70   // travel to the Nether and back
// Mouse look: one key-down byte per step (scripts/kc.py sends them from pointer motion).
#define MOUSE_LEFT  0x14
#define MOUSE_RIGHT 0x15
#define MOUSE_UP    0x16
#define MOUSE_DOWN  0x17

typedef struct {
    q16 pos[3];          // feet center, absolute blocks
    q16 vel_y;
    q16 yaw, pitch;      // Q16 angle units (1024 per turn)
    int16_t aim[3], place[3];         // aimed block and the cell in front of it (absolute)
    uint16_t held;       // bitmask of held movement/look keys (9 bits)
    uint8_t on_ground;
    uint8_t selected;    // hotbar slot 0..8
    uint8_t aim_hit;     // aim / place valid?
    uint8_t want_break, want_place;   // set by keys, applied in pick_and_edit()
} kc_player;                          // 44 bytes

extern kc_player kc_me;

// Frame loop pieces, in the order of issue #2.
void game_init(void);              // spawn + first world_update (generates the window)
void read_keys(void);              // drain UART_RX
void move_player(q16 dt);          // look, walk, gravity, collisions (dt in seconds, Q16)
void pick_and_edit(void);          // aim with the DDA, apply J / K
void write_camera(void);           // camera block (absolute coords) + render params
void game_draw_overlay(void);      // crosshair + hotbar into the back framebuffer
// 1 if the player's box overlaps any block in [x0..x1] x [y0..y1] x [z0..z1] (CR6 edits).
// Fill a finished obsidian frame that has (x, y, z) on its rim with portal; 1 if one lit.
int32_t portal_light(int32_t x, int32_t y, int32_t z);
int32_t player_overlaps(int32_t x0, int32_t y0, int32_t z0, int32_t x1, int32_t y1, int32_t z1);

#endif
