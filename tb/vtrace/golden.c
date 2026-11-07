// golden.c — VTRACE golden vectors from Kennedy's C reference (game/src/trace.c).
//
//   golden <outdir> [seed]
//
// Links game/src/trace.c and fixed.c unchanged (vtrace_ref, ray_setup) and
// writes two test sets for tb/vtrace/vtrace_tb.sv:
//   rand_world.hex, rand_groups.hex   seeded random 64x32x64 world, 10,000
//                                     random rays
//   edge_world.hex, edge_groups.hex   hand-built world and the edge cases
//   edge_names.txt                    group/lane -> edge case name
// world.hex: 131,072 lines, one hex digit each, index {y[4:0], z[5:0], x[5:0]}.
// groups.hex: word 0 = group count, then per group 3 + 8 * 11 words:
//   lane_mask, max_steps, flags (bit 0: probe max_steps = 0 and an empty
//   lane_mask before the real start), then per lane f0..f7, result, hit_cell,
//   t_hit. Lanes outside lane_mask carry random fields that must be ignored.
//
// The expected values come from model() with the wiki VTRACE rule (Tai page,
// One step): strict-< tie-break, tMax += tDelta saturating at 0x7FFF_FFFF.
// trace.c differs on ties (<=) and wraps on overflow (kc-p6-vtrace question
// on the thread). So that the expected values are still tied to Kennedy's
// code, every ray is also run through model() with trace.c's rule, which must
// equal vtrace_ref() bit for bit; the two model() runs can then differ only
// through a tie or a saturation, which is counted and printed.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "trace.h"
#include "kc_hal.h"

#define WSIZE (64 * 32 * 64)
static uint8_t world[WSIZE];

uint8_t hal_win_get(int32_t x, int32_t y, int32_t z) { return world[WIN_INDEX(x & 63, y & 31, z & 63)] & 15; }

static uint32_t rng = 1;
static uint32_t rnd(void) { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }
static uint32_t rnd_n(uint32_t n) { return (uint32_t)(((uint64_t)rnd() * n) >> 32); }

// ---------------------------------------------------------------- DDA model ----
enum { RULE_WIKI, RULE_TRACEC };
typedef struct { int tie, sat; } flags_t;

static void model(const kc_ray *r, int ms, int rule, kc_hit *h, flags_t *fl) {
    int32_t c[3] = { CELL_X(r->f[0]), CELL_Y(r->f[0]), CELL_Z(r->f[0]) };
    int32_t tm[3] = { (int32_t)r->f[1], (int32_t)r->f[2], (int32_t)r->f[3] };
    int32_t td[3] = { (int32_t)r->f[4], (int32_t)r->f[5], (int32_t)r->f[6] };
    int steps = 0, a = 0, hit = 0, typ = 0, oob = 0;
    int32_t t = 0;
    do {
        int sx, sy;
        if (rule == RULE_WIKI) { sx = tm[0] < tm[1] && tm[0] < tm[2]; sy = !sx && tm[1] < tm[2]; }
        else                   { sx = tm[0] <= tm[1] && tm[0] <= tm[2]; sy = !sx && tm[1] <= tm[2]; }
        a = sx ? 0 : sy ? 1 : 2;
        int32_t mn = tm[0] < tm[1] ? tm[0] : tm[1];
        mn = mn < tm[2] ? mn : tm[2];
        if ((tm[0] == mn) + (tm[1] == mn) + (tm[2] == mn) > 1) fl->tie = 1;
        t = tm[a];
        c[a] += (r->f[7] >> a) & 1 ? -1 : 1;
        int64_t sum = (int64_t)tm[a] + td[a];
        if (sum > INT32_MAX) {
            fl->sat = 1;
            tm[a] = rule == RULE_WIKI ? INT32_MAX : (int32_t)(uint32_t)sum;
        } else {
            tm[a] = (int32_t)(uint32_t)sum;   // the RTL wraps below INT32_MIN, like int32
        }
        steps++;
        oob = c[0] < 0 || c[0] > 63 || c[1] < 0 || c[1] > 31 || c[2] < 0 || c[2] > 63;
        typ = oob ? 0 : hal_win_get(c[0], c[1], c[2]);
        hit = typ != 0;
    } while (!hit && !oob && steps < ms);
    int neg = (r->f[7] >> a) & 1;
    h->res  = (uint32_t)hit | (uint32_t)a << 1 | (uint32_t)neg << 3 | (uint32_t)typ << 4 | (uint32_t)steps << 8;
    h->cell = CELL_PACK(c[0], c[1], c[2]);
    h->t    = t;
}

