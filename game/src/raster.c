// raster.c — tile-based rasterizer. Fixed point, no divide instruction, branch-free per pixel.
#include "raster.h"
#include "mesh.h"
#include "chunks.h"
#include "blocks.h"
#include "render.h"
#include "kc_hal.h"
#include "kc_lanes.h"
#include "fixed.h"
#include "kc_budget.h"
#include "arena.h"

#ifdef KC_HOST
#define GPUMEM
#else
#define GPUMEM __attribute__((section(".gpumem")))
#endif

#define NEAR   Q16(0.05)
#define TAN_X  45889               // tan(35 deg), Q16: half-width / focal
#define TAN_Y  34418               // half-height / focal (4:3)
#define MAX_TILES 300              // 20 x 15 at 320x240
#define MAX_POLY 12
#define EDGE_GROW 2                // subpixels; 2 closes every T-junction crack in the golden shots




#ifdef KC_HOST
raster_stats_t raster_stats;
#define STAT(x) (x)
#else
#define STAT(x) ((void)0)
#endif

// ---- command lists (per frame) -------------------------------------------------------------
GPUMEM static uint32_t vis_ref[RASTER_VIS_CAP];   // slot << 16 | page << 8 | quad
GPUMEM static uint32_t vis_box[RASTER_VIS_CAP];   // tile bbox: tx0 | ty0 << 8 | tx1 << 16 | ty1 << 24
GPUMEM static uint16_t bin_entry[RASTER_BIN_CAP]; // index into vis_*
static uint16_t tile_start[MAX_TILES + 1];
// Per-tile counts / fill cursors: binning only (lane 0), so frame scratch from the arena.
static uint16_t *tile_fill;

// ---- tile memory: 16 x 16 x (2-byte color + 2-byte depth) = 1 KB, +1 scratch slot ----------
// One 32-bit word per pixel (Josh's layout): color 11:0 (the 8-bit palette index, 4 spare
// bits), depth 23:12 (12-bit linear, 1/64 block), stencil 31:24 (unused for now, kept 0).
// One load and one masked store per pixel instead of three halfword operations.
#define PX_COLOR(w)   ((w) & 0xFFFu)
#define PX_DEPTH(w)   (((w) >> 12) & 0xFFFu)
#define PX_STENCIL(w) ((w) >> 24)
#define PX_PACK(c, d, s) ((uint32_t)(c) | ((uint32_t)(d) << 12) | ((uint32_t)(s) << 24))
#define DEPTH_MAX 0xFFFu
static uint32_t tile_px[TILE * TILE + 1];          // 1 KB + 1 scratch word

// One polygon vertex, two stages in the same five words: view space + texture coords (blocks)
// while clipping, then the screen vertex project() writes over it in place. Sharing the buffer
// keeps quad_to_screen off a second MAX_POLY array: the kernel runs it on every lane's 1 KB stack.
typedef union {
    struct { q16 x, y, z, u, v; };                 // pvert: view space
    struct { int32_t X, Y; q16 iz, uz, vz; };      // svert: Q4 subpixels, clamped; 1/z, u/z, v/z
} vert;
typedef vert pvert;
typedef vert svert;

typedef struct {
    int32_t ox, oz;                               // chunk corner in window coordinates
    q16 eye[3], fwd[3], right[3], up[3];
    int32_t W, H, focal;
} view_t;

