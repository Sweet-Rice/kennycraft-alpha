// kc_budget.h — the 192 KB rendering + real-time budget, checked at compile time.
// Chunk storage (memory API, up to 256 MB) is outside this budget.
//
// Framebuffers: Josh's plan puts the two framebuffers in main memory, so they are listed
// but not counted by default. Build with -DKC_BUDGET_COUNT_FB=1 to count them too; at
// 160x120 (1 byte per pixel, double-buffered) everything still fits.
#ifndef KC_BUDGET_H
#define KC_BUDGET_H
#include "kc_hal.h"
#include "mesh.h"
#include "raster.h"

#define KC_BUDGET_BYTES      (192 * 1024)

#define BUDGET_WORLD         (WIN_X * WIN_Y * WIN_Z / 2)           // 4 bits per block, 1 copy
#define BUDGET_TEXTURES      TEX_BYTES                              // 1 byte per texel
#define BUDGET_PALETTE       (256 * 2)
#define BUDGET_MESH          (MESH_PAGES * 1024)
#define BUDGET_CMDLISTS      (RASTER_VIS_CAP * 8 + RASTER_BIN_CAP * 2 + (300 + 1) * 2 + 300 * 2)
#define BUDGET_TILE          ((TILE * TILE + 1) * 4)                // 32-bit word: color 12, depth 12, stencil 8
#define BUDGET_MESHER        (18 * 18 * 4 + 32 * 16)                // column bitmasks + slice mask
#define BUDGET_CHUNKS        (512 * 4 + 256 * 5 + 16 * 5)          // stored-chunk set, fallback edit log, slots
#define BUDGET_FB_160        (2 * 160 * 120)

#ifndef KC_BUDGET_COUNT_FB
#define KC_BUDGET_COUNT_FB 0
#endif

#define BUDGET_TOTAL (BUDGET_WORLD + BUDGET_TEXTURES + BUDGET_PALETTE + BUDGET_MESH + BUDGET_CMDLISTS \
                      + BUDGET_TILE + BUDGET_MESHER + BUDGET_CHUNKS + KC_BUDGET_COUNT_FB * BUDGET_FB_160)

_Static_assert(BUDGET_TOTAL <= KC_BUDGET_BYTES, "rendering memory is over the 192 KB budget");
_Static_assert(BUDGET_TOTAL + BUDGET_FB_160 <= KC_BUDGET_BYTES,
               "over 192 KB if the 160x120 framebuffers end up inside the budget");
_Static_assert(sizeof(mesh_page) == 1024, "mesh pages must be exactly 1 KB");

#endif
