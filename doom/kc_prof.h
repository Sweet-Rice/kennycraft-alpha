// KC_PROF=1 profile hooks (doom/kc_prof.c).
#ifndef KC_PROF_H
#define KC_PROF_H

#include <stdint.h>

// After R_ExecuteSetViewSize: route colfunc/basecolfunc and spanfunc through
// the timing shims.
void kc_prof_hook_draw(void);
// Once per frame from DG_DrawFrame: print and clear the counters.
void kc_prof_frame(uint32_t draw_cycles);

#endif
