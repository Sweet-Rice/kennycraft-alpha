/* Host side of the Bad Apple codec (ba_codec.h).
 *   ba_tool enc <frames.gray> <stream.bin> <ref.bin>
 *       frames.gray: 8-bit gray frames, BA_W x BA_H each (ffmpeg -f rawvideo gray).
 *       A pixel is 1 when gray >= 128. Writes the coded stream and the
 *       reference frames (BA_H rows x BA_WORDS little-endian words per frame).
 *   ba_tool check <stream.bin> <ref.bin>
 *       Decodes the whole stream with the chip's decoder and compares every frame.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ba_codec.h"

static uint8_t *src_buf;
static size_t src_len, src_pos;
static uint8_t ba_next_byte(void) { return src_pos < src_len ? src_buf[src_pos++] : 0; }

static uint8_t *slurp(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(1); }
    fseek(f, 0, SEEK_END);
    *len = (size_t)ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *b = malloc(*len ? *len : 1);
    if (fread(b, 1, *len, f) != *len) { perror(path); exit(1); }
    fclose(f);
    return b;
}

typedef struct {
    uint64_t low, cache_size;
    uint32_t range;
    uint8_t cache;
    FILE *out;
    size_t bytes;
} ba_enc;

static void enc_shift_low(ba_enc *e) {
    if ((uint32_t)e->low < 0xFF000000u || (e->low >> 32) != 0) {
        uint8_t carry = (uint8_t)(e->low >> 32), temp = e->cache;
        do {
            fputc((uint8_t)(temp + carry), e->out);
            ++e->bytes;
            temp = 0xFF;
        } while (--e->cache_size != 0);
        e->cache = (uint8_t)(e->low >> 24);
    }
    ++e->cache_size;
    e->low = (uint32_t)((uint32_t)e->low << 8);
}

static void enc_bit(ba_enc *e, uint16_t *prob, uint32_t bit) {
    uint32_t pr = *prob, bound = (e->range >> 11) * pr;
    if (!bit) {
        e->range = bound;
        *prob = (uint16_t)(pr + ((2048 - pr) >> BA_SHIFT));
    } else {
        e->low += bound;
        e->range -= bound;
        *prob = (uint16_t)(pr - (pr >> BA_SHIFT));
    }
    while (e->range < (1u << 24)) {
        e->range <<= 8;
        enc_shift_low(e);
    }
}

/* Same context as ba_decode_frame, computed directly. */
static uint32_t px(ba_plane pl, int y, int x) {
    if (x < 0 || x >= BA_W) return 0;
    return (BA_ROW(pl, y)[x >> 5] >> (x & 31)) & 1;
}

static void encode_frame(ba_enc *e, uint16_t *probs, ba_plane cur, ba_plane prev) {
    for (int y = 0; y < BA_H; ++y)
        for (int x = 0; x < BA_W; ++x) {
            uint32_t ctx = px(cur, y, x - 1) | px(cur, y, x - 2) << 1
                         | px(cur, y - 1, x - 1) << 2 | px(cur, y - 1, x) << 3 | px(cur, y - 1, x + 1) << 4
                         | px(cur, y - 2, x) << 5
                         | px(prev, y, x - 1) << 6 | px(prev, y, x) << 7 | px(prev, y, x + 1) << 8
                         | px(prev, y - 1, x) << 9 | px(prev, y + 1, x) << 10;
            enc_bit(e, &probs[ctx], px(cur, y, x));
        }
}

static void write_frame(FILE *f, ba_plane pl) {
    for (int y = 0; y < BA_H; ++y)
        for (int j = 0; j < BA_WORDS; ++j) {
            uint32_t w = BA_ROW(pl, y)[j];
            uint8_t b[4] = {(uint8_t)w, (uint8_t)(w >> 8), (uint8_t)(w >> 16), (uint8_t)(w >> 24)};
            fwrite(b, 1, 4, f);
        }
}

static ba_plane planes[2];
static uint16_t probs[BA_CTX];

int main(int argc, char **argv) {
    if (argc == 5 && !strcmp(argv[1], "enc")) {
        size_t len;
        uint8_t *gray = slurp(argv[2], &len);
        size_t frames = len / (BA_W * BA_H);
        FILE *so = fopen(argv[3], "wb"), *ro = fopen(argv[4], "wb");
        if (!so || !ro) { perror("output"); return 1; }
        ba_enc e = {.low = 0, .cache_size = 1, .range = 0xFFFFFFFFu, .cache = 0, .out = so};
        ba_probs_init(probs);
        memset(planes, 0, sizeof planes);
        for (size_t f = 0; f < frames; ++f) {
            ba_plane *cur = &planes[f & 1], *prev = &planes[(f & 1) ^ 1];
            const uint8_t *g = gray + f * BA_W * BA_H;
            for (int y = 0; y < BA_H; ++y)
                for (int j = 0; j < BA_WORDS; ++j) {
                    uint32_t w = 0;
                    for (int i = 0; i < 32; ++i) w |= (uint32_t)(g[y * BA_W + j * 32 + i] >= 128) << i;
                    BA_ROW(*cur, y)[j] = w;
                }
            encode_frame(&e, probs, *cur, *prev);
            write_frame(ro, *cur);
        }
        for (int i = 0; i < 5; ++i) enc_shift_low(&e);
        fclose(so);
        fclose(ro);
        printf("%zu frames, %zu stream bytes (%.1f B/frame)\n", frames, e.bytes, (double)e.bytes / frames);
        return 0;
    }
    if (argc == 4 && !strcmp(argv[1], "check")) {
        size_t rlen;
        src_buf = slurp(argv[2], &src_len);
        uint8_t *ref = slurp(argv[3], &rlen);
        size_t frames = rlen / BA_FRAME_BYTES;
        ba_dec d;
        ba_probs_init(probs);
        memset(planes, 0, sizeof planes);
        ba_dec_init(&d);
        for (size_t f = 0; f < frames; ++f) {
            ba_plane *cur = &planes[f & 1], *prev = &planes[(f & 1) ^ 1];
            ba_decode_frame(&d, probs, *cur, *prev);
            const uint8_t *r = ref + f * BA_FRAME_BYTES;
            for (int y = 0; y < BA_H; ++y)
                for (int j = 0; j < BA_WORDS; ++j) {
                    const uint8_t *b = r + (y * BA_WORDS + j) * 4;
                    uint32_t w = b[0] | b[1] << 8 | b[2] << 16 | (uint32_t)b[3] << 24;
                    if (BA_ROW(*cur, y)[j] != w) {
                        printf("MISMATCH frame %zu row %d word %d\n", f, y, j);
                        return 1;
                    }
                }
        }
        printf("check: %zu frames bit-exact, %zu of %zu stream bytes consumed\n", frames, src_pos, src_len);
        return 0;
    }
    fprintf(stderr, "usage: ba_tool enc <frames.gray> <stream.bin> <ref.bin> | check <stream.bin> <ref.bin>\n");
    return 2;
}
