// mesh.c — greedy mesher + page pool. Lane 0 only; runs when chunks change, not per frame.
//
// Meshing a chunk reads each block once into column bitmasks (bit y of col[z][x] = solid),
// 16 x 16 columns = 1 KB. Each border column of the neighbors is only needed by one slice of
// one face, so it is loaded right then into a 16-entry row (64 B). Face visibility is bit
// math, and block types are only read for faces that are actually visible. The greedy slice
// is always 16 wide: 16 nibbles (block type, 0 = no face) in one uint64 per row, 256 B.
#include "mesh.h"
#include "chunks.h"
#include "blocks.h"
#include "kc_hal.h"
#include "fixed.h"
#include "arena.h"

#ifdef KC_HOST
#define GPUMEM
#else
#define GPUMEM __attribute__((section(".gpumem")))
#endif
#define NO_UNROLL _Pragma("GCC unroll 1")   // loops around calls: unrolling only costs IMEM

GPUMEM mesh_page mesh_pool[MESH_PAGES];
const uint16_t mesh_quad_index[6] = { 0, 1, 2, 0, 2, 3 };
uint8_t  mesh_page_next[MESH_PAGES];
uint8_t  mesh_page_quads[MESH_PAGES];
mesh_cmd mesh_cmds[16];
_Static_assert(MESH_PAGE_QUADS <= 255, "mesh_page_quads is uint8");

static uint8_t  free_head;
static uint16_t dirty_slots;
// Scratch from the per-frame arena (issue #2), only while meshing: 1,024 + 64 + 256 bytes.
static uint32_t *col;                      // [z * 16 + x], bit y = solid
static uint32_t *bcol;                     // neighbor border columns for the current border slice
static uint64_t *mrow;                     // greedy slice: [v], nibble u = type, 0 = no face
static int32_t  pool_overflow;
#ifdef KC_HOST
uint32_t mesh_stat_slots;                  // laptop profiling: chunks meshed
#endif

// ---------------------------------------------------------------- page pool -------------
static uint8_t page_alloc(void) {
    uint8_t p = free_head;
    if (p == MESH_NONE) return MESH_NONE;
    free_head = mesh_page_next[p];
    mesh_page_next[p] = MESH_NONE;
    mesh_page_quads[p] = 0;
    return p;
}

static void page_free_chain(uint8_t p) {
    while (p != MESH_NONE) {
        uint8_t n = mesh_page_next[p];
        mesh_page_next[p] = free_head;
        free_head = p;
        p = n;
    }
}

void mesh_init(void) {
    for (int32_t i = 0; i < MESH_PAGES; i++) mesh_page_next[i] = (uint8_t)(i + 1 < MESH_PAGES ? i + 1 : MESH_NONE);
    free_head = 0;
    for (int32_t s = 0; s < 16; s++) { mesh_cmds[s].cx = -1; mesh_cmds[s].first_page = MESH_NONE; mesh_cmds[s].quads = 0; }
    dirty_slots = 0;
    pool_overflow = 0;
}

int32_t mesh_pages_used(void) {
    int32_t n = 0;
    for (int32_t s = 0; s < 16; s++)
        for (uint8_t p = mesh_cmds[s].first_page; p != MESH_NONE; p = mesh_page_next[p]) n++;
    return n;
}

int32_t mesh_total_quads(void) {
    int32_t n = 0;
    for (int32_t s = 0; s < 16; s++) n += mesh_cmds[s].quads;
    return n;
}

void mesh_mark_slot(int32_t slot) { dirty_slots |= (uint16_t)(1u << slot); }

void mesh_mark_block(int32_t ax, int32_t az) {
    int32_t lx = ax & 15, lz = az & 15;
    int32_t sx = (ax >> 4) & 3, sz = (az >> 4) & 3;
    mesh_mark_slot(sz * 4 + sx);
    if (lx == 0)  mesh_mark_slot(sz * 4 + ((sx + 3) & 3));
    if (lx == 15) mesh_mark_slot(sz * 4 + ((sx + 1) & 3));
    if (lz == 0)  mesh_mark_slot(((sz + 3) & 3) * 4 + sx);
    if (lz == 15) mesh_mark_slot(((sz + 1) & 3) * 4 + sx);
}

// ---------------------------------------------------------------- meshing ---------------
// Unloaded neighbors count as solid (world_column_bits) so no walls are drawn where the
// loaded world ends.
typedef struct { int32_t slot; uint8_t page; int32_t ax0, az0; } emit_ctx;

static void emit_quad(emit_ctx *e, int32_t face, const int32_t c[4][3], int32_t type) {
    mesh_cmd *cmd = &mesh_cmds[e->slot];
    if (e->page == MESH_NONE || mesh_page_quads[e->page] == MESH_PAGE_QUADS) {
        uint8_t np = page_alloc();
        if (np == MESH_NONE) {
            if (!pool_overflow) { hal_puts("kc: mesh pool full\n"); hal_mmio_w(MMIO_LEDS, 2); }
            pool_overflow++;
            return;
        }
        if (e->page == MESH_NONE) cmd->first_page = np; else mesh_page_next[e->page] = np;
        e->page = np;
    }
    mesh_page *pg = &mesh_pool[e->page];
    uint32_t q = mesh_page_quads[e->page]++;
    uint32_t v0 = q * 4;
    for (int32_t i = 0; i < 4; i++) pg->vtx[v0 + i] = VTX_PACK(c[i][0], c[i][1], c[i][2]);
    pg->mat[q] = (uint8_t)(face | (type << 3));
    cmd->quads++;
}

