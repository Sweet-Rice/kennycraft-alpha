#include "entity.h"
#include "kc_hal.h"
#include "kc_lanes.h"
#include "render.h"
#include "chunks.h"
#include "blocks.h"

static struct { q16 pos[3], tgt[2]; uint8_t kind, facing; } ents[ENT_MAX];
static int32_t nents;
static const q16 walk_speed[ENT_KINDS] = {Q16(1.5), Q16(1.5), Q16(1.0), Q16(1.2)};   // blocks per second
ent_box ent_boxes[ENT_BOX_MAX];
int32_t ent_nboxes;
int16_t ent_span[ENT_ROWS][2];
uint32_t ent_bits[ENT_ROWS][4];
int32_t ent_row0, ent_row1;
// Per block row, the on-screen boxes whose rows overlap it, in box order.
static uint8_t ent_bin[ENT_ROWS][ENT_BOX_MAX], ent_bin_n[ENT_ROWS];
// 8 when every box bound is inside +-2^23 (128 blocks): entity_prepare then stores the bounds
// << 8, and for tDeltas < 2^23 one MULH of (bound << 8, td << 8) is (bound * td) >> 16 exactly,
// with |product| < 2^46 so slab_t never saturates. Else 0 and the bounds are stored as they are.
// Stays 0 without the fast path.
static int32_t ent_sh;
// Fast path only where it pays and fits: the Stage 2 chip build (VTRACE) and the laptop
// build, which checks it. Stage 0/1 chip builds (software walk, every file at -O2 in the
// golden checks) have no IMEM to spare and take the exact slow path everywhere.
#if defined(KC_CHIP) && !KC_VTRACE
#define KC_ENT_FAST 0
#else
#define KC_ENT_FAST 1
#endif

enum { C_BLACK = 0, C_GRASS_L = 1, C_GRASS_D = 2, C_DIRT_L = 3, C_DIRT_D = 4,
       C_STONE_D = 6, C_PLANKS = 8, C_SAND = 9, C_BRICK = 11, C_WOOD_L = 13, C_WHITE = 14 };
#define ROBE 15
// Local coordinates in sixteenths of a block; +z is the front.
typedef struct { int8_t x0, y0, z0, x1, y1, z1; uint8_t color; } ent_part;
// The face is painted on the skull: nose and eyes are thin boxes whose fronts lie in the
// head's front plane. ent_box_hit keeps the first box on a tie, so they come before the
// head, and the nose before the eyes so it splits the eye bar into two eyes.
static const ent_part villager_parts[5] = {
    {-4, 0,-3, 4,24,3,ROBE},          // robe: torso and legs
    {-1,25, 3, 1,29,4,C_DIRT_D},      // nose
    {-3,28, 3, 3,29,4,C_BLACK},       // eyes
    {-4,24,-4, 4,33,4,C_DIRT_L},      // head
    {-7,16,-3, 7,20,7,ROBE},          // folded arms, back through the torso to join at the sides
};
static const ent_part chicken_parts[7] = {
    {-3, 4,-4, 3,10, 4,C_WHITE},     // body
    {-2,10, 1, 2,15, 5,C_WHITE},     // head
    {-1,15, 2, 1,17, 4,C_BRICK},     // comb
    {-1,12, 5, 1,13, 7,C_PLANKS},    // beak
    {-1,10, 4, 1,12, 6,C_BRICK},     // wattle
    {-2, 0,-1,-1, 4, 0,C_WOOD_L},    // legs
    { 1, 0,-1, 2, 4, 0,C_WOOD_L},
};
static const ent_part zombie_parts[7] = {
    {-4, 0,-2, 4,12, 2,C_BLACK},
    {-4,12,-2, 4,24, 2,C_STONE_D},
    {-4,24,-4, 4,32, 4,C_GRASS_L},
    {-8,20,-2,-4,24,10,C_GRASS_L},
    { 4,20,-2, 8,24,10,C_GRASS_L},
    {-3,27, 4,-1,28, 5,C_BLACK},
    { 1,27, 4, 3,28, 5,C_BLACK},
};
static const struct { const ent_part *parts; uint8_t n, robe; } models[ENT_KINDS] = {
    {villager_parts,7,C_BRICK}, {villager_parts,7,C_WOOD_L},
    {chicken_parts,7,0}, {zombie_parts,7,0}
};

