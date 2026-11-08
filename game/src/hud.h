// hud.h — small HUD drawing on the back framebuffer (lane 0): rects, 3x5 text, numbers.
#ifndef KC_HUD_H
#define KC_HUD_H
#include <stdint.h>

void    hud_rect(int32_t x, int32_t y, int32_t w, int32_t h, uint8_t c);
// Text on a black plate, s = pixel scale. Returns the width drawn.
int32_t hud_text(int32_t x, int32_t y, int32_t s, const char *str, uint8_t c);
// Decimal digits of v at o, without a divide (the chip has no DIV). Returns the end.
char   *hud_num(char *o, uint32_t v);

#endif
