// main_host.c — headless laptop front-end.
//   kc_host shots   <dir>   golden camera shots: PNG (x4) + raw back buffer (.fb, 320x240 bytes)
//   kc_host play    <dir>   scripted play-through with checks (physics, editing, chunk round trip)
//   kc_host vectors <dir>   VTRACE test vectors: world.hex + rays.txt from the C reference
//   kc_host bench           render timing and world reads per frame
//   kc_host sweep           arena high water over many locations x frames x edits, plus
//                           a digest of the window (must not change with optimizations)
//   kc_host gencost         terrain generation cost per chunk (terrain_height, window reads/writes)
//   kc_host models  <dir>   static entity checks and renderer/close-up review shots
//   kc_host cr6             CR6 UART command link checks (framing, ops, chip-side rules, HUD)
//   kc_host link    <dir>   stdin = UART RX, stdout = UART TX at ~20 fps, <dir>/live.png every
//                           4th frame: the laptop's kc-host drives this build as it would the board
#define _DEFAULT_SOURCE   // usleep for kc_host link
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include "kc_hal.h"
#include "hal_host.h"
#include "kc_assets.h"   // kc_palette, for the Nether color checks
#include "kc_main.h"
#include "game.h"
#include "chunks.h"
#include "render.h"
#include "trace.h"
#include "blocks.h"
#include "arena.h"
#include "entity.h"
#include "terrain.h"
#define TERRAIN_GEN(cx, cz, x0, z0) terrain_gen_chunk(cx, cz, x0, z0, gen_scratch)

static const char *outdir = ".";
static int failures;

// Tag cells must never be visible: count y = 0 cells that aren't bedrock in slots whose
// SLOT_VALID bit is set (raw BRAM, so a tag nibble of 0 = air is caught too).
static int tag_leaks(void) {
    uint32_t v = host_slot_valid();
    int bad = 0;
    for (uint32_t s = 0; s < 16; s++) {
        if (!((v >> s) & 1)) continue;
        for (uint32_t z = 0; z < 16; z++)
            for (uint32_t x = 0; x < 16; x++)
                bad += host_bram_phys((s & 3) * 16 + x, 0, (s >> 2) * 16 + z) != B_BEDROCK;
    }
    return bad;
}
static uint64_t swap_scans, swap_leaks, hit_scans, hit_leaks;

void host_on_swap(void) { swap_scans++; swap_leaks += (uint64_t)tag_leaks(); }

// world_update, then (if a load's tag matched) check before anything else can look.
static void update_checked(int x, int z) {
    uint32_t h0 = world_stats_tag_hits();
    world_update(x, z);
    if (world_stats_tag_hits() != h0) { hit_scans++; hit_leaks += (uint64_t)tag_leaks(); }
}

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
    do { arena_reset(); update_checked(qfloor(x), qfloor(z)); frames++; } while (!world_ready() && frames < 200);
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

static void models_render(const char *name, uint8_t out[320 * 240]) {
    shot(name);
    memcpy(out,host_front_buffer(),320 * 240);
}