// ---------------------------------------------------------------- output ----
typedef struct { kc_ray r; int ms; const char *name; } ray_case;
typedef struct { uint32_t mask, ms, flags; kc_ray r[8]; kc_hit h[8]; } group_t;

static struct {
    int rays, hits, exits, caps, differ, differ_tie, differ_sat;
    int steps_max; long steps_sum;
} st;

static void fail(const char *what, const kc_ray *r, int ms, const kc_hit *a, const kc_hit *b) {
    fprintf(stderr, "golden: FAIL %s\n  fields", what);
    for (int k = 0; k < 8; k++) fprintf(stderr, " %08x", r->f[k]);
    fprintf(stderr, " ms %d\n  %04x %05x %08x vs %04x %05x %08x\n",
            ms, a->res, a->cell, (uint32_t)a->t, b->res, b->cell, (uint32_t)b->t);
    exit(1);
}

static int same(const kc_hit *a, const kc_hit *b) {
    return a->res == b->res && a->cell == b->cell && a->t == b->t;
}

// Expected result for one ray, cross-checked against vtrace_ref.
static kc_hit expect(const kc_ray *r, int ms) {
    kc_hit ref, mt, mw;
    flags_t ft = {0, 0}, fw = {0, 0};
    vtrace_ref(r, ms, &ref);
    model(r, ms, RULE_TRACEC, &mt, &ft);
    if (!same(&ref, &mt)) fail("model(trace.c rule) != vtrace_ref", r, ms, &mt, &ref);
    model(r, ms, RULE_WIKI, &mw, &fw);
    if (!same(&mw, &ref)) {
        if (!fw.tie && !fw.sat && !ft.tie && !ft.sat)
            fail("wiki rule != trace.c rule without a tie or saturation", r, ms, &mw, &ref);
        st.differ++;
        if (fw.sat || ft.sat) st.differ_sat++;
        else st.differ_tie++;
    }
    st.rays++;
    int steps = HIT_STEPS(mw.res);
    if (HIT_HIT(mw.res)) st.hits++;
    else if (steps == ms) st.caps++;
    else st.exits++;
    st.steps_sum += steps;
    if (steps > st.steps_max) st.steps_max = steps;
    return mw;
}

static void write_world(const char *dir, const char *name) {
    char path[512];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "w");
    if (!f) { perror(path); exit(1); }
    for (int i = 0; i < WSIZE; i++) fprintf(f, "%x\n", world[i]);
    fclose(f);
}

static void write_groups(const char *dir, const char *name, const group_t *g, int n) {
    char path[512];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "w");
    if (!f) { perror(path); exit(1); }
    fprintf(f, "%08x\n", n);
    for (int i = 0; i < n; i++) {
        fprintf(f, "%08x\n%08x\n%08x\n", g[i].mask, g[i].ms, g[i].flags);
        for (int l = 0; l < 8; l++) {
            for (int k = 0; k < 8; k++) fprintf(f, "%08x\n", g[i].r[l].f[k]);
            fprintf(f, "%08x\n%08x\n%08x\n", g[i].h[l].res, g[i].h[l].cell, (uint32_t)g[i].h[l].t);
        }
    }
    fclose(f);
}

static void print_stats(const char *set) {
    printf("golden: %s: %d rays, %d hit, %d left the world, %d stopped by the cap, "
           "steps avg %.1f max %d; wiki rule != vtrace_ref on %d (%d tie only, %d saturation)\n",
           set, st.rays, st.hits, st.exits, st.caps, st.rays ? (double)st.steps_sum / st.rays : 0.0,
           st.steps_max, st.differ, st.differ_tie, st.differ_sat);
    memset(&st, 0, sizeof st);
}

static void random_fields(kc_ray *r) { for (int k = 0; k < 8; k++) r->f[k] = rnd(); }

// ---------------------------------------------------------------- ray builders ----
static kc_ray setup(q16 ox, q16 oy, q16 oz, q16 dx, q16 dy, q16 dz) {   // Kennedy's ray_setup
    kc_ray r;
    q16 o[3] = { ox, oy, oz }, d[3] = { dx, dy, dz };
    ray_setup(&r, o, d);
    return r;
}

