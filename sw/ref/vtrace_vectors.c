/*
 * sw/ref/vtrace_vectors.c
 *
 * Deterministic host reference driver for VTRACE verification.
 * Compiles against and directly calls Kennedy's genuine C reference:
 *   game/src/trace.c: vtrace_ref(const kc_ray *r, int32_t max_steps, kc_hit *h)
 *
 * Supplies:
 *   - Real sparse world mapping and hal_win_get() accessor
 *   - 16 representative test vectors covering hits, misses, 6 exit directions,
 *     cap exhaustion, all 8 sign combinations, and multi-axis traversal
 *   - Verification that all chosen vectors have distinct positive tMax/tDelta
 *     with NO equal crossings at any step (ruling out tie-breaking ambiguity)
 *   - Assembly output emitter for sw/tests/t_vtrace_expected.inc
 *
 * Source reference & dependencies:
 *   - game/src/trace.h (kc_ray, kc_hit, VSET/VTRACE/VGET contracts)
 *   - game/src/trace.c (vtrace_ref DDA implementation)
 *   - game/src/kc_hal.h (WIN_INDEX, hal_win_get contract)
 *
 * Discrepancies and boundary exclusions:
 *   P6 reported three reference boundary discrepancies:
 *     1. Tie-breaking: game trace.c uses <= (x-first) vs frozen wiki strict < (z-first).
 *     2. Cap 0: game executes 1 step vs wiki no-statechange.
 *     3. Overflow: game allows standard int32 overflow vs saturating MAX.
 *   Exclusion contract:
 *     All 16 vectors here strictly avoid these ambiguous boundaries by using
 *     distinct positive tMax with no equal crossings, positive caps (max_steps >= 2),
 *     and small coordinates/deltas avoiding overflow.
 *     Disputed boundaries are specifically covered by P6 core verification tests.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <assert.h>

#include "trace.h"
#include "kc_hal.h"

#ifdef KC_HOST
/* Host emulation symbols declared in kc_hal.h */
kc_camera  host_camera;
kc_rparams host_rparams;
#endif


/*
 * Small fixed sparse world (64 x 32 x 64).
 * We maintain 8 non-zero voxel entries in air (type 0).
 */
typedef struct {
    int32_t     x;
    int32_t     y;
    int32_t     z;
    uint8_t     type;
    const char *desc;
} sparse_block_t;

static const sparse_block_t g_sparse_blocks[] = {
    { 10, 10, 10, 1, "Stone (hit -X face by Vector 9)" },
    { 25, 12, 14, 2, "Dirt (hit +X face by Vector 8)" },
    { 30,  8, 30, 3, "Grass (hit -Y face by Vector 11)" },
    { 35, 16, 35, 4, "Wood (hit +Y face by Vector 10)" },
    { 40, 15, 20, 5, "Leaves (hit -Z face by Vector 13)" },
    { 45, 15, 45, 6, "Glass (hit +Z face by Vector 12)" },
    { 20, 15, 20, 7, "Gold (hit diagonally -X/-Y/-Z by Vector 14)" },
    { 50, 20, 10, 9, "Water (hit diagonally -X/-Y by Vector 15)" },
};

#define NUM_SPARSE_BLOCKS ((int)(sizeof(g_sparse_blocks) / sizeof(g_sparse_blocks[0])))

static uint8_t s_host_world[WIN_X * WIN_Y * WIN_Z];

/*
 * Real world accessor supplied to trace.c vtrace_ref().
 */
uint8_t hal_win_get(int32_t x, int32_t y, int32_t z) {
    if (x < 0 || x >= WIN_X || y < 0 || y >= WIN_Y || z < 0 || z >= WIN_Z) {
        return 0;
    }
    return s_host_world[WIN_INDEX(x, y, z)];
}

