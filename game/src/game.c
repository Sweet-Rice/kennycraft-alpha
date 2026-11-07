// game.c — input, player physics, picking, block editing, camera, overlay. Lane 0 only.
#include "game.h"
#include "blocks.h"
#include "chunks.h"
#include "terrain.h"
#include "trace.h"
#include "render.h"
#include "kc_hal.h"

kc_player kc_me;

// Movement constants (Q16.16, folded at compile time; no float code is emitted).
#define WALK_SPEED  Q16(4.3)
#define DIAG_SCALE  46341          // 1/sqrt(2)
#define GRAVITY     Q16(32.0)
#define JUMP_VEL    Q16(8.95)      // ~1.25 block jump
#define FALL_MAX    Q16(40.0)
#define LOOK_RATE   Q16(330.0)     // angle units per second (~116 deg/s)
#define PITCH_MAX   Q16(235.0)     // ~83 deg
#define HALF_W      Q16(0.3)       // player box 0.6 x 1.8 x 0.6
#define HEIGHT      Q16(1.8)
#define EYE         Q16(1.62)
#define REACH       Q16(5.0)
#define SUBSTEP     1092           // 1/60 s
#define FOV_K_160   574            // 2*tan(35 deg)/160 in Q16
#define FOV_K_320   287
#define FOCAL_160   7487684        // (160/2) / tan(35 deg) pixels, Q16
#define FOCAL_320   14975368

enum { H_W = 1, H_A = 2, H_S = 4, H_D = 8, H_JUMP = 16, H_LEFT = 32, H_RIGHT = 64, H_UP = 128, H_DOWN = 256 };

static const uint8_t hotbar[9] = { B_GRASS, B_DIRT, B_STONE, B_COBBLE, B_LOG, B_LEAVES, B_PLANKS, B_SAND, B_BRICK };

// ---------------------------------------------------------------- collision -------------
static int32_t solid(int32_t x, int32_t y, int32_t z) { return world_get(x, y, z) != B_AIR; }

static int32_t box_hits(const q16 p[3]) {
    int32_t x0 = qfloor(p[0] - HALF_W), x1 = qfloor(p[0] + HALF_W - 1);
    int32_t y0 = qfloor(p[1]),          y1 = qfloor(p[1] + HEIGHT - 1);
    int32_t z0 = qfloor(p[2] - HALF_W), z1 = qfloor(p[2] + HALF_W - 1);
    for (int32_t y = y0; y <= y1; y++)
        for (int32_t z = z0; z <= z1; z++)
            for (int32_t x = x0; x <= x1; x++)
                if (solid(x, y, z)) return 1;
    return 0;
}

// Move along one axis; on contact, snap flush against the block. Returns 1 if blocked.
static int32_t move_axis(int32_t a, q16 delta) {
    if (delta == 0) return 0;
    q16 p[3] = { kc_me.pos[0], kc_me.pos[1], kc_me.pos[2] };
    p[a] += delta;
    if (!box_hits(p)) { kc_me.pos[a] = p[a]; return 0; }
    q16 lo = a == 1 ? 0 : HALF_W, hi = a == 1 ? HEIGHT : HALF_W;
    if (delta > 0) p[a] = Q16_INT(qfloor(p[a] + hi - 1)) - hi;
    else           p[a] = Q16_INT(qfloor(p[a] - lo) + 1) + lo;
    if (!box_hits(p)) kc_me.pos[a] = p[a];
    return 1;
}

static int32_t box_overlaps_block(int32_t bx, int32_t by, int32_t bz) {
    const q16 *p = kc_me.pos;
    return qfloor(p[0] - HALF_W) <= bx && bx <= qfloor(p[0] + HALF_W - 1)
        && qfloor(p[1]) <= by && by <= qfloor(p[1] + HEIGHT - 1)
        && qfloor(p[2] - HALF_W) <= bz && bz <= qfloor(p[2] + HALF_W - 1);
}

// ---------------------------------------------------------------- view vectors ----------
static void view_vectors(q16 fwd[3], q16 right[3], q16 up[3]) {
    int32_t yaw = kc_me.yaw >> 16, pit = kc_me.pitch >> 16;
    q16 sy = qsin(yaw), cy = qcos(yaw), sp = qsin(pit), cp = qcos(pit);
    fwd[0] = qmul(sy, cp);  fwd[1] = sp;  fwd[2] = qmul(cy, cp);
    right[0] = cy;          right[1] = 0; right[2] = -sy;
    up[0] = -qmul(sy, sp);  up[1] = cp;   up[2] = -qmul(cy, sp);
}

