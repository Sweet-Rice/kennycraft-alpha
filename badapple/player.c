/* Bad Apple player: plays the DDR3 image the loader passes wrote.
 *
 * 1. Loads the header chunk and checks every data chunk against its sum
 *    (one box per chunk, green = intact, red = damaged), shows that screen
 *    for 2 s, and stops there if anything is damaged.
 * 2. Streams the data chunks through the 16 world-window slots as a ring
 *    (chunk n in slot n mod 16; a slot is reloaded with chunk n + 16 as soon
 *    as chunk n is used up) and decodes one frame per two vsyncs (30 fps)
 *    into the back framebuffer at 160 x 120 (FB_MODE 1). Loops forever.
 *
 * Debug text on UART TX: the verify result, then every 256 frames the
 * decode + draw cycles per frame (average and maximum).
 */
#include "ba_chip.h"
#include "ba_codec.h"

static ba_plane planes[2];
static uint16_t probs[BA_CTX];
static ba_header hdr;

static uint32_t rd_chunk, rd_off, issued, done_base;
static uint32_t slot_ready[16];

static void ring_issue(uint32_t n) {
    slot_ready[n & 15] = done_base + ++issued;
    CHUNK_CMD = ba_cmd(n, 0);
}

static void ring_start(void) {
    done_base = CHUNK_DONE;
    issued = 0;
    for (uint32_t n = 1; n <= 16 && n <= hdr.chunks; ++n) ring_issue(n);
    rd_chunk = 1;
    rd_off = 0;
}

static uint8_t ba_next_byte(void) {
    if (rd_off == CHUNK_BYTES) {
        if (rd_chunk + 16 <= hdr.chunks) ring_issue(rd_chunk + 16);
        ++rd_chunk;
        rd_off = 0;
    }
    if (rd_chunk > hdr.chunks) return 0;
    const uint32_t s = rd_chunk & 15;
    while ((int32_t)(CHUNK_DONE - slot_ready[s]) < 0) { }
    return (uint8_t)ba_get_byte(s, rd_off++);
}

/* Pixel bytes for 4 pixels, bit k = pixel k: 0 -> C_BLACK, 1 -> C_WHITE. */
static const uint32_t expand[16] = {
#define E(v) ((((v) >> 0) & 1u) * C_WHITE | (((v) >> 1) & 1u) * C_WHITE << 8 | \
              (((v) >> 2) & 1u) * C_WHITE << 16 | (((v) >> 3) & 1u) * C_WHITE << 24)
    E(0), E(1), E(2), E(3), E(4), E(5), E(6), E(7),
    E(8), E(9), E(10), E(11), E(12), E(13), E(14), E(15),
#undef E
};

static void draw(ba_plane pl) {
    for (int y = 0; y < BA_H; ++y) {
        const uint32_t *r = BA_ROW(pl, y);
        volatile uint32_t *dst = FB32 + y * 80;
        for (int j = 0; j < BA_WORDS; ++j) {
            uint32_t w = r[j];
            for (int q = 0; q < 8; ++q, w >>= 4) *dst++ = expand[w & 15];
        }
    }
}

static void border(uint8_t c) {
    ba_rect(0, 0, 160, 2, c);
    ba_rect(0, 118, 160, 2, c);
    ba_rect(0, 0, 2, 120, c);
    ba_rect(158, 0, 2, 120, c);
}

static void halt(void) {
    ba_flush();
    for (;;) { }
}

int main(void) {
    FB_MODE = 1;
    ba_palette();
    ba_ddr_init();

    ba_chunk_sync(ba_cmd(0, 0));
    for (uint32_t b = 0; b < sizeof hdr; ++b) ((uint8_t *)&hdr)[b] = (uint8_t)ba_get_byte(0, b);
    ba_clear(C_BLACK);
    if (hdr.magic != BA_MAGIC || hdr.version != BA_VERSION || hdr.chunks == 0 || hdr.chunks > BA_MAX_CHUNKS) {
        border(C_RED);
        ba_swap();
        ba_puts("ba-play no image in DDR3\n");
        halt();
    }

    uint32_t bad = 0;
    for (uint32_t i = 0; i < hdr.chunks; ++i) {
        ba_chunk_sync(ba_cmd(i + 1, 0));
        const uint32_t ok = ba_sum((i + 1) & 15) == hdr.sums[i];
        bad += !ok;
        ba_box(i, ok ? C_GREEN : C_RED);
    }
    border(bad ? C_RED : C_GREEN);
    ba_swap();
    ba_puts("ba-play chunks ");
    ba_putu(hdr.chunks);
    ba_puts(" damaged ");
    ba_putu(bad);
    ba_putc('\n');
    if (bad) halt();
    /* Keep the all-green check screen up for 2 s (120 vsyncs) before playing. */
    const uint32_t shown = FRAME_COUNT;
    while (FRAME_COUNT - shown < 120) { }

    for (;;) {
        uint32_t *w = &planes[0][0][0];
        for (uint32_t i = 0; i < sizeof planes / 4; ++i) w[i] = 0;
        ba_probs_init(probs);
        ring_start();
        ba_dec d;
        ba_dec_init(&d);
        uint32_t due = FRAME_COUNT + 2, sum = 0, max = 0;
        for (uint32_t f = 0; f < hdr.frames; ++f) {
            const uint32_t t0 = CYCLES;
            ba_decode_frame(&d, probs, planes[f & 1], planes[(f & 1) ^ 1]);
            draw(planes[f & 1]);
            const uint32_t t = CYCLES - t0;
            sum += t;
            if (t > max) max = t;
            while ((int32_t)(FRAME_COUNT - due) < 0) { }
            ba_swap();
            due += 2;
            if ((f & 255) == 255 || f + 1 == hdr.frames) {
                ba_puts("ba-play frame ");
                ba_putu(f + 1);
                ba_puts(" avg ");
                ba_putu(sum / ((f & 255) + 1));
                ba_puts(" max ");
                ba_putu(max);
                ba_putc('\n');
                sum = max = 0;
            }
        }
    }
}