static void init_world(void) {
    memset(s_host_world, 0, sizeof(s_host_world));
    for (int i = 0; i < NUM_SPARSE_BLOCKS; i++) {
        const sparse_block_t *b = &g_sparse_blocks[i];
        s_host_world[WIN_INDEX(b->x, b->y, b->z)] = b->type & 0x0F;
    }
}

/*
 * Representative vector definition.
 */
typedef struct {
    kc_ray      ray;
    int32_t     max_steps;
    const char *desc;
} test_vector_def_t;

/*
 * 16 representative test vectors.
 * All vectors strictly satisfy:
 *   - Distinct positive tMax and tDelta values
 *   - No equal crossings at any DDA step (verified at runtime)
 *   - Positive caps (max_steps >= 2)
 *   - No integer overflow
 *   - Full coverage of 6 exit directions, cap exhaustion, 8 sign bits, 3 face axes
 */
static const test_vector_def_t g_vectors[] = {
    /* 0: Miss / Exit -X face (3 steps, oob at x=-1) */
    {
        .ray = { .f = { CELL_PACK(2, 10, 10), 0x00010000, 0x00500000, 0x00700000, 0x00010000, 0x00400000, 0x00600000, 0x01 } },
        .max_steps = 10,
        .desc = "Exit -X face (3 steps, oob at x=-1)"
    },
    /* 1: Miss / Exit +X face (3 steps, oob at x=64) */
    {
        .ray = { .f = { CELL_PACK(61, 10, 10), 0x00010000, 0x00500000, 0x00700000, 0x00010000, 0x00400000, 0x00600000, 0x00 } },
        .max_steps = 10,
        .desc = "Exit +X face (3 steps, oob at x=64)"
    },
    /* 2: Miss / Exit -Y face (3 steps, oob at y=-1) */
    {
        .ray = { .f = { CELL_PACK(10, 2, 10), 0x00500000, 0x00010000, 0x00700000, 0x00400000, 0x00010000, 0x00600000, 0x02 } },
        .max_steps = 10,
        .desc = "Exit -Y face (3 steps, oob at y=-1)"
    },
    /* 3: Miss / Exit +Y face (3 steps, oob at y=32) */
    {
        .ray = { .f = { CELL_PACK(10, 29, 10), 0x00500000, 0x00010000, 0x00700000, 0x00400000, 0x00010000, 0x00600000, 0x00 } },
        .max_steps = 10,
        .desc = "Exit +Y face (3 steps, oob at y=32)"
    },
    /* 4: Miss / Exit -Z face (3 steps, oob at z=-1) */
    {
        .ray = { .f = { CELL_PACK(10, 10, 2), 0x00500000, 0x00700000, 0x00010000, 0x00400000, 0x00600000, 0x00010000, 0x04 } },
        .max_steps = 10,
        .desc = "Exit -Z face (3 steps, oob at z=-1)"
    },
    /* 5: Miss / Exit +Z face (3 steps, oob at z=64) */
    {
        .ray = { .f = { CELL_PACK(10, 10, 61), 0x00500000, 0x00700000, 0x00010000, 0x00400000, 0x00600000, 0x00010000, 0x03 } },
        .max_steps = 10,
        .desc = "Exit +Z face (3 steps, oob at z=64)"
    },
    /* 6: Miss / Cap exhausted after 2 steps in empty space */
    {
        .ray = { .f = { CELL_PACK(5, 5, 5), 0x00010000, 0x00600000, 0x00800000, 0x00010000, 0x00400000, 0x00500000, 0x05 } },
        .max_steps = 2,
        .desc = "Cap exhausted at 2 steps in empty space"
    },
    /* 7: Miss / Cap exhausted after 4 steps in empty space */
    {
        .ray = { .f = { CELL_PACK(55, 5, 55), 0x00700000, 0x00010000, 0x00900000, 0x00500000, 0x00010000, 0x00600000, 0x06 } },
        .max_steps = 4,
        .desc = "Cap exhausted at 4 steps in empty space"
    },
    /* 8: Hit +X face of Dirt (3 steps, cell 25, 12, 14, type 2) */
    {
        .ray = { .f = { CELL_PACK(22, 12, 14), 0x00010000, 0x00600000, 0x00800000, 0x00010000, 0x00500000, 0x00700000, 0x00 } },
        .max_steps = 10,
        .desc = "Hit +X face of Dirt (3 steps, cell 25,12,14)"
    },
    /* 9: Hit -X face of Stone (3 steps, cell 10, 10, 10, type 1) */
    {
        .ray = { .f = { CELL_PACK(13, 10, 10), 0x00010000, 0x00600000, 0x00800000, 0x00010000, 0x00500000, 0x00700000, 0x01 } },
        .max_steps = 10,
        .desc = "Hit -X face of Stone (3 steps, cell 10,10,10)"
    },
    /* 10: Hit +Y face of Wood (3 steps, cell 35, 16, 35, type 4) */
    {
        .ray = { .f = { CELL_PACK(35, 13, 35), 0x00600000, 0x00010000, 0x00800000, 0x00500000, 0x00010000, 0x00700000, 0x00 } },
        .max_steps = 10,
        .desc = "Hit +Y face of Wood (3 steps, cell 35,16,35)"
    },
    /* 11: Hit -Y face of Grass (3 steps, cell 30, 8, 30, type 3) */
    {
        .ray = { .f = { CELL_PACK(30, 11, 30), 0x00600000, 0x00010000, 0x00800000, 0x00500000, 0x00010000, 0x00700000, 0x02 } },
        .max_steps = 10,
        .desc = "Hit -Y face of Grass (3 steps, cell 30,8,30)"
    },
    /* 12: Hit +Z face of Glass (3 steps, cell 45, 15, 45, type 6) */
    {
        .ray = { .f = { CELL_PACK(45, 15, 42), 0x00600000, 0x00800000, 0x00010000, 0x00500000, 0x00700000, 0x00010000, 0x00 } },
        .max_steps = 10,
        .desc = "Hit +Z face of Glass (3 steps, cell 45,15,45)"
    },
    /* 13: Hit -Z face of Leaves (3 steps, cell 40, 15, 20, type 5) */
    {
        .ray = { .f = { CELL_PACK(40, 15, 23), 0x00600000, 0x00800000, 0x00010000, 0x00500000, 0x00700000, 0x00010000, 0x04 } },
        .max_steps = 10,
        .desc = "Hit -Z face of Leaves (3 steps, cell 40,15,20)"
    },
    /* 14: Hit -Z face of Gold via multi-axis step (4 steps, cell 20, 15, 20, type 7) */
    {
        .ray = { .f = { CELL_PACK(22, 16, 21), 0x00010000, 0x00016666, 0x00028000, 0x00013333, 0x00030000, 0x00020000, 0x07 } },
        .max_steps = 10,
        .desc = "Hit -Z face of Gold multi-axis (4 steps, cell 20,15,20)"
    },
    /* 15: Hit -Y face of Water via multi-axis step (3 steps, cell 50, 20, 10, type 9) */
    {
        .ray = { .f = { CELL_PACK(51, 22, 10), 0x00014CCD, 0x0000E666, 0x00090000, 0x00020000, 0x00011999, 0x00080000, 0x03 } },
        .max_steps = 10,
        .desc = "Hit -Y face of Water multi-axis (3 steps, cell 50,20,10)"
    },
};