static void eye_pos(q16 e[3]) {
    e[0] = kc_me.pos[0];
    e[1] = iclamp(kc_me.pos[1] + EYE, Q16(0.05), Q16(31.95));   // keep the camera in the window
    e[2] = kc_me.pos[2];
}

// ---------------------------------------------------------------- picking ---------------
static void update_aim(void) {
    q16 fwd[3], right[3], up[3], e[3];
    view_vectors(fwd, right, up);
    eye_pos(e);
    int32_t wx0 = world_corner_x(), wz0 = world_corner_z();
    q16 o[3] = { e[0] - Q16_INT(wx0), e[1], e[2] - Q16_INT(wz0) };

    kc_ray r;
    kc_hit h;
    ray_setup(&r, o, fwd);
    kc_trace(&r, 12, &h);                 // the same trace the renderer uses
    kc_me.aim_hit = HIT_HIT(h.res) && h.t <= REACH;
    if (!kc_me.aim_hit) return;

    kc_me.aim[0] = CELL_X(h.cell) + wx0;
    kc_me.aim[1] = CELL_Y(h.cell);
    kc_me.aim[2] = CELL_Z(h.cell) + wz0;
    for (int32_t i = 0; i < 3; i++) kc_me.place[i] = kc_me.aim[i];
    kc_me.place[HIT_AXIS(h.res)] += HIT_NEG(h.res) ? 1 : -1;   // the cell the ray came from
}

static void do_break(void) {
    if (!kc_me.aim_hit) return;
    if (world_get(kc_me.aim[0], kc_me.aim[1], kc_me.aim[2]) == B_BEDROCK) return;
    world_set(kc_me.aim[0], kc_me.aim[1], kc_me.aim[2], B_AIR);
}

static void do_place(void) {
    if (!kc_me.aim_hit) return;
    int32_t *p = kc_me.place;
    if (p[1] < 1 || p[1] > BUILD_MAX_Y) return;
    if (world_get(p[0], p[1], p[2]) != B_AIR) return;
    if (box_overlaps_block(p[0], p[1], p[2])) return;
    world_set(p[0], p[1], p[2], hotbar[kc_me.selected]);
}

// ---------------------------------------------------------------- public ----------------
void game_init(void) {
    int32_t sx = 2048, sz = 2048;
    while (terrain_tree_at(sx, sz)) sx++;
    kc_me.pos[0] = Q16_INT(sx) + Q16_HALF;
    kc_me.pos[2] = Q16_INT(sz) + Q16_HALF;
    kc_me.pos[1] = Q16_INT(terrain_height(sx, sz) + 1);
    kc_me.vel_y = 0;
    kc_me.yaw = Q16(128.0);               // 45 degrees
    kc_me.pitch = Q16(-40.0);
    kc_me.on_ground = 0;
    kc_me.selected = 0;
    kc_me.held = 0;
    kc_me.want_break = kc_me.want_place = 0;
    world_update(sx, sz);                 // first call generates the whole window
    update_aim();
}

static void game_key(uint8_t b) {
    int32_t down = (b & 0x80) != 0;
    uint32_t bit = 0;
    switch (b & 0x7F) {
    case KEY_W: bit = H_W; break;
    case KEY_A: bit = H_A; break;
    case KEY_S: bit = H_S; break;
    case KEY_D: bit = H_D; break;
    case KEY_SPACE: bit = H_JUMP; break;
    case KEY_LEFT:  bit = H_LEFT; break;
    case KEY_RIGHT: bit = H_RIGHT; break;
    case KEY_UP:    bit = H_UP; break;
    case KEY_DOWN:  bit = H_DOWN; break;
    case KEY_BREAK: if (down) kc_me.want_break = 1; return;   // done in pick_and_edit()
    case KEY_PLACE: if (down) kc_me.want_place = 1; return;
    default:
        if ((b & 0x7F) >= '1' && (b & 0x7F) <= '9' && down) kc_me.selected = (b & 0x7F) - '1';
        return;
    }
    if (down) kc_me.held |= bit; else kc_me.held &= ~bit;
}

void read_keys(void) {
    while (hal_mmio_r(MMIO_UART_STATUS) & 1u)
        game_key((uint8_t)hal_mmio_r(MMIO_UART_RX));
}

