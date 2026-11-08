// chunks.c — world memory API (issue #2). Lane 0 only.
//
// world_update, per frame:
//   1. Wanted window = 4 x 4 chunks from round((p - 32) / 16) per axis (player 24-40 blocks
//      from every edge), clamped to the world.
//   2. Each slot holding the wrong chunk: clear its SLOT_VALID bit; if dirty, write its tag
//      (below) and chunk_store it.
//   3. Incoming chunk -> chunk_load. When it lands, check the tag: match -> put the tag cells
//      back to bedrock, then slot valid. No match (never stored this boot) -> generate it
//      into the window, dirty. At most one generation per frame after startup (startup
//      does all 16).
//   4. Whole new window in -> window_origin().
//
// Tags instead of issue #2's 8 KB "generated" bitmap (KC_GEN_BITMAP=1 brings that back).
// y = 0 is bedrock in every chunk and the game can't change it (break refuses bedrock,
// place needs y >= 1). TAG_CELLS of those cells carry a 128-bit signature of (seed, chunk
// id, TAG_FORMAT, boot nonce) while the chunk is in DDR3:
//   store: SLOT_VALID clear -> write tag cells -> chunk_store. The engine runs commands in
//          order and counts a STORE done once the slot is read out, so any later command
//          on the slot (the next load) sees the stored data, tags included.
//   load:  ticket done -> SLOT_VALID on for the 32 tag reads only (reads of an invalid
//          slot return air) and off again -> on a match write bedrock back -> SLOT_VALID on,
//          S_READY, remesh. All of it is on lane 0 inside world_update, before the kernel
//          runs, and world_get / the mesher only see S_READY slots: nothing that draws or
//          collides can read a tag nibble.
// The boot nonce hashes a boot counter kept in DDR3 with CYCLES once the startup loads have
// landed, so it differs per reset even when boot timing repeats exactly, and chunks stored
// by an earlier boot don't match (as with the bitmap, they're regenerated). The counter
// lives in chunk (0, 0)'s y = 0 row z = 2 (BOOT_CELLS nibbles: count, then a check hash):
// every boot loads that chunk, bumps the count, and stores it back before anything else;
// whenever chunk (0, 0) is stored later its tag write puts the count back, and a tag clear
// or generation turns the cells to bedrock like the tag cells. A failed check (power-on
// DRAM) starts the count from the garbage itself. KC_TAG_PERSIST=1 fixes the nonce at 0: chunks survive a reset. Random DRAM
// matches with probability 2^-128 per load; a constant fill or another chunk's bytes
// (address mix-up) doesn't match. Cost: never-seen chunks take one extra LOAD (async)
// before they are generated; revisits are unchanged.
//
// Addressing: the CPU uses window-relative x, z in 0..63 and hardware adds WIN_ORIGIN, so
// physical = abs & 63. Using (abs - committed_corner) & 63 reaches the right BRAM cell even
// for a chunk the committed window doesn't cover yet, which is what lets the new edge fill
// in before window_origin() moves.
//
// Fallback (KC_NO_DDR, or DDR_STATUS never calibrates): chunk_load/chunk_store are no-ops
// and every chunk is generated (no tags are written). Game code doesn't change.
#include "chunks.h"
#include "blocks.h"
#include "terrain.h"
#include "kc_hal.h"
#include "fixed.h"
#include "arena.h"
#if KC_RASTER
#include "mesh.h"
#define MESH_MARK_SLOT(s) mesh_mark_slot(s)
#define MESH_MARK_BLOCK(x, z) mesh_mark_block(x, z)
#else
#define MESH_MARK_SLOT(s) ((void)0)
#define MESH_MARK_BLOCK(x, z) ((void)0)
#endif

#define CAL_TIMEOUT_CYCLES (2u * CORE_HZ)      // wait up to 2 s for DDR3 calibration

#define TAG_CELLS 32                           // y = 0, z = 0..1, x = 0..15: 32 nibbles = 128 bits
#define TAG_FORMAT 0x4B430001u                 // bump if the DDR3 chunk layout changes
#define BOOT_ID    0                           // chunk (0, 0) holds the boot counter
#define BOOT_CELLS 16                          // y = 0, z = 2, x = 0..15: count + check hash
#define BOOT_MAGIC 0x6B63626Fu