// Fields by hand: cell, tMax, tDelta, signs.
static kc_ray fields(int x, int y, int z, uint32_t tmx, uint32_t tmy, uint32_t tmz,
                     uint32_t tdx, uint32_t tdy, uint32_t tdz, uint32_t neg) {
    kc_ray r = {{ CELL_PACK(x, y, z), tmx, tmy, tmz, tdx, tdy, tdz, neg }};
    return r;
}

#define INF 0x7FFFFFFFu
#define Q(i) ((q16)((i) << 16))

// Axis ray from the centre of cell (x, y, z), wiki convention: the other two
// axes get tMax = tDelta = 0x7FFF_FFFF.
static kc_ray axis_ray(int x, int y, int z, int axis, int negative) {
    uint32_t tm[3] = { INF, INF, INF }, td[3] = { INF, INF, INF };
    tm[axis] = 0x8000; td[axis] = 0x10000;
    return fields(x, y, z, tm[0], tm[1], tm[2], td[0], td[1], td[2], negative ? 1u << axis : 0);
}

static kc_ray axis_setup(int x, int y, int z, int axis, int negative) {
    q16 d[3] = { 0, 0, 0 };
    d[axis] = negative ? -Q16_ONE : Q16_ONE;
    return setup(Q(x) + Q16_HALF, Q(y) + Q16_HALF, Q(z) + Q16_HALF, d[0], d[1], d[2]);
}

// ---------------------------------------------------------------- random set ----
static void make_random_world(void) {
    for (int y = 0; y < 32; y++)
        for (int z = 0; z < 64; z++)
            for (int x = 0; x < 64; x++) {
                uint32_t p = y < 3 ? 600 : y < 6 ? 150 : 25;       // per mille
                world[WIN_INDEX(x, y, z)] = rnd_n(1000) < p ? (uint8_t)(1 + rnd_n(15)) : 0;
            }
}

static q16 rand_dir(void) {
    uint32_t k = rnd_n(100);
    if (k < 4) return 0;                                       // zero component
    if (k < 6) return rnd_n(2) ? Q16_ONE : -Q16_ONE;
    if (k < 8) return (q16)rnd_n(9) - 4;                       // tiny: qrcp -> Q16_BIG
    return (q16)rnd_n(0x20001) - 0x10000;
}

static kc_ray random_ray(void) {
    if (rnd_n(10) < 6) {                                       // Kennedy's setup
        q16 o[3] = { (q16)rnd_n(64 << 16), (q16)rnd_n(32 << 16), (q16)rnd_n(64 << 16) };
        uint32_t k = rnd_n(20);
        if (k == 0) for (int i = 0; i < 3; i++) o[i] &= ~0xFFFF;          // on a block corner
        if (k == 1) o[rnd_n(3)] &= ~0xFFFF;                                // on a block face
        return setup(o[0], o[1], o[2], rand_dir(), rand_dir(), rand_dir());
    }
    kc_ray r;                                                  // raw fields
    r.f[0] = CELL_PACK(rnd_n(64), rnd_n(32), rnd_n(64));
    for (int i = 0; i < 3; i++) {
        uint32_t td = rnd_n(10) == 0 ? INF : 0x400 + rnd_n(0x80000);
        r.f[4 + i] = td;
        r.f[1 + i] = td == INF ? INF : rnd_n(td + 1);
    }
    r.f[7] = rnd_n(8);
    return r;
}

static int random_ms(void) {
    uint32_t k = rnd_n(10);
    if (k < 6) return 255;
    if (k < 8) return 1 + (int)rnd_n(255);
    return 1 + (int)rnd_n(12);
}

static void random_set(const char *dir) {
    static group_t g[10000];
    int n = 0, rays = 0;
    make_random_world();
    while (rays < 10000) {
        group_t *p = &g[n++];
        uint32_t mask = rnd_n(5) ? 0xFFu : 1u + rnd_n(255);
        int active = __builtin_popcount(mask);
        if (rays + active > 10000) mask = (1u << (10000 - rays)) - 1;
        p->mask = mask; p->ms = (uint32_t)random_ms(); p->flags = rnd_n(50) == 0;
        for (int l = 0; l < 8; l++) {
            if (mask >> l & 1) {
                p->r[l] = random_ray();
                p->h[l] = expect(&p->r[l], (int)p->ms);
                rays++;
            } else {
                random_fields(&p->r[l]);
                memset(&p->h[l], 0, sizeof p->h[l]);
            }
        }
    }
    write_world(dir, "rand_world.hex");
    write_groups(dir, "rand_groups.hex", g, n);
    printf("golden: rand: %d groups\n", n);
    print_stats("rand");
}

