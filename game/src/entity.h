// Flat-colored box models (voxels, vertex colors). They walk to a target; no collision.
#ifndef KC_ENTITY_H
#define KC_ENTITY_H
#include "fixed.h"
#include "trace.h"

enum { ENT_TRADER, ENT_CONTRACTOR, ENT_PIG, ENT_ZOMBIE, ENT_KINDS };
#define ENT_MAX 8
#define ENT_PARTS_MAX 9
#define ENT_BOX_MAX (ENT_MAX * ENT_PARTS_MAX)

typedef struct {
    q16 lo[3], hi[3];
    int16_t sx0, sy0, sx1, sy1; // Inclusive; sx0 > sx1 means off screen.
    uint8_t color;
    uint8_t pad[3];
} ent_box;
typedef struct { q16 t; int32_t col; } ent_hit;

extern ent_box ent_boxes[ENT_BOX_MAX];
extern int32_t ent_nboxes;

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
uint8_t ent_composite(int32_t px, int32_t py, const q16 o[3], const kc_ray *r, q16 tw, uint8_t col);
void ent_box_hit(const ent_box *b, const q16 o[3], const kc_ray *r, ent_hit *h);
#endif