// ---------------------------------------------------------------- geometry ----------------
static void quad_verts(const view_t *vw, int32_t page, int32_t q, pvert out[4], int32_t *mat) {
    const mesh_page *pg = &mesh_pool[page];
    int32_t m = pg->mat[q];
    int32_t a = (m & 7) >> 1;
    int32_t ua = a == 0 ? 2 : 0, va = a == 1 ? 2 : 1;
    // Polygon order from the shared index buffer (base vertex q * 4): triangles (i0 i1 i2)
    // and (i3 i4 i5) share i0 and i2, so the quad outline is i0 i1 i2 i5.
    const uint16_t *ix = mesh_quad_index;
    uint32_t base = (uint32_t)q * 4;
    uint16_t order[4] = { (uint16_t)(base + ix[0]), (uint16_t)(base + ix[1]), (uint16_t)(base + ix[2]), (uint16_t)(base + ix[5]) };
    for (int32_t i = 0; i < 4; i++) {
        uint16_t pv = pg->vtx[order[i]];
        q16 w[3] = { Q16_INT(VTX_X(pv) + vw->ox), Q16_INT(VTX_Y(pv)), Q16_INT(VTX_Z(pv) + vw->oz) };
        q16 r[3] = { w[0] - vw->eye[0], w[1] - vw->eye[1], w[2] - vw->eye[2] };
        out[i].x = qmul(r[0], vw->right[0]) + qmul(r[1], vw->right[1]) + qmul(r[2], vw->right[2]);
        out[i].y = qmul(r[0], vw->up[0])    + qmul(r[1], vw->up[1])    + qmul(r[2], vw->up[2]);
        out[i].z = qmul(r[0], vw->fwd[0])   + qmul(r[1], vw->fwd[1])   + qmul(r[2], vw->fwd[2]);
        out[i].u = w[ua];
        out[i].v = w[va];
    }
    *mat = m;
}

// Signed distance to frustum plane k (>= 0 inside): near, left, right, bottom, top.
static q16 plane_d(const pvert *p, int32_t k) {
    switch (k) {
    case 0:  return p->z - NEAR;
    case 1:  return qmul(p->z, TAN_X) + p->x;
    case 2:  return qmul(p->z, TAN_X) - p->x;
    case 3:  return qmul(p->z, TAN_Y) + p->y;
    default: return qmul(p->z, TAN_Y) - p->y;
    }
}

// Sutherland-Hodgman against the 5 planes. Returns the vertex count (0 = fully outside).
static int32_t clip_poly(pvert *poly, int32_t n) {
    pvert tmp[MAX_POLY];
    for (int32_t k = 0; k < 5 && n > 0; k++) {
        int32_t m = 0;
        for (int32_t i = 0; i < n; i++) {
            const pvert *a = &poly[i], *b = &poly[i + 1 == n ? 0 : i + 1];
            q16 da = plane_d(a, k), db = plane_d(b, k);
            if (da >= 0) tmp[m++] = *a;
            if ((da >= 0) != (db >= 0) && m < MAX_POLY) {
                // Signs differ, so |da| + |db| = |da - db| > 0 (idiv needs a positive divisor).
                q16 t = qdiv(iabs(da), iabs(da) + iabs(db));
                pvert *o = &tmp[m++];
                o->x = a->x + qmul(b->x - a->x, t);
                o->y = a->y + qmul(b->y - a->y, t);
                o->z = a->z + qmul(b->z - a->z, t);
                o->u = a->u + qmul(b->u - a->u, t);
                o->v = a->v + qmul(b->v - a->v, t);
            }
        }
        for (int32_t i = 0; i < m; i++) poly[i] = tmp[i];
        n = m;
    }
    return n;
}

// View-space vertex -> screen vertex (Q4 subpixels, clamped to the screen), in place.
static void project(const view_t *vw, vert *p) {
    q16 z = imax(p->z, NEAR);
    q16 iz = qrcp(z);
    q16 sx = qmul(qmul(p->x, vw->focal), iz);        // pixels from center, Q16
    q16 sy = qmul(qmul(p->y, vw->focal), iz);
    q16 uz = qmul(p->u, iz), vz = qmul(p->v, iz);    // every read before the first write
    p->X = iclamp(vw->W * 8 + (sx >> 12), 0, vw->W * 16);
    p->Y = iclamp(vw->H * 8 - (sy >> 12), 0, vw->H * 16);
    p->iz = iz;
    p->uz = uz;
    p->vz = vz;
}

