// main_host.c — headless laptop front-end.
//   kc_host shots   <dir>   golden camera shots: PNG (x4) + raw back buffer (.fb, 320x240 bytes)
//   kc_host play    <dir>   scripted play-through with checks (physics, editing, chunk round trip)
//   kc_host vectors <dir>   VTRACE test vectors: world.hex + rays.txt from the C reference
//   kc_host bench           render timing and world reads per frame
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "kc_hal.h"
#include "hal_host.h"
#include "kc_main.h"
#include "game.h"
#include "chunks.h"
#include "render.h"
#include "trace.h"
#include "blocks.h"
#include "mesh.h"
#include "raster.h"
#include "arena.h"

void host_on_swap(void) {}

static const char *outdir = ".";
static int failures;

static void check(int ok, const char *what) {
    printf("  %s  %s\n", ok ? "PASS" : "FAIL", what);
    if (!ok) failures++;
}

static void save_frame(const char *name) {
    char path[512];
    int w = KC_RP->width, h = KC_RP->height;
    snprintf(path, sizeof path, "%s/%s.png", outdir, name);
    png_write_fb(path, host_front_buffer(), host_palette(), w, h, w == 160 ? 4 : 2);
    snprintf(path, sizeof path, "%s/%s.fb", outdir, name);
    FILE *f = fopen(path, "wb");
    if (!f) { fprintf(stderr, "kc_host: cannot write %s (does the folder exist?)\n", path); exit(2); }
    fwrite(host_front_buffer(), 1, 320 * 240, f);
    fclose(f);
}

static void step_frames(int n) {
    for (int i = 0; i < n; i++) {
        host_advance_cycles(CORE_HZ / 30);
        kc_frame();
    }
}

static void key(uint8_t code, int down) { host_push_key((uint8_t)(code | (down ? 0x80 : 0))); }

// Teleport, then run world_update once per "frame" until the window is complete.
// Returns how many frames that took (at most one chunk generation per frame).
static int pose(q16 x, q16 y, q16 z, q16 yaw, q16 pitch) {
    kc_me.pos[0] = x; kc_me.pos[1] = y; kc_me.pos[2] = z;
    kc_me.yaw = yaw; kc_me.pitch = pitch; kc_me.vel_y = 0;
    int frames = 0;
    do { world_update(qfloor(x), qfloor(z)); frames++; } while (!world_ready() && frames < 200);
    return frames;
}

// Render one frame at a fixed pose without running physics.
static void shot(const char *name) {
    arena_reset();
    write_camera();
    kc_draw_world();
    game_draw_overlay();
    hal_mmio_w(MMIO_FB_SWAP, 1);
    save_frame(name);
}

static int cmd_shots(void) {
    kc_use_raster = 0;                                  // golden shots = the ray-traced reference
    struct { const char *name; double x, y, z, yaw, pitch; int w; } s[] = {
        { "g0_spawn",     0, 0, 0, 128, -40, 160 },
        { "g1_horizon",   0, 0, 0, 300,   0, 160 },
        { "g2_down",      0, 0, 0, 0,  -200, 160 },
        { "g3_up",        0, 0, 0, 700,  120, 160 },
        { "g4_high",      0, 6, 0, 900,  -60, 160 },
        { "g5_spawn_320", 0, 0, 0, 128,  -40, 320 },
    };
    q16 bx = kc_me.pos[0], by = kc_me.pos[1], bz = kc_me.pos[2];
    for (unsigned i = 0; i < sizeof s / sizeof s[0]; i++) {
        kc_set_resolution(s[i].w);
        pose(bx + (q16)(s[i].x * 65536), by + (q16)(s[i].y * 65536), bz + (q16)(s[i].z * 65536),
             (q16)(s[i].yaw * 65536), (q16)(s[i].pitch * 65536));
        uint64_t r0 = hstats.world_reads;
        shot(s[i].name);
        printf("  %-14s %dx%d  world reads %llu\n", s[i].name, s[i].w, s[i].w * 3 / 4,
               (unsigned long long)(hstats.world_reads - r0));
    }
    kc_set_resolution(160);
    return 0;
}

static int box_overlap_any(void) {
    for (int dy = 0; dy < 2; dy++) {
        int32_t y = qfloor(kc_me.pos[1] + Q16(0.9) * dy);
        if (world_get(qfloor(kc_me.pos[0]), y, qfloor(kc_me.pos[2])) != B_AIR) return 1;
    }
    return 0;
}

