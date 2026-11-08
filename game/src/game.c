// game.c — input, player physics, picking, block editing, camera, overlay. Lane 0 only.
#include "game.h"
#include "blocks.h"
#include "chunks.h"
#include "terrain.h"
#include "trace.h"
#include "render.h"
#include "cr6.h"
#include "kc_hal.h"
#include "kc_tables.h"

kc_player kc_me;
_Static_assert(WORLD_CHUNKS * CHUNK_W < 32767, "aim / place are int16");

// Movement constants (Q16.16, folded at compile time; no float code is emitted).
#define WALK_SPEED  Q16(4.3)
#define DIAG_SCALE  46341          // 1/sqrt(2)
#define GRAVITY     Q16(32.0)
#define JUMP_VEL    Q16(8.95)      // ~1.25 block jump
#define FALL_MAX    Q16(40.0)
#define LOOK_RATE   Q16(330.0)     // angle units per second (~116 deg/s)
#define PITCH_MAX   Q16(235.0)     // ~83 deg
#define MOUSE_STEP  Q16(3.0)       // angle units per mouse-look byte (~1 deg); sensitivity knob
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

static q16 back_pos[3];   // where you left the overworld
static int32_t landing;   // just travelled: hold still until the new window is in, then land

static int32_t in_portal; // standing in a portal: it fires again only after you step out

// Slot 6 is obsidian for portals (leaves were there; trees still grow them).
// Sky and fog colors per world (generated, tools/gen_assets.py): rewritten on the way in and
// out, and once at boot (palette RAM keeps the last world's colors across a reset).
static const uint16_t pal_overworld[KC_PAL_SWAP_N] = KC_PAL_OVERWORLD;
static const uint16_t pal_nether[KC_PAL_SWAP_N] = KC_PAL_NETHER;
static int32_t pal_world = -1;   // which set is in palette RAM

static void set_world_colors(int32_t nether) {
    if (nether == pal_world) return;
    const uint16_t *src = nether ? pal_nether : pal_overworld;
    for (int32_t b = 0, k = 0; b < 256; b++)
        if ((b >> 4) == 15 || (b & 3)) hal_pal_set((uint32_t)b, src[k++]);
    pal_world = nether;
}

static const uint8_t hotbar[9] = { B_GRASS, B_DIRT, B_STONE, B_COBBLE, B_LOG, B_OBSIDIAN, B_PLANKS, B_SAND, B_BRICK };

// ---------------------------------------------------------------- collision -------------
static int32_t solid(int32_t x, int32_t y, int32_t z) {
    uint8_t t = world_get(x, y, z);
    return t != B_AIR && t != B_PORTAL;   // you walk into portals
}

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

int32_t player_overlaps(int32_t x0, int32_t y0, int32_t z0, int32_t x1, int32_t y1, int32_t z1) {
    const q16 *p = kc_me.pos;
    return qfloor(p[0] - HALF_W) <= x1 && x0 <= qfloor(p[0] + HALF_W - 1)
        && qfloor(p[1]) <= y1 && y0 <= qfloor(p[1] + HEIGHT - 1)
        && qfloor(p[2] - HALF_W) <= z1 && z0 <= qfloor(p[2] + HALF_W - 1);
}

static int32_t box_overlaps_block(int32_t bx, int32_t by, int32_t bz) { return player_overlaps(bx, by, bz, bx, by, bz); }

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

    kc_me.aim[0] = (int16_t)(CELL_X(h.cell) + wx0);
    kc_me.aim[1] = (int16_t)CELL_Y(h.cell);
    kc_me.aim[2] = (int16_t)(CELL_Z(h.cell) + wz0);
    for (int32_t i = 0; i < 3; i++) kc_me.place[i] = kc_me.aim[i];
    kc_me.place[HIT_AXIS(h.res)] += (int16_t)(HIT_NEG(h.res) ? 1 : -1);   // the cell the ray came from
}

static void do_break(void) {
    if (!kc_me.aim_hit) return;
    if (world_get(kc_me.aim[0], kc_me.aim[1], kc_me.aim[2]) == B_BEDROCK) return;
    world_set(kc_me.aim[0], kc_me.aim[1], kc_me.aim[2], B_AIR);
}