enum { S_EMPTY = 0, S_NEED, S_LOAD, S_GEN, S_READY };
enum { TAG_WRITE, TAG_CHECK, TAG_CLEAR, TAG_READ };

#if KC_GEN_BITMAP
static uint8_t  generated[WORLD_CHUNKS * WORLD_CHUNKS / 8];   // 8 KB: chunk was generated before
#else
static uint32_t tag_key;                       // hash of seed, format and boot nonce
static uint32_t n_tag_hit, n_tag_miss;
static uint32_t boot_nonce;                    // laptop test only
static uint32_t boot_count;                    // DDR3 boot counter, this boot's value
static uint32_t boot_rd[2];                    // TAG_READ: the boot cells as found (count, check)
#endif
static uint16_t slot_id[16];                   // chunk id (cz * 256 + cx) this slot holds or fills
static uint8_t  slot_state[16];                // S_EMPTY = holds nothing
static uint16_t dirty_mask;                    // bit s: slot s differs from its DDR3 copy
static uint32_t slot_ticket[16];               // pending load, or the last store from this slot
static int32_t  corner_cx, corner_cz;          // committed window (= WIN_ORIGIN)
static int32_t  target_cx = -1, target_cz = -1;
static int32_t  committed;
static uint32_t issued;                        // tickets handed out
static int32_t  storage_ok;
static int32_t  started;
static uint32_t n_generated;

// ---------------------------------------------------------------- low level --------------
uint32_t chunk_load(int cx, int cz) {
    if (!storage_ok) return issued;            // fallback: no-op, already "done"
    hal_mmio_w(MMIO_CHUNK_CMD, ((uint32_t)cz << 8) | (uint32_t)cx);
    return ++issued;
}

uint32_t chunk_store(int cx, int cz) {
    if (!storage_ok) return issued;
    hal_mmio_w(MMIO_CHUNK_CMD, (1u << 31) | ((uint32_t)cz << 8) | (uint32_t)cx);
    return ++issued;
}

int chunk_done(uint32_t ticket) { return (int32_t)(hal_mmio_r(MMIO_CHUNK_DONE) - ticket) >= 0; }

void chunk_wait(uint32_t ticket) { while (!chunk_done(ticket)) {} }

void slot_valid(int cx, int cz, int on) {
    uint32_t bit = 1u << ((cz & 3) * 4 + (cx & 3));
    uint32_t v = hal_mmio_r(MMIO_SLOT_VALID);
    hal_mmio_w(MMIO_SLOT_VALID, on ? (v | bit) : (v & ~bit));
}

void window_origin(int corner_x, int corner_z) {
    hal_mmio_w(MMIO_WIN_ORIGIN, (uint32_t)(corner_x & 63) | ((uint32_t)(corner_z & 63) << 8));
}

// ---------------------------------------------------------------- helpers ----------------
#if !KC_GEN_BITMAP
__attribute__((noinline))   // one copy for this file's hashes (.text)
static uint32_t h32(uint32_t x) { return hash32(x); }
#endif
#if KC_GEN_BITMAP
static int32_t gen_bit(int32_t id) { return (generated[id >> 3] >> (id & 7)) & 1; }
static void    gen_set(int32_t id) { generated[id >> 3] |= (uint8_t)(1u << (id & 7)); }
#else
// Tag cells of chunk id at its window position (chunk BOOT_ID: the boot cells too).
// TAG_CHECK returns 1 on a match and TAG_READ fills boot_rd; both need the slot's SLOT_VALID
// bit on. TAG_WRITE and TAG_CLEAR need it off.
__attribute__((noinline))   // one copy, not three inlined ones (.text)
static int32_t tag_cells(int32_t id, int32_t mode) {
    int32_t wx = ((id & 255) - corner_cx) * CHUNK_W, wz = ((id >> 8) - corner_cz) * CHUNK_W;
    int32_t ok = 1, n = TAG_CELLS + (id == BOOT_ID ? BOOT_CELLS : 0);
    uint32_t w = 0;
    for (int32_t k = 0; k < n; k++) {
        if (!(k & 7))
            w = k < TAG_CELLS ? h32((uint32_t)id * 0x9E3779B1u ^ h32(tag_key + (uint32_t)k * 0x85EBCA6Bu))
              : k < TAG_CELLS + 8 ? boot_count : h32(boot_count ^ BOOT_MAGIC);
        int32_t x = (wx + (k & 15)) & 63, z = (wz + (k >> 4)) & 63;
        uint8_t v = (uint8_t)((w >> ((k & 7) * 4)) & 15);
        if (mode == TAG_WRITE)      hal_win_set(x, 0, z, v);
        else if (mode == TAG_CHECK) ok &= k >= TAG_CELLS || hal_win_get(x, 0, z) == v;
        else if (mode == TAG_READ)  { if (k >= TAG_CELLS) boot_rd[(k >> 3) & 1] |= (uint32_t)hal_win_get(x, 0, z) << ((k & 7) * 4); }
        else                        hal_win_set(x, 0, z, B_BEDROCK);
    }
    return ok;
}

