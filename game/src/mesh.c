// mesh.c — greedy mesher + page pool. Lane 0 only; runs when chunks change, not per frame.
//
// Meshing a chunk reads each block once into column bitmasks (bit y of col[x][z] = solid),
// 18 x 18 columns including a 1-block border = 1.3 KB. Face visibility is then bit math,
// and block types are only read for faces that are actually visible.
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

GPUMEM mesh_page mesh_pool[MESH_PAGES];
const uint16_t mesh_quad_index[6] = { 0, 1, 2, 0, 2, 3 };
uint8_t  mesh_page_next[MESH_PAGES];
uint8_t  mesh_page_quads[MESH_PAGES];
mesh_cmd mesh_cmds[16];
_Static_assert(MESH_PAGE_QUADS <= 255, "mesh_page_quads is uint8");

static uint8_t  free_head;
static uint16_t dirty_slots;
// Scratch from the per-frame arena (issue #2): 1,296 + 512 bytes, only while meshing.
static uint32_t (*col)[18];                // [z+1][x+1], bit y = solid
static uint8_t  *mask;                     // one greedy slice: type + 1, 0 = no face
static int32_t  pool_overflow;

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
// Unloaded neighbors count as solid so no walls are drawn where the loaded world ends.
static uint32_t load_column(int32_t ax, int32_t az) {
    if (!world_loaded(ax, az)) return 0xFFFFFFFFu;
    uint32_t c = 0;
    for (int32_t y = 0; y < WIN_Y; y++)
        c |= (uint32_t)(world_get(ax, y, az) != B_AIR) << y;
    return c;
}

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

// Is face `face` of local block (x, y, z) visible? (using the column bitmasks)
static int32_t face_visible(int32_t face, int32_t x, int32_t y, int32_t z) {
    uint32_t self = col[z + 1][x + 1];
    if (!((self >> y) & 1)) return 0;
    switch (face) {
    case 0: return !((col[z + 1][x + 2] >> y) & 1);
    case 1: return !((col[z + 1][x] >> y) & 1);
    case 2: return y == 31 || !((self >> (y + 1)) & 1);
    case 3: return y > 0 && !((self >> (y - 1)) & 1);
    case 4: return !((col[z + 2][x + 1] >> y) & 1);
    default: return !((col[z][x + 1] >> y) & 1);
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

    emit_ctx e = { slot, MESH_NONE, cmd->cx * CHUNK_W, cmd->cz * CHUNK_W };
    for (int32_t z = -1; z <= 16; z++)
        for (int32_t x = -1; x <= 16; x++)
            col[z + 1][x + 1] = load_column(e.ax0 + x, e.az0 + z);

    static const int32_t SIZE[3] = { 16, 32, 16 };
    for (int32_t face = 0; face < 6; face++) {
        int32_t a = face >> 1, neg = face & 1;
        int32_t ua = a == 0 ? 2 : 0;               // tangent axes: x-faces (z, y), y-faces (x, z), z-faces (x, y)
        int32_t va = a == 1 ? 2 : 1;
        int32_t U = SIZE[ua], V = SIZE[va];
        for (int32_t d = 0; d < SIZE[a]; d++) {
            // 1. Visible-face mask for this slice
            for (int32_t v = 0; v < V; v++)
                for (int32_t u = 0; u < U; u++) {
                    int32_t p[3];
                    p[a] = d; p[ua] = u; p[va] = v;
                    uint8_t m = 0;
                    if (face_visible(face, p[0], p[1], p[2]))
                        m = (uint8_t)(world_get(e.ax0 + p[0], p[1], e.az0 + p[2]) + 1);
                    mask[v * U + u] = m;
                }
            // 2. Greedy merge into rectangles of the same type
            for (int32_t v = 0; v < V; v++)
                for (int32_t u = 0; u < U; ) {
                    uint8_t m = mask[v * U + u];
                    if (!m) { u++; continue; }
                    int32_t w = 1;
                    while (u + w < U && mask[v * U + u + w] == m) w++;
                    int32_t h = 1;
                    for (; v + h < V; h++) {
                        int32_t k = 0;
                        while (k < w && mask[(v + h) * U + u + k] == m) k++;
                        if (k < w) break;
                    }
                    for (int32_t j = 0; j < h; j++)
                        for (int32_t k = 0; k < w; k++) mask[(v + j) * U + u + k] = 0;

                    int32_t plane = d + (neg ? 0 : 1);
                    int32_t c[4][3];
                    int32_t uu[4] = { u, u + w, u + w, u };
                    int32_t vv[4] = { v, v, v + h, v + h };
                    for (int32_t i = 0; i < 4; i++) { c[i][a] = plane; c[i][ua] = uu[i]; c[i][va] = vv[i]; }
                    emit_quad(&e, face, c, m - 1);
                    u += w;
                }
        }
    }
}

void mesh_update(void) {
    if (!dirty_slots) return;
    col = (uint32_t (*)[18])arena_alloc(18 * 18 * sizeof(uint32_t));
    mask = (uint8_t *)arena_alloc(32 * 16);
    for (int32_t s = 0; s < 16; s++)
        if (dirty_slots & (1u << s)) mesh_slot(s);
    dirty_slots = 0;
}