static int cmd_models(void) {
    static uint8_t base[320 * 240], model[320 * 240], hidden[320 * 240];
    q16 bx = kc_me.pos[0], by = kc_me.pos[1], bz = kc_me.pos[2];
    int32_t sx = qfloor(bx), sz = qfloor(bz);
    kc_set_resolution(160);
    pose(bx,by,bz,Q16_INT(128),Q16_INT(-40));
    entity_clear();
    models_render("base",base);
    const int32_t dx[ENT_KINDS] = {2,5,4,7}, dz[ENT_KINDS] = {5,2,4,6}, facing[ENT_KINDS] = {2,3,2,3};
    int32_t chick_x = 0, chick_z = 0;
    for (int32_t k = 0; k < ENT_KINDS; k++) {
        int32_t x = sx+dx[k], z = sz+dz[k];
        while (terrain_tree_at(x,z)) x++;
        entity_add(k,Q16_INT(x)+Q16_HALF,Q16_INT(terrain_height(x,z)+1),Q16_INT(z)+Q16_HALF,facing[k]);
        if (k == ENT_CHICKEN) { chick_x = x; chick_z = z; }
    }
    models_render("m0_models",model);
    int changed = 0, bad = 0, brick = 0, wood = 0;
    const uint32_t colors = (1u<<0)|(1u<<1)|(1u<<2)|(1u<<3)|(1u<<4)|(1u<<6)|(1u<<8)|(1u<<9)|(1u<<11)|(1u<<13)|(1u<<14);
    for (int32_t y = 0; y < KC_RP->height; y++)
        for (int32_t x = 0; x < KC_RP->width; x++) {
            int32_t i = y*FB_STRIDE+x;
            int a = base[i] != model[i];
            changed += a;
            bad += a && !(colors & (1u << (model[i] >> 4)));
            brick += a && (model[i] >> 4) == 11;
            wood += a && (model[i] >> 4) == 13;
        }
    printf("  changed %d; brick %d wood %d\n",changed,brick,wood);
    check(changed >= 300,"entities change at least 300 pixels");
    check(!bad,"entity pixels use only model palette colors");
    check(brick >= 20,"at least 20 brick-colored entity pixels");
    check(wood >= 20,"at least 20 light-wood entity pixels");

    entity_clear();
    entity_add(ENT_ZOMBIE,Q16_INT(chick_x)+Q16_HALF,Q16(2.0),Q16_INT(chick_z)+Q16_HALF,2);
    models_render("buried",hidden);
    check(!memcmp(base,hidden,sizeof hidden),"buried entity leaves the frame unchanged");
    entity_clear();
    int32_t x = sx-4, z = sz-4;
    entity_add(ENT_ZOMBIE,Q16_INT(x)+Q16_HALF,Q16_INT(terrain_height(x,z)+1),Q16_INT(z)+Q16_HALF,2);
    models_render("behind",hidden);
    check(!memcmp(base,hidden,sizeof hidden),"entity behind the camera leaves the frame unchanged");
    entity_clear();
    for (int32_t i = 0; i < ENT_MAX; i++) entity_add(ENT_CHICKEN,bx,by,bz,0);
    check(entity_add(ENT_CHICKEN,bx,by,bz,0) == -1,"ninth entity is rejected");
    entity_clear();
    check(entity_add(ENT_KINDS,bx,by,bz,0) == -1,"invalid entity kind is rejected");

    // Walking: 4 blocks east at 1.2 blocks/s arrives within 4 s of 0.1 s frames, facing +x, on the ground.
    int32_t wx = sx+2, wz = sz+6, id = entity_add(ENT_ZOMBIE,Q16_INT(wx)+Q16_HALF,by,Q16_INT(wz)+Q16_HALF,0);
    check(entity_move(id,Q16_INT(wx+4)+Q16_HALF,Q16_INT(wz)+Q16_HALF) == 0,"entity_move accepts a live id");
    check(entity_move(id+1,0,0) == -1,"entity_move rejects an unused id");
    q16 wp[3]; int32_t wf;
    world_set(wx+4,terrain_height(wx+4,wz)+4,wz,B_LEAVES);    // canopy over the target
    for (int32_t f = 0; f < 40; f++) entity_tick(Q16(0.1));
    entity_get(id,wp,&wf);
    check(wp[0] == Q16_INT(wx+4)+Q16_HALF && wp[2] == Q16_INT(wz)+Q16_HALF,"walking entity reaches its target");
    check(wf == 1,"walking entity faces its direction of travel (+x)");
    check(wp[1] == Q16_INT(terrain_height(wx+4,wz)+1),"walking entity stands on the ground, not the canopy");
    entity_clear();

    const char *names[ENT_KINDS] = {"m1_trader","m1_contractor","m1_chicken","m1_zombie"};
    kc_set_resolution(320);
    for (int32_t k = 0; k < ENT_KINDS; k++) {
        entity_clear();
        pose(bx,by,bz,0,Q16(-30.0));
        entity_add(k,Q16_INT(sx)+Q16_HALF,Q16_INT(terrain_height(sx,sz+3)+1),Q16_INT(sz+3)+Q16_HALF,2);
        shot(names[k]);
    }
    entity_clear();
    kc_set_resolution(160);
    printf("%s\n",failures ? "SOME CHECKS FAILED" : "all checks passed");
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
    uint32_t gen0 = world_stats_generated(), miss0 = world_stats_tag_misses();
    printf("  ddr3 power-on fill: %s, %s%s\n", host_ddr_fill_name(),
           KC_GEN_BITMAP ? "8 KB generated bitmap" : "chunk tags",
           KC_GEN_BITMAP ? "" : KC_TAG_PERSIST ? " (KC_TAG_PERSIST: no boot nonce)" : " with boot nonce");
    q16 home[3] = { kc_me.pos[0], kc_me.pos[1], kc_me.pos[2] };
    int far_frames = pose(home[0] + Q16(200.0), Q16(30.0), home[2], 0, 0);
    check(world_get(mx, 27, mz) == B_AIR, "marker chunk is out of the window");
    check(world_stats_generated() - gen0 == 16, "16 new chunks generated far away");
    check(far_frames >= 16, "at most one generation per frame after startup");
    if (!world_storage_ok())
        check(hstats.chunk_loads == loads0, "power-on DDR3: fallback never loads, nothing from DDR3 accepted");
    else if (KC_GEN_BITMAP)
        check(hstats.chunk_loads == loads0, "power-on DDR3: bitmap never loads a chunk it didn't generate");
    else
        check(world_stats_tag_misses() - miss0 == 16 && hstats.chunk_loads - loads0 == 16,
              "power-on DDR3: 16 loads of never-stored chunks, no tag accepted, all generated");
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
    {
        int bedrock = 1;
        for (int32_t z = mz & ~15; z < (mz & ~15) + 16; z++)
            for (int32_t x = mx & ~15; x < (mx & ~15) + 16; x++) bedrock &= world_get(x, 0, z) == B_BEDROCK;
        check(bedrock, "marker chunk has its full bedrock layer (tag cells restored)");
    }

    // A stored chunk's bytes at another chunk's DDR3 address (addressing mix-up) must not be
    // accepted: the tag names the chunk. The copy target was never stored this boot.
    {
        int32_t mcx = mx >> 4, mcz = mz >> 4, dcx = mcx + 30;
        host_ddr_copy((uint32_t)(mcz * 256 + mcx), (uint32_t)(mcz * 256 + dcx));
        uint32_t gen1 = world_stats_generated();
        pose(home[0] + Q16(30.0 * 16), home[1], home[2], 0, 0);
        check(world_stats_generated() - gen1 == 16, "misaddressed chunk: copy at the wrong address is regenerated");
        check(world_get(mx + 30 * 16, 27, mz) == B_AIR, "misaddressed chunk: the copy's marker did not appear");
        pose(home[0], home[1], home[2], 0, 0);
        check(world_get(mx, 27, mz) == (world_storage_ok() ? B_BRICK : B_AIR),
              world_storage_ok() ? "marker still there after a second round trip" : "fallback: marker gone after a second round trip");
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

    printf("reset\n");
    // Edit a block, move away so its chunk is stored, press reset (DDR3 keeps its contents,
    // CYCLES restarts with different jitter, so a new boot nonce), boot at spawn again.
    {
        int32_t rx = 2048 + 5, rz = 2048 + 3;                // inside the spawn window
        pose(Q16_INT(rx), Q16(30.0), Q16_INT(rz), 0, 0);
        world_set(rx, 27, rz, B_PLANKS);
        check(world_get(rx, 27, rz) == B_PLANKS, "reset test: edit placed");
        uint64_t st0 = hstats.chunk_stores;
        pose(Q16_INT(rx) + Q16(200.0), Q16(30.0), Q16_INT(rz), 0, 0);
        check(!world_storage_ok() || hstats.chunk_stores > st0, "reset test: edited chunk stored on leaving");
        host_reset(0x5A17u);
        world_reboot();
        kc_init();                                         // game_init: first world_update at spawn
        uint64_t hs0 = hit_scans, hl0 = hit_leaks;
        if (world_stats_tag_hits()) { hit_scans++; hit_leaks += (uint64_t)tag_leaks(); }
        pose(Q16_INT(rx), Q16(30.0), Q16_INT(rz), 0, 0);
        int persist = world_storage_ok() && !KC_GEN_BITMAP && KC_TAG_PERSIST;
        uint32_t g = world_stats_generated(), hits = world_stats_tag_hits();
        printf("  after reset: %u generated, %u tag hits, %u tag misses\n", (unsigned)g, (unsigned)hits,
               (unsigned)world_stats_tag_misses());
        if (persist) {
            check(world_get(rx, 27, rz) == B_PLANKS, "KC_TAG_PERSIST: same seed after reset reloads, edit survives");
            check(hits == 16 && g == 0, "KC_TAG_PERSIST: all 16 chunks tag-matched, none generated");
            check(hit_scans > hs0 && hit_leaks == hl0, "KC_TAG_PERSIST: y = 0 all bedrock right after the boot's tag-matched loads");
        } else if (world_storage_ok()) {
            check(world_get(rx, 27, rz) == B_AIR, "same seed after reset regenerates instead of reloading: edit gone");
            check(g == 16 && hits == 0, KC_GEN_BITMAP ? "after reset: all 16 chunks generated (bitmap starts empty)"
                                                      : "after reset: all 16 chunks generated, no tag from the old boot accepted");
        } else {
            check(world_get(rx, 27, rz) == B_AIR, "fallback: same seed after reset regenerates, edit gone");
            check(g == 16 && hstats.chunk_loads == 0, "fallback: after reset all 16 chunks generated, nothing loaded");
        }
    }

    // Reset again with exactly the same CYCLES jitter as the last boot. The nonce must still
    // change (DDR3 boot counter), or chunks stored by the last boot would be trusted.
    if (world_storage_ok() && !KC_GEN_BITMAP && !KC_TAG_PERSIST) {
        int32_t rx = 2048 + 5, rz = 2048 + 3;
        uint32_t n1 = world_boot_nonce();
        world_set(rx, 27, rz, B_PLANKS);
        pose(Q16_INT(rx) + Q16(200.0), Q16(30.0), Q16_INT(rz), 0, 0);   // store the spawn window
        host_reset(0x5A17u);                               // same jitter as the reset above
        world_reboot();
        kc_init();
        uint32_t n2 = world_boot_nonce();
        printf("  same-jitter reset: nonce 0x%08x -> 0x%08x\n", (unsigned)n1, (unsigned)n2);
        check(n1 != n2, "same-jitter reset: boot nonce still changes (boot counter)");
        pose(Q16_INT(rx), Q16(30.0), Q16_INT(rz), 0, 0);
        check(world_get(rx, 27, rz) == B_AIR && world_stats_tag_hits() == 0,
              "same-jitter reset: no tag from the previous boot accepted, edit gone");
        // Visit the world corner: chunk (1, 0) is generated (bedrock over the counter cells)
        // and stored on leaving, so its tag write must put the counter back.
        uint32_t c2 = world_boot_count();
        pose(Q16(8.0), Q16(30.0), Q16(8.0), 0, 0);
        pose(Q16_INT(rx), Q16(30.0), Q16_INT(rz), 0, 0);
        host_reset(0x5A17u);
        world_reboot();
        kc_init();
        printf("  boot counter across a corner visit: %u -> %u\n", (unsigned)c2, (unsigned)world_boot_count());
        check(world_boot_count() == c2 + 1, "boot counter survives chunk (1, 0) being generated and stored in play");
        check(world_boot_nonce() != n2, "nonce changes again after the corner visit");
    }

    printf("nether\n");
    {
        step_frames(30);
        q16 ox = kc_me.pos[0], oz = kc_me.pos[2];
        key(KEY_P, 1); key(KEY_P, 0);
        step_frames(150);
        int32_t nx = qfloor(kc_me.pos[0]), ny = qfloor(kc_me.pos[1]), nz = qfloor(kc_me.pos[2]);
        uint8_t under = world_get(nx, ny - 1, nz);
        printf("  landed at %d %d %d on block %u\n", (int)nx, (int)ny, (int)nz, (unsigned)under);
        check(nx >= NETHER_X0 && kc_me.pos[2] == oz, "P takes you into the Nether strip, same z");
        check(kc_me.on_ground && under == B_OBSIDIAN && world_get(nx, ny, nz) == B_PORTAL
              && world_get(nx, ny + 2, nz) == B_PORTAL, "you arrive standing in a lit return portal");
        check(world_get(nx, WIN_Y - 1, nz) == B_BEDROCK, "the Nether has a bedrock roof");
        const uint16_t *pal = host_palette();
        check((pal[0xF8] >> 8) > (pal[0xF8] & 15) && pal[0x50] == kc_palette[0x50],
              "the Nether sky is red, unfogged block colors are unchanged");
        save_frame("p9_nether");
        key(KEY_P, 1); key(KEY_P, 0);
        step_frames(150);
        q16 dx = kc_me.pos[0] - ox;
        check(dx >= 0 && dx < Q16_INT(16) && kc_me.pos[2] == oz && kc_me.on_ground,
              "P again brings you back to where you left, standing");
        check(!memcmp(host_palette(), kc_palette, sizeof kc_palette), "back home: the whole palette is palette.hex again");

        // Portal: an obsidian frame 3 blocks ahead in z, standing along x, built on the ground.
        int32_t px = qfloor(kc_me.pos[0]), py = qfloor(kc_me.pos[1]), pz = qfloor(kc_me.pos[2]) + 3;
        for (int32_t v = 0; v < 6; v++)
            for (int32_t a = -1; a < 5; a++) world_set(px + a, py + v, pz, B_AIR);
        for (int32_t a = 0; a < 4; a++) world_set(px + a, py - 1, pz, B_OBSIDIAN);   // bottom rim
        for (int32_t v = 0; v < 4; v++) { world_set(px, py + v, pz, B_OBSIDIAN); world_set(px + 3, py + v, pz, B_OBSIDIAN); }
        world_set(px + 1, py + 3, pz, B_OBSIDIAN);
        check(!portal_light(px + 1, py + 3, pz), "an unfinished frame does not light");
        world_set(px + 2, py + 3, pz, B_OBSIDIAN);
        check(portal_light(px + 2, py + 3, pz) && world_get(px + 1, py, pz) == B_PORTAL
              && world_get(px + 2, py + 2, pz) == B_PORTAL, "the last obsidian block lights a 2 x 3 portal");
        kc_me.yaw = 0; kc_me.pitch = 0;   // face +z, at the portal
        step_frames(2);
        save_frame("p10_portal");
        kc_me.pos[0] = Q16_INT(px + 1) + Q16_HALF;
        kc_me.pos[2] = Q16_INT(pz) + Q16_HALF;
        step_frames(150);
        check(qfloor(kc_me.pos[0]) >= NETHER_X0 && kc_me.on_ground, "walking into the portal takes you to the Nether");
        int32_t qx = qfloor(kc_me.pos[0]), qy = qfloor(kc_me.pos[1]), qz = qfloor(kc_me.pos[2]);
        check(world_get(qx, qy, qz) == B_PORTAL, "the return portal from the first trip is reused");
        step_frames(60);
        check(qfloor(kc_me.pos[0]) >= NETHER_X0, "standing in the return portal does not send you back");
        world_set(qx, qy, qz + 1, B_AIR); world_set(qx, qy + 1, qz + 1, B_AIR);   // room to step out
        kc_me.pos[2] += Q16_INT(1);
        step_frames(5);
        kc_me.pos[2] -= Q16_INT(1);                                             // and back in
        step_frames(150);
        int32_t bx = qfloor(kc_me.pos[0]);
        check(bx >= px + 1 && bx < NETHER_X0 && qfloor(kc_me.pos[2]) == pz,
              "back in the overworld at the portal, and it does not fire again until you step out");

        // Breaking: a frame block puts the whole portal out; so does breaking a portal block.
        game_break(px, py + 1, pz);
        int32_t lit = 0;
        for (int32_t v = 0; v < 3; v++) for (int32_t a = 1; a < 3; a++) lit += world_get(px + a, py + v, pz) == B_PORTAL;
        check(lit == 0 && world_get(px, py + 1, pz) == B_AIR, "breaking a frame block clears all 6 portal blocks");
        world_set(px, py + 1, pz, B_OBSIDIAN);
        check(portal_light(px, py + 1, pz), "putting the block back relights it");
        game_break(px + 2, py + 2, pz);
        lit = 0;
        for (int32_t v = 0; v < 3; v++) for (int32_t a = 1; a < 3; a++) lit += world_get(px + a, py + v, pz) == B_PORTAL;
        check(lit == 0, "breaking one portal block clears the rest");

        // The wall: x = NETHER_X0 is bedrock top to bottom, and walking east stops at it.
        int32_t wz = qfloor(kc_me.pos[2]), wall = 1;
        pose(Q16_INT(NETHER_X0 - 4) + Q16_HALF, Q16(30.0), Q16_INT(wz) + Q16_HALF, Q16_INT(256), 0);
        for (int32_t y = 0; y < WIN_Y; y++) wall &= world_get(NETHER_X0, y, wz) == B_BEDROCK;
        check(wall, "a full-height bedrock wall stands at x = 3072");
        step_frames(60);                                   // fall onto the ground
        key(KEY_W, 1); key(KEY_SPACE, 1);
        step_frames(240);                                  // walk and jump east into the wall
        key(KEY_W, 0); key(KEY_SPACE, 0);
        step_frames(2);
        printf("  walked east to x = %.2f\n", kc_me.pos[0] / 65536.0);
        check(kc_me.pos[0] < Q16_INT(NETHER_X0) && kc_me.pos[0] > Q16_INT(NETHER_X0 - 1),
              "walking east from the overworld reaches the wall and stops there");
    }

    printf("tag visibility\n");
    check(tag_leaks() == 0, "window settled: every y = 0 cell of every valid slot is bedrock");
    printf("  %llu frame swaps and %llu world_updates with tag-matched loads checked\n",
           (unsigned long long)swap_scans, (unsigned long long)hit_scans);
    check(swap_leaks == 0, "every frame swap: y = 0 of every valid slot is bedrock");
    if (world_storage_ok() && !KC_GEN_BITMAP)
        check(hit_scans > 0 && hit_leaks == 0, "right after each tag-matched load: y = 0 of every valid slot is bedrock");
    check(hstats.stores_from_valid == 0, "every chunk_store came from a slot whose SLOT_VALID bit was clear");

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
        for (int i = 0; i < 20; i++) { write_camera(); kc_draw_world(); }
        double ms = (double)(clock() - c0) * 1000.0 / CLOCKS_PER_SEC / 20;
        double reads = (double)(hstats.world_reads - r0) / 20;
        printf("  %dx%d: %.2f ms/frame on the laptop, %.0f DDA steps/frame (%.1f per pixel)\n",
               w, w * 3 / 4, ms, reads, reads / (w * w * 3 / 4));
    }
    return 0;
}


