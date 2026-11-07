// terrain.c — value-noise heightmap, layered columns, hashed trees. Fixed point only.
#include "terrain.h"
#include "blocks.h"
#include "fixed.h"
#include "kc_hal.h"

static q16 smooth(q16 f) { return qmul(qmul(f, f), 3 * Q16_ONE - 2 * f); }

// Value noise in [0, 1) with a grid cell of 2^shift blocks.
static q16 vnoise(int32_t ax, int32_t az, int32_t shift, uint32_t seed) {
    int32_t ix = ax >> shift, iz = az >> shift;
    q16 sx = smooth((ax & ((1 << shift) - 1)) << (16 - shift));
    q16 sz = smooth((az & ((1 << shift) - 1)) << (16 - shift));
    q16 c00 = (q16)(hash2(ix, iz, seed) & 0xFFFF);
    q16 c10 = (q16)(hash2(ix + 1, iz, seed) & 0xFFFF);
    q16 c01 = (q16)(hash2(ix, iz + 1, seed) & 0xFFFF);
    q16 c11 = (q16)(hash2(ix + 1, iz + 1, seed) & 0xFFFF);
    q16 a = c00 + qmul(c10 - c00, sx);
    q16 b = c01 + qmul(c11 - c01, sx);
    return a + qmul(b - a, sz);
}

#ifdef KC_HOST
uint32_t terrain_height_calls;
#endif

int32_t terrain_height(int32_t ax, int32_t az) {
#ifdef KC_HOST
    terrain_height_calls++;
#endif
    q16 n1 = vnoise(ax, az, 5, WORLD_SEED);          // 32-block hills
    q16 n2 = vnoise(ax, az, 3, WORLD_SEED ^ 0x55AAu); // 8-block bumps
    return 10 + ((n1 * 12) >> 16) + ((n2 * 4) >> 16);
}

int32_t terrain_tree_at(int32_t ax, int32_t az) {
    if ((hash2(ax, az, WORLD_SEED ^ 0x7EEu) & 127u) != 0) return 0;
    int32_t h = terrain_height(ax, az);
    return h > 12 && h <= 21;
}

// Per-chunk noise (scratch from the arena). A chunk is 16 blocks on a 16-aligned corner, so per
// axis it sits inside ONE 32-block cell of octave 1 and spans exactly TWO 8-block cells of
// octave 2: 4 + 9 corner hashes per chunk instead of 8 per column, and the lerps along x are
// done once per chunk. A column then costs 2 qmul. Same operations in the same order as
// terrain_height, so heights are bit-identical.
typedef struct {
    q16 a1[16], d1[16];       // octave 1 along x: a = lerp at iz, d = (lerp at iz + 1) - a
    q16 a2[16], d2[16];       // octave 2, for the current 8-block z cell
    q16 s3[8];                // smooth() of the 8 octave-2 fractions (shared by x and z)
} gen_scratch;                // 288 bytes
_Static_assert(sizeof(gen_scratch) <= TERRAIN_SCRATCH_BYTES, "TERRAIN_SCRATCH_BYTES");

static void lerp_x(q16 *a, q16 *d, int32_t n, const q16 *s, q16 c00, q16 c10, q16 c01, q16 c11) {
    for (int32_t i = 0; i < n; i++) {
        q16 ta = c00 + qmul(c10 - c00, s[i]);
        q16 tb = c01 + qmul(c11 - c01, s[i]);
        a[i] = ta; d[i] = tb - ta;
    }
}

static void octave2_row(gen_scratch *g, int32_t ax0, int32_t iz) {
    uint32_t seed = WORLD_SEED ^ 0x55AAu;
    int32_t ix = ax0 >> 3;
    q16 h0[3], h1[3];
    for (int32_t i = 0; i < 3; i++) {
        h0[i] = (q16)(hash2(ix + i, iz, seed) & 0xFFFF);
        h1[i] = (q16)(hash2(ix + i, iz + 1, seed) & 0xFFFF);
    }
    lerp_x(g->a2, g->d2, 8, g->s3, h0[0], h0[1], h1[0], h1[1]);
    lerp_x(g->a2 + 8, g->d2 + 8, 8, g->s3, h0[1], h0[2], h1[1], h1[2]);
}