int32_t entity_add(int32_t kind, q16 x, q16 y, q16 z, int32_t facing) {
    if ((uint32_t)kind >= ENT_KINDS || (uint32_t)facing > 3u || nents == ENT_MAX) return -1;
    int32_t i = nents++;
    ents[i].pos[0] = x; ents[i].pos[1] = y; ents[i].pos[2] = z;
    ents[i].kind = (uint8_t)kind; ents[i].facing = (uint8_t)facing;
    ents[i].tgt[0] = x; ents[i].tgt[1] = z;
    return i;
}

int32_t entity_move(int32_t id, q16 tx, q16 tz) {
    if ((uint32_t)id >= (uint32_t)nents) return -1;
    ents[id].tgt[0] = tx; ents[id].tgt[1] = tz;
    return 0;
}

int32_t entity_teleport(int32_t id, q16 x, q16 z) {
    if ((uint32_t)id >= (uint32_t)nents) return -1;
    ents[id].pos[0] = ents[id].tgt[0] = x;
    ents[id].pos[2] = ents[id].tgt[1] = z;
    return 0;
}

void entity_get(int32_t id, q16 pos[3], int32_t *facing) {
    for (int32_t a = 0; a < 3; a++) pos[a] = ents[id].pos[a];
    *facing = ents[id].facing;
}

// ponytail: straight line, each axis clamped to the step (diagonals ~1.4x faster), no collision;
// the laptop agents plan the route. Feet snap onto the column's top non-tree block when loaded.
void entity_tick(q16 dt) {
    for (int32_t i = 0; i < nents; i++) {
        q16 step = qmul(walk_speed[ents[i].kind], dt);
        q16 dx = ents[i].tgt[0] - ents[i].pos[0], dz = ents[i].tgt[1] - ents[i].pos[2];
        if (!dx && !dz) continue;
        ents[i].pos[0] += iclamp(dx, -step, step);
        ents[i].pos[2] += iclamp(dz, -step, step);
        ents[i].facing = (uint8_t)(iabs(dx) > iabs(dz) ? (dx > 0 ? 1 : 3) : (dz > 0 ? 0 : 2));
        int32_t x = qfloor(ents[i].pos[0]), z = qfloor(ents[i].pos[2]), top = 31;
        if (!world_loaded(x, z)) continue;             // column not loaded: keep the height
        for (; top > 0; top--) {                     // trees don't count: walk under the canopy
            int32_t t = world_get(x, top, z);
            if (t != B_AIR && t != B_LEAVES && t != B_LOG) break;
        }
        ents[i].pos[1] = Q16_INT(top + 1);
    }
}
void entity_clear(void) { nents = 0; }
int32_t entity_count(void) { return nents; }

// The kernel's ray for pixel (x, y) is F + kx R - ky U with F = forward, R = right_step,
// U = up_step, kx = x + 0.5 - W/2 and ky = y + 0.5 - H/2 (render.c; the >> 1 of an odd
// multiple is off by half a unit at most). A point P = a F + b R + c U is on that ray for
// kx = b / a and ky = -c / a, and a, b, c times det = F . (R x U) are P . (R x U), P . (U x F)
// and P . (F x R). Those cross products are exact integers (R, U < 2^10, F <= 2^16); ent_dz
// is R x U, ent_dx and ent_dy the others shifted right by ent_dsh to stay below 2^20.
// game.c view_vectors makes right x up = forward, so det > 0 and a > 0 in front of the eye.
static q16 ent_dx[3], ent_dy[3], ent_dz[3];
static int32_t ent_dsh;

__attribute__((noinline)) static void cross(const int32_t *u, const int32_t *v, q16 *w, int32_t sh) {
    for (int32_t i = 0; i < 3; i++) {
        int32_t j = i == 2 ? 0 : i + 1, k = i == 0 ? 2 : i - 1;
        w[i] = (u[j] * v[k] - u[k] * v[j]) >> sh;   // |u|, |v| <= 2^16, one of them < 2^10
    }
}