// ---------------------------------------------------------------- sweep / gencost --------
static uint32_t lcg_state = 12345;
static uint32_t lcg(void) { lcg_state = lcg_state * 1664525u + 1013904223u; return lcg_state >> 8; }
static uint64_t fnv(uint64_t h, uint32_t v) { for (int i = 0; i < 4; i++) { h ^= (v >> (8 * i)) & 255; h *= 1099511628211ull; } return h; }

static uint64_t window_digest(uint64_t h) {
    int32_t x0 = world_corner_x(), z0 = world_corner_z();
    for (int32_t y = 0; y < 32; y++)
        for (int32_t z = 0; z < 64; z++)
            for (int32_t x = 0; x < 64; x += 4) {
                uint32_t v = 0;
                for (int k = 0; k < 4; k++) v |= (uint32_t)world_get(x0 + x + k, y, z0 + z) << (8 * k);
                h = fnv(h, v);
            }
    return h;
}

static void tap(uint8_t code) { key(code, 1); key(code, 0); }

static int cmd_sweep(void) {
    uint64_t wd = 1469598103934665603ull;
    int locations = 48, frames = 0, edits = 0;
    uint32_t worst_loc = 0, worst = 0;
    for (int l = 0; l < locations; l++) {
        int32_t x = 64 + (int32_t)(lcg() % 3968), z = 64 + (int32_t)(lcg() % 3968);
        if (l == 0) { x = qfloor(kc_me.pos[0]); z = qfloor(kc_me.pos[2]); }
        if (l % 6 == 5) { x = (x & ~15) + 15; z = (z & ~15); }   // chunk corners
        kc_me.pos[0] = Q16_INT(x) + Q16_HALF; kc_me.pos[2] = Q16_INT(z) + Q16_HALF;
        kc_me.pos[1] = Q16(30.0); kc_me.vel_y = 0;
        int n = 0;
        do { step_frames(1); n++; kc_me.pos[1] = Q16(30.0); kc_me.vel_y = 0; } while (!world_ready() && n < 100);
        kc_me.pos[1] = Q16_INT(terrain_height(x, z) + 1);
        for (int f = 0; f < 48; f++) {
            kc_me.yaw = (q16)(lcg() % 1024) << 16;
            kc_me.pitch = (q16)((int32_t)(lcg() % 400) - 250) << 16;
            if (f % 3 == 0) tap((uint8_t)('1' + lcg() % 9));
            if (f % 3 == 1) { tap(KEY_BREAK); edits++; }
            if (f % 3 == 2) { tap(KEY_PLACE); edits++; }
            if (f % 8 == 0) {                               // direct edits on chunk borders
                for (int k = 0; k < 6; k++) {
                    int32_t bx = world_corner_x() + (int32_t)(lcg() % 64), bz = world_corner_z() + (int32_t)(lcg() % 64);
                    if (k & 1) bx = (bx & ~15) + (k & 2 ? 15 : 0);
                    else       bz = (bz & ~15) + (k & 2 ? 15 : 0);
                    world_set(bx, 1 + (int32_t)(lcg() % 31), bz, (uint8_t)(lcg() % 16));
                    edits++;
                }
            }
            if (f == 40) key(KEY_W, 1);
            if (f == 47) key(KEY_W, 0);
            step_frames(1);
            n++;
        }
        frames += n;
        wd = window_digest(wd);
        if (arena_high_water() > worst) { worst = arena_high_water(); worst_loc = (uint32_t)l; }
    }
    printf("  sweep: %d locations, %d frames, %d edits, %u chunks generated\n",
           locations, frames, edits, (unsigned)world_stats_generated());
    printf("  arena high water: %u of %u bytes (first reached at location %u)\n",
           (unsigned)arena_high_water(), (unsigned)ARENA_SIZE, (unsigned)worst_loc);
    printf("  window digest %016llx\n", (unsigned long long)wd);
    return 0;
}