static int cmd_compare(void) {
    struct { const char *name; double yaw, pitch, dy; int w; } s[] = {
        { "c0_spawn", 128, -40, 0, 160 }, { "c1_horizon", 300, 0, 0, 160 },
        { "c2_down", 0, -200, 0, 160 },   { "c3_high", 900, -60, 6, 160 },
        { "c4_spawn_320", 128, -40, 0, 320 },
    };
    q16 bx = kc_me.pos[0], by = kc_me.pos[1], bz = kc_me.pos[2];
    mesh_update();
    printf("  mesh: %d quads in %d of %d pages (%d KB)\n", mesh_total_quads(), mesh_pages_used(), MESH_PAGES,
           mesh_pages_used());
    for (unsigned i = 0; i < sizeof s / sizeof s[0]; i++) {
        kc_set_resolution(s[i].w);
        pose(bx, by + (q16)(s[i].dy * 65536), bz, (q16)(s[i].yaw * 65536), (q16)(s[i].pitch * 65536));
        static uint8_t ray[320 * 240];
        char name[64];
        kc_use_raster = 0; snprintf(name, sizeof name, "%s_ray", s[i].name);
        mesh_update();                                  // don't count remeshing as ray work
        uint64_t r0 = hstats.world_reads;
        shot(name);
        double ray_mi = ((hstats.world_reads - r0) * 52.0 + KC_RP->width * KC_RP->height * 200.0) / 1e6;
        printf("  %-13s ray tracer: %llu DDA steps, est. %.1f M instr\n", s[i].name,
               (unsigned long long)(hstats.world_reads - r0), ray_mi);
        memcpy(ray, host_front_buffer(), sizeof ray);
        kc_use_raster = 1; snprintf(name, sizeof name, "%s_raster", s[i].name); shot(name);
        const uint8_t *ras = host_front_buffer();
        int w = KC_RP->width, h = KC_RP->height, same = 0, close = 0, geo = 0, holes = 0;
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                uint8_t a = ray[y * 320 + x], b = ras[y * 320 + x];
                int sa = (a >> 4) == COLOR_SKY, sb = (b >> 4) == COLOR_SKY;
                same += a == b;
                close += (a >> 2) == (b >> 2);          // same color + shade, fog level may differ
                geo += sa == sb && (sa || ((a >> 2) & 3) == ((b >> 2) & 3));   // sky vs surface + face
                holes += !sa && sb;                     // ray hit ground, raster shows sky
            }
        double geo_pct = 100.0 * geo / (w * h);
        printf("  %-13s geometry match %5.1f%%, sky holes %d\n", s[i].name, geo_pct, holes);
        // Edge growth (1/8 px, closes T-junction cracks) fattens silhouettes: 98-99% is expected.
        if (geo_pct < 97.5 || holes) { printf("  FAIL  %s: geometry below 97.5%% or sky holes\n", s[i].name); failures++; }
        raster_stats_t *r = &raster_stats;
        // Instruction estimates from the rv32 disassembly: covers ~25, shade_px+qrcp ~310,
        // triangle setup ~450, bin per quad ~40 (culled) / ~250 (visible); ray: 52 per DDA step + ~200 per pixel.
        double ras_mi = (r->pixels_tested * 25.0 + r->pixels_covered * 310.0 + r->tri_setups * 450.0
                       + r->quads_culled * 40.0 + r->quads_visible * 250.0 + r->bin_entries * 300.0) / 1e6;
        printf("  %-13s same %5.1f%% | quads vis %4u culled %4u, tile entries %4u, tri setups %4u, px tested %6u "
               "covered %6u written %6u | est. %.1f M instr%s\n",
               s[i].name, 100.0 * same / (w * h), r->quads_visible, r->quads_culled,
               r->bin_entries, r->tri_setups, r->pixels_tested, r->pixels_covered, r->pixels_written, ras_mi,
               r->vis_overflow || r->bin_overflow ? "  OVERFLOW" : "");
    }
    kc_set_resolution(160);
    printf("%s\n", failures ? "SOME CHECKS FAILED" : "all checks passed");
    return failures != 0;
}

