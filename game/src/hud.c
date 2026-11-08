// hud.c — HUD drawing shared by the overlay and the CR6 bank HUD (lane 0).
#include "hud.h"
#include "render.h"
#include "kc_hal.h"

// 3x5 glyphs, rows top to bottom, 3 bits each (bit 2 = left column).
static const uint16_t font[] = {
    0x7B6F, 0x2C97, 0x73E7, 0x73CF, 0x5BC9, 0x79CF, 0x79EF, 0x7249, 0x7BEF, 0x7BCF,   // 0-9
    0x5BAD, 0x7927, 0x6B6D, 0x5BD2, 0x12A4, 0x72C2,                                  // K C N Y / ?
};
static int32_t glyph(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    return c == 'K' ? 10 : c == 'C' ? 11 : c == 'N' ? 12 : c == 'Y' ? 13 : c == '/' ? 14 : c == '?' ? 15 : -1;
}

void hud_rect(int32_t x, int32_t y, int32_t w, int32_t h, uint8_t c) {
    for (int32_t j = 0; j < h; j++)
        for (int32_t i = 0; i < w; i++) hal_fb_put((uint32_t)((y + j) * FB_STRIDE + x + i), c);
}

int32_t hud_text(int32_t x, int32_t y, int32_t s, const char *str, uint8_t c) {
    int32_t n = 0;
    while (str[n]) n++;
    hud_rect(x - s, y - s, n * 4 * s + s, 7 * s, PIX(COLOR_BLACK, 0, 0));
    for (int32_t i = 0; i < n; i++) {
        int32_t g = glyph(str[i]);
        if (g < 0) continue;
        for (int32_t r = 0; r < 5; r++)
            for (int32_t col = 0; col < 3; col++)
                if ((font[g] >> (14 - r * 3 - col)) & 1) hud_rect(x + (i * 4 + col) * s, y + r * s, s, s, c);
    }
    return n * 4 * s;
}

char *hud_num(char *o, uint32_t v) {
    static const uint16_t p10[] = { 10000, 1000, 100, 10, 1 };
    int32_t any = 0;
    for (int32_t i = 0; i < 5; i++) {
        char d = '0';
        while (v >= p10[i]) { v -= p10[i]; d++; }
        if (d != '0' || any || i == 4) { *o++ = d; any = 1; }
    }
    return o;
}