static void do_place(void) {
    if (!kc_me.aim_hit) return;
    const int16_t *p = kc_me.place;
    if (p[1] < 1 || p[1] > BUILD_MAX_Y) return;
    if (world_get(p[0], p[1], p[2]) != B_AIR) return;
    if (box_overlaps_block(p[0], p[1], p[2])) return;
    world_set(p[0], p[1], p[2], hotbar[kc_me.selected]);
    if (hotbar[kc_me.selected] == B_OBSIDIAN) portal_light(p[0], p[1], p[2]);
}

// ---------------------------------------------------------------- the Nether ------------
// P: overworld -> the Nether strip 512 blocks past NETHER_X0 (same z), and back to where you
// left. The window then reloads around the new spot over a few frames (one chunk generated
// per frame), so physics waits for it; land() then finds standing room in that column.
// P stays as a shortcut beside obsidian portals (portal_light).
static void travel(void) {
    if (kc_me.pos[0] < Q16_INT(NETHER_X0)) {
        for (int32_t i = 0; i < 3; i++) back_pos[i] = kc_me.pos[i];
        kc_me.pos[0] = Q16_INT(NETHER_X0 + 512) + Q16_HALF;
    } else if (back_pos[0]) {
        kc_me.pos[0] = back_pos[0];
        kc_me.pos[2] = back_pos[2];
    } else {
        kc_me.pos[0] = Q16_INT(2048) + Q16_HALF;   // walked in from the side: back to spawn x
    }
    kc_me.vel_y = 0;
    landing = 1;
}

// A portal frame is obsidian around a 2 wide x 3 tall hole of air (corners optional), standing
// along x or z. The obsidian block just placed at (x, y, z) may finish one: try every frame
// position that has it on the rim and fill the first complete one's hole with portal.
// Limit: breaking the frame leaves the portal blocks; clear them in do_break if that matters
int32_t portal_light(int32_t x, int32_t y, int32_t z) {
    for (int32_t along_x = 0; along_x < 2; along_x++)
        for (int32_t oy = -4; oy <= 0; oy++)
            for (int32_t oa = -3; oa <= 0; oa++) {
                int32_t x0 = x + (along_x ? oa : 0), z0 = z + (along_x ? 0 : oa), y0 = y + oy;
                int32_t ok = 1;
                for (int32_t v = 0; v < 5 && ok; v++)
                    for (int32_t a = 0; a < 4 && ok; a++) {
                        int32_t rim_a = a == 0 || a == 3, rim_v = v == 0 || v == 4;
                        if (rim_a && rim_v) continue;                       // corners
                        uint8_t t = world_get(x0 + (along_x ? a : 0), y0 + v, z0 + (along_x ? 0 : a));
                        ok = (rim_a || rim_v) ? t == B_OBSIDIAN : t == B_AIR;
                    }
                if (!ok) continue;
                for (int32_t v = 1; v < 4; v++)
                    for (int32_t a = 1; a < 3; a++)
                        world_set(x0 + (along_x ? a : 0), y0 + v, z0 + (along_x ? 0 : a), B_PORTAL);
                return 1;
            }
    return 0;
}

// Lowest spot in the column (or the next ones east) with a solid non-lava block under 2 of air.
static void land(void) {
    int32_t x = qfloor(kc_me.pos[0]), z = qfloor(kc_me.pos[2]);
    for (int32_t dx = 0; dx < 16; dx++)
        for (int32_t y = 1; y + 1 < WIN_Y; y++)
            if (solid(x + dx, y - 1, z) && world_get(x + dx, y - 1, z) != B_LAVA
                && !solid(x + dx, y, z) && !solid(x + dx, y + 1, z)) {
                kc_me.pos[0] += Q16_INT(dx);
                kc_me.pos[1] = Q16_INT(y);
                return;
            }
    kc_me.pos[1] = Q16_INT(WIN_Y - 3);   // no room anywhere: drop from the top
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
    back_pos[0] = back_pos[1] = back_pos[2] = 0;
    landing = 0;
    in_portal = 0;
    pal_world = -1;
    set_world_colors(0);
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
    case KEY_E: case KEY_Y: case KEY_N: if (down) cr6_key(b & 0x7F); return;
    case KEY_P: if (down && !landing) travel(); return;
    case MOUSE_LEFT:  if (down) kc_me.yaw = (kc_me.yaw - MOUSE_STEP) & (Q16_INT(ANG_FULL) - 1); return;
    case MOUSE_RIGHT: if (down) kc_me.yaw = (kc_me.yaw + MOUSE_STEP) & (Q16_INT(ANG_FULL) - 1); return;
    case MOUSE_UP:    if (down) kc_me.pitch = iclamp(kc_me.pitch + MOUSE_STEP, -PITCH_MAX, PITCH_MAX); return;
    case MOUSE_DOWN:  if (down) kc_me.pitch = iclamp(kc_me.pitch - MOUSE_STEP, -PITCH_MAX, PITCH_MAX); return;
    default:
        if ((b & 0x7F) >= '1' && (b & 0x7F) <= '9' && down) kc_me.selected = (uint8_t)((b & 0x7F) - '1');
        return;
    }
    if (down) kc_me.held |= (uint16_t)bit; else kc_me.held &= (uint16_t)~bit;
}

