#ifndef KC_MAIN_H
#define KC_MAIN_H
#include <stdint.h>
void kc_init(void);
void kc_frame(void);
void kc_set_resolution(int32_t width);   // 160 or 320
void kc_set_max_steps(int32_t steps);
void kc_draw_world(void);                // ray tracer or tile rasterizer
#ifdef KC_HOST
extern int32_t kc_use_raster;            // laptop flips this to compare with the ray tracer
#elif KC_RASTER
#define kc_use_raster 1                  // chip: nothing writes it, so the ray-trace frame path is dropped
#endif
#endif
