// raster.h — tile-based rasterizer (the mobile-GPU design).
//
// Per frame:
//   1. Bin (lane 0): walk every chunk's quads, cull back faces and the view frustum, and
//      append each surviving quad to the command list of every 16x16 screen tile it covers.
//   2. Tiles (all lanes): for each tile, clear a 16x16 tile buffer (2-byte color + 2-byte
//      depth = 1 KB, no stencil), rasterize the tile's quads into it with a depth test, then
//      write the finished tile to the back framebuffer once.
// The framebuffer is touched once per pixel per frame; depth never leaves the tile.
#ifndef KC_RASTER_H
#define KC_RASTER_H
#include <stdint.h>

#define TILE 16
#ifndef RASTER_VIS_CAP
#define RASTER_VIS_CAP 1024      // visible quads per frame (worst golden shot: 469)
#endif
#ifndef RASTER_BIN_CAP
#define RASTER_BIN_CAP 4096      // tile command list entries per frame (worst: 1,571 at 320x240)
#endif

typedef struct {
    uint32_t quads_visible, quads_culled, bin_entries, tri_setups, pixels_tested, pixels_covered, pixels_written;
    uint32_t vis_overflow, bin_overflow;
    // Chunk frustum culling and the split pixel path (laptop stats only)
    uint32_t chunks_drawn, chunks_frustum_culled, quads_skipped;
    uint32_t quads_backface, quads_clipped;          // split of quads_culled
    uint32_t groups_covered, groups_shaded;          // 8-pixel groups with a covered / a passing lane
    uint32_t pixels_in_shaded_groups;                // covered pixels that also ran the color half
} raster_stats_t;
extern raster_stats_t raster_stats;

void raster_bin(void);           // game side, lane 0: per-tile command lists for this frame
void kc_raster_kernel(void);     // kernel: call with all lanes active


#endif