#define NUM_TEST_VECTORS ((int)(sizeof(g_vectors) / sizeof(g_vectors[0])))

/*
 * Verification helper: ensures ray traversal never encounters an equal crossing
 * (i.e. tmx != tmy && tmx != tmz && tmy != tmz at every single step).
 */
static void assert_no_equal_crossings(int idx, const test_vector_def_t *vec) {
    const kc_ray *r = &vec->ray;
    int32_t max_steps = vec->max_steps;
    q16 tmx = (q16)r->f[1], tmy = (q16)r->f[2], tmz = (q16)r->f[3];
    q16 tdx = (q16)r->f[4], tdy = (q16)r->f[5], tdz = (q16)r->f[6];
    int32_t x = CELL_X(r->f[0]), y = CELL_Y(r->f[0]), z = CELL_Z(r->f[0]);
    int32_t nx = r->f[7] & 1, ny = (r->f[7] >> 1) & 1, nz = (r->f[7] >> 2) & 1;
    int32_t sx = 1 - 2 * nx, sy = 1 - 2 * ny, sz = 1 - 2 * nz;

    assert(max_steps > 0 && "Vector has non-positive max_steps");

    for (int32_t s = 0; s < max_steps; s++) {
        if (tmx == tmy || tmx == tmz || tmy == tmz) {
            fprintf(stderr, "FATAL: Vector %d (%s) encountered equal crossing at step %d: tmx=%d, tmy=%d, tmz=%d\n",
                    idx, vec->desc, s, tmx, tmy, tmz);
            exit(1);
        }
        int32_t cx = (tmx <= tmy) & (tmx <= tmz);
        int32_t cy = (cx ^ 1) & (tmy <= tmz);
        int32_t cz = (cx | cy) ^ 1;
        x += cx ? sx : 0;
        y += cy ? sy : 0;
        z += cz ? sz : 0;
        tmx += cx ? tdx : 0;
        tmy += cy ? tdy : 0;
        tmz += cz ? tdz : 0;

        int32_t oob = ((uint32_t)x > 63u) | ((uint32_t)y > 31u) | ((uint32_t)z > 63u);
        uint8_t typ = hal_win_get(x & 63, y & 31, z & 63);
        int32_t hit = (typ != 0) & (oob ^ 1);
        if (hit || oob) break;
    }
}