void terrain_gen_chunk(int32_t cx, int32_t cz, int32_t win_x0, int32_t win_z0, void *scratch) {
    gen_scratch *g = (gen_scratch *)scratch;
    int32_t ax0 = cx * CHUNK_W, az0 = cz * CHUNK_W;
    // Window-relative, wrapped to 0..63: hardware adds WIN_ORIGIN, so this lands on
    // physical abs & 63 whether or not the committed window covers the chunk yet.
    int32_t rx0 = ax0 - win_x0, rz0 = az0 - win_z0;
#define WX(x) (((x) + rx0) & 63)
#define WZ(z) (((z) + rz0) & 63)

    for (int32_t i = 0; i < 8; i++) g->s3[i] = smooth(i << 13);
    {   // octave 1: one cell for the whole chunk; x fractions start at 0 or 16
        int32_t ix = ax0 >> 5, iz = az0 >> 5, fx = (ax0 & 31) << 11;
        q16 c00 = (q16)(hash2(ix, iz, WORLD_SEED) & 0xFFFF);
        q16 c10 = (q16)(hash2(ix + 1, iz, WORLD_SEED) & 0xFFFF);
        q16 c01 = (q16)(hash2(ix, iz + 1, WORLD_SEED) & 0xFFFF);
        q16 c11 = (q16)(hash2(ix + 1, iz + 1, WORLD_SEED) & 0xFFFF);
        q16 sx[16];
        for (int32_t lx = 0; lx < 16; lx++) sx[lx] = smooth(fx + (lx << 11));
        lerp_x(g->a1, g->d1, 16, sx, c00, c10, c01, c11);
    }

    for (int32_t lz = 0; lz < CHUNK_W; lz++) {
        if ((lz & 7) == 0) octave2_row(g, ax0, (az0 + lz) >> 3);
        q16 sz1 = smooth(((az0 + lz) & 31) << 11), sz2 = g->s3[lz & 7];
        int32_t z = WZ(lz);
        for (int32_t lx = 0; lx < CHUNK_W; lx++) {
            q16 n1 = g->a1[lx] + qmul(g->d1[lx], sz1);
            q16 n2 = g->a2[lx] + qmul(g->d2[lx], sz2);
            int32_t h = 10 + ((n1 * 12) >> 16) + ((n2 * 4) >> 16);   // = terrain_height, 10..25
            int32_t x = WX(lx), y = 0;
            // Column layers: bedrock, stone to h - 4, then 4 of sand (low ground) or dirt + grass.
            hal_win_set(x, y++, z, B_BEDROCK);
            for (; y < h - 3; y++) hal_win_set(x, y, z, B_STONE);
            if (h <= 12) for (; y <= h; y++) hal_win_set(x, y, z, B_SAND);
            else {
                for (; y < h; y++) hal_win_set(x, y, z, B_DIRT);
                hal_win_set(x, y++, z, B_GRASS);
            }
            for (; y < WIN_Y; y++) hal_win_set(x, y, z, B_AIR);
        }
    }

    // Trees: trunks within 2 blocks of the chunk can drop leaves into it. The hash rejects
    // 127 of 128 positions before any noise is evaluated.
    for (int32_t az = az0 - 2; az < az0 + CHUNK_W + 2; az++)
        for (int32_t ax = ax0 - 2; ax < ax0 + CHUNK_W + 2; ax++) {
            if ((hash2(ax, az, WORLD_SEED ^ 0x7EEu) & 127u) != 0) continue;
            int32_t h = terrain_height(ax, az);           // = terrain_tree_at, height once
            if (h <= 12 || h > 21) continue;
            for (int32_t dy = 3; dy <= 6; dy++) {
                int32_t r = dy <= 4 ? 2 : 1;
                for (int32_t dz = -r; dz <= r; dz++)
                    for (int32_t dx = -r; dx <= r; dx++) {
                        if (r == 2 && iabs(dx) == 2 && iabs(dz) == 2) continue;  // round corners
                        if (dy == 6 && dx != 0 && dz != 0) continue;              // plus-shaped top
                        int32_t bx = ax + dx - ax0, bz = az + dz - az0, y = h + dy;
                        if ((uint32_t)bx >= CHUNK_W || (uint32_t)bz >= CHUNK_W) continue;
                        if (hal_win_get(WX(bx), y, WZ(bz)) == B_AIR)
                            hal_win_set(WX(bx), y, WZ(bz), B_LEAVES);
                    }
            }
            int32_t bx = ax - ax0, bz = az - az0;
            if ((uint32_t)bx < CHUNK_W && (uint32_t)bz < CHUNK_W)
                for (int32_t dy = 1; dy <= 4; dy++)
                    hal_win_set(WX(bx), h + dy, WZ(bz), B_LOG);
        }
}
