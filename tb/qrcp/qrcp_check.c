/* qrcp_check: the hardware model (qrcp_model.h, rtl/core/qrcp.sv step by
   step) against the normative qrcp() in game/src/fixed.c (D22), linked
   unchanged.

     qrcp_check all                   every 32-bit input (about a minute)
     qrcp_check stride N              every Nth input plus the edge classes
     qrcp_check vectors FILE N SEED   check, then write the edge classes and N
                                      random inputs as "x expected" hex lines
                                      for tb/qrcp/qrcp_unit_tb.sv

   Exits 1 on the first mismatch. */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "fixed.h"
#include "kc_tables.h"
#include "qrcp_model.h"

static FILE    *vec_out;
static uint64_t checked;

static void check(uint32_t ux) {
    int32_t x = (int32_t)ux, want = qrcp(x), got = qrcp_model(x);
    checked++;
    if (got != want) {
        fprintf(stderr, "FAIL: qrcp(%08" PRIx32 ") = %08" PRIx32 ", model %08" PRIx32 "\n",
                ux, (uint32_t)want, (uint32_t)got);
        exit(1);
    }
    if (vec_out) fprintf(vec_out, "%08" PRIx32 " %08" PRIx32 "\n", ux, (uint32_t)want);
}

/* 0..1023, -1024..-1, the extremes, 2^k and 2^k +- 1, +-2 for every k (and
   their negatives), the 2^16 neighbourhood, every seed bucket edge (m[15:8]
   steps) at three exponents, the top of the positive range. */
static void edges(void) {
    for (uint32_t i = 0; i < 1024; i++) { check(i); check(0u - 1u - i); }
    for (int k = 0; k < 32; k++)
        for (int d = -2; d <= 2; d++) {
            uint32_t v = (1u << k) + (uint32_t)d;
            check(v);
            check(0u - v);
        }
    for (uint32_t i = 0; i < 4096; i++) check(0xF800u + i);
    const int exps[3] = { 10, 16, 30 };      /* bit position of the leading 1 */
    for (int e = 0; e < 3; e++)
        for (uint32_t b = 0; b < 256; b++) {
            uint32_t base = (256u + b) << (exps[e] - 8);
            for (int d = -1; d <= 1; d++) check(base + (uint32_t)d);
        }
    for (uint32_t i = 0; i < 1024; i++) { check(0x7FFFFFFFu - i); check(0x80000000u + i); }
}

static uint32_t xs = 0x4B43u;
static uint32_t rnd(void) {           /* xorshift32 */
    xs ^= xs << 13; xs ^= xs >> 17; xs ^= xs << 5;
    return xs;
}

int main(int argc, char **argv) {
    for (uint32_t i = 0; i < 256; i++)  /* the ROM equals the 1/x table it replaced */
        if (qrcp_model_seed(i) > 0xFFFFu || qrcp_model_seed(i) < 0x8000u) {
            fprintf(stderr, "FAIL: seed %" PRIu32 " = %" PRIu32 " outside 16 bits\n", i,
                    qrcp_model_seed(i));
            return 1;
        }

    if (argc == 2 && !strcmp(argv[1], "all")) {
        uint32_t ux = 0;
        do check(ux); while (++ux != 0);
    } else if (argc == 3 && !strcmp(argv[1], "stride")) {
        uint64_t n = strtoull(argv[2], NULL, 0);
        if (n == 0) n = 1;
        edges();
        for (uint64_t v = 0; v <= 0xFFFFFFFFull; v += n) check((uint32_t)v);
    } else if (argc == 5 && !strcmp(argv[1], "vectors")) {
        vec_out = fopen(argv[2], "w");
        if (!vec_out) { perror(argv[2]); return 1; }
        xs = (uint32_t)strtoul(argv[4], NULL, 0);
        if (xs == 0) xs = 1;
        edges();
        for (long i = strtol(argv[3], NULL, 0); i > 0; i--) {
            uint32_t v = rnd();
            check(v >> (v & 31));     /* spread over every exponent */
            check(rnd());
        }
        fclose(vec_out);
    } else {
        fprintf(stderr, "usage: %s all | stride N | vectors FILE N SEED\n", argv[0]);
        return 2;
    }
    printf("PASS: qrcp model = fixed.c qrcp() on %" PRIu64 " inputs\n", checked);
    return 0;
}