void move_player(q16 dt) {
    uint32_t k = kc_me.held;

    // Look
    q16 look = qmul(LOOK_RATE, dt);
    kc_me.yaw += look * (((k & H_RIGHT) != 0) - ((k & H_LEFT) != 0));
    kc_me.yaw &= Q16_INT(ANG_FULL) - 1;
    kc_me.pitch += look * (((k & H_UP) != 0) - ((k & H_DOWN) != 0));
    kc_me.pitch = iclamp(kc_me.pitch, -PITCH_MAX, PITCH_MAX);

    // Walk direction from yaw only
    int32_t yaw = kc_me.yaw >> 16;
    q16 sy = qsin(yaw), cy = qcos(yaw);
    int32_t f = ((k & H_W) != 0) - ((k & H_S) != 0);
    int32_t r = ((k & H_D) != 0) - ((k & H_A) != 0);
    q16 speed = (f && r) ? qmul(WALK_SPEED, DIAG_SCALE) : WALK_SPEED;
    q16 vx = qmul(sy * f + cy * r, speed);
    q16 vz = qmul(cy * f - sy * r, speed);

    if ((k & H_JUMP) && kc_me.on_ground) kc_me.vel_y = JUMP_VEL;

    // Integrate in 1/60 s substeps so fast falls never tunnel
    q16 left = dt;
    while (left > 0) {
        q16 h = imin(left, SUBSTEP);
        left -= h;
        kc_me.vel_y = imax(kc_me.vel_y - qmul(GRAVITY, h), -FALL_MAX);
        move_axis(0, qmul(vx, h));
        move_axis(2, qmul(vz, h));
        q16 dy = qmul(kc_me.vel_y, h);
        kc_me.on_ground = 0;
        if (move_axis(1, dy)) {
            if (dy < 0) kc_me.on_ground = 1;
            kc_me.vel_y = 0;
        }
    }
    kc_me.pos[0] = iclamp(kc_me.pos[0], Q16(17.0), Q16(4079.0));
    kc_me.pos[2] = iclamp(kc_me.pos[2], Q16(17.0), Q16(4079.0));
}

void pick_and_edit(void) {
    update_aim();
    if (kc_me.want_break) do_break();
    if (kc_me.want_place) do_place();
    kc_me.want_break = kc_me.want_place = 0;
}

void write_camera(void) {
    q16 fwd[3], right[3], up[3], e[3];
    view_vectors(fwd, right, up);
    eye_pos(e);
    q16 kfov = KC_RP->width == 160 ? FOV_K_160 : FOV_K_320;
    kc_camera *c = KC_CAM;
    c->origin[0] = e[0];                  // absolute world coordinates (issue #2)
    c->origin[1] = e[1];
    c->origin[2] = e[2];
    kc_rparams *p = KC_RP;
    p->corner_x = world_corner_x();
    p->corner_z = world_corner_z();
    for (int32_t i = 0; i < 3; i++) {
        c->forward[i] = fwd[i];
        c->right_step[i] = qmul(right[i], kfov);
        c->up_step[i] = qmul(up[i], kfov);
        p->right[i] = right[i];
        p->up[i] = up[i];
    }
    p->focal = KC_RP->width == 160 ? FOCAL_160 : FOCAL_320;
}

static void put(int32_t x, int32_t y, uint8_t v) { hal_fb_put((uint32_t)(y * FB_STRIDE + x), v); }

// ---------------------------------------------------------------- selection box ----------
// Alpha-style wire box around the aimed block, drawn by lane 0 after the frame (no kernel
// cost). Only faces turned toward the eye AND open to air are drawn, so edges buried in the
// ground stay hidden without a depth test. No divide: Bresenham lines, qrcp for projection.
static void line(int32_t x0, int32_t y0, int32_t x1, int32_t y1, int32_t W, int32_t H, uint8_t c) {
    int32_t dx = iabs(x1 - x0), dy = -iabs(y1 - y0), ex = x0 < x1 ? 1 : -1, ey = y0 < y1 ? 1 : -1;
    int32_t err = dx + dy;
    for (int32_t n = 0; n < 4096; n++) {                  // bounded: corners are clamped to +-2048
        if ((uint32_t)x0 < (uint32_t)W && (uint32_t)y0 < (uint32_t)H) put(x0, y0, c);
        if (x0 == x1 && y0 == y1) break;
        int32_t e2 = 2 * err;
        if (e2 >= dy) { err += dy; x0 += ex; }
        if (e2 <= dx) { err += dx; y0 += ey; }
    }
}