static void screen_rect(ent_box *b) {
    const kc_rparams *p = KC_RP;
    int32_t W = p->width, H = p->height;
    // A corner's coordinate on axis a is lo[a] or hi[a] (eye-relative), so each of the 12
    // products has only two values per box: compute those 24 once and add them up per corner.
    q16 px[3][2], py[3][2], pz[3][2], pa[3][2];
    for (int32_t a = 0; a < 3; a++) {
        pz[a][0] = qmul(b->lo[a] >> ent_sh,KC_CAM->forward[a]); pz[a][1] = qmul(b->hi[a] >> ent_sh,KC_CAM->forward[a]);
    }
    // Wholly behind the eye: every ray has a positive forward component and a hit needs t >= 0,
    // so no ray can reach the box. Cull it (the margin covers qmul rounding) instead of
    // letting the near-plane case below cover the whole screen with it.
    int32_t behind = 0;
    q16 zmin = 0x7FFFFFFF;
    for (int32_t k = 0; k < 8; k++) {
        q16 z = pz[0][k & 1] + pz[1][(k >> 1) & 1] + pz[2][(k >> 2) & 1];
        behind += z < -16;
        zmin = imin(zmin, z);
    }
    // Every ray's forward component is 1 (right and up are perpendicular to forward), so a hit
    // on the box has t >= its nearest corner depth. The margin (1/16 of the depth plus a
    // quarter block) covers qmul rounding in z and in the ray directions.
    b->zlim = zmin - (zmin >> 4) - Q16(0.25);
    if (behind == 8) { b->sx0 = 1; b->sx1 = 0; b->sy0 = b->sy1 = 0; return; }
    for (int32_t a = 0; a < 3; a++)
        for (int32_t h = 0; h < 2; h++) {
            q16 r = (h ? b->hi[a] : b->lo[a]) >> ent_sh;   // eye-relative already
            px[a][h] = qmul(r,ent_dx[a]); py[a][h] = qmul(r,ent_dy[a]); pa[a][h] = qmul(r,ent_dz[a]);
        }
    q16 lim = Q16_INT(4096) >> ent_dsh;
    q16 kx0 = lim, ky0 = lim, kx1 = -lim, ky1 = -lim;
    for (int32_t k = 0; k < 8; k++) {
        int32_t i0 = k & 1, i1 = (k >> 1) & 1, i2 = (k >> 2) & 1;
        q16 z = pz[0][i0] + pz[1][i1] + pz[2][i2];
        if (z < Q16(0.05)) {
            b->sx0 = b->sy0 = 0; b->sx1 = W - 1; b->sy1 = H - 1;
            return;
        }
        q16 ia = qrcp(pa[0][i0] + pa[1][i1] + pa[2][i2]);
        q16 kx = iclamp(qmul(px[0][i0] + px[1][i1] + px[2][i2], ia), -lim, lim);
        q16 ky = iclamp(qmul(py[0][i0] + py[1][i1] + py[2][i2], ia), -lim, lim);
        kx0 = imin(kx0,kx); kx1 = imax(kx1,kx); ky0 = imin(ky0,ky); ky1 = imax(ky1,ky);
    }
    // In pixels, kx = (b / a) << ent_dsh and ky = -(c / a) << ent_dsh (rounding: under 1/32
    // pixel at z >= 0.05, ray and box_hit rounding less). The box's pixels are the rays
    // through its corners' hull: x + 0.5 - W/2 in [kx0, kx1], so x in
    // [ceil(kx0 + W/2 - 0.5), floor(kx1 + W/2 - 0.5)], widened by 1/8 pixel for all that.
    q16 ox = Q16_INT(W >> 1) - Q16_HALF, oy = Q16_INT(H >> 1) - Q16_HALF, m = Q16(0.125);  // W, H > 0: >> 1 is / 2
    int32_t x0 = ((kx0 << ent_dsh) + ox - m + 0xFFFF) >> 16, x1 = ((kx1 << ent_dsh) + ox + m) >> 16;
    int32_t y0 = (oy - (ky1 << ent_dsh) - m + 0xFFFF) >> 16, y1 = (oy - (ky0 << ent_dsh) + m) >> 16;
    if (x1 < 0 || y1 < 0 || x0 >= W || y0 >= H || x0 > x1 || y0 > y1) {
        b->sx0 = 1; b->sx1 = 0; b->sy0 = b->sy1 = 0;
        return;
    }
    b->sx0 = iclamp(x0,0,W-1); b->sx1 = iclamp(x1,0,W-1);
    b->sy0 = iclamp(y0,0,H-1); b->sy1 = iclamp(y1,0,H-1);
}

