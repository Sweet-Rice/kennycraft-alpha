/* Bad Apple loader pass: copies this image's slice of the DDR3 image
 * (ba_chip.h) into DDR3 through the world window, then reads every chunk it
 * touched back and checks it.
 *
 * The slice is ba_pass_dmem (data memory) followed by ba_pass_tex_len bytes
 * in texture memory, two cells per byte, low nibble first. A chunk the slice
 * covers only partly is loaded from DDR3 first, so the bytes an earlier or a
 * later pass owns survive.
 *
 * Screen: one bar per pass along the top (this pass white), one box per
 * chunk (green = read back intact, red = mismatch), and a green or red
 * border for the whole pass.
 */
#include "ba_chip.h"

extern const uint32_t ba_pass_index, ba_pass_count, ba_pass_start, ba_pass_dmem_len, ba_pass_tex_len;
extern const uint8_t ba_pass_dmem[];

static uint32_t payload(uint32_t i) {
    if (i < ba_pass_dmem_len) return ba_pass_dmem[i];
    i = 2 * (i - ba_pass_dmem_len);
    return (TEX[i] & 15u) | (TEX[i + 1] & 15u) << 4;
}

int main(void) {
    FB_MODE = 1;
    ba_palette();
    ba_clear(C_BLACK);
    for (uint32_t k = 0; k < ba_pass_count; ++k)
        ba_rect(5 + (int)k * 6, 5, 5, 8, k == ba_pass_index ? C_WHITE : C_DIM);
    ba_ddr_init();

    const uint32_t a0 = ba_pass_start, a1 = a0 + ba_pass_dmem_len + ba_pass_tex_len;
    const uint32_t n0 = a0 / CHUNK_BYTES, n1 = (a1 + CHUNK_BYTES - 1) / CHUNK_BYTES;

    for (uint32_t n = n0; n < n1; ++n) {
        const uint32_t base = n * CHUNK_BYTES, s = n & 15;
        const uint32_t lo = a0 > base ? a0 : base, hi = a1 < base + CHUNK_BYTES ? a1 : base + CHUNK_BYTES;
        if (lo != base || hi != base + CHUNK_BYTES) ba_chunk_sync(ba_cmd(n, 0));
        for (uint32_t b = lo; b < hi; ++b) ba_put_byte(s, b - base, payload(b - a0));
        ba_chunk_sync(ba_cmd(n, 1));
    }

    uint32_t bad = 0;
    for (uint32_t n = n0; n < n1; ++n) {
        const uint32_t base = n * CHUNK_BYTES, s = n & 15;
        const uint32_t lo = a0 > base ? a0 : base, hi = a1 < base + CHUNK_BYTES ? a1 : base + CHUNK_BYTES;
        /* Overwrite the slot first, so a load that never lands cannot pass. */
        for (uint32_t b = 0; b < CHUNK_BYTES; ++b) ba_put_byte(s, b, ~b & 0xFF);
        ba_chunk_sync(ba_cmd(n, 0));
        uint32_t ok = 1;
        for (uint32_t b = lo; b < hi && ok; ++b) ok = ba_get_byte(s, b - base) == payload(b - a0);
        bad += !ok;
        ba_box(n - n0, ok ? C_GREEN : C_RED);
    }

    const uint8_t edge = bad ? C_RED : C_GREEN;
    ba_rect(0, 0, 160, 2, edge);
    ba_rect(0, 118, 160, 2, edge);
    ba_rect(0, 0, 2, 120, edge);
    ba_rect(158, 0, 2, 120, edge);
    ba_swap();

    ba_puts("ba-load pass ");
    ba_putu(ba_pass_index + 1);
    ba_putc('/');
    ba_putu(ba_pass_count);
    ba_puts(" bytes ");
    ba_putu(a0);
    ba_putc('-');
    ba_putu(a1);
    ba_puts(bad ? " FAIL\n" : " ok\n");
    ba_flush();
    return 0;
}