static int cmd_play(void) {
    printf("physics\n");
    step_frames(60);
    check(kc_me.on_ground, "player lands on the ground after spawning");
    q16 y_ground = kc_me.pos[1];
    check((kc_me.pos[1] & 0xFFFF) == 0, "feet rest exactly on a block top");
    save_frame("p0_start");

    key(KEY_SPACE, 1); step_frames(8); key(KEY_SPACE, 0);
    check(kc_me.pos[1] > y_ground + Q16(0.9), "jump rises about a block");
    step_frames(40);
    check(kc_me.on_ground, "lands again after the jump");

    printf("editing\n");
    key('9', 1); key('9', 0);
    kc_me.pitch = Q16(-110.0);                         // look at the ground a couple of blocks ahead
    step_frames(1);
    check(kc_me.aim_hit, "aiming at the ground ahead");
    {   // selection box: same pose with and without an aimed block must differ only by the box
        static uint8_t with_box[320 * 240];
        shot("p1_aim");
        memcpy(with_box, host_front_buffer(), sizeof with_box);
        kc_me.aim_hit = 0;
        shot("p1_noaim");
        kc_me.aim_hit = 1;
        const uint8_t *no_box = host_front_buffer();
        int32_t w = KC_RP->width, h = KC_RP->height, drawn = 0, other = 0;
        for (int32_t y = 0; y < h; y++)
            for (int32_t x = 0; x < w; x++) {
                int32_t i = y * FB_STRIDE + x;
                if (with_box[i] != no_box[i]) { if (with_box[i] == PIX(COLOR_BLACK, 0, 0)) drawn++; else other++; }
            }
        printf("  selection box: %d px\n", drawn);
        check(drawn > 20 && other == 0, "selection box outlines the aimed block (black pixels only)");
    }
    {
        int32_t px = kc_me.place[0], py = kc_me.place[1], pz = kc_me.place[2];
        key(KEY_PLACE, 1); key(KEY_PLACE, 0); step_frames(1);
        check(world_get(px, py, pz) == B_BRICK, "K places brick (slot 9) on the aimed face");
        save_frame("p1_placed");
        key(KEY_BREAK, 1); key(KEY_BREAK, 0); step_frames(1);
        check(world_get(px, py, pz) == B_AIR, "J breaks it again");
    }
    kc_me.pitch = Q16(-200.0);                         // look down at the feet
    step_frames(1);
    check(kc_me.aim_hit, "aiming at the block under the player");
    int32_t ax = kc_me.aim[0], ay = kc_me.aim[1], az = kc_me.aim[2];
    uint8_t before = world_get(ax, ay, az);
    key(KEY_BREAK, 1); key(KEY_BREAK, 0); step_frames(1);
    check(before != B_AIR && world_get(ax, ay, az) == B_AIR, "J breaks the aimed block");
    step_frames(30);
    check(kc_me.pos[1] < y_ground, "player falls into the hole");
    kc_me.pitch = Q16(-200.0);
    step_frames(1);
    check(!kc_me.aim_hit || world_get(kc_me.place[0], kc_me.place[1], kc_me.place[2]) == B_AIR,
          "placing into our own cell is refused");
    key(KEY_PLACE, 1); key(KEY_PLACE, 0); step_frames(1);
    check(!box_overlap_any(), "player is not inside a block after K at the feet");

    printf("chunk round trip\n");
    // Leave a marker tower at a known spot, walk far enough that its chunk leaves the window,
    // come back, and make sure it was stored to DDR3 and loaded back.
    int32_t mx = qfloor(kc_me.pos[0]) + 3, mz = qfloor(kc_me.pos[2]);
    for (int32_t y = 26; y <= 28; y++) world_set(mx, y, mz, B_BRICK);
    uint64_t stores0 = hstats.chunk_stores, loads0 = hstats.chunk_loads;
    uint32_t gen0 = world_stats_generated();
    q16 home[3] = { kc_me.pos[0], kc_me.pos[1], kc_me.pos[2] };
    int far_frames = pose(home[0] + Q16(200.0), Q16(30.0), home[2], 0, 0);
    check(world_get(mx, 27, mz) == B_AIR, "marker chunk is out of the window");
    check(world_stats_generated() - gen0 == 16, "16 new chunks generated far away");
    check(far_frames >= 16, "at most one generation per frame after startup");
    int back_frames = pose(home[0], home[1], home[2], 0, 0);
    if (world_storage_ok()) {
        check(hstats.chunk_stores >= stores0 + 16, "evicted chunks (generated = dirty) were stored");
        check(hstats.chunk_loads >= loads0 + 16, "coming back loads all 16 chunks instead of generating");
        check(world_stats_generated() - gen0 == 16, "nothing regenerated on the way back");
        check(world_get(mx, 27, mz) == B_BRICK, "marker survived leaving and coming back");
        check(world_get(ax, ay, az) == B_AIR, "the broken block is still broken");
    } else {
        check(world_get(mx, 27, mz) == B_AIR, "fallback: chunk regenerated, edit gone (issue #2 rule)");
    }
    printf("  storage: %s | far window %d frames, back %d frames | %llu stores, %llu loads, %u generated\n",
           world_storage_ok() ? "DDR3 chunk store" : "fallback (no DDR3)", far_frames, back_frames,
           (unsigned long long)hstats.chunk_stores, (unsigned long long)hstats.chunk_loads,
           (unsigned)world_stats_generated());
    printf("  arena high water: %u of %u bytes\n", (unsigned)arena_high_water(), (unsigned)ARENA_SIZE);

    printf("walk\n");
    kc_me.pos[1] = Q16(30.0); kc_me.vel_y = 0;          // drop in from above (fallback may have refilled the hole)
    step_frames(45);
    q16 z0 = kc_me.pos[2];
    kc_me.yaw = 0; kc_me.pitch = Q16(-20.0);
    key(KEY_W, 1); key(KEY_SPACE, 1); step_frames(90); key(KEY_W, 0); key(KEY_SPACE, 0);
    q16 moved = kc_me.pos[2] - z0;
    printf("  walked %.2f blocks in 3 s (blocked by terrain is fine)\n", moved / 65536.0);
    check(moved > 0, "W moves forward");
    save_frame("p2_walk");

    printf("%s\n", failures ? "SOME CHECKS FAILED" : "all checks passed");
    return failures != 0;
}

