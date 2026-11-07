// terrain.h — deterministic world generation from absolute block coordinates.
// Any chunk can be regenerated on its own at any time, so DDR3 only has to hold chunks the
// player has edited (and generation is the fallback if DDR3 never calibrates, D14).
#ifndef KC_TERRAIN_H
#define KC_TERRAIN_H
#include <stdint.h>

int32_t terrain_height(int32_t ax, int32_t az);          // surface y, 10..25
int32_t terrain_tree_at(int32_t ax, int32_t az);         // 1 if a tree trunk stands here

// Generate chunk (cx, cz) straight into its window slot; win_x0/z0 = the committed corner
// (WIN_ORIGIN). The slot must be valid (tree code reads blocks back). Lane 0 only.
void terrain_gen_chunk(int32_t cx, int32_t cz, int32_t win_x0, int32_t win_z0);

#ifdef KC_HOST
extern uint32_t terrain_height_calls;                  // laptop profiling only
#endif

#endif