// ---------------------------------------------------------------- edge set ----
// World: empty, except six blocks of types 1..6 five cells from C1 on each
// axis, and a bedrock floor (type 10) under x < 16. C2's axis lines are empty.
#define C1X 32
#define C1Y 16
#define C1Z 32
#define C2X 20
#define C2Y 8
#define C2Z 44

static void make_edge_world(void) {
    memset(world, 0, sizeof world);
    world[WIN_INDEX(C1X + 5, C1Y, C1Z)] = 1;
    world[WIN_INDEX(C1X - 5, C1Y, C1Z)] = 2;
    world[WIN_INDEX(C1X, C1Y + 5, C1Z)] = 3;
    world[WIN_INDEX(C1X, C1Y - 5, C1Z)] = 4;
    world[WIN_INDEX(C1X, C1Y, C1Z + 5)] = 5;
    world[WIN_INDEX(C1X, C1Y, C1Z - 5)] = 6;
    for (int z = 0; z < 64; z++)
        for (int x = 0; x < 16; x++) world[WIN_INDEX(x, 0, z)] = 10;
}

static ray_case cases[1024];
static int ncases;
static void add(kc_ray r, int ms, const char *name) { cases[ncases++] = (ray_case){ r, ms, name }; }

static void edge_set(const char *dir) {
    static char names[1024][64];
    int nn = 0;
#define NAME(...) (snprintf(names[nn], sizeof names[nn], __VA_ARGS__), names[nn++])
    make_edge_world();
    static const char *ax = "xyz";

    for (int a = 0; a < 3; a++)
        for (int s = 0; s < 2; s++) {
            // axis-aligned hits on the six blocks around C1, both setups
            add(axis_ray(C1X, C1Y, C1Z, a, s), 255, NAME("axis hit %c%c (0x7FFFFFFF)", s ? '-' : '+', ax[a]));
            add(axis_setup(C1X, C1Y, C1Z, a, s), 255, NAME("axis hit %c%c (ray_setup)", s ? '-' : '+', ax[a]));
            // axis-aligned rays from C2 leaving through each face
            add(axis_ray(C2X, C2Y, C2Z, a, s), 255, NAME("leave %c%c face from C2 (0x7FFFFFFF)", s ? '-' : '+', ax[a]));
            add(axis_setup(C2X, C2Y, C2Z, a, s), 255, NAME("leave %c%c face from C2 (ray_setup)", s ? '-' : '+', ax[a]));
        }
    // leave each face on the first step
    add(axis_ray(63, 9, 9, 0, 0), 255, "leave +x on step 1");
    add(axis_ray(0, 9, 9, 0, 1), 255, "leave -x on step 1");
    add(axis_ray(30, 31, 9, 1, 0), 255, "leave +y on step 1");
    add(axis_ray(30, 0, 9, 1, 1), 255, "leave -y on step 1");
    add(axis_ray(30, 9, 63, 2, 0), 255, "leave +z on step 1");
    add(axis_ray(30, 9, 0, 2, 1), 255, "leave -z on step 1");
    // leave through each face on a diagonal (corner exits)
    add(setup(Q(60) + 0x4000, Q(28) + 0x4000, Q(60) + 0x4000, Q16_ONE, Q16_ONE, Q16_ONE), 255, "leave +x+y+z corner diagonal");
    add(setup(Q(3) + 0xC000, Q(3) + 0xC000, Q(3) + 0xC000, -Q16_ONE, -Q16_ONE, -Q16_ONE), 255, "-x-y-z corner diagonal, ties every step, ends on the floor or -x");
    add(setup(Q(40) + 0x1234, Q(20) + 0x8765, Q(50), 0x9000, -0x3000, 0x2000), 255, "leave shallow -y");
    // zero direction component
    add(fields(C2X, C2Y, C2Z, 0x5A82, 0xB504, INF, 0xB504, 0x16A09, INF, 0), 255, "zero dz (0x7FFFFFFF), xy diagonal");
    add(fields(C2X, C2Y, C2Z, INF, 0x2000, 0x9000, INF, 0x20000, 0x14000, 6), 255, "zero dx (0x7FFFFFFF), -y -z");
    add(setup(Q(C2X) + 0x3000, Q(C2Y) + 0x9000, Q(C2Z) + 0x1000, 0x9999, -0xCCCC, 0), 255, "zero dz (ray_setup)");
    add(setup(Q(C2X) + 0x3000, Q(C2Y) + 0x9000, Q(C2Z) + 0x1000, 0, 0x9999, 0xCCCC), 255, "zero dx (ray_setup)");
    add(setup(Q(C2X) + 0x3000, Q(C2Y) + 0x9000, Q(C2Z) + 0x1000, -0xCCCC, 0, 0x9999), 255, "zero dy (ray_setup)");
    add(setup(Q(C1X) + 0x8000, Q(C1Y) + 0x8000, Q(C1Z) + 0x8000, 0, 0, 0), 255, "all-zero direction (ray_setup)");
    // starting on a block edge / corner (frac 0: tMax 0 on negative axes)
    static const q16 dirs[][3] = {
        { 0x10000, 0x10000, 0 }, { 0x10000, 0x10000, 0x10000 }, { -0x10000, -0x10000, -0x10000 },
        { 0x10000, -0x10000, 0x10000 }, { 0x8000, -0x10000, 0x4000 }, { -0x10000, 0, 0 },
        { 0, -0x10000, 0 }, { -0xB505, -0xB505, 0 }, { 0x4000, -0x10000, -0x4000 },
    };
    static const int org[][3] = { { 8, 6, 8 }, { C2X, C2Y, C2Z }, { C1X, C1Y, C1Z }, { C1X + 3, C1Y, C1Z - 2 } };
    for (unsigned o = 0; o < sizeof org / sizeof org[0]; o++)
        for (unsigned d = 0; d < sizeof dirs / sizeof dirs[0]; d++) {
            add(setup(Q(org[o][0]), Q(org[o][1]), Q(org[o][2]), dirs[d][0], dirs[d][1], dirs[d][2]), 255,
                NAME("block corner start (%d,%d,%d) dir %d", org[o][0], org[o][1], org[o][2], d));
            add(setup(Q(org[o][0]), Q(org[o][1]) + 0x8000, Q(org[o][2]) + 0x3000, dirs[d][0], dirs[d][1], dirs[d][2]), 255,
                NAME("block x-face start (%d,%d,%d) dir %d", org[o][0], org[o][1], org[o][2], d));
        }
    // ties: all three tMax equal, two equal
    add(fields(C2X, C2Y, C2Z, 0x8000, 0x8000, 0x8000, 0x10000, 0x10000, 0x10000, 0), 255, "tie: all three tMax equal, +++");
    add(fields(C1X, C1Y, C1Z, 0x8000, 0x8000, 0x8000, 0x10000, 0x10000, 0x10000, 7), 255, "tie: all three tMax equal, ---");
    add(fields(C2X, C2Y, C2Z, 0x8000, 0x8000, 0x10000, 0x10000, 0x10000, 0x10000, 2), 255, "tie: tMax x = y < z");
    add(fields(C2X, C2Y, C2Z, 0x8000, 0x10000, 0x8000, 0x10000, 0x10000, 0x10000, 4), 255, "tie: tMax x = z < y");
    add(fields(C2X, C2Y, C2Z, 0x10000, 0x8000, 0x8000, 0x10000, 0x10000, 0x10000, 1), 255, "tie: tMax y = z < x");
    // step cap reached
    add(axis_ray(C2X, C2Y, C2Z, 0, 0), 1, "cap 1, +x from C2");
    add(axis_ray(C2X, C2Y, C2Z, 0, 0), 2, "cap 2, +x from C2");
    add(axis_ray(C2X, C2Y, C2Z, 0, 0), 7, "cap 7, +x from C2");
    add(axis_ray(C2X, C2Y, C2Z, 0, 0), 43, "cap 43 = one step before leaving +x");
    add(axis_ray(C2X, C2Y, C2Z, 0, 0), 44, "cap 44 = the leaving step +x");
    add(axis_ray(C1X, C1Y, C1Z, 0, 0), 4, "cap 4 = one step before the hit +x");
    add(axis_ray(C1X, C1Y, C1Z, 0, 0), 5, "cap 5 = the hit step +x");
    add(setup(Q(2) + 0x100, Q(30) + 0x200, Q(2) + 0x300, 0x10000, -0x80, 0x10000), 255, "long shallow walk");
    add(fields(1, 1, 1, 0x1000, 0x1000, 0x1000, 0x40, 0x41, 0x42, 0), 255, "long walk, tiny tDelta");
    // A walk in the 64x32x64 window leaves it within 64 + 32 + 64 = 160
    // steps, so max_steps = 255 can never be the limit.
    add(fields(0, 0, 0, 0x8000, 0x10, 0x8001, 0x10000, 0x20000, 0x10000, 0), 255, "longest walk, corner to corner");
    add(fields(0, 0, 0, 0x8000, 0x10, 0x8001, 0x10000, 0x20000, 0x10000, 0), 150, "cap 150 on the corner-to-corner walk");
    for (int k = 1; k <= 3; k++)
        add(setup(Q(C2X) + 0x4321, Q(C2Y) + 0x1234, Q(C2Z) + 0x2468, 0x7000, 0x3000, -0x9000), k, NAME("cap %d, oblique", k));
    // saturation
    add(fields(C2X, C2Y, C2Z, 0x7FFFFF00, 0x7FFFFF01, 0x7FFFFF02, INF, INF, INF, 0), 255, "saturation: all tMax near 0x7FFFFFFF");
    add(fields(C2X, C2Y, C2Z, 0x7FFF0000, 0x7FFF8000, 0x7FFFFFFF, 0x20000, 0x20000, INF, 5), 255, "saturation: x and y saturate");
    // start cell inside a block is never tested
    add(axis_ray(C1X + 5, C1Y, C1Z, 0, 0), 255, "start inside block, +x");
    add(axis_ray(C1X, C1Y + 5, C1Z, 1, 1), 255, "start inside block, -y back toward C1");
    add(setup(Q(10) + 0x8000, Q(0) + 0x8000, Q(30) + 0x8000, 0x10000, 0x8000, 0), 255, "start inside floor, up and out");
    // random rays in the edge world, integer and half-integer origins
    for (int k = 0; k < 64; k++) {
        q16 frac = k & 1 ? Q16_HALF : 0;
        add(setup(Q(rnd_n(64)) + frac, Q(rnd_n(32)) + frac, Q(rnd_n(64)) + frac, rand_dir(), rand_dir(), rand_dir()),
            k & 2 ? 255 : 1 + (int)rnd_n(40), NAME("random grid-aligned origin %d", k));
    }

    // Pack the cases into groups that share max_steps; leftover lanes inactive.
    static group_t g[1024];
    int n = 0;
    static int used[1024];
    FILE *nf;
    char path[512];
    snprintf(path, sizeof path, "%s/edge_names.txt", dir);
    nf = fopen(path, "w");
    if (!nf) { perror(path); exit(1); }
    for (int i = 0; i < ncases; i++) {
        if (used[i]) continue;
        group_t *p = &g[n];
        p->ms = (uint32_t)cases[i].ms; p->flags = 1; p->mask = 0;
        int l = 0;
        for (int j = i; j < ncases && l < 8; j++) {
            if (used[j] || cases[j].ms != cases[i].ms) continue;
            used[j] = 1;
            // spread a short group over lanes 7, 5, 3, ... so lanes outside the
            // mask sit between active ones
            int lane = l;
            p->r[lane] = cases[j].r;
            p->h[lane] = expect(&cases[j].r, cases[j].ms);
            p->mask |= 1u << lane;
            fprintf(nf, "group %d lane %d: %s\n", n, lane, cases[j].name);
            l++;
        }
        if (l < 8 && l <= 4) {           // move the rays to odd lanes
            for (int k = l - 1; k >= 0; k--) {
                p->r[2 * k + 1] = p->r[k];
                p->h[2 * k + 1] = p->h[k];
            }
            p->mask = 0;
            for (int k = 0; k < l; k++) p->mask |= 2u << (2 * k);
            fprintf(nf, "group %d: lanes moved to 1,3,5,7 (lane k -> 2k+1)\n", n);
        }
        for (int k = 0; k < 8; k++)
            if (!(p->mask >> k & 1)) { random_fields(&p->r[k]); memset(&p->h[k], 0, sizeof p->h[k]); }
        n++;
    }
    fclose(nf);
    write_world(dir, "edge_world.hex");
    write_groups(dir, "edge_groups.hex", g, n);
    printf("golden: edge: %d cases in %d groups\n", ncases, n);
    print_stats("edge");
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: golden <outdir> [seed]\n"); return 2; }
    rng = argc > 2 ? (uint32_t)strtoul(argv[2], 0, 0) : 0x4B43u;
    if (rng == 0) rng = 1;
    random_set(argv[1]);
    edge_set(argv[1]);
    return 0;
}