// VTRACE contract cases (wiki Tai page, "One step"), checked against vtrace_ref.
static kc_ray contract_ray(q16 tx, q16 ty, q16 tz, q16 dx, q16 dy, q16 dz) {
    kc_ray r;
    r.f[0] = CELL_PACK(10, 20, 10);                     // open air above the spawn terrain
    r.f[1] = (uint32_t)tx; r.f[2] = (uint32_t)ty; r.f[3] = (uint32_t)tz;
    r.f[4] = (uint32_t)dx; r.f[5] = (uint32_t)dy; r.f[6] = (uint32_t)dz;
    r.f[7] = 0;
    return r;
}

static int cmd_contract(void) {
    kc_hit h;
    kc_ray r;
    printf("vtrace contract\n");
    r = contract_ray(0x8000, 0x8000, 0x10000, Q16_ONE, Q16_ONE, Q16_ONE);
    vtrace_ref(&r, 1, &h);
    check(HIT_AXIS(h.res) == 1, "tie x == y < z steps y (strict <)");
    r = contract_ray(0x8000, 0x10000, 0x8000, Q16_ONE, Q16_ONE, Q16_ONE);
    vtrace_ref(&r, 1, &h);
    check(HIT_AXIS(h.res) == 2, "tie x == z < y steps z");
    r = contract_ray(0x8000, 0x8000, 0x8000, Q16_ONE, Q16_ONE, Q16_ONE);
    vtrace_ref(&r, 1, &h);
    check(HIT_AXIS(h.res) == 2, "three-way tie steps z");
    r = contract_ray(0x7FFF0000, Q16_ONE, 0x7FFFFFFF, 0x10000, 0x7FFFFFFF, 0x7FFFFFFF);
    vtrace_ref(&r, 2, &h);       // step 1: y (smallest); tMax.y += 0x7FFF_FFFF saturates instead of
                                 // wrapping negative, so step 2 is x, not y again
    check(HIT_AXIS(h.res) == 0 && HIT_STEPS(h.res) == 2, "tMax saturates at 0x7FFF_FFFF (no wrap)");
    q16 o[3] = { Q16(10.5), Q16(20.5), Q16(10.5) }, d[3] = { 0, -Q16_ONE, 0 };
    ray_setup(&r, o, d);
    check(r.f[4] == 0x7FFFFFFF && r.f[6] == 0x7FFFFFFF, "zero direction component gets tDelta 0x7FFF_FFFF");
    vtrace_ref(&r, 64, &h);
    check(HIT_AXIS(h.res) == 1 && CELL_X(h.cell) == 10 && CELL_Z(h.cell) == 10, "straight-down ray never steps x or z");
    kc_hit before = { 0x1234, 0x5678, 0x9ABC };
    h = before;
    vtrace_ref(&r, 0, &h);
    check(h.res == before.res && h.cell == before.cell && h.t == before.t, "max_steps 0 leaves results unchanged");
    printf("%s\n", failures ? "SOME CHECKS FAILED" : "all checks passed");
    return failures != 0;
}