static int cmd_gencost(void) {
    int n = 256;
    arena_reset();
    void *gen_scratch = arena_alloc(TERRAIN_SCRATCH_BYTES);
    uint64_t wd = 1469598103934665603ull;
    uint32_t th0 = terrain_height_calls;
    uint64_t r0 = hstats.world_reads, w0 = hstats.world_writes;
    clock_t c0 = clock();
    for (int i = 0; i < n; i++) {
        int32_t cx = (int32_t)(lcg() % 256), cz = (int32_t)(lcg() % 256);
        if (i < 4) { cx = i & 1 ? 255 : 0; cz = i & 2 ? 255 : 0; }   // world edges
        TERRAIN_GEN(cx, cz, world_corner_x(), world_corner_z());
        uint64_t r1 = hstats.world_reads;
        int32_t x0 = (cx * 16 - world_corner_x()) & 63, z0 = (cz * 16 - world_corner_z()) & 63;
        for (int32_t y = 0; y < 32; y++)
            for (int32_t z = 0; z < 16; z++)
                for (int32_t x = 0; x < 16; x++) wd = fnv(wd, hal_win_get((x0 + x) & 63, y, (z0 + z) & 63));
        r0 += hstats.world_reads - r1;                  // don't count the digest reads
    }
    double ms = (double)(clock() - c0) * 1000.0 / CLOCKS_PER_SEC;
    printf("  gencost: %d chunks | per chunk: terrain_height %.1f, hal_win_set %.1f, hal_win_get %.1f | %.1f ms total (incl. digest)\n",
           n, (double)(terrain_height_calls - th0) / n, (double)(hstats.world_writes - w0) / n,
           (double)(hstats.world_reads - r0) / n, ms);
    printf("  chunk digest %016llx\n", (unsigned long long)wd);
    return 0;
}