void entity_prepare(void) {
    ent_nboxes = 0;
    const kc_camera *cam = KC_CAM;
    int32_t m = 0, sh = 0;                           // |U x F| <= 2 * max(|R|, |U|) * 2^16
    for (int32_t a = 0; a < 3; a++) m |= iabs(cam->up_step[a]) | iabs(cam->right_step[a]);
    while ((m << 17) >> sh >= 1 << 20) sh++;
    ent_dsh = sh;
    cross(cam->right_step, cam->up_step, ent_dz, 0);
    cross(cam->up_step, cam->forward, ent_dx, sh);
    cross(cam->forward, cam->right_step, ent_dy, sh);
    int32_t cx = KC_RP->corner_x, cz = KC_RP->corner_z;
    q16 e[3] = {KC_CAM->origin[0]-Q16_INT(cx),KC_CAM->origin[1],KC_CAM->origin[2]-Q16_INT(cz)};
    // ent_sh: a part reaches less than 2.2 blocks from its entity's feet, so feet less than 64
    // blocks from the eye on every axis keep every bound inside +-128 blocks (2^23).
#if KC_ENT_FAST
    uint32_t far = 0;
    for (int32_t i = 0; i < nents; i++) {
        if ((uint32_t)(qfloor(ents[i].pos[0])-cx) > 63u ||
            (uint32_t)(qfloor(ents[i].pos[2])-cz) > 63u) continue;
        q16 f[3] = {ents[i].pos[0] - Q16_INT(cx) - e[0], ents[i].pos[1] - e[1],
                    ents[i].pos[2] - Q16_INT(cz) - e[2]};
        for (int32_t a = 0; a < 3; a++) far |= (uint32_t)(f[a] ^ (f[a] >> 31));  // >= |f| - 1
    }
    ent_sh = sel(far >> 22 != 0, 0, 8);
#endif
    for (int32_t i = 0; i < nents; i++) {
        if ((uint32_t)(qfloor(ents[i].pos[0])-cx) > 63u ||
            (uint32_t)(qfloor(ents[i].pos[2])-cz) > 63u) continue;
        int32_t kind = ents[i].kind, facing = ents[i].facing;
        for (int32_t j = 0; j < models[kind].n; j++) {
            const ent_part *p = &models[kind].parts[j];
            int32_t x0 = p->x0, z0 = p->z0, x1 = p->x1, z1 = p->z1;
            int32_t rx0, rz0, rx1, rz1;
            switch (facing) {
            case 1: rx0=z0; rz0=-x0; rx1=z1; rz1=-x1; break;
            case 2: rx0=-x0; rz0=-z0; rx1=-x1; rz1=-z1; break;
            case 3: rx0=-z0; rz0=x0; rx1=-z1; rz1=x1; break;
            default: rx0=x0; rz0=z0; rx1=x1; rz1=z1; break;
            }
            ent_box *b = &ent_boxes[ent_nboxes++];
            b->lo[0] = (q16)((uint32_t)((ents[i].pos[0] + imin(rx0,rx1)*4096 - Q16_INT(cx)) - e[0]) << ent_sh);
            b->hi[0] = (q16)((uint32_t)((ents[i].pos[0] + imax(rx0,rx1)*4096 - Q16_INT(cx)) - e[0]) << ent_sh);
            b->lo[1] = (q16)((uint32_t)((ents[i].pos[1] + p->y0*4096) - e[1]) << ent_sh);
            b->hi[1] = (q16)((uint32_t)((ents[i].pos[1] + p->y1*4096) - e[1]) << ent_sh);
            b->lo[2] = (q16)((uint32_t)((ents[i].pos[2] + imin(rz0,rz1)*4096 - Q16_INT(cz)) - e[2]) << ent_sh);
            b->hi[2] = (q16)((uint32_t)((ents[i].pos[2] + imax(rz0,rz1)*4096 - Q16_INT(cz)) - e[2]) << ent_sh);
            b->color = (uint16_t)(0x100 | (p->color == ROBE ? models[kind].robe : p->color) << 4);
            screen_rect(b);
        }
    }
    // Row spans: block row r (pixels 2r, 2r + 1) overlaps rect rows [u1, u3] when
    // 2r + 1 >= u1 and 2r <= u3, i.e. r in [u1 >> 1, u3 >> 1] (u1 >= 0): walk only those rows.
    int32_t rows = KC_RP->height >> 1;
    // Block columns: block bx = 4c overlaps rect columns [u0, u2] for c in [u0 >> 2, u2 >> 2].
    for (int32_t r = 0; r < rows; r++) {
        ent_span[r][0] = 4096; ent_span[r][1] = -4096;
        ent_bits[r][0] = ent_bits[r][1] = ent_bits[r][2] = 0;
        ent_bin_n[r] = 0;
        ent_bits[r][3] = 0x7FFFFFFF;
    }
    ent_row0 = rows; ent_row1 = 0;
    // Per box, not per entity rect: blocks in a rect's empty corners call nothing.
    for (int32_t i = 0; i < ent_nboxes; i++) {
        ent_box *bb = &ent_boxes[i];
        if (bb->sx0 > bb->sx1) continue;
        const int16_t u[4] = {bb->sx0, bb->sy0, bb->sx1, bb->sy1};
        int32_t r0 = u[1] >> 1, r1 = imin(u[3] >> 1, rows - 1);
        ent_row0 = imin(ent_row0, r0); ent_row1 = imax(ent_row1, r1 + 1);
        int32_t c0 = u[0] >> 2, c1 = u[2] >> 2;
        uint32_t m[3];                               // this rect's block columns as word masks
        for (int32_t w = 0; w < 3; w++) {
            int32_t lo = imax(c0 - 32 * w, 0), hi = imin(c1 - 32 * w, 31);
            m[w] = lo > hi ? 0u : (((2u << hi) - 1u) & ~((1u << lo) - 1u));
        }
        for (int32_t r = r0; r <= r1; r++) {
            ent_span[r][0] = (int16_t)imin(ent_span[r][0], u[0]);
            ent_span[r][1] = (int16_t)imax(ent_span[r][1], u[2]);
            ent_bits[r][0] |= m[0]; ent_bits[r][1] |= m[1]; ent_bits[r][2] |= m[2];
            ent_bin[r][ent_bin_n[r]++] = (uint8_t)i;
            ent_bits[r][3] = (uint32_t)imin((q16)ent_bits[r][3], bb->zlim);
        }
        bb->sx0 -= 3;                                // box_live tests the block's left column
    }
}

