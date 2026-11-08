#ifndef KC_MAIN_H
#define KC_MAIN_H
#include <stdint.h>
void kc_init(void);
void kc_frame(void);
void kc_set_resolution(int32_t width);   // 160 or 320
void kc_set_max_steps(int32_t steps);
void kc_draw_world(void);                // the ray tracer (VTRACE on Stage 2)
// Last frame's timing in CYCLES ticks (20 ns): the whole frame and the draw (entity prep, the
// swap wait and the kernel), for the performance overlay. Zero in KC_FIXED_DT builds, which
// keep CYCLES out of game state.
typedef struct { uint32_t frame, draw; } kc_perf_t;
extern kc_perf_t kc_perf;
#endif