// ---------------------------------------------------------------- CR6 ---------------------
static uint8_t cr6_crc(const uint8_t *p, int n) {
    uint32_t c = 0;
    for (int i = 0; i < n; i++) {
        c ^= p[i];
        for (int k = 0; k < 8; k++) c = (c & 0x80) ? ((c << 1) ^ 0x07) & 0xFF : (c << 1) & 0xFF;
    }
    return (uint8_t)c;
}

static void cr6_push(uint8_t seq, uint8_t op, const uint8_t *p, int n, int corrupt) {
    uint8_t f[16] = { 0xA5, (uint8_t)(n + 2), seq, op };
    memcpy(f + 4, p, (size_t)n);
    f[n + 4] = (uint8_t)(cr6_crc(f + 1, n + 3) ^ corrupt);
    for (int i = 0; i < n + 5; i++) host_push_key(f[i]);
}

typedef struct { int status, seq, ev, ev_arg, rop, rn, frames; uint8_t rp[40]; } cr6_out;

// One frame; decode what the chip sent back.
static cr6_out cr6_step(void) {
    cr6_out o = { -1, -1, -1, -1, -1, 0, 0, { 0 } };
    host_tx_clear();
    step_frames(1);
    for (uint32_t i = 0; i + 4 < host_tx_n; ) {
        uint8_t *f = host_tx + i;
        if (f[0] != 0xA5) { i++; continue; }
        int n = f[1] - 2;
        if (i + (uint32_t)n + 5 > host_tx_n || cr6_crc(f + 1, n + 3) != f[n + 4]) { o.frames = -99; break; }
        o.frames++;
        if (f[3] == 0x81) { o.status = f[4]; o.seq = f[2]; }
        else if (f[3] == 0x8F) { o.ev = f[4]; o.ev_arg = f[5] | f[6] << 8; }
        else { o.rop = f[3]; o.rn = n; memcpy(o.rp, f + 4, (size_t)n); }
        i += (uint32_t)n + 5;
    }
    return o;
}