// Startup, window corner 0: load chunk (0, 0), bump the counter in its boot cells, store it
// back (tag_cells writes them; its tag cells get a key-0 tag no boot will match). Runs
// before any window chunk is requested; the engine is in order, so the window's own load of
// slot 0 comes after this store has read the slot out.
__attribute__((noinline))   // startup only: keep it out of world_update (.text)
static void boot_count_bump(void) {
    chunk_wait(chunk_load(0, 0));
    slot_valid(0, 0, 1);                                      // reads of an invalid slot are air
    boot_rd[0] = boot_rd[1] = 0;
    tag_cells(BOOT_ID, TAG_READ);
    slot_valid(0, 0, 0);
    boot_count = boot_rd[1] == h32(boot_rd[0] ^ BOOT_MAGIC) ? boot_rd[0] + 1 : h32(boot_rd[0] ^ boot_rd[1]);
    tag_cells(BOOT_ID, TAG_WRITE);
    chunk_wait(chunk_store(0, 0));
}

static void puts_nonce(uint32_t v) {
    char b[] = "kc: chunk tag nonce 0x00000000\n";
    for (int32_t i = 0; i < 8; i++) {
        int32_t d = (int32_t)(v >> (28 - 4 * i)) & 15;
        b[22 + i] = (char)(d < 10 ? '0' + d : 'a' - 10 + d);
    }
    hal_puts(b);
}
#endif
static int32_t slot_of(int32_t cx, int32_t cz) { return (cz & 3) * 4 + (cx & 3); }

static int32_t window_c0(int32_t p) {
    return iclamp((p - 24) >> 4, 0, WORLD_CHUNKS - 4);       // = round((p - 32) / 16)
}

static void slot_ready(int32_t s) {
    slot_state[s] = S_READY;
    int32_t sx = s & 3, sz = s >> 2;                          // remesh it and its neighbors
    MESH_MARK_SLOT(s);
    MESH_MARK_SLOT(sz * 4 + ((sx + 1) & 3)); MESH_MARK_SLOT(sz * 4 + ((sx + 3) & 3));
    MESH_MARK_SLOT(((sz + 1) & 3) * 4 + sx); MESH_MARK_SLOT(((sz + 3) & 3) * 4 + sx);
    (void)sx; (void)sz;
}

