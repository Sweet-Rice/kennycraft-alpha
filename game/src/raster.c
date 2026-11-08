// raster.c — tile-based rasterizer. Fixed point, no divide instruction, branch-free per pixel.
#include "raster.h"
#include "mesh.h"
#include "entity.h"
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
// Lane-0 per-chunk helpers: built for size (clang minsize), they run 16 times a frame, not per pixel.
#if defined(__clang__)
#define LANE0_SMALL __attribute__((minsize, noinline))
#else
#define LANE0_SMALL __attribute__((noinline))
#endif
#define EDGE_GROW 2                // subpixels; 2 closes every T-junction crack in the golden shots
#define ENT_REF 0x80000000u




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

// ---- tile memory: 16 x 16 x 32-bit words = 1 KB, +1 scratch slot ---------------------------
// One 32-bit word per pixel: color 7:0 (the palette byte), depth 31:8 (24 bits: 1/z in Q16,
// flipped so the tile's "smaller wins" test holds). 24 bits hold every 1/z down to NEAR exactly,
// so near faces never tie (a 12-bit depth saturated under about 1 block).
// One load and one masked store per pixel instead of three halfword operations.
#define PX_COLOR(w)   ((w) & 0xFFu)
#define PX_DEPTH(w)   ((w) >> 8)
#define PX_PACK(c, d) ((uint32_t)(c) | ((uint32_t)(d) << 8))
#define DEPTH_MAX 0xFFFFFFu
static uint32_t tile_px[TILE * TILE + 1];          // 1 KB + 1 scratch word

// One polygon vertex, two stages in the same three words: view space while clipping, then the
// screen vertex project() writes over it in place. Sharing the buffer keeps quad_to_screen off a
// second MAX_POLY array: the kernel runs it on every lane's 1 KB stack. Vertex colors: no u, v.
typedef union {
    struct { q16 x, y, z; };                       // pvert: view space
    struct { int32_t X, Y; q16 iz; };              // svert: Q4 subpixels, clamped; 1/z
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
    }
    *mat = m;
}

static void ent_quad_verts(const view_t *vw, int32_t box, int32_t face, pvert out[4], int32_t *mat) {
    const ent_box *b = &ent_boxes[box];
    int32_t a = face >> 1, ua = (a + 1) % 3, va = (a + 2) % 3;
    q16 plane = (face & 1) ? b->lo[a] : b->hi[a];
    for (int32_t i = 0; i < 4; i++) {
        q16 w[3];
        w[a] = plane;
        w[ua] = (i == 1 || i == 2) ? b->hi[ua] : b->lo[ua];
        w[va] = (i >= 2) ? b->hi[va] : b->lo[va];
        q16 r[3] = {w[0]-vw->eye[0],w[1]-vw->eye[1],w[2]-vw->eye[2]};
        out[i].x = qmul(r[0],vw->right[0]) + qmul(r[1],vw->right[1]) + qmul(r[2],vw->right[2]);
        out[i].y = qmul(r[0],vw->up[0]) + qmul(r[1],vw->up[1]) + qmul(r[2],vw->up[2]);
        out[i].z = qmul(r[0],vw->fwd[0]) + qmul(r[1],vw->fwd[1]) + qmul(r[2],vw->fwd[2]);
    }
    *mat = face | ((16 + b->color) << 3);
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
    p->X = iclamp(vw->W * 8 + (sx >> 12), 0, vw->W * 16);
    p->Y = iclamp(vw->H * 8 - (sy >> 12), 0, vw->H * 16);
    p->iz = iz;
}