int main(int argc, char **argv) {
    const char *out_path = "sw/tests/t_vtrace_expected.inc";
    if (argc > 1) {
        out_path = argv[1];
    }

    init_world();

    /* Pre-verify that no vector has equal crossings */
    for (int i = 0; i < NUM_TEST_VECTORS; i++) {
        assert_no_equal_crossings(i, &g_vectors[i]);
    }

    FILE *f = fopen(out_path, "w");
    if (!f) {
        perror("fopen");
        fprintf(stderr, "Failed to open output file: %s\n", out_path);
        return 1;
    }

    fprintf(f, "# ==============================================================================\n");
    fprintf(f, "# Deterministic Reference Expected Values for Stage 2 Custom-1 VTRACE Hardware\n");
    fprintf(f, "# Generated by sw/ref/vtrace_vectors.c calling genuine game/src/trace.c:vtrace_ref()\n");
    fprintf(f, "# DO NOT EDIT MANUALLY.\n");
    fprintf(f, "#\n");
    fprintf(f, "# Reference Source & Dependencies:\n");
    fprintf(f, "#   - game/src/trace.h: VSET, VTRACE, VGET formats and structs\n");
    fprintf(f, "#   - game/src/trace.c: vtrace_ref() DDA traversal algorithm\n");
    fprintf(f, "#   - game/src/kc_hal.h: hal_win_get() accessor\n");
    fprintf(f, "#\n");
    fprintf(f, "# Discrepancy & Exclusion Contract:\n");
    fprintf(f, "#   P6 identified three reference discrepancies:\n");
    fprintf(f, "#     1. Tie-breaking: game <= (x-first) vs wiki strict < (z-first).\n");
    fprintf(f, "#     2. Cap 0: game executes 1 step vs wiki no-statechange.\n");
    fprintf(f, "#     3. Overflow: game allows normal overflow vs saturating MAX.\n");
    fprintf(f, "#   All 16 vectors here strictly enforce distinct positive tMax with NO equal\n");
    fprintf(f, "#   crossings at any step, positive caps (max_steps >= 2), and no overflow.\n");
    fprintf(f, "#   Disputed boundary conditions are covered separately in P6 verification.\n");
    fprintf(f, "# ==============================================================================\n\n");

    /* 1. Sparse world table */
    fprintf(f, "    .section .rodata\n");
    fprintf(f, "    .balign 4\n");
    fprintf(f, "    .globl vtrace_sparse_world_count\n");
    fprintf(f, "vtrace_sparse_world_count:\n");
    fprintf(f, "    .word %d\n\n", NUM_SPARSE_BLOCKS);

    fprintf(f, "    .globl vtrace_sparse_world\n");
    fprintf(f, "vtrace_sparse_world:\n");
    for (int i = 0; i < NUM_SPARSE_BLOCKS; i++) {
        const sparse_block_t *b = &g_sparse_blocks[i];
        uint32_t offset = WIN_INDEX(b->x, b->y, b->z);
        fprintf(f, "    # Block %d: (%d, %d, %d) -> %s\n", i, b->x, b->y, b->z, b->desc);
        fprintf(f, "    .word 0x%08x, 0x%08x\n", offset, (uint32_t)b->type);
    }
    fprintf(f, "\n");

    /* 2. Test vectors count */
    fprintf(f, "    .globl vtrace_test_count\n");
    fprintf(f, "vtrace_test_count:\n");
    fprintf(f, "    .word %d\n\n", NUM_TEST_VECTORS);

    /* 3. Test vectors table */
    fprintf(f, "    .globl vtrace_vectors\n");
    fprintf(f, "vtrace_vectors:\n");

    for (int i = 0; i < NUM_TEST_VECTORS; i++) {
        const test_vector_def_t *vec = &g_vectors[i];
        kc_hit hit;
        memset(&hit, 0, sizeof(hit));

        /* Execute genuine C reference from game/src/trace.c */
        vtrace_ref(&vec->ray, vec->max_steps, &hit);

        uint32_t hit_bit = HIT_HIT(hit.res);
        uint32_t hit_axis = HIT_AXIS(hit.res);
        uint32_t hit_neg = HIT_NEG(hit.res);
        uint32_t hit_type = HIT_TYPE(hit.res);
        uint32_t hit_steps = HIT_STEPS(hit.res);

        fprintf(f, "    # --------------------------------------------------------------------------\n");
        fprintf(f, "    # Vector %2d: %s\n", i, vec->desc);
        fprintf(f, "    #   max_steps=%d, expected res=0x%04x (hit=%u, ax=%u, neg=%u, type=%u, steps=%u)\n",
                vec->max_steps, hit.res & 0xFFFFu, hit_bit, hit_axis, hit_neg, hit_type, hit_steps);
        fprintf(f, "    #   expected cell=0x%05x (x=%d, y=%d, z=%d), t=0x%08x\n",
                hit.cell, CELL_X(hit.cell), CELL_Y(hit.cell), CELL_Z(hit.cell), (uint32_t)hit.t);
        fprintf(f, "    # --------------------------------------------------------------------------\n");

        /* 8 words for f0..f7 */
        fprintf(f, "    .word 0x%08x, 0x%08x, 0x%08x, 0x%08x\n",
                vec->ray.f[0], vec->ray.f[1], vec->ray.f[2], vec->ray.f[3]);
        fprintf(f, "    .word 0x%08x, 0x%08x, 0x%08x, 0x%08x\n",
                vec->ray.f[4], vec->ray.f[5], vec->ray.f[6], vec->ray.f[7]);

        /* 4 words for max_steps, expected res, cell, t */
        fprintf(f, "    .word 0x%08x, 0x%08x, 0x%08x, 0x%08x\n\n",
                (uint32_t)vec->max_steps,
                hit.res & 0xFFFFu,
                hit.cell,
                (uint32_t)hit.t);
    }

    fclose(f);
    printf("Successfully generated deterministic reference include: %s (%d vectors, %d sparse blocks)\n",
           out_path, NUM_TEST_VECTORS, NUM_SPARSE_BLOCKS);
    return 0;
}
