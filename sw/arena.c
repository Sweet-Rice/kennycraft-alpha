#include "arena.h"
static uint8_t  arena_buf[ARENA_SIZE] __attribute__((aligned(4)));
static uint32_t arena_top, arena_peak;
__attribute__((noreturn)) static void arena_panic(uint32_t bytes);
void arena_reset(void) { arena_top = 0; }
void *arena_alloc(uint32_t bytes) {
    bytes = (bytes + 3u) & ~3u;
    if (bytes > ARENA_SIZE - arena_top) arena_panic(bytes);
    void *p = &arena_buf[arena_top];
    arena_top += bytes;
    if (arena_top > arena_peak) arena_peak = arena_top;
    return p;
}
uint32_t arena_high_water(void) { return arena_peak; }
#ifdef KC_CHIP
static void arena_panic(uint32_t bytes) {
    (void)bytes;
    *(volatile uint32_t *)0x50000024 = 0xA;   /* LEDS pattern 1010 */
    for (;;) { }                              /* jump-to-self, the simulator halts here */
}
#else
#include <stdio.h>
#include <stdlib.h>
static void arena_panic(uint32_t bytes) {
    fprintf(stderr, "arena full: asked %u, peak %u of %u\n",
            (unsigned)bytes, (unsigned)arena_peak, (unsigned)ARENA_SIZE);
    abort();
}
#endif