static void le16(uint8_t *p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }

static int cmd_cr6(void) {
    enum { OK, CRC, BAD_OP, ZONE, BAD_BLOCK, PROTECTED, RATE };
    host_uart_out(NULL, 1);
    entity_clear();
    step_frames(2);
    int px = qfloor(kc_me.pos[0]), py = qfloor(kc_me.pos[1]), pz = qfloor(kc_me.pos[2]);
    int ty = py + 2;
    while (world_get(px + 3, ty, pz) != B_AIR || world_get(px + 4, ty, pz) != B_AIR) ty++;
    uint8_t p[8];
    cr6_out o;

    le16(p, (uint32_t)px + 3); le16(p + 2, (uint32_t)pz); p[4] = (uint8_t)ty; p[5] = B_PLANKS;
    cr6_push(1, 0x10, p, 6, 0);
    o = cr6_step();
    check(host_tx_n == 0 && world_get(px + 3, ty, pz) == B_AIR, "before HELLO: commands ignored, nothing sent back");

    cr6_push(2, 0x01, (const uint8_t *)"KC\x01", 3, 0);
    o = cr6_step();
    check(o.rop == 0x82 && o.rn == 7 && o.rp[0] == 1 && o.rp[1] == 16 && o.status == OK && o.seq == 2,
          "HELLO -> HELLO_ACK (ver 1, RX_DEPTH 16) and a STATUS after the drain");
    o = cr6_step();
    check(o.status == OK && o.frames == 1, "linked: one STATUS per frame even with nothing to do");

    le16(p, (uint32_t)px + 3); le16(p + 2, (uint32_t)pz); p[4] = (uint8_t)ty; p[5] = B_PLANKS;
    cr6_push(3, 0x10, p, 6, 0);
    check(cr6_step().status == ZONE, "PLACE before the player has talked to anyone: OUT_OF_ZONE");

    p[0] = 0 | 1 << 4; le16(p + 1, (uint32_t)(px + 2) * 16 + 8); le16(p + 3, (uint32_t)pz * 16 + 8); p[5] = (uint8_t)(py * 8);
    cr6_push(4, 0x20, p, 6, 0);
    check(cr6_step().status == OK && entity_count() == 1, "SPAWN a contractor 2 blocks away");
    p[0] = 5;
    cr6_push(5, 0x20, p, 6, 0);
    check(cr6_step().status == 9, "SPAWN with an out-of-order id: BAD_ENTITY");

    key(KEY_E, 1); key(KEY_E, 0);
    o = cr6_step();
    check(o.ev == 3 && o.ev_arg == 0, "E next to the contractor: EVENT INTERACT entity 0");

    {   // MOVE with bit 7 of the id set: the contractor is there at once, no walking
        q16 at[3];
        int32_t facing;
        p[0] = 0x80; le16(p + 1, (uint32_t)(px + 5) * 16 + 8); le16(p + 3, (uint32_t)(pz + 1) * 16 + 8);
        cr6_push(200, 0x21, p, 5, 0);
        int ok = cr6_step().status == OK;
        entity_get(0, at, &facing);
        check(ok && qfloor(at[0]) == px + 5 && qfloor(at[2]) == pz + 1, "MOVE with the teleport bit: there at once");
        p[0] = 0x80; le16(p + 1, (uint32_t)(px + 2) * 16 + 8); le16(p + 3, (uint32_t)pz * 16 + 8);
        cr6_push(201, 0x21, p, 5, 0);
        cr6_step();
    }

    le16(p, (uint32_t)px + 3); le16(p + 2, (uint32_t)pz); p[4] = (uint8_t)ty; p[5] = B_PLANKS;
    cr6_push(6, 0x10, p, 6, 0);
    o = cr6_step();
    check(o.status == OK && o.seq == 6 && world_get(px + 3, ty, pz) == B_PLANKS, "PLACE in the zone: OK, block placed");
    cr6_push(6, 0x10, p, 6, 0);
    check(cr6_step().status == OK, "same seq again (retransmit): OK without running twice");
    cr6_push(7, 0x10, p, 6, 0);
    check(cr6_step().status == PROTECTED, "PLACE into a solid block: PROTECTED");
    p[5] = 10; le16(p, (uint32_t)px + 4);
    cr6_push(8, 0x10, p, 6, 0);
    check(cr6_step().status == BAD_BLOCK, "PLACE bedrock: BAD_BLOCK");
    p[5] = B_DIRT; p[4] = 29;
    cr6_push(9, 0x10, p, 6, 0);
    check(cr6_step().status == ZONE, "PLACE at y = 29: OUT_OF_ZONE");
    le16(p, (uint32_t)px); le16(p + 2, (uint32_t)pz); p[4] = (uint8_t)py + 1; p[5] = B_DIRT;
    cr6_push(10, 0x10, p, 6, 0);
    check(cr6_step().status == PROTECTED, "PLACE inside the player: PROTECTED");

    le16(p, (uint32_t)px + 4); le16(p + 2, (uint32_t)pz); p[4] = (uint8_t)ty; p[5] = B_DIRT;
    cr6_push(11, 0x10, p, 6, 0);
    le16(p, (uint32_t)px + 5);
    cr6_push(12, 0x10, p, 6, 0);
    o = cr6_step();
    check(o.status == RATE && world_get(px + 4, ty, pz) == B_DIRT && world_get(px + 5, ty, pz) != B_DIRT,
          "two edits in one frame: the second gets RATE");

    le16(p, (uint32_t)px + 3); le16(p + 2, (uint32_t)pz - 1); p[4] = (uint8_t)ty + 1; p[5] = 2 | 2 << 4; p[6] = 0 | B_COBBLE << 4;
    cr6_push(13, 0x12, p, 7, 0);
    int filled = 0;
    o = cr6_step();
    for (int z = -1; z <= 1; z++) for (int x = 3; x <= 5; x++) filled += world_get(px + x, ty + 1, pz + z) == B_COBBLE;
    check(o.status == OK && filled == 9, "FILL 3x1x3 cobble above the planks: 9 cells");

    cr6_push(14, 0x30, p, 0, 0);
    o = cr6_step();
    check(o.rop == 0x83 && (uint32_t)(o.rp[0] | o.rp[1] << 8) == (uint32_t)kc_me.pos[0] >> 12 && o.rp[4] == (uint32_t)kc_me.pos[1] >> 13,
          "Q_PLAYER: x, z in 1/16 block, y in 1/8 block");
    le16(p, (uint32_t)px + 3); le16(p + 2, (uint32_t)pz); p[4] = (uint8_t)ty; p[5] = 1;   // sx 2, sy 1, sz 1
    cr6_push(15, 0x31, p, 6, 0);
    o = cr6_step();
    check(o.rop == 0x84 && o.rn == 1 && o.rp[0] == (B_PLANKS | B_DIRT << 4), "Q_BLOCKS 2x1x1: planks, dirt (nibbles)");
    p[5] = 1 << 2;                                                                          // sx 1, sy 2, sz 1
    cr6_push(21, 0x31, p, 6, 0);
    o = cr6_step();
    check(o.rop == 0x84 && o.rp[0] == (B_PLANKS | B_COBBLE << 4), "Q_BLOCKS 1x2x1: planks, cobble above (y after x and z)");
    p[0] = 0;
    cr6_push(22, 0x33, p, 1, 0);
    o = cr6_step();
    { q16 e[3]; int32_t f; entity_get(0, e, &f);
      check(o.rop == 0x86 && o.rn == 7 && o.rp[0] == 0 && (uint32_t)(o.rp[1] | o.rp[2] << 8) == (uint32_t)e[0] >> 12,
            "Q_ENTITY 0: R_ENTITY id, x, z (1/16), y (1/8), state"); }

    le16(p, 1234);
    cr6_push(16, 0x40, p, 2, 0);
    cr6_step();
    p[0] = 7; le16(p + 1, 43);
    cr6_push(17, 0x41, p, 3, 0);
    cr6_step();
    o = cr6_step();
    const uint8_t *fb = host_front_buffer();
    int gold = 0;
    for (int y = 0; y < 20; y++) for (int x = 0; x < 60; x++) gold += fb[y * 320 + x] == PIX(kc_face_color[B_SAND * 3], 0, 0);
    check(gold > 20, "SET_BALANCE / SET_QUOTE: HUD drawn in the top-left corner");
    if (*outdir) save_frame("cr6_hud");
    key(KEY_Y, 1); key(KEY_Y, 0);
    o = cr6_step();
    check(o.ev == 4 && o.ev_arg == (7 | 0x100), "Y with quote 7 on the HUD: EVENT CONFIRM 7 yes");

    key(KEY_W, 1);
    le16(p, 1);
    cr6_push(18, 0x40, p, 2, 0x55);
    o = cr6_step();
    check(o.status == CRC && kc_me.held == 0, "bad CRC: status CRC and held keys released");
    cr6_push(19, 0x77, p, 0, 0);
    check(cr6_step().status == BAD_OP, "unknown op: BAD_OP");

    cr6_push(20, 0x02, p, 0, 0);
    cr6_step();
    check(cr6_step().frames == 0, "BYE: the chip stops sending STATUS");
    host_uart_out(NULL, 0);
    return failures ? 1 : 0;
}

