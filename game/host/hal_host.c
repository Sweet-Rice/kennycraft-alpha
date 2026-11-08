#define _POSIX_C_SOURCE 199309L
// hal_host.c — laptop emulation of the chip's memory map.
// Mirrors the hardware rules from the Interfaces section so chunk and render code is tested
// as-is: world window with WIN_ORIGIN ring addressing and SLOT_VALID (invalid reads = air),
// a DDR3 chunk engine (random at power-on), double framebuffer with FB_SWAP, UART RX FIFO, CYCLES counter.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "kc_hal.h"
#include "hal_host.h"
#include "kc_assets.h"

kc_camera  host_camera;
kc_rparams host_rparams;

static uint8_t  bram_world[WIN_X * WIN_Y * WIN_Z];
static uint32_t win_origin, slot_valid;
static uint8_t  fb[2][FB_STRIDE * 240];
static int      back = 1;
static uint32_t frame_count, fb_mode, leds;
static uint8_t *ddr[256 * 256];           // chunk store, allocated on first touch
static int      ddr_fill = 1;             // KC_DDR_FILL: what never-written DDR3 holds (power-on)
static uint32_t chunk_done;
static uint8_t  rx_fifo[256];
static uint32_t rx_head, rx_tail;
static uint64_t cycles;
static int      realtime;
static FILE    *uart_out;                    // where UART_TX bytes go (NULL: stderr)
static int      uart_quiet;
uint8_t  host_tx[4096];                      // every UART_TX byte since host_tx_clear()
uint32_t host_tx_n;
static int      storage_ok = 1;
static uint64_t t0_ns;
host_stats      hstats;

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static void mig_calibrate(void);

void host_init(int realtime_clock) {
    realtime = realtime_clock;
    storage_ok = getenv("KC_NO_STORAGE") == NULL;
    const char *f = getenv("KC_DDR_FILL");    // random (default) | zero | bedrock | ones
    ddr_fill = !f || !strcmp(f, "random") ? 1 : !strcmp(f, "zero") ? 0 : !strcmp(f, "bedrock") ? 2 :
               !strcmp(f, "ones") ? 3 : 1;
    t0_ns = now_ns();
    mig_calibrate();
}

// ---- world window ---------------------------------------------------------------------
static uint32_t phys(int32_t x, int32_t y, int32_t z, int *slot) {
    uint32_t px = ((uint32_t)x + (win_origin & 63)) & 63;
    uint32_t pz = ((uint32_t)z + ((win_origin >> 8) & 63)) & 63;
    if (slot) *slot = (int)((pz >> 4) * 4 + (px >> 4));
    return WIN_INDEX(px, (uint32_t)y & 31, pz);
}

uint8_t hal_win_get(int32_t x, int32_t y, int32_t z) {
    if ((uint32_t)x > 63 || (uint32_t)y > 31 || (uint32_t)z > 63) {
        fprintf(stderr, "hal: world read out of window (%d,%d,%d)\n", x, y, z);
        abort();
    }
    int s;
    uint32_t i = phys(x, y, z, &s);
    hstats.world_reads++;
    return (slot_valid >> s) & 1 ? (bram_world[i] & 15) : 0;
}

void hal_win_set(int32_t x, int32_t y, int32_t z, uint8_t t) {
    if ((uint32_t)x > 63 || (uint32_t)y > 31 || (uint32_t)z > 63) {
        fprintf(stderr, "hal: world write out of window (%d,%d,%d)\n", x, y, z);
        abort();
    }
    hstats.world_writes++;
    bram_world[phys(x, y, z, NULL)] = t & 15;
}

// ---- textures, framebuffer ---------------------------------------------------------------
uint8_t hal_tex_get(uint32_t idx) { return idx < TEX_BYTES ? kc_textures[idx] : 0; }

