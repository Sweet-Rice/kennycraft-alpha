// kc_golden.c: plain-C reference frames for the chip's own startup sequence.
//
// Links Kennedy's game sources with his laptop HAL (game/host/hal_host.c), the
// same C the chip build compiles, and runs what the chip's main() runs:
// kc_init(), then kc_frame() once per frame. After frame N it writes the
// front buffer (what VGA shows after FB_SWAP N) through the palette as
// <out_dir>/golden<N>.ppm, in t_top_frame's 160x120 format (P3, 8-bit
// channels = 4-bit level x 17). Build it with -DKC_RASTER=1 for the raster
// chip builds and without for the ray tracer ones; KC_LANES stays 1 (the
// reference is the one-lane C, independent of the lane split).
//
// Only the time step depends on the chip: kc_frame turns CYCLES deltas into
// dt and clamps it at 0.35 s. CYCLES advances <cycles_per_frame> per frame
// (default 50,000,000 = 1 s, i.e. the clamp, as on a chip slower than about
// 3 fps). Without key input the player rests on a block top, so dt does not
// change the picture.
//
//   kc_golden <frames> <out_dir> [<sim_dir>] [<cycles_per_frame>]
//
// With <sim_dir> each golden frame is compared pixel for pixel with
// <sim_dir>/frame<N>.ppm from t_top_frame; the exit status is 0 only when
// every frame matches.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "kc_hal.h"
#include "hal_host.h"
#include "kc_main.h"

enum { W = 160, H = 120 };

void host_on_swap(void) {}

static void golden_rgb(uint8_t rgb[H][W][3]) {
    const uint8_t *fb = host_front_buffer();
    const uint16_t *pal = host_palette();
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) {
            uint16_t c = pal[fb[y * FB_STRIDE + x]];
            rgb[y][x][0] = (uint8_t)(17 * ((c >> 8) & 15));
            rgb[y][x][1] = (uint8_t)(17 * ((c >> 4) & 15));
            rgb[y][x][2] = (uint8_t)(17 * (c & 15));
        }
}

static void write_ppm(const char *path, uint8_t rgb[H][W][3]) {
    FILE *f = fopen(path, "w");
    if (!f) { fprintf(stderr, "kc_golden: cannot write %s\n", path); exit(2); }
    fprintf(f, "P3\n%d %d\n255\n", W, H);
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++)
            fprintf(f, "%d %d %d\n", rgb[y][x][0], rgb[y][x][1], rgb[y][x][2]);
    fclose(f);
}

// Pixels that differ from the golden frame, or -1 if the file is unreadable.
static int compare_ppm(const char *path, uint8_t rgb[H][W][3]) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    int w, h, max, diff = 0;
    if (fscanf(f, "P3 %d %d %d", &w, &h, &max) != 3 || w != W || h != H || max != 255) { fclose(f); return -1; }
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) {
            int r, g, b;
            if (fscanf(f, "%d %d %d", &r, &g, &b) != 3) { fclose(f); return -1; }
            if (r != rgb[y][x][0] || g != rgb[y][x][1] || b != rgb[y][x][2]) {
                if (diff < 5)
                    printf("kc_golden:   (%d,%d) sim %d %d %d, golden %d %d %d\n",
                           x, y, r, g, b, rgb[y][x][0], rgb[y][x][1], rgb[y][x][2]);
                diff++;
            }
        }
    fclose(f);
    return diff;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: kc_golden <frames> <out_dir> [<sim_dir>] [<cycles_per_frame>]\n");
        return 2;
    }
    int frames = atoi(argv[1]);
    const char *out = argv[2], *sim = argc > 3 && argv[3][0] ? argv[3] : NULL;
    uint32_t step = argc > 4 ? (uint32_t)strtoul(argv[4], NULL, 0) : CORE_HZ;
    static uint8_t rgb[H][W][3];
    char path[1024];
    int bad = 0;

    host_init(0);
    kc_init();
    for (int n = 1; n <= frames; n++) {
        host_advance_cycles(step);
        kc_frame();
        if (host_fb_mode() != 1) { fprintf(stderr, "kc_golden: FB_MODE is not 160x120\n"); return 2; }
        golden_rgb(rgb);
        snprintf(path, sizeof path, "%s/golden%d.ppm", out, n);
        write_ppm(path, rgb);
        if (!sim) continue;
        snprintf(path, sizeof path, "%s/frame%d.ppm", sim, n);
        int d = compare_ppm(path, rgb);
        if (d < 0) { printf("kc_golden: frame %d: cannot read %s\n", n, path); bad++; }
        else if (d) { printf("kc_golden: frame %d: %d of %d pixels differ from the C reference\n", n, d, W * H); bad++; }
        else printf("kc_golden: frame %d: all %d pixels match the C reference\n", n, W * H);
    }
    if (sim) printf("kc_golden: %s\n", bad ? "FAIL" : "PASS");
    return bad != 0;
}
