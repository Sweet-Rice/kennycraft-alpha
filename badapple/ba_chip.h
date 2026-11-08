/* Chip-side helpers shared by the Bad Apple loader and player.
 *
 * DDR3 image: a linear byte space cut into 4 KB chunks. Chunk 0 is the
 * header (ba_header), chunks 1..N hold the coded stream, zero-padded to a
 * whole chunk. DDR3 is reachable only through the chunk engine, which copies
 * a chunk between DDR3 and a 16 x 32 x 16 world-window slot (one 4-bit cell
 * per byte address, Shared: Memory map, Chunks). A chunk byte b lives in the
 * slot's cells 2b (low nibble) and 2b + 1 (high nibble), cells in BRAM order
 * (y, then z, then x).
 *
 * Chunk n uses slot n mod 16, so 16 consecutive chunks fill the window once
 * and the player can stream them as a ring. Chunks sit at cz >= 128 (DDR3
 * byte address >= 128 MB), away from anything near address 0.
 */
#pragma once
#include <stdint.h>

#define REG(a) (*(volatile uint32_t *)(a))
#define FB_SWAP     REG(0x50000000)
#define FRAME_COUNT REG(0x50000004)
#define CYCLES      REG(0x5000000C)
#define UART_STATUS REG(0x50000014)
#define UART_TX     REG(0x50000018)
#define FB_MODE     REG(0x50000028)
#define DDR_STATUS  REG(0x5000002C)
#define CHUNK_CMD   REG(0x50000030)
#define CHUNK_DONE  REG(0x50000034)
#define SLOT_VALID  REG(0x50000038)
#define WIN_ORIGIN  REG(0x5000003C)

#define WORLD   ((volatile uint8_t *)0x20000000)
#define TEX     ((volatile uint8_t *)0x30000000)
#define FB      ((volatile uint8_t *)0x40000000)
#define FB32    ((volatile uint32_t *)0x40000000)
#define PALETTE ((volatile uint32_t *)0x60000000)

#define CHUNK_BYTES 4096
#define BA_MAGIC    0x4C504142u /* "BAPL" */
#define BA_VERSION  1
#define BA_MAX_CHUNKS ((CHUNK_BYTES - 32) / 4)

/* Chunk 0. sums[i] is ba_sum() of data chunk i + 1. */
typedef struct {
    uint32_t magic, version, frames, stream_bytes, chunks, passes, reserved[2];
    uint32_t sums[BA_MAX_CHUNKS];
} ba_header;

/* Palette indices. */
enum { C_BLACK, C_WHITE, C_GREEN, C_RED, C_GRAY, C_DIM };

static inline void ba_palette(void) {
    PALETTE[C_BLACK] = 0x000;
    PALETTE[C_WHITE] = 0xFFF;
    PALETTE[C_GREEN] = 0x0C0;
    PALETTE[C_RED]   = 0xE00;
    PALETTE[C_GRAY]  = 0x888;
    PALETTE[C_DIM]   = 0x333;
}

static inline uint32_t ba_cmd(uint32_t n, uint32_t store) {
    uint32_t s = n & 15, g = n >> 4;
    uint32_t cx = 4 * (g & 63) + (s & 3), cz = 128 + 4 * (g >> 6) + (s >> 2);
    return store << 31 | cz << 8 | cx;
}

/* World address of cell c (0..8191) of slot s. */
static inline volatile uint8_t *ba_cell(uint32_t s, uint32_t c) {
    uint32_t y = c >> 8, z = (c >> 4) & 15, x = c & 15;
    return WORLD + (y << 12) + ((((s >> 2) << 4) + z) << 6) + ((s & 3) << 4) + x;
}

static inline uint32_t ba_get_byte(uint32_t s, uint32_t b) {
    volatile uint8_t *p = ba_cell(s, 2 * b);   /* 2b and 2b + 1 share y, z */
    return (p[0] & 15u) | (p[1] & 15u) << 4;
}

static inline void ba_put_byte(uint32_t s, uint32_t b, uint32_t v) {
    volatile uint8_t *p = ba_cell(s, 2 * b);
    p[0] = (uint8_t)(v & 15);
    p[1] = (uint8_t)(v >> 4);
}

/* Fletcher-style sum of a whole chunk in slot s. */
static inline uint32_t ba_sum(uint32_t s) {
    uint32_t a = 1, b = 0;
    for (uint32_t i = 0; i < CHUNK_BYTES; ++i) {
        a += ba_get_byte(s, i);
        b += a;
    }
    return a ^ (b << 16) ^ (b >> 16);
}

/* Issue one chunk command and wait for it. */
static inline void ba_chunk_sync(uint32_t cmd) {
    uint32_t want = CHUNK_DONE + 1;
    CHUNK_CMD = cmd;
    while ((int32_t)(CHUNK_DONE - want) < 0) { }
}

static inline void ba_ddr_init(void) {
    while (!(DDR_STATUS & 1)) { }
    WIN_ORIGIN = 0;
    SLOT_VALID = 0xFFFF;
}

static inline void ba_rect(int x0, int y0, int w, int h, uint8_t c) {
    for (int y = y0; y < y0 + h; ++y)
        for (int x = x0; x < x0 + w; ++x) FB[y * 320 + x] = c;
}

static inline void ba_clear(uint8_t c) { ba_rect(0, 0, 160, 120, c); }

/* Status box for chunk i of a grid of 4 x 4 boxes, 30 per row. */
static inline void ba_box(uint32_t i, uint8_t c) {
    ba_rect(5 + (int)(i % 30) * 5, 20 + (int)(i / 30) * 5, 4, 4, c);
}

static inline void ba_swap(void) {
    FB_SWAP = 1;
    while (FB_SWAP) { }
}

/* Debug text on UART TX (laptop log only; nothing is read from UART). */
static inline void ba_putc(char ch) {
    while (UART_STATUS & 2) { }
    UART_TX = (uint8_t)ch;
}
static inline void ba_puts(const char *s) { while (*s) ba_putc(*s++); }
static inline void ba_flush(void) {
    while (UART_STATUS & 2) { }
}
static inline void ba_putu(uint32_t v) {
    char buf[11];
    int i = 0;
    do {
        uint32_t q = (uint32_t)(((uint64_t)v * 0xCCCCCCCDu) >> 35);  /* v / 10, no divide */
        buf[i++] = (char)('0' + (v - q * 10));
        v = q;
    } while (v);
    while (i) ba_putc(buf[--i]);
}