void hal_fb_put(uint32_t idx, uint8_t v) {
    if (idx >= FB_STRIDE * 240) { fprintf(stderr, "hal: fb write out of range %u\n", idx); abort(); }
    fb[back][idx] = v;
}
uint8_t hal_fb_get(uint32_t idx) { return fb[back][idx % (FB_STRIDE * 240)]; }

const uint8_t *host_front_buffer(void) { return fb[back ^ 1]; }
const uint8_t *host_back_buffer(void)  { return fb[back]; }
static uint16_t pal[256];                 // palette RAM: starts as palette.hex, game code may rewrite it
static int      pal_loaded;
const uint16_t *host_palette(void) {
    if (!pal_loaded) { memcpy(pal, kc_palette, sizeof pal); pal_loaded = 1; }
    return pal;
}
void hal_pal_set(uint32_t i, uint16_t rgb444) { host_palette(); pal[i & 255] = rgb444 & 0xFFF; }
int host_fb_mode(void)                 { return (int)fb_mode; }

// Real DDR3 is not initialized at power-on: fill a chunk's 4 KB (8192 nibbles, one per byte
// here) the first time it is touched. "bedrock" = 0xAA bytes, every nibble 10 = B_BEDROCK.
static uint8_t *ddr_chunk(uint32_t id) {
    if (ddr[id]) return ddr[id];
    ddr[id] = malloc(16 * 32 * 16);
    uint32_t r = id * 2654435761u + 12345u;
    for (int i = 0; i < 16 * 32 * 16; i++) {
        r = r * 1664525u + 1013904223u;
        ddr[id][i] = ddr_fill == 1 ? (uint8_t)(r >> 28) : ddr_fill == 2 ? 10 : ddr_fill == 3 ? 15 : 0;
    }
    return ddr[id];
}

const char *host_ddr_fill_name(void) {
    static const char *n[] = { "zero", "random", "bedrock (0xAA)", "ones (0xFF)" };
    return n[ddr_fill];
}

// Test hook: DDR3 chunk dst gets a copy of chunk src (models an addressing mix-up).
void host_ddr_copy(uint32_t src, uint32_t dst) { memcpy(ddr_chunk(dst), ddr_chunk(src), 16 * 32 * 16); }

// ---- chunk engine: chunk (cx,cz) <-> slot (cx&3, cz&3). DDR3 order y, z, x. -----------------
static void chunk_cmd(uint32_t cmd) {
    uint32_t cx = cmd & 255, cz = (cmd >> 8) & 255, id = cz * 256 + cx;
    int store = (cmd >> 31) & 1;
    uint32_t sx = (cx & 3) * 16, sz = (cz & 3) * 16;
    uint8_t *d = ddr_chunk(id);
    if (store && ((slot_valid >> ((cz & 3) * 4 + (cx & 3))) & 1)) hstats.stores_from_valid++;
    for (uint32_t y = 0; y < 32; y++)
        for (uint32_t z = 0; z < 16; z++)
            for (uint32_t x = 0; x < 16; x++) {
                uint8_t *b = &bram_world[WIN_INDEX(sx + x, y, sz + z)];
                uint32_t c = (y * 16 + z) * 16 + x;
                if (store) d[c] = *b;
                else *b = d[c];
            }
    if (store) hstats.chunk_stores++; else hstats.chunk_loads++;
    chunk_done++;
}

// ---- MMIO -------------------------------------------------------------------------------
uint32_t hal_mmio_r(uint32_t off) {
    switch (off) {
    case MMIO_FB_SWAP:     return 0;                       // swaps complete immediately
    case MMIO_FRAME_COUNT: return frame_count;
    case MMIO_VSYNC:       return 1;
    case MMIO_CYCLES:
        if (realtime) cycles = (now_ns() - t0_ns) * (CORE_HZ / 1000000u) / 1000u;
        else cycles += 64;                             // a free-running counter moves between reads
        return (uint32_t)cycles;
    case MMIO_UART_RX:     return rx_head != rx_tail ? rx_fifo[rx_tail++ & 255] : 0;
    case MMIO_UART_STATUS: return rx_head != rx_tail ? 1u : 0u;
    case MMIO_ERR: case MMIO_ERR_PC: return 0;
    case MMIO_FB_MODE:     return fb_mode;
    case MMIO_DDR_STATUS:  return (uint32_t)storage_ok;    // memory API ready, idle
    case MMIO_CHUNK_DONE:  return chunk_done;
    case MMIO_SLOT_VALID:  return slot_valid;
    case MMIO_WIN_ORIGIN:  return win_origin;
    default: fprintf(stderr, "hal: read of unknown MMIO 0x%02x\n", off); abort();
    }
}