// Transform + cull + clip one quad into a screen polygon in poly[MAX_POLY]. Returns the count.
static int32_t quad_to_screen(const view_t *vw, int32_t page, int32_t q, vert *poly, int32_t *mat) {
    quad_verts(vw, page, q, poly, mat);

    // Trivial accept / reject per plane
    int32_t all_in = 1;
    for (int32_t k = 0; k < 5; k++) {
        int32_t out_n = 0;
        for (int32_t i = 0; i < 4; i++) out_n += plane_d(&poly[i], k) < 0;
        if (out_n == 4) return 0;
        if (out_n) all_in = 0;
    }
    int32_t n = all_in ? 4 : clip_poly(poly, 4);
    for (int32_t i = 0; i < n; i++) project(vw, &poly[i]);
    return n;
}

static void view_init(view_t *vw) {
    const kc_camera *c = KC_CAM;
    const kc_rparams *p = KC_RP;
    for (int32_t i = 0; i < 3; i++) {
        vw->eye[i] = c->origin[i]; vw->fwd[i] = c->forward[i];   // absolute; made relative below
        vw->right[i] = p->right[i]; vw->up[i] = p->up[i];
    }
    vw->W = p->width; vw->H = p->height; vw->focal = p->focal;
    vw->eye[0] -= Q16_INT(p->corner_x);                       // window-relative eye
    vw->eye[2] -= Q16_INT(p->corner_z);
}

static void view_set_slot(view_t *vw, int32_t slot) {
    vw->ox = mesh_cmds[slot].cx * CHUNK_W - KC_RP->corner_x;
    vw->oz = mesh_cmds[slot].cz * CHUNK_W - KC_RP->corner_z;
}

// ---------------------------------------------------------------- 1. binning (lane 0) ----
static int32_t bin_frame(const view_t *vw0, int32_t tiles_x, int32_t tiles_y) {
    view_t vw = *vw0;
    int32_t nvis = 0, ntiles = tiles_x * tiles_y;
    tile_fill = (uint16_t *)arena_alloc(MAX_TILES * sizeof(uint16_t));
    for (int32_t t = 0; t < ntiles; t++) tile_fill[t] = 0;

    for (int32_t s = 0; s < 16; s++) {
        if (mesh_cmds[s].cx < 0) continue;
        view_set_slot(&vw, s);
        for (uint8_t pg = mesh_cmds[s].first_page; pg != MESH_NONE; pg = mesh_page_next[pg]) {
            const mesh_page *P = &mesh_pool[pg];
            for (int32_t q = 0; q < mesh_page_quads[pg]; q++) {
                // Back-face cull from the face direction alone: no transform needed.
                int32_t m = P->mat[q], face = m & 7, a = face >> 1;
                uint16_t v0 = P->vtx[q * 4];
                int32_t plane = a == 0 ? VTX_X(v0) + vw.ox : a == 1 ? VTX_Y(v0) : VTX_Z(v0) + vw.oz;
                q16 e = vw.eye[a], pl = Q16_INT(plane);
                if ((face & 1) ? e >= pl : e <= pl) { STAT(raster_stats.quads_culled++); continue; }

                svert sv[MAX_POLY];
                int32_t mat, n = quad_to_screen(&vw, pg, q, sv, &mat);
                if (n < 3) { STAT(raster_stats.quads_culled++); continue; }
                int32_t x0 = sv[0].X, x1 = sv[0].X, y0 = sv[0].Y, y1 = sv[0].Y;
                for (int32_t i = 1; i < n; i++) {
                    x0 = imin(x0, sv[i].X); x1 = imax(x1, sv[i].X);
                    y0 = imin(y0, sv[i].Y); y1 = imax(y1, sv[i].Y);
                }
                int32_t tx0 = x0 >> 8, ty0 = y0 >> 8;                       // Q4 / 16 px per tile
                int32_t tx1 = imin(x1 >> 8, tiles_x - 1), ty1 = imin(y1 >> 8, tiles_y - 1);
                if (nvis == RASTER_VIS_CAP) { STAT(raster_stats.vis_overflow++); continue; }
                vis_ref[nvis] = ((uint32_t)s << 16) | ((uint32_t)pg << 8) | (uint32_t)q;
                vis_box[nvis] = (uint32_t)tx0 | ((uint32_t)ty0 << 8) | ((uint32_t)tx1 << 16) | ((uint32_t)ty1 << 24);
                for (int32_t ty = ty0; ty <= ty1; ty++)
                    for (int32_t tx = tx0; tx <= tx1; tx++) tile_fill[ty * tiles_x + tx]++;
                nvis++;
            }
        }
    }
    STAT(raster_stats.quads_visible += nvis);

    // Prefix sum -> per-tile command list ranges, then fill.
    uint32_t acc = 0;
    for (int32_t t = 0; t < ntiles; t++) {
        tile_start[t] = (uint16_t)imin((int32_t)acc, RASTER_BIN_CAP);
        acc += tile_fill[t];
        tile_fill[t] = 0;
    }
    tile_start[ntiles] = (uint16_t)imin((int32_t)acc, RASTER_BIN_CAP);
    if (acc > RASTER_BIN_CAP) STAT(raster_stats.bin_overflow++);
    for (int32_t i = 0; i < nvis; i++) {
        uint32_t b = vis_box[i];
        for (int32_t ty = (b >> 8) & 255; ty <= (int32_t)(b >> 24); ty++)
            for (int32_t tx = b & 255; tx <= (int32_t)((b >> 16) & 255); tx++) {
                int32_t t = ty * tiles_x + tx;
                uint32_t at = tile_start[t] + tile_fill[t];
                if (at < tile_start[t + 1]) { bin_entry[at] = (uint16_t)i; tile_fill[t]++; }
            }
    }
    STAT(raster_stats.bin_entries += imin((int32_t)acc, RASTER_BIN_CAP));
    return nvis;
}

