// doomgeneric platform layer for KennyCraft, Doom configuration
// (HAS_DDR_MEM=1, FB_COUNT=2; doom/README.md).
//
// Screen: Doom draws its 320x200 indexed frame (I_VideoBuffer) straight into
// the 64 KB SCRATCH BRAM at 0x7000_0000, and DG_DrawFrame copies it to
// framebuffer rows 20..219 of the 320x240 back buffer, clearing the letterbox
// rows (the back buffer holds a stale frame). Without editing doomgeneric:
//   --wrap=I_InitGraphics  lets doomgeneric allocate its zone buffer, then
//                          frees it and points I_VideoBuffer at SCRATCH;
//   --wrap=I_FinishUpdate  skips doomgeneric's copy into DG_ScreenBuffer
//                          (DG_ScreenBuffer is SCRATCH too) and draws.
// Palette: RGB888 -> RGB444 at 0x6000_0000 whenever Doom changes it.
// Time: CYCLES (20 ns ticks). Keys: UART RX key bytes, map in map_key.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "doomgeneric.h"
#include "doomkeys.h"
#include "i_video.h"
#include "z_zone.h"

#define MMIO ((volatile uint32_t *)0x50000000u)
#define MMIO_FB_SWAP     0x00
#define MMIO_CYCLES      0x0C
#define MMIO_UART_RX     0x10
#define MMIO_UART_STATUS 0x14
#define MMIO_FB_MODE     0x28

#define FB      ((volatile uint32_t *)0x40000000u)
#define PAL     ((volatile uint32_t *)0x60000000u)
#define SCRATCH ((uint8_t *)0x70000000u)

#define FB_W      320
#define FB_H      240
#define FB_TOP    ((FB_H - DOOMGENERIC_RESY) / 2)    // 20
#define ROW_WORDS (FB_W / 4)

#define TICKS_PER_MS 50000u                          // CYCLES counts 20 ns ticks

static inline uint32_t mmio_r(uint32_t off) { return MMIO[off >> 2]; }
static inline void mmio_w(uint32_t off, uint32_t v) { MMIO[off >> 2] = v; }

// ---- time ---------------------------------------------------------------
static uint64_t ticks;           // CYCLES extended to 64 bits
static uint32_t last_cycles;

static uint64_t now_ticks(void) {
    uint32_t c = mmio_r(MMIO_CYCLES);
    ticks += (uint32_t)(c - last_cycles);
    last_cycles = c;
    return ticks;
}

uint32_t DG_GetTicksMs(void) {
    return (uint32_t)(now_ticks() / TICKS_PER_MS);
}

void DG_SleepMs(uint32_t ms) {
    uint64_t until = now_ticks() + (uint64_t)ms * TICKS_PER_MS;
    while (now_ticks() < until) {}
}

// ---- video --------------------------------------------------------------
static void clear_rows(uint32_t y0, uint32_t y1) {
    for (uint32_t i = y0 * ROW_WORDS; i < y1 * ROW_WORDS; i++) FB[i] = 0;
}

void DG_Init(void) {
    last_cycles = mmio_r(MMIO_CYCLES);
    free(DG_ScreenBuffer);           // doomgeneric_Create's heap copy is never used
    DG_ScreenBuffer = SCRATCH;
    mmio_w(MMIO_FB_MODE, 0);
    clear_rows(0, FB_H);
}

void __real_I_InitGraphics(void);
void __wrap_I_InitGraphics(void) {
    __real_I_InitGraphics();
    Z_Free(I_VideoBuffer);
    I_VideoBuffer = SCRATCH;
}

static uint32_t frames;

void DG_DrawFrame(void) {
    while (mmio_r(MMIO_FB_SWAP)) {}

    if (palette_changed) {
        for (int i = 0; i < 256; i++) {
            PAL[i] = ((uint32_t)(colors[i].r >> 4) << 8) | ((uint32_t)(colors[i].g >> 4) << 4)
                   | (uint32_t)(colors[i].b >> 4);
        }
        palette_changed = false;
    }

    clear_rows(0, FB_TOP);
    const uint32_t *src = (const uint32_t *)SCRATCH;
    volatile uint32_t *dst = FB + FB_TOP * ROW_WORDS;
    for (uint32_t i = 0; i < DOOMGENERIC_RESY * ROW_WORDS; i++) dst[i] = src[i];
    clear_rows(FB_TOP + DOOMGENERIC_RESY, FB_H);

    mmio_w(MMIO_FB_SWAP, 1);

    printf("kc: frame %lu at %lu ms\n", (unsigned long)frames, (unsigned long)DG_GetTicksMs());
    frames++;
}

void __wrap_I_FinishUpdate(void) {
    DG_DrawFrame();
}

// ---- keys ---------------------------------------------------------------
// UART RX key bytes: bit 7 = down, bits 6:0 = code (doom/README.md).
static unsigned char map_key(uint32_t code) {
    switch (code) {
    case 0x77: return KEY_UPARROW;     // w
    case 0x73: return KEY_DOWNARROW;   // s
    case 0x61: return KEY_STRAFE_L;    // a
    case 0x64: return KEY_STRAFE_R;    // d
    case 0x10: return KEY_LEFTARROW;
    case 0x11: return KEY_RIGHTARROW;
    case 0x12: return KEY_UPARROW;
    case 0x13: return KEY_DOWNARROW;
    case 0x20: return KEY_USE;         // space
    case 0x14: return KEY_FIRE;        // Ctrl
    case 0x6A: return KEY_FIRE;        // j
    case 0x6B: return KEY_USE;         // k
    case 0x0D: return KEY_ENTER;
    case 0x1B: return KEY_ESCAPE;
    case 0x79: return 'y';
    case 0x6E: return 'n';
    default:
        if (code >= 0x31 && code <= 0x37) return (unsigned char)code;   // weapons 1..7
        return 0;
    }
}

int DG_GetKey(int *pressed, unsigned char *key) {
    while (mmio_r(MMIO_UART_STATUS) & 1u) {
        uint32_t b = mmio_r(MMIO_UART_RX) & 0xFFu;
        unsigned char k = map_key(b & 0x7Fu);
        if (k) {
            *pressed = (b & 0x80u) != 0;
            *key = k;
            return 1;
        }
    }
    return 0;
}

void DG_SetWindowTitle(const char *title) {
    (void)title;
}

// ---- main ---------------------------------------------------------------
#ifndef KC_DOOM_ARGS
#define KC_DOOM_ARGS
#endif

int main(void) {
    static char *argv[] = { "doom", "-iwad", "doom1.wad", "-mb", "16", KC_DOOM_ARGS NULL };
    int argc = (int)(sizeof argv / sizeof argv[0]) - 1;
    setvbuf(stdout, NULL, _IOLBF, 0);
    printf("kc: doomgeneric on KennyCraft\n");
    doomgeneric_Create(argc, argv);
    for (;;) doomgeneric_Tick();
}