void hal_mmio_w(uint32_t off, uint32_t v) {
    switch (off) {
    case MMIO_FB_SWAP:
        if (v & 1) { back ^= 1; frame_count++; hstats.frames++; host_on_swap(); }
        break;
    case MMIO_UART_TX:
        if (host_tx_n < sizeof host_tx) host_tx[host_tx_n++] = (uint8_t)v;
        if (!uart_quiet) fputc((int)(v & 255), uart_out ? uart_out : stderr);
        break;
    case MMIO_ERR:         break;
    case MMIO_LEDS:        leds = v; break;
    case MMIO_FB_MODE:     fb_mode = v & 1; break;
    case MMIO_CHUNK_CMD:   chunk_cmd(v); break;
    case MMIO_SLOT_VALID:  slot_valid = v & 0xFFFF; break;
    case MMIO_WIN_ORIGIN:
        if ((v & 0x0F) || (v & 0x0F00)) { fprintf(stderr, "hal: WIN_ORIGIN not chunk aligned 0x%x\n", v); abort(); }
        win_origin = v & 0x3F3F; break;
    default: fprintf(stderr, "hal: write to unknown/read-only MMIO 0x%02x\n", off); abort();
    }
}

// ---- host-side hooks -----------------------------------------------------------------------
void host_push_key(uint8_t b) { rx_fifo[rx_head++ & 255] = b; }
void host_uart_out(FILE *f, int quiet) { uart_out = f; uart_quiet = quiet; }
void host_tx_clear(void) { host_tx_n = 0; }
void host_advance_cycles(uint32_t c) { cycles += c; }

// MIG calibration (every configuration and every reset) writes its training pattern over
// DDR3 bytes 0..63: chunk 0's first 128 nibbles (y = 0, z = 0..7). These are the 16-bit
// words read back on the board, one nibble value per word.
static void mig_calibrate(void) {
    static const uint8_t word[32] = { 0xF, 0x0, 0xA, 0x5, 0x5, 0xA, 0x9, 0x6,
        0xB, 0x1, 0xE, 0x4, 0x4, 0xE, 0xD, 0x8, 0xB, 0x1, 0xE, 0x4, 0x4, 0xE, 0xD, 0x8,
        0xB, 0x1, 0xE, 0x4, 0x4, 0xE, 0xD, 0x8 };
    uint8_t *c = ddr_chunk(0);
    for (int i = 0; i < 128; i++) c[i] = word[i >> 2];
}

// Reset button: chip registers go back to their reset values and CYCLES restarts. BRAM and
// DDR3 keep their contents, except what MIG calibration overwrites. cycles0 stands in for
// the boot-to-boot jitter of the first DDR3 loads (they cross into the DDR3 controller's
// clock domain), which the boot nonce samples.
void host_reset(uint32_t cycles0) {
    win_origin = 0; slot_valid = 0; chunk_done = 0; fb_mode = 0; leds = 0;
    rx_head = rx_tail = 0;
    cycles = cycles0;
    mig_calibrate();
}

uint32_t host_slot_valid(void) { return slot_valid; }
uint8_t host_bram_phys(uint32_t px, uint32_t y, uint32_t pz) { return bram_world[WIN_INDEX(px & 63, y & 31, pz & 63)] & 15; }