// KC_RAW=<file> writes every frame there as raw RGB888, w*h*3 bytes (scripts/kc.py --host).
static void write_raw(const char *path, int w, int h) {
    static uint8_t rgb[320 * 240 * 3];
    char tmp[600];
    const uint8_t *fb = host_front_buffer();
    const uint16_t *pal = host_palette();
    for (int y = 0, i = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            uint16_t c = pal[fb[y * FB_STRIDE + x]];
            rgb[i++] = (uint8_t)(((c >> 8) & 15) * 17);
            rgb[i++] = (uint8_t)(((c >> 4) & 15) * 17);
            rgb[i++] = (uint8_t)((c & 15) * 17);
        }
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    FILE *f = fopen(tmp, "wb");
    if (!f) return;
    fwrite(rgb, 1, (size_t)w * h * 3, f);
    fclose(f);
    rename(tmp, path);                                 // the reader never sees half a frame
}

// KC_LINK_FPS=n runs the game clock at n real frames per second (default: the old 20 fps
// loop, 1/30 s of game time per frame). KC_REC=<dir> also saves every frame there as
// 000000.png, ... for a smooth demo video (raw PNGs: keep <dir> on a fast disk).
static int cmd_link(void) {
    char path[512], tmp[512];
    const char *rec = getenv("KC_REC"), *fps_s = getenv("KC_LINK_FPS"), *raw = getenv("KC_RAW");
    int fps = fps_s ? atoi(fps_s) : 0;
    uint32_t step = fps > 0 ? CORE_HZ / (uint32_t)fps : CORE_HZ / 30;
    long frame_ns = fps > 0 ? 1000000000L / fps : 50000000L;
    snprintf(path, sizeof path, "%s/live.png", outdir);
    snprintf(tmp, sizeof tmp, "%s/live.tmp.png", outdir);
    fcntl(0, F_SETFL, fcntl(0, F_GETFL) | O_NONBLOCK);
    host_uart_out(stdout, 0);
    struct timespec next;
    clock_gettime(CLOCK_MONOTONIC, &next);
    for (uint32_t n = 0;; n++) {
        uint8_t b[256];
        ssize_t k;
        while ((k = read(0, b, sizeof b)) > 0)
            for (ssize_t i = 0; i < k; i++) host_push_key(b[i]);
        if (k == 0) return 0;                              // kc-host closed the pipe
        host_advance_cycles(step);
        kc_frame();
        fflush(stdout);
        int w = KC_RP->width, h = KC_RP->height;
        if (rec) {
            char f[600];
            snprintf(f, sizeof f, "%s/%06u.png", rec, n);
            png_write_fb(f, host_front_buffer(), host_palette(), w, h, 1);
        }
        if (raw) write_raw(raw, w, h);
        if ((n & 3) == 0) {
            png_write_fb(tmp, host_front_buffer(), host_palette(), w, h, w == 160 ? 4 : 2);
            rename(tmp, path);
        }
        next.tv_nsec += frame_ns;                          // a steady clock, not sleep-after-work
        while (next.tv_nsec >= 1000000000L) { next.tv_nsec -= 1000000000L; next.tv_sec++; }
        clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, NULL);
    }
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: kc_host shots|play|vectors|models|link <dir> | contract | bench | sweep | gencost | cr6\n");
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
    if (!strcmp(argv[1], "sweep"))   return cmd_sweep();
    if (!strcmp(argv[1], "gencost")) return cmd_gencost();
    if (!strcmp(argv[1], "models"))  return cmd_models();
    if (!strcmp(argv[1], "cr6"))     return cmd_cr6();
    if (!strcmp(argv[1], "link"))    return cmd_link();
    fprintf(stderr, "unknown command %s\n", argv[1]);
    return 2;
}
