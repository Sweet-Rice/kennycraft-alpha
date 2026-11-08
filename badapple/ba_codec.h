/* Bad Apple 1-bit video codec, shared by the host encoder, the host check
 * and the chip player, so all three model the bits identically.
 *
 * Each pixel is coded with an adaptive binary range coder (the LZMA bit
 * coder: 11-bit probabilities, 32-bit range) in one of 2,048 contexts built
 * from 11 already-known pixels:
 *   bit 0 W  (y, x-1)   bit 1 WW (y, x-2)                        this frame
 *   bit 2 NW (y-1, x-1) bit 3 N (y-1, x) bit 4 NE (y-1, x+1)     this frame
 *   bit 5 NN (y-2, x)                                           this frame
 *   bit 6 PW (y, x-1)   bit 7 P (y, x)   bit 8 PE (y, x+1)      previous frame
 *   bit 9 PN (y-1, x)   bit 10 PS (y+1, x)                       previous frame
 * Pixels outside the frame are 0, and the frame before the first is all 0.
 * One stream covers the whole video; probabilities carry across frames.
 *
 * Frames are planes of 32-bit words, bit i of word j = pixel 32 * j + i.
 * Each stored row has a zero pad word on both sides, and the plane has two
 * zero rows above the frame and one below, so neighbours never need bounds
 * checks.
 *
 * The decoder pulls stream bytes through ba_next_byte(), which the including
 * file defines before including this header.
 */
#pragma once
#include <stdint.h>

#define BA_W        160
#define BA_H        120
#define BA_WORDS    (BA_W / 32)
#define BA_STRIDE   (BA_WORDS + 2)
#define BA_ROWS     (BA_H + 3)
#define BA_CTX      2048
#define BA_FRAME_BYTES (BA_W * BA_H / 8)

typedef uint32_t ba_plane[BA_ROWS][BA_STRIDE];

/* Probability adaptation rate. LZMA uses 5; on this video 3 codes 498 KB,
 * 4 569 KB and 5 738 KB. The decoder's normalization is a loop, so any
 * rate is safe. */
#ifndef BA_SHIFT
#define BA_SHIFT    3
#endif

/* Row y of plane p (y from -2 to BA_H), as a pointer to its first frame word. */
#define BA_ROW(p, y) (&(p)[(y) + 2][1])

static inline void ba_probs_init(uint16_t *probs) {
    for (unsigned i = 0; i < BA_CTX; ++i) probs[i] = 1024;
}

#ifndef BA_NO_DECODER
static uint8_t ba_next_byte(void);

typedef struct { uint32_t range, code; } ba_dec;

static inline void ba_dec_init(ba_dec *d) {
    d->range = 0xFFFFFFFFu;
    d->code = 0;
    for (int i = 0; i < 5; ++i) d->code = (d->code << 8) | ba_next_byte();
}

/* Decode one frame into cur, given the previous frame in prev. Both planes'
 * pad words and pad rows must be 0. */
static void ba_decode_frame(ba_dec *d, uint16_t *probs, ba_plane cur, ba_plane prev) {
    uint32_t range = d->range, code = d->code;
    for (int y = 0; y < BA_H; ++y) {
        const uint32_t *n = BA_ROW(cur, y - 1), *nn = BA_ROW(cur, y - 2);
        const uint32_t *p = BA_ROW(prev, y), *pn = BA_ROW(prev, y - 1), *ps = BA_ROW(prev, y + 1);
        uint32_t *out = BA_ROW(cur, y);
        uint32_t hist = 0;
        for (int j = 0; j < BA_WORDS; ++j) {
            uint32_t a0 = (n[j] << 1) | (n[j - 1] >> 31), a1 = n[j], a2 = (n[j] >> 1) | (n[j + 1] << 31);
            uint32_t a3 = nn[j];
            uint32_t a4 = (p[j] << 1) | (p[j - 1] >> 31), a5 = p[j], a6 = (p[j] >> 1) | (p[j + 1] << 31);
            uint32_t a7 = pn[j], a8 = ps[j];
            uint32_t word = 0;
            for (int i = 0; i < 32; ++i) {
                uint32_t ctx = hist | (a0 & 1) << 2 | (a1 & 1) << 3 | (a2 & 1) << 4 | (a3 & 1) << 5
                             | (a4 & 1) << 6 | (a5 & 1) << 7 | (a6 & 1) << 8 | (a7 & 1) << 9 | (a8 & 1) << 10;
                a0 >>= 1; a1 >>= 1; a2 >>= 1; a3 >>= 1; a4 >>= 1; a5 >>= 1; a6 >>= 1; a7 >>= 1; a8 >>= 1;
                uint32_t pr = probs[ctx];
                uint32_t bound = (range >> 11) * pr;
                uint32_t bit;
                if (code < bound) {
                    range = bound;
                    probs[ctx] = (uint16_t)(pr + ((2048 - pr) >> BA_SHIFT));
                    bit = 0;
                } else {
                    code -= bound;
                    range -= bound;
                    probs[ctx] = (uint16_t)(pr - (pr >> BA_SHIFT));
                    bit = 1;
                }
                while (range < (1u << 24)) {
                    range <<= 8;
                    code = (code << 8) | ba_next_byte();
                }
                word |= bit << i;
                hist = ((hist << 1) | bit) & 3;
            }
            out[j] = word;
        }
    }
    d->range = range;
    d->code = code;
}
#endif