static int cmd_vectors(void) {
    char path[512];
    snprintf(path, sizeof path, "%s/world.hex", outdir);
    FILE *w = fopen(path, "w");
    for (int y = 0; y < 32; y++)                       // window-relative order, WIN_ORIGIN = 0
        for (int z = 0; z < 64; z++)
            for (int x = 0; x < 64; x++)
                fprintf(w, "%x\n", hal_win_get(x, y, z));
    fclose(w);

    snprintf(path, sizeof path, "%s/rays.txt", outdir);
    FILE *f = fopen(path, "w");
    fprintf(f, "# f0 f1 f2 f3 f4 f5 f6 f7 max_steps -> res cell t   (hex, from vtrace_ref)\n");
    uint32_t seed = 1;
    int n = 0;
    for (int i = 0; i < 2000; i++) {
        seed = seed * 1664525u + 1013904223u;
        q16 o[3] = { (q16)(4 + (seed >> 8) % 56) << 16, 0, 0 };
        seed = seed * 1664525u + 1013904223u; o[1] = (q16)((18 + (seed >> 8) % 12) << 16);
        seed = seed * 1664525u + 1013904223u; o[2] = (q16)((4 + (seed >> 8) % 56) << 16);
        for (int k = 0; k < 3; k++) { seed = seed * 1664525u + 1013904223u; o[k] |= (seed >> 12) & 0xFFFF; }
        q16 d[3];
        for (int k = 0; k < 3; k++) { seed = seed * 1664525u + 1013904223u; d[k] = (q16)((seed >> 14) & 0x1FFFF) - 0x10000; }
        if (i < 6) { d[0] = d[1] = d[2] = 0; d[i % 3] = i < 3 ? Q16_ONE : -Q16_ONE; }   // axis-aligned
        int steps = i == 6 ? 1 : (i % 7 == 0 ? 8 : 160);
        kc_ray r; kc_hit h;
        ray_setup(&r, o, d);
        vtrace_ref(&r, steps, &h);
        for (int k = 0; k < 8; k++) fprintf(f, "%08x ", r.f[k]);
        fprintf(f, "%02x -> %04x %05x %08x\n", steps, h.res, h.cell, (uint32_t)h.t);
        n++;
    }
    fclose(f);
    printf("  wrote %s/world.hex and %d rays to %s/rays.txt\n", outdir, n, outdir);
    return 0;
}

static int cmd_bench(void) {
    for (int w = 160; w <= 320; w += 160) {
        kc_set_resolution(w);
        uint64_t r0 = hstats.world_reads;
        clock_t c0 = clock();
        kc_use_raster = 0;
        for (int i = 0; i < 20; i++) { write_camera(); kc_draw_world(); }
        double ms = (double)(clock() - c0) * 1000.0 / CLOCKS_PER_SEC / 20;
        double reads = (double)(hstats.world_reads - r0) / 20;
        printf("  %dx%d: %.2f ms/frame on the laptop, %.0f DDA steps/frame (%.1f per pixel)\n",
               w, w * 3 / 4, ms, reads, reads / (w * w * 3 / 4));
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: kc_host shots|play|vectors|compare <dir> | contract | bench\n");
        return 2;
    }
    if (argc > 2) outdir = argv[2];
    host_init(0);
    kc_init();
    if (!strcmp(argv[1], "shots"))   return cmd_shots();
    if (!strcmp(argv[1], "play"))    return cmd_play();
    if (!strcmp(argv[1], "vectors")) return cmd_vectors();
    if (!strcmp(argv[1], "contract")) return cmd_contract();
    if (!strcmp(argv[1], "bench"))   return cmd_bench();
    if (!strcmp(argv[1], "compare")) return cmd_compare();
    fprintf(stderr, "unknown command %s\n", argv[1]);
    return 2;
}
