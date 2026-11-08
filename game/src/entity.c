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

enum { C_BLACK = 0, C_GRASS_L = 1, C_GRASS_D = 2, C_DIRT_L = 3,
       C_STONE_D = 6, C_SAND = 9, C_BRICK = 11, C_WOOD_L = 13 };
#define ROBE 15
// Local coordinates in sixteenths of a block; +z is the front.
typedef struct { int8_t x0, y0, z0, x1, y1, z1; uint8_t color; } ent_part;
static const ent_part villager_parts[7] = {
    {-4, 0,-3, 4,24,3,ROBE},
    {-4,24,-4, 4,34,4,C_DIRT_L},
    {-1,25, 4, 1,29,6,C_DIRT_L},
    {-3,29, 4,-1,30,5,C_GRASS_D},
    { 1,29, 4, 3,30,5,C_GRASS_D},
    {-6,15, 3, 6,19,7,ROBE},
    {-2,15, 7, 2,19,8,C_DIRT_L},
};
static const ent_part pig_parts[9] = {
    {-5, 6,-8, 5,14, 8,C_SAND},
    {-4, 7, 8, 4,15,14,C_SAND},
    {-2, 8,14, 2,11,15,C_BRICK},
    {-4,12,14,-2,13,15,C_BLACK},
    { 2,12,14, 4,13,15,C_BLACK},
    {-5, 0, 5,-2, 6, 8,C_SAND},
    { 2, 0, 5, 5, 6, 8,C_SAND},
    {-5, 0,-8,-2, 6,-5,C_SAND},
    { 2, 0,-8, 5, 6,-5,C_SAND},
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
    {pig_parts,9,0}, {zombie_parts,7,0}
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
    int32_t x0 = 4096, y0 = 4096, x1 = -4096, y1 = -4096;
    for (int32_t k = 0; k < 8; k++) {
        q16 r[3];
        for (int32_t a = 0; a < 3; a++) r[a] = (((k >> a) & 1) ? b->hi[a] : b->lo[a]) - e[a];
        q16 x = qmul(r[0],p->right[0]) + qmul(r[1],p->right[1]) + qmul(r[2],p->right[2]);
        q16 y = qmul(r[0],p->up[0]) + qmul(r[1],p->up[1]) + qmul(r[2],p->up[2]);
        q16 z = qmul(r[0],KC_CAM->forward[0]) + qmul(r[1],KC_CAM->forward[1]) + qmul(r[2],KC_CAM->forward[2]);
        if (z < Q16(0.05)) {
            b->sx0 = b->sy0 = 0; b->sx1 = p->width - 1; b->sy1 = p->height - 1;
            return;
        }
        q16 iz = qrcp(z);
        int32_t sx = p->width / 2 + iclamp(qmul(qmul(x,p->focal),iz) >> 16,-4096,4096);
        int32_t sy = p->height / 2 - iclamp(qmul(qmul(y,p->focal),iz) >> 16,-4096,4096);
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
        ent_nrects += u[0] <= u[2];
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

__attribute__((noinline))
void ent_box_hit(const ent_box *b, const q16 o[3], const kc_ray *r, ent_hit *h) {
    int32_t nx = r->f[7] & 1, ny = (r->f[7] >> 1) & 1, nz = (r->f[7] >> 2) & 1;
    q16 tn0 = slab_t(sel(nx,o[0]-b->hi[0],b->lo[0]-o[0]),(q16)r->f[4]);
    q16 tf0 = slab_t(sel(nx,o[0]-b->lo[0],b->hi[0]-o[0]),(q16)r->f[4]);
    q16 tn1 = slab_t(sel(ny,o[1]-b->hi[1],b->lo[1]-o[1]),(q16)r->f[5]);
    q16 tf1 = slab_t(sel(ny,o[1]-b->lo[1],b->hi[1]-o[1]),(q16)r->f[5]);
    q16 tn2 = slab_t(sel(nz,o[2]-b->hi[2],b->lo[2]-o[2]),(q16)r->f[6]);
    q16 tf2 = slab_t(sel(nz,o[2]-b->lo[2],b->hi[2]-o[2]),(q16)r->f[6]);
    q16 near = smax(tn0,smax(tn1,tn2)), far = smin(tf0,smin(tf1,tf2));
    int32_t isx = (tn0 >= tn1) & (tn0 >= tn2), isy = (isx ^ 1) & (tn1 >= tn2);
    int32_t shade = sel(isy,sel(ny,0,3),sel(isx,1,2));
    int32_t fog = (near >= KC_RP->fog_d[0]) + (near >= KC_RP->fog_d[1]) + (near >= KC_RP->fog_d[2]);
    int32_t win = (near >= 0) & (near < far) & (near < h->t);
    h->t = sel(win,near,h->t);
    h->col = sel(win,PIX(b->color,shade,fog),h->col);
}

uint8_t ent_composite(int32_t px, int32_t py, const q16 o[3], const kc_ray *r, q16 tw, uint8_t col) {
    // The box skip below branches per lane, but every lane of a 4x2 block computes the same
    // (bx, by), so it is uniform. A different lane layout would make it divergent.
    ent_hit h = {tw,col};
    int32_t bx = px & ~3, by = py & ~1;
    for (int32_t i = 0; i < ent_nboxes; i++) {
        const ent_box *b = &ent_boxes[i];
        if ((bx+3 < b->sx0) | (bx > b->sx1) | (by+1 < b->sy0) | (by > b->sy1)) continue;
        ent_box_hit(b,o,r,&h);
    }
    return (uint8_t)h.col;
}