// ---------------------------------------------------------------- 2. tiles (all lanes) ----
typedef struct {
    int32_t A[3], B[3], C[3];       // edge i: E = A*X + B*Y + C >= 0 inside (X, Y in Q4)
    int32_t X0, Y0;
    q16 a0[3], gx[3], gy[3];        // attribute planes (iz, uz, vz): value per pixel step
    int32_t px0, px1, py0, py1;     // pixel bbox clipped to the tile
} tri_t;

static int32_t tri_setup(tri_t *t, const svert *v0, const svert *v1, const svert *v2,
                         int32_t tx0, int32_t ty0) {
    int32_t area = (v1->X - v0->X) * (v2->Y - v0->Y) - (v2->X - v0->X) * (v1->Y - v0->Y);
    if (area == 0) return 0;
    if (area < 0) { const svert *tmp = v1; v1 = v2; v2 = tmp; area = -area; }
    const svert *v[3] = { v0, v1, v2 };
    for (int32_t i = 0; i < 3; i++) {
        const svert *a = v[i], *b = v[i == 2 ? 0 : i + 1];
        t->A[i] = -(b->Y - a->Y);
        t->B[i] = b->X - a->X;
        // Grow every edge outward by EDGE_GROW subpixels (1/16 px each): closes the hairline
        // T-junction cracks greedy meshing creates. The depth test hides the tiny overlap.
        t->C[i] = -(t->A[i] * a->X + t->B[i] * a->Y) + EDGE_GROW * (iabs(t->A[i]) + iabs(t->B[i]));
    }
    t->X0 = v0->X; t->Y0 = v0->Y;
    int32_t dx1 = v1->X - v0->X, dy1 = v1->Y - v0->Y, dx2 = v2->X - v0->X, dy2 = v2->Y - v0->Y;
    for (int32_t k = 0; k < 3; k++) {
        q16 A0 = k == 0 ? v0->iz : k == 1 ? v0->uz : v0->vz;
        q16 A1 = k == 0 ? v1->iz : k == 1 ? v1->uz : v1->vz;
        q16 A2 = k == 0 ? v2->iz : k == 1 ? v2->uz : v2->vz;
        int64_t d1 = A1 - A0, d2 = A2 - A0;
        t->a0[k] = A0;                                         // gradients per pixel (x16 per Q4 unit)
        t->gx[k] = idiv((d1 * dy2 - d2 * dy1) * 16, area);
        t->gy[k] = idiv((d2 * dx1 - d1 * dx2) * 16, area);
    }
    int32_t xmin = imin(v0->X, imin(v1->X, v2->X)), xmax = imax(v0->X, imax(v1->X, v2->X));
    int32_t ymin = imin(v0->Y, imin(v1->Y, v2->Y)), ymax = imax(v0->Y, imax(v1->Y, v2->Y));
    t->px0 = imax(xmin >> 4, tx0); t->px1 = imin(xmax >> 4, tx0 + TILE - 1);
    t->py0 = imax(ymin >> 4, ty0); t->py1 = imin(ymax >> 4, ty0 + TILE - 1);
    STAT(raster_stats.tri_setups++);
    return t->px0 <= t->px1 && t->py0 <= t->py1;
}

