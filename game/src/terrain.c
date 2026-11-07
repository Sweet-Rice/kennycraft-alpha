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

static int32_t column_block(int32_t y, int32_t h) {
    if (y == 0) return B_BEDROCK;
    if (y > h) return B_AIR;
    if (y < h - 3) return B_STONE;
    if (h <= 12) return B_SAND;                       // low ground is beach
    return y == h ? B_GRASS : B_DIRT;
}

void terrain_gen_chunk(int32_t cx, int32_t cz, int32_t win_x0, int32_t win_z0) {
    int32_t ax0 = cx * CHUNK_W, az0 = cz * CHUNK_W;
    // Window-relative, wrapped to 0..63: hardware adds WIN_ORIGIN, so this lands on
    // physical abs & 63 whether or not the committed window covers the chunk yet.
    int32_t rx0 = ax0 - win_x0, rz0 = az0 - win_z0;
#define WX(x) (((x) + rx0) & 63)
#define WZ(z) (((z) + rz0) & 63)

    for (int32_t lz = 0; lz < CHUNK_W; lz++)
        for (int32_t lx = 0; lx < CHUNK_W; lx++) {
            int32_t h = terrain_height(ax0 + lx, az0 + lz);
            for (int32_t y = 0; y < WIN_Y; y++)
                hal_win_set(WX(lx), y, WZ(lz), (uint8_t)column_block(y, h));
        }

    // Trees: trunks within 2 blocks of the chunk can drop leaves into it.
    for (int32_t az = az0 - 2; az < az0 + CHUNK_W + 2; az++)
        for (int32_t ax = ax0 - 2; ax < ax0 + CHUNK_W + 2; ax++) {
            if (!terrain_tree_at(ax, az)) continue;
            int32_t h = terrain_height(ax, az);
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