// Cull, clip and project a transformed quad in poly[MAX_POLY].
static int32_t poly_to_screen(const view_t *vw, vert *poly) {
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

static int32_t quad_to_screen(const view_t *vw, int32_t page, int32_t q, vert *poly, int32_t *mat) {
    quad_verts(vw,page,q,poly,mat);
    return poly_to_screen(vw,poly);
}

static int32_t ent_quad_to_screen(const view_t *vw, int32_t box, int32_t face, vert *poly, int32_t *mat) {
    ent_quad_verts(vw,box,face,poly,mat);
    return poly_to_screen(vw,poly);
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
// Chunk box (16 x 32 x 16 at the slot's offset) against the 5 frustum planes: cull when all
// 8 corners are outside one plane. Conservative, so it only drops quads the quad test drops.
LANE0_SMALL static int32_t chunk_in_frustum(const view_t *vw) {
    pvert c[8];
    for (int32_t i = 0; i < 8; i++) {
        q16 r[3] = { Q16_INT(vw->ox + (i & 1) * CHUNK_W) - vw->eye[0], Q16_INT(((i >> 1) & 1) * 32) - vw->eye[1],
                     Q16_INT(vw->oz + (i >> 2) * CHUNK_W) - vw->eye[2] };
        c[i].x = qmul(r[0], vw->right[0]) + qmul(r[1], vw->right[1]) + qmul(r[2], vw->right[2]);
        c[i].y = qmul(r[0], vw->up[0])    + qmul(r[1], vw->up[1])    + qmul(r[2], vw->up[2]);
        c[i].z = qmul(r[0], vw->fwd[0])   + qmul(r[1], vw->fwd[1])   + qmul(r[2], vw->fwd[2]);
    }
    for (int32_t k = 0; k < 5; k++) {
        int32_t out_n = 0;
        for (int32_t i = 0; i < 8; i++) out_n += plane_d(&c[i], k) < 0;
        if (out_n == 8) return 0;
    }
    return 1;
}

static int32_t bin_poly(const svert *sv, int32_t n, uint32_t ref, int32_t nvis,
                        int32_t tiles_x, int32_t tiles_y) {
    if (n < 3) { STAT(raster_stats.quads_culled++); STAT(raster_stats.quads_clipped++); return nvis; }
    int32_t x0 = sv[0].X, x1 = sv[0].X, y0 = sv[0].Y, y1 = sv[0].Y;
    for (int32_t i = 1; i < n; i++) {
        x0 = imin(x0,sv[i].X); x1 = imax(x1,sv[i].X);
        y0 = imin(y0,sv[i].Y); y1 = imax(y1,sv[i].Y);
    }
    int32_t tx0 = x0 >> 8, ty0 = y0 >> 8;
    int32_t tx1 = imin(x1 >> 8,tiles_x-1), ty1 = imin(y1 >> 8,tiles_y-1);
    if (nvis == RASTER_VIS_CAP) { STAT(raster_stats.vis_overflow++); return nvis; }
    vis_ref[nvis] = ref;
    vis_box[nvis] = (uint32_t)tx0 | ((uint32_t)ty0 << 8) | ((uint32_t)tx1 << 16) | ((uint32_t)ty1 << 24);
    for (int32_t ty = ty0; ty <= ty1; ty++)
        for (int32_t tx = tx0; tx <= tx1; tx++) tile_fill[ty*tiles_x+tx]++;
    return nvis + 1;
}

static int32_t bin_frame(const view_t *vw0, int32_t tiles_x, int32_t tiles_y) {
    view_t vw = *vw0;
    int32_t nvis = 0, ntiles = tiles_x * tiles_y;
    tile_fill = (uint16_t *)arena_alloc(MAX_TILES * sizeof(uint16_t));
    for (int32_t t = 0; t < ntiles; t++) tile_fill[t] = 0;

    for (int32_t s = 0; s < 16; s++) {
        if (mesh_cmds[s].cx < 0) continue;
        view_set_slot(&vw, s);
        if (!chunk_in_frustum(&vw)) { STAT(raster_stats.chunks_frustum_culled++); STAT(raster_stats.quads_skipped += mesh_cmds[s].quads); continue; }
        STAT(raster_stats.chunks_drawn++);
        for (uint8_t pg = mesh_cmds[s].first_page; pg != MESH_NONE; pg = mesh_page_next[pg]) {
            const mesh_page *P = &mesh_pool[pg];
            for (int32_t q = 0; q < mesh_page_quads[pg]; q++) {
                // Back-face cull from the face direction alone: no transform needed.
                int32_t m = P->mat[q], face = m & 7, a = face >> 1;
                uint16_t v0 = P->vtx[q * 4];
                int32_t plane = a == 0 ? VTX_X(v0) + vw.ox : a == 1 ? VTX_Y(v0) : VTX_Z(v0) + vw.oz;
                q16 e = vw.eye[a], pl = Q16_INT(plane);
                if ((face & 1) ? e >= pl : e <= pl) { STAT(raster_stats.quads_culled++); STAT(raster_stats.quads_backface++); continue; }

                svert sv[MAX_POLY];
                int32_t mat, n = quad_to_screen(&vw, pg, q, sv, &mat);
                uint32_t ref = ((uint32_t)s << 16) | ((uint32_t)pg << 8) | (uint32_t)q;
                nvis = bin_poly(sv,n,ref,nvis,tiles_x,tiles_y);
            }
        }
    }
    for (int32_t i = 0; i < ent_nboxes; i++)
        for (int32_t f = 0; f < 6; f++) {
            int32_t a = f >> 1;
            q16 e = vw.eye[a], pl = (f & 1) ? ent_boxes[i].lo[a] : ent_boxes[i].hi[a];
            if ((f & 1) ? e >= pl : e <= pl) { STAT(raster_stats.quads_culled++); STAT(raster_stats.quads_backface++); continue; }
            svert sv[MAX_POLY];
            int32_t mat, n = ent_quad_to_screen(&vw,i,f,sv,&mat);
            nvis = bin_poly(sv,n,ENT_REF | (uint32_t)i << 3 | (uint32_t)f,nvis,tiles_x,tiles_y);
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
    q16 a0, gx, gy;                 // 1/z plane: value at (X0, Y0), change per pixel step
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
    int64_t d1 = v1->iz - v0->iz, d2 = v2->iz - v0->iz;
    t->a0 = v0->iz;                                            // gradients per pixel (x16 per Q4 unit)
    t->gx = idiv((d1 * dy2 - d2 * dy1) * 16, area);
    t->gy = idiv((d2 * dx1 - d1 * dx2) * 16, area);
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

// The pixel work, split in two branch-free halves. depth_px: interpolate 1/z, depth, test.
// color_px: flat face color, shade, fog, masked write; the caller runs it only when BALLOT says
// some lane of the group passed (a uniform branch). Vertex colors: no texture, no reciprocal.
// Depth is stored as 1/z (larger = nearer), flipped so the tile's "smaller wins" test holds.
// 24-bit depth = 0xFFFFFE - min(iz, 0xFFFFFE): iz <= 1/NEAR ~ 1.31 M < 2^24, so no shift and no
// saturation inside the view; equal iz ties keep the first face, like the strict < before.
typedef struct { q16 iz; int32_t idx, dep, pass; uint32_t old; } zpx_t;

static q16 fog_iz[3];               // 1/fog_d: fog thresholds in 1/z space

__attribute__((noinline)) static void depth_px(const tri_t *t, int32_t px, int32_t py, int32_t inside,
                                               int32_t tx0, int32_t ty0, zpx_t *o) {
    int32_t X = px * 16 + 8, Y = py * 16 + 8;
    int64_t dX = X - t->X0, dY = Y - t->Y0;
    q16 iz = t->a0 + (q16)(((int64_t)t->gx * dX + (int64_t)t->gy * dY) >> 4);
    iz = sel(iz < 64, 64, iz);
    int32_t dep = (int32_t)DEPTH_MAX - 1 - sel(iz > (int32_t)DEPTH_MAX - 1, (int32_t)DEPTH_MAX - 1, iz);
    int32_t idx = sel(inside, (py - ty0) * TILE + (px - tx0), TILE * TILE);
    uint32_t old = tile_px[idx];
    o->iz = iz; o->idx = idx; o->dep = dep; o->old = old;
    o->pass = inside & (dep < (int32_t)PX_DEPTH(old));
}

__attribute__((noinline)) static void color_px(const zpx_t *o, int32_t mat) {
    int32_t face = mat & 7, a = face >> 1, type = mat >> 3;
    int32_t tface = sel(a == 1, sel(face & 1, 2, 0), 1);
    int32_t flat = (type >> 4) & 1;                   // entity box: its own flat color
    int32_t shade = sel(a == 1, sel(face & 1, 3, 0), sel(a == 0, 1, 2));
    q16 iz = o->iz;
    int32_t color = sel(flat, type & 15, kc_face_color[sel(flat, 0, type) * 3 + tface]);
    int32_t fog = (iz <= fog_iz[0]) + (iz <= fog_iz[1]) + (iz <= fog_iz[2]);
    int32_t col = PIX(color, shade, fog);
    int32_t pass = o->pass, idx = o->idx;
    STAT(raster_stats.pixels_written += pass);
#if KC_LANES == 8
    uint32_t m = mask_get();
    lmask((uint32_t)pass);                             // masked stores: only winning lanes write
    tile_px[idx] = PX_PACK(col, o->dep);
    mask_set(m);
#else
    if (pass) tile_px[idx] = PX_PACK(col, o->dep);
#endif
}

static void raster_tri(const tri_t *t, int32_t tx0, int32_t ty0, int32_t mat, int32_t lane0) {
    for (int32_t py = t->py0; py <= t->py1; py++)
        for (int32_t gx = t->px0; gx <= t->px1; gx += 8) {
#if KC_LANES == 1
            // One lane plays all 8 in turn; the "ballots" are ORs over the group.
            zpx_t z8[8];
            int32_t any_in = 0, any_pass = 0, n_in = 0;
            for (int32_t lane = 0; lane < 8; lane++) {
                int32_t px = gx + lane;
                int32_t in = covers(t, px, py, px <= t->px1);
                STAT(raster_stats.pixels_tested++);
                STAT(raster_stats.pixels_covered += in);
                z8[lane].pass = 0;
                if (in) { depth_px(t, px, py, in, tx0, ty0, &z8[lane]); any_pass |= z8[lane].pass; }
                any_in |= in; n_in += in;
            }
            STAT(raster_stats.groups_covered += any_in);
            STAT(raster_stats.groups_shaded += any_pass);
            if (any_pass) {
                STAT(raster_stats.pixels_in_shaded_groups += n_in);
                for (int32_t lane = 0; lane < 8; lane++)
                    if (z8[lane].pass) color_px(&z8[lane], mat);
            }
            (void)n_in; (void)any_in;
#else
            int32_t px = gx + lane0;
            int32_t in = covers(t, px, py, px <= t->px1);
            if (ballot((uint32_t)in) != 0) {              // uniform: skip groups no lane covers
                zpx_t zp;
                depth_px(t, px, py, in, tx0, ty0, &zp);
                if (ballot((uint32_t)zp.pass) != 0)       // uniform: skip groups no lane wins
                    color_px(&zp, mat);
            }
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
            tile_px[k] = PX_PACK((COLOR_SKY << 4) | sel(sky_i > 15, 15, sky_i), DEPTH_MAX);
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

// Lane 0, every frame: fog thresholds in 1/z space (the fog distance can change).
LANE0_SMALL static void fog_frame(void) {
    for (int32_t k = 0; k < 3; k++) fog_iz[k] = qrcp(KC_RP->fog_d[k]);
}

// Game side, lane 0: build this frame's per-tile command lists.
void raster_bin(void) {
    view_t vw;
    view_init(&vw);
    frame_tiles_x = vw.W >> 4;
    frame_tiles_y = (vw.H + TILE - 1) >> 4;
#ifdef KC_HOST
    raster_stats = (raster_stats_t){0};
#endif
    fog_frame();
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
                svert sv[MAX_POLY];
                int32_t mat, n;
                if (ref & ENT_REF) {
                    n = ent_quad_to_screen(&vw,(ref >> 3) & 0xFF,ref & 7,sv,&mat);
                } else {
                    int32_t slot = (int32_t)(ref >> 16), pg = (int32_t)((ref >> 8) & 255), q = (int32_t)(ref & 255);
                    view_set_slot(&vw,slot);
                    n = quad_to_screen(&vw,pg,q,sv,&mat);
                }
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
        if (ref & ENT_REF) {
            printf(" entity box %d face %d\n",(int)((ref >> 3) & 0xFF),(int)(ref & 7));
            continue;
        }
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