// ---------------------------------------------------------------- world_update -----------
void world_update(int px, int pz) {
    if (!started) {                                           // first call: storage check
        uint32_t t0 = hal_mmio_r(MMIO_CYCLES);
#if KC_NO_DDR
        storage_ok = 0;
#else
        while (!(hal_mmio_r(MMIO_DDR_STATUS) & 1u) && hal_mmio_r(MMIO_CYCLES) - t0 < CAL_TIMEOUT_CYCLES) {}
        storage_ok = (int32_t)(hal_mmio_r(MMIO_DDR_STATUS) & 1u);
#endif
        hal_puts(storage_ok ? "kc: ddr3 chunk store ready\n" : "kc: no ddr3, generating every chunk\n");
        issued = hal_mmio_r(MMIO_CHUNK_DONE);
        for (int32_t s = 0; s < 16; s++) { slot_state[s] = S_EMPTY; slot_ticket[s] = issued; }
        hal_mmio_w(MMIO_SLOT_VALID, 0);
        window_origin(0, 0);                                  // corner 0 until the first commit
#if !KC_GEN_BITMAP
        if (storage_ok && !KC_TAG_PERSIST) boot_count_bump();
#endif
    }

    // 1-2. New target: evict slots that hold the wrong chunk.
    int32_t tcx = window_c0(px), tcz = window_c0(pz);
    if (tcx != target_cx || tcz != target_cz) {
        target_cx = tcx; target_cz = tcz;
        for (int32_t s = 0; s < 16; s++) {
            int32_t cx = tcx + (((s & 3) - tcx) & 3);         // chunk cx lives in slot cx & 3
            int32_t cz = tcz + (((s >> 2) - tcz) & 3);
            int32_t want = cz * WORLD_CHUNKS + cx;
            if (slot_state[s] != S_EMPTY && slot_id[s] == want) continue;
            int32_t old = slot_id[s];
            int32_t store = slot_state[s] == S_READY && (dirty_mask >> s & 1);
            if (slot_state[s] != S_EMPTY) {
                slot_valid(old & 255, old >> 8, 0);           // 1. hardware reads are air now
                MESH_MARK_SLOT(s);                            // drop its old mesh
            }
            slot_id[s] = (uint16_t)want;                      // world_get / mesher: not loaded
            slot_state[s] = S_NEED;
            dirty_mask &= (uint16_t)~(1u << s);
            if (store) {
#if !KC_GEN_BITMAP
                if (storage_ok) tag_cells(old, TAG_WRITE);    // 2. tag into the invalid slot
#endif
                slot_ticket[s] = chunk_store(old & 255, old >> 8);   // 3. reads tags + chunk
            }
        }
    }

    // 3. Start loads; generate (all at startup, then one per frame).
    int32_t gens = started ? 1 : 16;
    void *gen_scratch = 0;                                    // arena, once per call (startup: 16 gens)
    for (int32_t s = 0; s < 16; s++) {
        if (slot_state[s] != S_NEED) continue;
        int32_t id = slot_id[s];
#if KC_GEN_BITMAP
        if (storage_ok && gen_bit(id)) {
#else
        if (storage_ok) {                                     // the tag decides once it lands
#endif
            slot_ticket[s] = chunk_load(id & 255, id >> 8);   // engine is in order: after any store
            slot_state[s] = S_LOAD;
        } else {
            slot_state[s] = S_GEN;
        }
    }
    if (!started) {                                           // startup: whole window now
        chunk_wait(issued);
#if !KC_GEN_BITMAP
        // Boot nonce: the DDR3 boot counter, plus CYCLES after the first loads (which cross
        // into the DDR3 clock domain) for boots whose counter was lost.
        uint32_t nonce = KC_TAG_PERSIST ? 0
                       : h32(hal_mmio_r(MMIO_CYCLES) ^ 0x6B637467u) ^ h32(boot_count * 0x9E3779B1u);
        tag_key = h32(h32(WORLD_SEED ^ TAG_FORMAT) + nonce);
        if (storage_ok) puts_nonce(nonce);
        boot_nonce = nonce;
#endif
    }
    for (int32_t s = 0; s < 16; s++) {
        int32_t id = slot_id[s];
        if (slot_state[s] == S_LOAD && chunk_done(slot_ticket[s])) {
#if KC_GEN_BITMAP
            slot_valid(id & 255, id >> 8, 1);
            slot_ready(s);
#else
            slot_valid(id & 255, id >> 8, 1);                 // only for the 32 tag reads
            int32_t hit = tag_cells(id, TAG_CHECK);
            slot_valid(id & 255, id >> 8, 0);
            if (hit) {
                tag_cells(id, TAG_CLEAR);                     // bedrock back, still invalid
                slot_valid(id & 255, id >> 8, 1);
                slot_ready(s);
                n_tag_hit++;
            } else {                                          // DDR3 garbage or an old boot
                slot_state[s] = S_GEN;
                n_tag_miss++;
            }
#endif
        }
        if (slot_state[s] == S_GEN && gens > 0) {
            chunk_wait(slot_ticket[s]);                       // a store may still be reading the slot
            slot_valid(id & 255, id >> 8, 1);                 // valid first: tree code reads back
            if (!gen_scratch) gen_scratch = arena_alloc(TERRAIN_SCRATCH_BYTES);
            terrain_gen_chunk(id & 255, id >> 8, corner_cx * CHUNK_W, corner_cz * CHUNK_W, gen_scratch);
#if KC_GEN_BITMAP
            gen_set(id);
#endif
            dirty_mask |= (uint16_t)(1u << s);                // generated chunks get stored too
            n_generated++;
            gens--;
            slot_ready(s);
        }
    }

    // 4. Whole window in: commit it.
    int32_t all = 1;
    for (int32_t s = 0; s < 16; s++) all &= slot_state[s] == S_READY;
    if (all && (!committed || corner_cx != target_cx || corner_cz != target_cz)) {
        corner_cx = target_cx; corner_cz = target_cz;
        window_origin(corner_cx * CHUNK_W, corner_cz * CHUNK_W);
        committed = 1;
    }
    started = 1;
}

// ---------------------------------------------------------------- block access -----------
static int32_t loaded_slot(int x, int z) {
    if (x < 0 || z < 0) return -1;
    int32_t cx = x >> 4, cz = z >> 4;
    int32_t s = slot_of(cx, cz);
    return (slot_state[s] == S_READY && slot_id[s] == cz * WORLD_CHUNKS + cx) ? s : -1;
}

uint8_t world_get(int x, int y, int z) {
    if (y < 0) return B_BEDROCK;
    if (y >= WIN_Y || loaded_slot(x, z) < 0) return B_AIR;
    return hal_win_get((x - corner_cx * CHUNK_W) & 63, y, (z - corner_cz * CHUNK_W) & 63);
}

void world_set(int x, int y, int z, uint8_t t) {
    int32_t s = loaded_slot(x, z);
    if (s < 0 || (uint32_t)y >= WIN_Y) return;
    hal_win_set((x - corner_cx * CHUNK_W) & 63, y, (z - corner_cz * CHUNK_W) & 63, t);
    dirty_mask |= (uint16_t)(1u << s);
    MESH_MARK_BLOCK(x, z);
}

int world_corner_x(void) { return corner_cx * CHUNK_W; }
int world_corner_z(void) { return corner_cz * CHUNK_W; }
int world_ready(void) { return committed && corner_cx == target_cx && corner_cz == target_cz; }
int world_storage_ok(void) { return storage_ok; }
int world_loaded(int x, int z) { return loaded_slot(x, z) >= 0; }
#if KC_RASTER
uint32_t world_column_bits(int x, int z) {
    if (loaded_slot(x, z) < 0) return 0xFFFFFFFFu;
    int32_t wx = (x - corner_cx * CHUNK_W) & 63, wz = (z - corner_cz * CHUNK_W) & 63;
    uint32_t c = 0;
    for (int32_t y = 0; y < WIN_Y; y++) c |= (uint32_t)(hal_win_get(wx, y, wz) != B_AIR) << y;
    return c;
}
#endif
int world_slot_chunk(int s) { return slot_state[s] == S_READY ? slot_id[s] + 1 : 0; }
uint32_t world_stats_generated(void) { return n_generated; }
#if KC_GEN_BITMAP
uint32_t world_stats_tag_hits(void) { return 0; }
uint32_t world_stats_tag_misses(void) { return 0; }
#else
uint32_t world_stats_tag_hits(void) { return n_tag_hit; }
uint32_t world_stats_tag_misses(void) { return n_tag_miss; }
#endif

#ifdef KC_HOST
uint32_t world_boot_nonce(void) {
#if KC_GEN_BITMAP
    return 0;
#else
    return boot_nonce;
#endif
}
uint32_t world_boot_count(void) {
#if KC_GEN_BITMAP
    return 0;
#else
    return boot_count;
#endif
}
// Laptop only: forget everything, as a reset would (DDR3 keeps its contents).
void world_reboot(void) {
    for (int32_t s = 0; s < 16; s++) { slot_id[s] = 0; slot_state[s] = S_EMPTY; slot_ticket[s] = 0; }
#if KC_GEN_BITMAP
    for (uint32_t i = 0; i < sizeof generated; i++) generated[i] = 0;
#else
    tag_key = 0; n_tag_hit = n_tag_miss = 0;
#endif
    dirty_mask = 0;
    corner_cx = corner_cz = 0;
    target_cx = target_cz = -1;
    committed = 0; issued = 0; storage_ok = 0; started = 0; n_generated = 0;
}
#endif
