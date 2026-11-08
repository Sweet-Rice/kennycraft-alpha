#include "entity.h"
#include "kc_hal.h"
#include "render.h"
#include "chunks.h"
#include "blocks.h"

static struct { q16 pos[3], tgt[2]; uint8_t kind, facing; } ents[ENT_MAX];
static int32_t nents;
static const q16 walk_speed[ENT_KINDS] = {Q16(1.5), Q16(1.5), Q16(1.0), Q16(1.2)};   // blocks per second
ent_box ent_boxes[ENT_BOX_MAX];
int32_t ent_nboxes;
static int16_t ent_rects[ENT_MAX][4];   // x0, y0, x1, y1 inclusive: union of one entity's boxes
int32_t ent_nrects;
int16_t ent_span[ENT_ROWS][2];
static uint8_t ent_rect_box[ENT_MAX][2];  // [first, end) of each rect's boxes in ent_boxes

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

static void screen_rect(ent_box *b, const q16 e[3]) {
    const kc_rparams *p = KC_RP;
    int32_t W = p->width, H = p->height, w2 = W / 2, h2 = H / 2;
    q16 focal = p->focal;
    // A corner's coordinate on axis a is lo[a] - e[a] or hi[a] - e[a], so each of the 9
    // camera-axis products has only two values per box: compute those 18 once and add them up
    // per corner, in the same order as before (identical sums).
    q16 px[3][2], py[3][2], pz[3][2];
    for (int32_t a = 0; a < 3; a++) {
        q16 rl = b->lo[a] - e[a], rh = b->hi[a] - e[a];
        q16 ra = p->right[a], ua = p->up[a], fa = KC_CAM->forward[a];
        px[a][0] = qmul(rl,ra); px[a][1] = qmul(rh,ra);
        py[a][0] = qmul(rl,ua); py[a][1] = qmul(rh,ua);
        pz[a][0] = qmul(rl,fa); pz[a][1] = qmul(rh,fa);
    }
    int32_t x0 = 4096, y0 = 4096, x1 = -4096, y1 = -4096;
    for (int32_t k = 0; k < 8; k++) {
        int32_t i0 = k & 1, i1 = (k >> 1) & 1, i2 = (k >> 2) & 1;
        q16 x = px[0][i0] + px[1][i1] + px[2][i2];
        q16 y = py[0][i0] + py[1][i1] + py[2][i2];
        q16 z = pz[0][i0] + pz[1][i1] + pz[2][i2];
        if (z < Q16(0.05)) {
            b->sx0 = b->sy0 = 0; b->sx1 = W - 1; b->sy1 = H - 1;
            return;
        }
        q16 iz = qrcp(z);
        int32_t sx = w2 + iclamp(qmul(qmul(x,focal),iz) >> 16,-4096,4096);
        int32_t sy = h2 - iclamp(qmul(qmul(y,focal),iz) >> 16,-4096,4096);
        x0 = imin(x0,sx); x1 = imax(x1,sx); y0 = imin(y0,sy); y1 = imax(y1,sy);
    }
    x0 -= 2; y0 -= 2; x1 += 2; y1 += 2;
    if (x1 < 0 || y1 < 0 || x0 >= p->width || y0 >= p->height) {
        b->sx0 = 1; b->sx1 = 0; b->sy0 = b->sy1 = 0;
        return;
    }
    b->sx0 = iclamp(x0,0,p->width-1); b->sx1 = iclamp(x1,0,p->width-1);
    b->sy0 = iclamp(y0,0,p->height-1); b->sy1 = iclamp(y1,0,p->height-1);
}

void entity_prepare(void) {
    ent_nboxes = ent_nrects = 0;
    int32_t cx = KC_RP->corner_x, cz = KC_RP->corner_z;
    q16 e[3] = {KC_CAM->origin[0]-Q16_INT(cx),KC_CAM->origin[1],KC_CAM->origin[2]-Q16_INT(cz)};
    for (int32_t i = 0; i < nents; i++) {
        if ((uint32_t)(qfloor(ents[i].pos[0])-cx) > 63u ||
            (uint32_t)(qfloor(ents[i].pos[2])-cz) > 63u) continue;
        int32_t kind = ents[i].kind, facing = ents[i].facing;
        int16_t *u = ent_rects[ent_nrects];
        u[0] = u[1] = 4096; u[2] = u[3] = -1;
        int32_t first = ent_nboxes;
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
            b->lo[0] = ents[i].pos[0] + imin(rx0,rx1)*4096 - Q16_INT(cx);
            b->hi[0] = ents[i].pos[0] + imax(rx0,rx1)*4096 - Q16_INT(cx);
            b->lo[1] = ents[i].pos[1] + p->y0*4096;
            b->hi[1] = ents[i].pos[1] + p->y1*4096;
            b->lo[2] = ents[i].pos[2] + imin(rz0,rz1)*4096 - Q16_INT(cz);
            b->hi[2] = ents[i].pos[2] + imax(rz0,rz1)*4096 - Q16_INT(cz);
            b->color = p->color == ROBE ? models[kind].robe : p->color;
            screen_rect(b,e);
            if (b->sx0 > b->sx1) continue;
            u[0] = imin(u[0],b->sx0); u[1] = imin(u[1],b->sy0);
            u[2] = imax(u[2],b->sx1); u[3] = imax(u[3],b->sy1);
        }
        ent_rect_box[ent_nrects][0] = (uint8_t)first; ent_rect_box[ent_nrects][1] = (uint8_t)ent_nboxes;
        ent_nrects += u[0] <= u[2];
    }
    // Row spans: block row r (pixels 2r, 2r + 1) overlaps rect rows [u1, u3] when
    // 2r + 1 >= u1 and 2r <= u3, i.e. r in [u1 >> 1, u3 >> 1] (u1 >= 0): walk only those rows.
    int32_t rows = KC_RP->height >> 1;
    for (int32_t r = 0; r < rows; r++) { ent_span[r][0] = 4096; ent_span[r][1] = -4096; }
    for (int32_t i = 0; i < ent_nrects; i++) {
        const int16_t *u = ent_rects[i];
        int32_t r0 = u[1] >> 1, r1 = imin(u[3] >> 1, rows - 1);
        for (int32_t r = r0; r <= r1; r++) {
            ent_span[r][0] = (int16_t)imin(ent_span[r][0], u[0]);
            ent_span[r][1] = (int16_t)imax(ent_span[r][1], u[2]);
        }
    }
}