static inline q16 slab_t(q16 dist, q16 inv) {
    int64_t p = ((int64_t)dist * inv) >> 16;
    int32_t top = (int32_t)(p >> 31);
    int32_t ovf = (uint32_t)(top + 1) > 1u;
    return sel(ovf,sel(top < 0,-Q16_BIG,Q16_BIG),(q16)p);
}
static inline q16 smin(q16 a, q16 b) { return sel(a < b,a,b); }

// All ones for v < 0. On the chip, volatile so it stays in the box loop: hoisted, the step
// masks would cost more saved registers per call than the shifts cost per box.
static inline q16 sign_mask(q16 v) {
#ifdef __riscv
    q16 m;
    __asm__ volatile("srai %0, %1, 31" : "=r"(m) : "r"(v));
    return m;
#else
    return v >> 31;
#endif
}

// One box against one ray, everything in registers. Box bounds are eye-relative (the window
// origin o of the kernel equals entity_prepare's e) and stored << ent_sh, ts = tDelta (1/|d|
// per axis) negated where the ray steps negative, ys = the y face's shade << 2. Same values
// as slab_t(n ? -hi : lo, td) and slab_t(n ? -lo : hi, td) on the unshifted bounds: the
// products are equal, and as ts > 0 or ts < 0 the near one is the smaller (slab_t is
// monotone). sh < 0 (fast): ts is << 8 too, and one MULH is the exact >> 16 (see ent_sh).
// Else slab_t on the bounds >> sh: rare (far entities or huge tDeltas), so a rolled loop.
static inline __attribute__((always_inline))
void box_hit(int32_t sh, const ent_box *b, const q16 ts[3], int32_t ys, q16 *ht, int32_t *hcol) {
    q16 w[6];
    if (KC_ENT_FAST && sh < 0) {
        for (int32_t a = 0; a < 3; a++) {
            w[a] = (q16)(((int64_t)b->lo[a] * ts[a]) >> 32); w[a + 3] = (q16)(((int64_t)b->hi[a] * ts[a]) >> 32);
        }
    } else {
        _Pragma("GCC unroll 1")
        for (int32_t a = 0; a < 3; a++) {
            w[a] = slab_t(b->lo[a] >> sh,ts[a]); w[a + 3] = slab_t(b->hi[a] >> sh,ts[a]);
        }
    }
    q16 tn[3], tf[3];
    for (int32_t a = 0; a < 3; a++) { tn[a] = smin(w[a],w[a + 3]); tf[a] = w[a] ^ w[a + 3] ^ tn[a]; }
    // near = max(tn) and its face (ties to x, then y): x when tn0 >= tn1, tn2; else y when
    // tn1 >= tn2; else z. Shade << 2: x 4, y ys, z 8.
    int32_t z12 = tn[1] < tn[2], nx = (tn[0] < tn[1]) | (tn[0] < tn[2]);
    q16 nyz = sel(z12,tn[2],tn[1]), near = sel(nx,nyz,tn[0]);
    int32_t shade4 = sel(nx,sel(z12,8,ys),4);
    // near < far = min(tf), and 0 <= near < *ht as one unsigned compare: *ht >= 0 (the world's
    // t is in [0, 0x7FFF_FFFF], and a box's win sets it to near >= 0).
    int32_t win = ((uint32_t)near < (uint32_t)*ht) & (near < tf[0]) & (near < tf[1]) & (near < tf[2]);
    *ht = sel(win,near,*ht);
    *hcol = sel(win,b->color | shade4,*hcol);        // bit 8 set: fog added once, after the loop
}