// Visible faces of slice d of face `face` into mrow (u = 16 wide, v = V rows).
// x faces: u = z, v = y. y faces: u = x, v = z. z faces: u = x, v = y.
static void build_slice(int32_t face, int32_t d, int32_t ax0, int32_t az0, int32_t wx0, int32_t wz0) {
    int32_t a = face >> 1;
    NO_UNROLL for (int32_t v = 0; v < 32; v++) mrow[v] = 0;
    if (a == 1) {
        for (int32_t z = 0; z < 16; z++) {
            uint64_t r = 0;
            for (int32_t x = 0; x < 16; x++) {
                uint32_t s = col[z * 16 + x];
                uint32_t vis = face == 2 ? s & ~(s >> 1) : s & ~(s << 1) & ~1u;   // top at y 31 shows
                if ((vis >> d) & 1) r |= (uint64_t)hal_win_get(wx0 + x, d, wz0 + z) << (4 * x);
            }
            mrow[z] = r;
        }
        return;
    }
    int32_t pos = !(face & 1), edge = pos ? 15 : 0, step = pos ? 1 : -1;
    if (d == edge)                                        // the one slice that needs the neighbor
        NO_UNROLL for (int32_t u = 0; u < 16; u++)
            bcol[u] = a == 0 ? world_column_bits(ax0 + d + step, az0 + u)
                             : world_column_bits(ax0 + u, az0 + d + step);
    for (int32_t u = 0; u < 16; u++) {
        int32_t x = a == 0 ? d : u, z = a == 0 ? u : d;
        uint32_t s = col[z * 16 + x];
        uint32_t n = d == edge ? bcol[u] : (a == 0 ? col[z * 16 + x + step] : col[(z + step) * 16 + x]);
        uint32_t vis = s & ~n;
        for (int32_t y = 0; vis; y++, vis >>= 1)
            if (vis & 1) mrow[y] |= (uint64_t)hal_win_get(wx0 + x, y, wz0 + z) << (4 * u);
    }
}

static void mesh_slot(int32_t slot) {
    mesh_cmd *cmd = &mesh_cmds[slot];
    page_free_chain(cmd->first_page);
    cmd->first_page = MESH_NONE;
    cmd->quads = 0;
    int32_t id1 = world_slot_chunk(slot);
    if (!id1) { cmd->cx = -1; return; }
    int32_t id = id1 - 1;
    cmd->cx = (int16_t)(id & 255); cmd->cz = (int16_t)(id >> 8);
#ifdef KC_HOST
    mesh_stat_slots++;
#endif

    emit_ctx e = { slot, MESH_NONE, cmd->cx * CHUNK_W, cmd->cz * CHUNK_W };
    int32_t wx0 = (e.ax0 - world_corner_x()) & 63, wz0 = (e.az0 - world_corner_z()) & 63;   // as world_get
    for (int32_t z = 0; z < 16; z++)
        NO_UNROLL for (int32_t x = 0; x < 16; x++)
            col[z * 16 + x] = world_column_bits(e.ax0 + x, e.az0 + z);

    static const int32_t SIZE[3] = { 16, 32, 16 };
    for (int32_t face = 0; face < 6; face++) {
        int32_t a = face >> 1, neg = face & 1;
        int32_t ua = a == 0 ? 2 : 0;               // tangent axes: x-faces (z, y), y-faces (x, z), z-faces (x, y)
        int32_t va = a == 1 ? 2 : 1;
        int32_t V = SIZE[va];                      // U = 16 for every face
        for (int32_t d = 0; d < SIZE[a]; d++) {
            build_slice(face, d, e.ax0, e.az0, wx0, wz0);
            // Greedy merge into rectangles of the same type, rows top to bottom, left to right
            for (int32_t v = 0; v < V; v++)
                for (int32_t u = 0; u < 16; ) {
                    uint64_t row = mrow[v] >> (4 * u);
                    if (!row) break;
                    uint32_t m = (uint32_t)row & 15u;
                    if (!m) { u++; continue; }
                    int32_t w = 1;
                    while (u + w < 16 && ((row >> (4 * w)) & 15u) == m) w++;
                    uint64_t span = (w == 16 ? ~0ull : (1ull << (4 * w)) - 1) << (4 * u);
                    uint64_t pat = (0x1111111111111111ull * m) & span;
                    int32_t h = 1;
                    while (v + h < V && (mrow[v + h] & span) == pat) h++;
                    for (int32_t j = 0; j < h; j++) mrow[v + j] &= ~span;

                    int32_t plane = d + (neg ? 0 : 1);
                    int32_t c[4][3];
                    int32_t uu[4] = { u, u + w, u + w, u };
                    int32_t vv[4] = { v, v, v + h, v + h };
                    for (int32_t i = 0; i < 4; i++) { c[i][a] = plane; c[i][ua] = uu[i]; c[i][va] = vv[i]; }
                    emit_quad(&e, face, c, (int32_t)m);
                    u += w;
                }
        }
    }
}

void mesh_update(void) {
    if (!dirty_slots) return;
    col  = (uint32_t *)arena_alloc(16 * 16 * sizeof(uint32_t));
    bcol = (uint32_t *)arena_alloc(16 * sizeof(uint32_t));
    mrow = (uint64_t *)arena_alloc(32 * sizeof(uint64_t));   // 4-aligned is enough: rv32 loads it as 2 words
    for (int32_t s = 0; s < 16; s++)
        if (dirty_slots & (1u << s)) mesh_slot(s);
    dirty_slots = 0;
}