// One pixel, branch-free. `valid` = the lane has a pixel in range.
// Coverage only: cheap, run for every pixel in the triangle's box.
static inline int32_t covers(const tri_t *t, int32_t px, int32_t py, int32_t valid) {
    int32_t X = px * 16 + 8, Y = py * 16 + 8;
    int32_t e0 = t->A[0] * X + t->B[0] * Y + t->C[0];
    int32_t e1 = t->A[1] * X + t->B[1] * Y + t->C[1];
    int32_t e2 = t->A[2] * X + t->B[2] * Y + t->C[2];
    return ((e0 | e1 | e2) >= 0) & valid;
}

// Depth test + texture + shade + masked write. Only run for groups where some lane is inside.
__attribute__((noinline)) static void shade_px(const tri_t *t, int32_t px, int32_t py, int32_t inside,
                            int32_t tx0, int32_t ty0, int32_t mat, const kc_rparams *p) {
    int32_t X = px * 16 + 8, Y = py * 16 + 8;

    int64_t dX = X - t->X0, dY = Y - t->Y0;
    q16 iz = t->a0[0] + (q16)(((int64_t)t->gx[0] * dX + (int64_t)t->gy[0] * dY) >> 4);
    q16 uz = t->a0[1] + (q16)(((int64_t)t->gx[1] * dX + (int64_t)t->gy[1] * dY) >> 4);
    q16 vz = t->a0[2] + (q16)(((int64_t)t->gx[2] * dX + (int64_t)t->gy[2] * dY) >> 4);
    iz = sel(iz < 64, 64, iz);
    q16 z = qrcp(iz);                                  // perspective-correct
    q16 u = qmul(uz, z), v = qmul(vz, z);

    int32_t dep = z >> 10;                             // 12-bit linear depth, 1/64 block
    dep = sel(dep > (int32_t)DEPTH_MAX - 1, (int32_t)DEPTH_MAX - 1, dep);
    int32_t idx = sel(inside, (py - ty0) * TILE + (px - tx0), TILE * TILE);
    uint32_t old = tile_px[idx];
    int32_t pass = inside & (dep < (int32_t)PX_DEPTH(old));

    int32_t face = mat & 7, a = face >> 1, type = mat >> 3;
    int32_t tu = (qfrac(u) >> 12) & 15, tv = (qfrac(v) >> 12) & 15;
    tv = sel(a == 1, tv, 15 - tv);
    int32_t tface = sel(a == 1, sel(face & 1, 2, 0), 1);
    int32_t texel = hal_tex_get(TEX_INDEX(type, tface, tu, tv)) & 15;
    int32_t shade = sel(a == 1, sel(face & 1, 3, 0), sel(a == 0, 1, 2));
    int32_t fog = (z >= p->fog_d[0]) + (z >= p->fog_d[1]) + (z >= p->fog_d[2]);
    int32_t col = PIX(texel, shade, fog);

    STAT(raster_stats.pixels_written += pass);
#if KC_LANES == 8
    uint32_t m = mask_get();
    lmask((uint32_t)pass);                             // masked stores: only winning lanes write
    tile_px[idx] = PX_PACK(col, dep, PX_STENCIL(old));
    mask_set(m);
#else
    if (pass) tile_px[idx] = PX_PACK(col, dep, PX_STENCIL(old));
#endif
}

