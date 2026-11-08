#ifndef KC_MAIN_H
#define KC_MAIN_H
#include <stdint.h>
void kc_init(void);
void kc_frame(void);
void kc_set_resolution(int32_t width);   // 160 or 320
void kc_set_max_steps(int32_t steps);
void kc_draw_world(void);                // the ray tracer (VTRACE on Stage 2)
// Last frame's length in CYCLES ticks (20 ns), for the performance overlay. Zero in
// KC_FIXED_DT builds, which keep CYCLES out of game state.
extern uint32_t kc_frame_cycles;
#endif