static void draw_aim_box(int32_t W, int32_t H, uint8_t c) {
    const kc_camera *cam = KC_CAM;
    const kc_rparams *p = KC_RP;
    int32_t sx[8], sy[8], front[8];
    for (int32_t k = 0; k < 8; k++) {                     // corner k: bit a set = far side on axis a
        q16 r[3];
        for (int32_t a = 0; a < 3; a++) {
            int32_t hi = (k >> a) & 1;
            // 1/64 block outside the faces so the box isn't hidden by them
            r[a] = Q16_INT(kc_me.aim[a] + hi) + (hi ? 1024 : -1024) - cam->origin[a];
        }
        q16 x = qmul(r[0], p->right[0]) + qmul(r[1], p->right[1]) + qmul(r[2], p->right[2]);
        q16 y = qmul(r[0], p->up[0]) + qmul(r[1], p->up[1]) + qmul(r[2], p->up[2]);
        q16 z = qmul(r[0], cam->forward[0]) + qmul(r[1], cam->forward[1]) + qmul(r[2], cam->forward[2]);
        front[k] = z > Q16(0.25);                         // corners right at the eye: skip their edges
        q16 iz = qrcp(imax(z, Q16(0.25)));
        sx[k] = (W >> 1) + iclamp(qmul(qmul(x, p->focal), iz) >> 16, -2048, 2048);
        sy[k] = (KC_RP->height >> 1) - iclamp(qmul(qmul(y, p->focal), iz) >> 16, -2048, 2048);
    }
    for (int32_t a = 0; a < 3; a++) {
        int32_t side;
        if (cam->origin[a] < Q16_INT(kc_me.aim[a])) side = 0;
        else if (cam->origin[a] > Q16_INT(kc_me.aim[a] + 1)) side = 1;
        else continue;                                    // eye inside this slab: face edge-on
        int32_t n[3] = { kc_me.aim[0], kc_me.aim[1], kc_me.aim[2] };
        n[a] += side ? 1 : -1;
        if (world_get(n[0], n[1], n[2]) != B_AIR) continue;   // face is buried
        int32_t b = a == 2 ? 0 : a + 1, d = a == 0 ? 2 : a - 1;
        int32_t q[4] = { 0, 1 << b, (1 << b) | (1 << d), 1 << d };
        for (int32_t i = 0; i < 4; i++) {
            int32_t u = q[i] | (side << a), v = q[(i + 1) & 3] | (side << a);
            if (front[u] & front[v]) line(sx[u], sy[u], sx[v], sy[v], W, H, c);
        }
    }
}

void game_draw_overlay(void) {
    int32_t W = KC_RP->width, H = KC_RP->height;
    uint8_t white = PIX(COLOR_WHITE, 0, 0), black = PIX(COLOR_BLACK, 0, 0);

    if (kc_me.aim_hit) draw_aim_box(W, H - (W >> 4) - 3, black);   // stop above the hotbar

    // Crosshair: white plus with a 1 px black outline so it reads on sky and snow
    int32_t cx = W >> 1, cy = H >> 1;
    for (int32_t i = -4; i <= 4; i++)
        for (int32_t d = -1; d <= 1; d++) { put(cx + i, cy + d, black); put(cx + d, cy + i, black); }
    for (int32_t i = -3; i <= 3; i++) { put(cx + i, cy, white); put(cx, cy + i, white); }

    // Hotbar: 9 slots of the block's top texture
    int32_t S = W >> 4;                               // 10 px at 160, 20 at 320
    int32_t inner = S - 2;
    q16 tstep = W == 160 ? Q16(2.0) : 58254;          // 16 / inner, Q16
    int32_t x0 = (W - 9 * S) >> 1, y0 = H - S - 2;
    for (int32_t i = 0; i < 9; i++) {
        int32_t sx = x0 + i * S;
        uint8_t border = i == kc_me.selected ? white : black;
        for (int32_t j = 0; j < S; j++) {
            put(sx + j, y0, border); put(sx + j, y0 + S - 1, border);
            put(sx, y0 + j, border); put(sx + S - 1, y0 + j, border);
        }
        for (int32_t v = 0; v < inner; v++)
            for (int32_t u = 0; u < inner; u++) {
                int32_t tu = (u * tstep) >> 16, tv = (v * tstep) >> 16;
                uint8_t texel = hal_tex_get(TEX_INDEX(hotbar[i], 0, tu, tv)) & 15;
                put(sx + 1 + u, y0 + 1 + v, PIX(texel, i == kc_me.selected ? 0 : 1, 0));
            }
    }
}