int32_t ent_block(int32_t bx, int32_t by) {
    for (int32_t i = 0; i < ent_nrects; i++) {
        const int16_t *u = ent_rects[i];
        if (bx+3 >= u[0] && bx <= u[2] && by+1 >= u[1] && by <= u[3]) return 1;
    }
    return 0;
}

static inline q16 slab_t(q16 dist, q16 inv) {
    int64_t p = ((int64_t)dist * inv) >> 16;
    int32_t top = (int32_t)(p >> 31);
    int32_t ovf = (uint32_t)(top + 1) > 1u;
    return sel(ovf,sel(top < 0,-Q16_BIG,Q16_BIG),(q16)p);
}
static inline q16 smin(q16 a, q16 b) { return sel(a < b,a,b); }
static inline q16 smax(q16 a, q16 b) { return sel(a > b,a,b); }

// One box against one ray, everything in registers: o = window-relative eye, td = tDelta
// (1/|d| per axis), n = step signs, fog = KC_RP fog_d. Same arithmetic as before.
static inline __attribute__((always_inline))
void box_hit(const ent_box *b, const q16 o[3], const q16 td[3], const int32_t n[3],
             const q16 fog[3], q16 *ht, int32_t *hcol) {
    q16 lo0 = b->lo[0] - o[0], hi0 = b->hi[0] - o[0];
    q16 lo1 = b->lo[1] - o[1], hi1 = b->hi[1] - o[1];
    q16 lo2 = b->lo[2] - o[2], hi2 = b->hi[2] - o[2];
    q16 tn0 = slab_t(sel(n[0],-hi0,lo0),td[0]), tf0 = slab_t(sel(n[0],-lo0,hi0),td[0]);
    q16 tn1 = slab_t(sel(n[1],-hi1,lo1),td[1]), tf1 = slab_t(sel(n[1],-lo1,hi1),td[1]);
    q16 tn2 = slab_t(sel(n[2],-hi2,lo2),td[2]), tf2 = slab_t(sel(n[2],-lo2,hi2),td[2]);
    q16 near = smax(tn0,smax(tn1,tn2)), far = smin(tf0,smin(tf1,tf2));
    int32_t isx = (tn0 >= tn1) & (tn0 >= tn2), isy = (isx ^ 1) & (tn1 >= tn2);
    int32_t shade = sel(isy,sel(n[1],0,3),sel(isx,1,2));
    int32_t fl = (near >= fog[0]) + (near >= fog[1]) + (near >= fog[2]);
    int32_t win = (near >= 0) & (near < far) & (near < *ht);
    *ht = sel(win,near,*ht);
    *hcol = sel(win,PIX(b->color,shade,fl),*hcol);
}

static void ray_regs(const kc_ray *r, q16 td[3], int32_t n[3], q16 fog[3]) {
    td[0] = (q16)r->f[4]; td[1] = (q16)r->f[5]; td[2] = (q16)r->f[6];
    n[0] = r->f[7] & 1; n[1] = (r->f[7] >> 1) & 1; n[2] = (r->f[7] >> 2) & 1;
    fog[0] = KC_RP->fog_d[0]; fog[1] = KC_RP->fog_d[1]; fog[2] = KC_RP->fog_d[2];
}

uint8_t ent_composite(int32_t px, int32_t py, const q16 o[3], const kc_ray *r, q16 tw, uint8_t col) {
    // The skips below branch per lane, but every lane of a 4x2 block computes the same
    // (bx, by), so they are uniform. A different lane layout would make them divergent.
    int32_t bx = px & ~3, by = py & ~1;
    q16 oo[3] = {o[0], o[1], o[2]}, td[3], fog[3];
    int32_t n[3];
    ray_regs(r, td, n, fog);
    q16 t = tw;
    int32_t c = col;
    for (int32_t e = 0; e < ent_nrects; e++) {         // whole entity first, then its boxes
        const int16_t *u = ent_rects[e];
        if ((bx+3 < u[0]) | (bx > u[2]) | (by+1 < u[1]) | (by > u[3])) continue;
        for (int32_t i = ent_rect_box[e][0]; i < ent_rect_box[e][1]; i++) {
            const ent_box *b = &ent_boxes[i];
            if ((bx+3 < b->sx0) | (bx > b->sx1) | (by+1 < b->sy0) | (by > b->sy1)) continue;
            box_hit(b, oo, td, n, fog, &t, &c);
        }
    }
    return (uint8_t)c;
}