static void raster_tri(const tri_t *t, int32_t tx0, int32_t ty0, int32_t mat, int32_t lane0) {
    const kc_rparams *p = KC_RP;
    for (int32_t py = t->py0; py <= t->py1; py++)
        for (int32_t gx = t->px0; gx <= t->px1; gx += 8) {
#if KC_LANES == 1
            for (int32_t lane = 0; lane < 8; lane++) {
#else
            int32_t lane = lane0;
#endif
                int32_t px = gx + lane;
                int32_t in = covers(t, px, py, px <= t->px1);
                STAT(raster_stats.pixels_tested++);
#if KC_LANES == 1
                STAT(raster_stats.pixels_covered += in);
                if (in) shade_px(t, px, py, in, tx0, ty0, mat, p);
            }
#else
                if (ballot((uint32_t)in) != 0)            // uniform: skip groups no lane covers
                    shade_px(t, px, py, in, tx0, ty0, mat, p);
#endif
        }
}

// Triangle fan of one screen polygon into the tile. noinline: the tri_t and the raster loops
// spills then live in this frame, beside quad_to_screen's, not under it (1 KB lane stacks).
__attribute__((noinline)) static void raster_fan(const svert *sv, int32_t n, int32_t tx0, int32_t ty0,
                                                 int32_t mat, int32_t lane0) {
    for (int32_t i = 1; i + 1 < n; i++) {
        tri_t tri;
        if (tri_setup(&tri, &sv[0], &sv[i], &sv[i + 1], tx0, ty0))
            raster_tri(&tri, tx0, ty0, mat, lane0);
    }
}

static void tile_clear(int32_t ty0, int32_t lane0) {
    const kc_rparams *p = KC_RP;
    for (int32_t i = 0; i < TILE * TILE; i += 8) {
#if KC_LANES == 1
        for (int32_t lane = 0; lane < 8; lane++) {
#else
        int32_t lane = lane0;
#endif
            int32_t k = i + lane;
            int32_t sky_i = ((ty0 + (k >> 4)) * p->sky_k) >> 16;
            tile_px[k] = PX_PACK((COLOR_SKY << 4) | sel(sky_i > 15, 15, sky_i), DEPTH_MAX, 0);
#if KC_LANES == 1
        }
#endif
    }
}

static void tile_flush(int32_t tx0, int32_t ty0, int32_t H, int32_t lane0) {
    for (int32_t i = 0; i < TILE * TILE; i += 8) {
#if KC_LANES == 1
        for (int32_t lane = 0; lane < 8; lane++) {
#else
        int32_t lane = lane0;
#endif
            int32_t k = i + lane;
            int32_t py = ty0 + (k >> 4);
            int32_t px = tx0 + (k & 15);
            int32_t addr = sel(py < H, py * FB_STRIDE + px, 0);   // partial bottom tile row at 120
            uint8_t c = (uint8_t)PX_COLOR(tile_px[k]);
#if KC_LANES == 8
            uint32_t m = mask_get();
            lmask((uint32_t)(py < H));
            hal_fb_put((uint32_t)addr, c);
            mask_set(m);
#else
            if (py < H) hal_fb_put((uint32_t)addr, c);
#endif
#if KC_LANES == 1
        }
#endif
    }
}

static int32_t frame_tiles_x, frame_tiles_y;

// Game side, lane 0: build this frame's per-tile command lists.
void raster_bin(void) {
    view_t vw;
    view_init(&vw);
    frame_tiles_x = vw.W >> 4;
    frame_tiles_y = (vw.H + TILE - 1) >> 4;
#ifdef KC_HOST
    raster_stats = (raster_stats_t){0};
#endif
    bin_frame(&vw, frame_tiles_x, frame_tiles_y);
}