void read_keys(void) {
    while (hal_mmio_r(MMIO_UART_STATUS) & 1u) {
        uint8_t b = (uint8_t)hal_mmio_r(MMIO_UART_RX);
        if (!cr6_byte(b)) game_key(b);
    }
    cr6_end_drain();   // CR6 commands ran above, before world_update / pick_and_edit
}

void move_player(q16 dt) {
    uint32_t k = kc_me.held;

    // Look
    q16 look = qmul(LOOK_RATE, dt);
    kc_me.yaw += look * (((k & H_RIGHT) != 0) - ((k & H_LEFT) != 0));
    kc_me.yaw &= Q16_INT(ANG_FULL) - 1;
    kc_me.pitch += look * (((k & H_UP) != 0) - ((k & H_DOWN) != 0));
    kc_me.pitch = iclamp(kc_me.pitch, -PITCH_MAX, PITCH_MAX);

    if (landing) {                        // after travel(): wait for the window, then stand up
        if (!world_ready() || !world_loaded(qfloor(kc_me.pos[0]), qfloor(kc_me.pos[2]))) return;
        land();
        landing = 0;
        in_portal = 1;   // landed back in the portal you left by: step out before it fires
    }

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

    // Portal: travel when you walk in (feet or head), not again until you step out.
    int32_t px = qfloor(kc_me.pos[0]), py = qfloor(kc_me.pos[1]), pz = qfloor(kc_me.pos[2]);
    int32_t now_in = world_get(px, py, pz) == B_PORTAL || world_get(px, py + 1, pz) == B_PORTAL;
    if (now_in && !in_portal) travel();
    in_portal = now_in;
    set_world_colors(kc_me.pos[0] >= Q16_INT(NETHER_X0));   // also when you walk in from the side
}

void pick_and_edit(void) {
    update_aim();
    if (kc_me.want_break) do_break();
    if (kc_me.want_place) do_place();
    kc_me.want_break = kc_me.want_place = 0;
}

// The hotbar's pixels, [x0, x1) x [y0, y1): 9 opaque slots of S x S drawn by
// game_draw_overlay over every frame. write_camera hands the same rectangle to the kernel
// (kc_rparams hud_*), which skips the blocks inside it.
static void hotbar_rect(int32_t W, int32_t H, int32_t *x0, int32_t *x1, int32_t *y0, int32_t *y1) {
    int32_t S = W >> 4;                               // 10 px at 160, 20 at 320
    *x0 = (W - 9 * S) >> 1; *x1 = *x0 + 9 * S;
    *y0 = H - S - 2;        *y1 = *y0 + S;
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
    hotbar_rect(p->width, p->height, &p->hud_x0, &p->hud_x1, &p->hud_y0, &p->hud_y1);
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

    // Hotbar: 9 slots, each a flat swatch of the block's top color. Every pixel of
    // hotbar_rect is written: the kernel does not trace the blocks inside it.
    int32_t S = W >> 4, x0, x1, y0, y1;
    hotbar_rect(W, H, &x0, &x1, &y0, &y1);
    for (int32_t i = 0; i < 9; i++) {
        int32_t sx = x0 + i * S, sel_i = i == kc_me.selected;
        uint8_t border = sel_i ? white : black;
        uint8_t fill = PIX(kc_face_color[hotbar[i] * 3], sel_i ? 0 : 1, 0);
        for (int32_t v = 0; v < S; v++)
            for (int32_t u = 0; u < S; u++) {
                int32_t edge = u == 0 || v == 0 || u == S - 1 || v == S - 1;
                put(sx + u, y0 + v, edge ? border : fill);
            }
    }
    cr6_draw_hud(W);
}