// 1 if box b can win at block column bx for some lane with current nearest hit t: its
// columns overlap the block (the bin already matched the rows; sx0 is stored - 3) and some
// lane's t is beyond its zlim (a hit on it has near > zlim, and wins only at near < t).
// BALLOT makes the test uniform across the lanes.
static inline __attribute__((always_inline)) int32_t box_live(const ent_box *b, int32_t bx, q16 t) {
    return !((bx < b->sx0) | (bx > b->sx1)) && ballot(t > b->zlim);
}

// From the first live box k to the bin's end e; t0..t2 = ts and sh as in box_hit, sc = col |
// (sh & 0xFF) << 8. A negated td of 0 loses its sign, but then that axis has tn = tf = 0 and
// near < tf fails for near >= 0, whatever the y shade.
// Separate from ent_composite, so the scan there runs before any register is saved.
__attribute__((noinline)) static uint8_t composite(const uint8_t *k, const uint8_t *e, int32_t bx,
                                                   q16 t0, q16 t1, q16 t2, q16 tw, uint32_t sc) {
    q16 ts[3] = {t0, t1, t2};
    int32_t ys = ~sign_mask(t1) & 12, c = (int32_t)(sc & 0xFF), sh = (int32_t)sc >> 8;
    q16 t = tw;
    for (;;) {
        box_hit(sh, &ent_boxes[*k], ts, ys, &t, &c);
        do if (++k == e) goto done; while (!box_live(&ent_boxes[*k], bx, t));
    }
done:;
    // Bit 8: a box won, so c lacks the fog level of its distance t.
    const q16 *fog = KC_RP->fog_d;
    int32_t fl = (t >= fog[0]) + (t >= fog[1]) + (t >= fog[2]);
    return (uint8_t)(c | (fl & -(c >> 8)));
}

uint8_t ent_composite(int32_t bx, int32_t by, q16 tdx, q16 tdy, q16 tdz, uint32_t signs,
                      q16 tw, uint8_t col) {
    // The skips branch per lane, but every lane of a 4x2 block has the same (bx, by), so
    // they are uniform. A different lane layout would make them divergent.
    // Only the boxes binned to this block row; none live (columns, or hidden): col stays.
    const uint8_t *k = ent_bin[by >> 1], *e = k + ent_bin_n[by >> 1];
    for (; k < e && !box_live(&ent_boxes[*k], bx, tw); k++) {}
    if (k == e) return col;
    // Uniform: the fast path needs every lane's tDeltas < 2^23 (ent_sh).
    int32_t fast = KC_ENT_FAST && ent_sh && !ballot((uint32_t)(tdx | tdy | tdz) >> 23 != 0);
    int32_t s = fast ? 8 : 0, sh = fast ? -1 : ent_sh;
    int32_t m0 = -(int32_t)(signs & 1), m1 = -(int32_t)((signs >> 1) & 1), m2 = -(int32_t)((signs >> 2) & 1);
    return composite(k, e, bx, ((tdx << s) ^ m0) - m0, ((tdy << s) ^ m1) - m1, ((tdz << s) ^ m2) - m2,
                     tw, col | (uint32_t)sh << 8);
}