// Kernel, all lanes active: rasterize every tile from its command list.
void kc_raster_kernel(void) {
    view_t vw;
    view_init(&vw);
#if KC_LANES == 8
    int32_t lane0 = (int32_t)lane_id();
#else
    int32_t lane0 = 0;
#endif
    int32_t tiles_x = frame_tiles_x, tiles_y = frame_tiles_y;
    for (int32_t ty = 0; ty < tiles_y; ty++)
        for (int32_t tx = 0; tx < tiles_x; tx++) {
            int32_t t = ty * tiles_x + tx, X0 = tx * TILE, Y0 = ty * TILE;
            tile_clear(Y0, lane0);
            for (uint32_t e = tile_start[t]; e < tile_start[t + 1]; e++) {
                uint32_t ref = vis_ref[bin_entry[e]];
                int32_t slot = (int32_t)(ref >> 16), pg = (int32_t)((ref >> 8) & 255), q = (int32_t)(ref & 255);
                view_set_slot(&vw, slot);
                svert sv[MAX_POLY];
                int32_t mat, n = quad_to_screen(&vw, pg, q, sv, &mat);
                raster_fan(sv, n, X0, Y0, mat, lane0);
            }
            tile_flush(X0, Y0, vw.H, lane0);
        }
}

#ifdef KC_HOST
#include <stdio.h>
void raster_debug_pixel(int32_t px, int32_t py) {
    view_t vw; view_init(&vw);
    int32_t tiles_x = vw.W >> 4, tiles_y = (vw.H + 15) >> 4;
    bin_frame(&vw, tiles_x, tiles_y);
    int32_t t = (py >> 4) * tiles_x + (px >> 4);
    printf("tile %d entries %d\n", t, tile_start[t + 1] - tile_start[t]);
    for (uint32_t e = tile_start[t]; e < tile_start[t + 1]; e++) {
        uint32_t ref = vis_ref[bin_entry[e]];
        int32_t slot = ref >> 16, pg = (ref >> 8) & 255, q = ref & 255;
        view_set_slot(&vw, slot);
        svert sv[MAX_POLY]; pvert pv[4]; int32_t mat;
        quad_verts(&vw, pg, q, pv, &mat);
        int32_t n = quad_to_screen(&vw, pg, q, sv, &mat);
        printf(" quad s%d p%d q%d face %d type %d n=%d\n", slot, pg, q, mat & 7, mat >> 3, n);
        for (int i = 0; i < 4; i++) printf("   view %.3f %.3f %.3f\n", pv[i].x/65536.0, pv[i].y/65536.0, pv[i].z/65536.0);
        for (int i = 0; i < n; i++) printf("   scr %.2f %.2f iz %.3f\n", sv[i].X/16.0, sv[i].Y/16.0, sv[i].iz/65536.0);
        for (int32_t i = 1; i + 1 < n; i++) {
            tri_t tri;
            int ok = tri_setup(&tri, &sv[0], &sv[i], &sv[i + 1], (px >> 4) * 16, (py >> 4) * 16);
            int32_t X = px * 16 + 8, Y = py * 16 + 8;
            printf("   tri %d ok %d e %d %d %d bbox %d-%d %d-%d\n", i, ok, tri.A[0]*X+tri.B[0]*Y+tri.C[0],
                   tri.A[1]*X+tri.B[1]*Y+tri.C[1], tri.A[2]*X+tri.B[2]*Y+tri.C[2], tri.px0, tri.px1, tri.py0, tri.py1);
        }
    }
}
#endif
#ifdef KC_HOST
void raster_debug_clip(int32_t slot, int32_t pg, int32_t q) {
    view_t vw; view_init(&vw); view_set_slot(&vw, slot);
    pvert poly[MAX_POLY]; int32_t mat;
    quad_verts(&vw, pg, q, poly, &mat);
    int32_t n = clip_poly(poly, 4);
    for (int i = 0; i < n; i++) {
        printf(" clip %.4f %.4f %.4f  d:", poly[i].x/65536.0, poly[i].y/65536.0, poly[i].z/65536.0);
        for (int k = 0; k < 5; k++) printf(" %.4f", plane_d(&poly[i], k)/65536.0);
        printf("\n");
    }
}
#endif
