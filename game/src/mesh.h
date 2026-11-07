// mesh.h — greedy meshing of the world window into vertex / index buffers.
//
// Each of the 16 window slots (one chunk) owns a chain of 1 KB pages from a fixed pool.
// A page holds up to MESH_PAGE_QUADS quads:
//   vertex buffer  uint16  x 4 per quad   chunk-local position, x 5 bits | y 6 | z 5
//   material       uint8   x 1 per quad   face (2:0, 0 +x 1 -x 2 +y 3 -y 4 +z 5 -z) | type << 3
// 113 quads x (8 + 1) bytes = 1,017 bytes per page.
//
// Index buffer: every quad has the same two triangles, so there is ONE shared index buffer
// (mesh_quad_index, 6 entries) drawn with base vertex = quad * 4, the way engines draw quads.
// A per-quad copy would cost 12 of every 21 bytes.
//
// Draw command per slot: the chunk's absolute corner; the rasterizer adds (corner - window
// corner) so moving the window never forces a remesh, only chunks that change.
#ifndef KC_MESH_H
#define KC_MESH_H
#include <stdint.h>

#define MESH_PAGE_QUADS 113                 // fits the uint8 per-page quad count
#ifndef MESH_PAGES
#define MESH_PAGES 52                       // 52 x 1 KB; worst of 60 sampled locations: 42
#endif
#define MESH_NONE 0xFF

typedef struct {
    uint16_t vtx[MESH_PAGE_QUADS * 4];
    uint8_t  mat[MESH_PAGE_QUADS];
    uint8_t  pad[7];
} mesh_page;                                // exactly 1,024 bytes

extern const uint16_t mesh_quad_index[6];   // shared index buffer: 0 1 2, 0 2 3

typedef struct {
    int16_t cx, cz;                         // chunk coordinates, -1 = empty slot
    uint16_t quads;
    uint8_t first_page;                     // MESH_NONE if no quads
} mesh_cmd;                                 // 8 bytes

extern mesh_page mesh_pool[MESH_PAGES];
extern uint8_t   mesh_page_next[MESH_PAGES];
extern uint8_t   mesh_page_quads[MESH_PAGES];   // <= MESH_PAGE_QUADS
extern mesh_cmd  mesh_cmds[16];

#define VTX_PACK(x, y, z) ((uint16_t)((x) | ((y) << 5) | ((z) << 11)))
#define VTX_X(v) ((int32_t)((v) & 31u))
#define VTX_Y(v) ((int32_t)(((v) >> 5) & 63u))
#define VTX_Z(v) ((int32_t)(((v) >> 11) & 31u))

void mesh_init(void);
void mesh_mark_slot(int32_t slot);          // chunk in this slot changed; remesh before next frame
void mesh_mark_block(int32_t ax, int32_t az); // block edit: its slot, plus neighbors on a border
void mesh_update(void);                     // rebuild every marked slot (lane 0)
int32_t mesh_pages_used(void);
int32_t mesh_total_quads(void);
#ifdef KC_HOST
extern uint32_t mesh_stat_slots;            // laptop profiling: chunks meshed since boot
#endif

#endif
