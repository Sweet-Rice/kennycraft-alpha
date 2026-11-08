// Flat-colored box models (voxels, vertex colors). They walk to a target; no collision.
#ifndef KC_ENTITY_H
#define KC_ENTITY_H
#include "fixed.h"
#include "trace.h"

enum { ENT_TRADER, ENT_CONTRACTOR, ENT_CHICKEN, ENT_ZOMBIE, ENT_KINDS };
#define ENT_MAX 8
#define ENT_PARTS_MAX 9
#define ENT_BOX_MAX (ENT_MAX * ENT_PARTS_MAX)

typedef struct {
    q16 lo[3], hi[3];           // eye-relative: window-relative bounds minus the camera origin
    int16_t sx0, sy0, sx1, sy1; // Inclusive; sx0 > sx1 means off screen.
    q16 zlim;                   // no ray hits the box at t <= zlim (nearest depth minus a margin)
    uint8_t color;
    uint8_t pad[3];
} ent_box;
typedef struct { q16 t; int32_t col; } ent_hit;

extern ent_box ent_boxes[ENT_BOX_MAX];
extern int32_t ent_nboxes;
extern int32_t ent_nrects;  // entities with a screen rect this frame
// 1 if any entity's screen rect overlaps the 4x2 block at (bx, by). Uniform across lanes.
int32_t ent_block(int32_t bx, int32_t by);
// Per block row (by / 2), the pixel columns [x0, x1] that some entity's screen rect covers in
// that row (x0 > x1: none). Built by entity_prepare, so the kernel loads it once per row and
// tests each block in registers: (bx + 3 >= x0) & (bx <= x1) is ent_block or a superset of
// it (the span can bridge two entities; ent_composite then finds no box there).
#define ENT_ROWS 120            // 240 / 2: block rows at 320 x 240
extern int16_t ent_span[ENT_ROWS][2];
// Per block row, one bit per 4-pixel block column (80 at 320 wide): set when some entity's
// rect overlaps that block, exactly ent_block. Tested only inside the span, so the gap the
// span bridges between two entities costs one uniform load instead of an ent_composite call.
extern uint32_t ent_bits[ENT_ROWS][3];

// Lane 0. Absolute feet center. Facing: 0 +z, 1 +x, 2 -z, 3 -x.
// Returns the entity index, or -1 for invalid kind/facing or a full table.
int32_t entity_add(int32_t kind, q16 x, q16 y, q16 z, int32_t facing);
void entity_clear(void);
int32_t entity_count(void);
// Lane 0. Walk entity id toward (tx, tz) at its kind's speed; -1 for a bad id.
int32_t entity_move(int32_t id, q16 tx, q16 tz);
void entity_get(int32_t id, q16 pos[3], int32_t *facing);
// Lane 0, once per frame: step every entity toward its target and onto the ground.
void entity_tick(q16 dt);
// Lane 0, after write_camera(): rebuild boxes for the committed window and camera.
void entity_prepare(void);
// Per lane: composite over the world color and hit distance.
// (bx, by): the 4x2 block; tdx..tdz and signs: the ray's tDeltas and step signs (VSET 4..7).
uint8_t ent_composite(int32_t bx, int32_t by, q16 tdx, q16 tdy, q16 tdz, uint32_t signs,
                      q16 tw, uint8_t col);
#endif
