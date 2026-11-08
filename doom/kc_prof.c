// KC_PROF=1 profile (doom/README.md): CYCLES around the main per-frame work,
// printed once per frame by DG_DrawFrame. Cross-object calls are timed with
// linker wraps (doom/doom.mk); R_DrawColumn and R_DrawSpan are reached
// through colfunc/basecolfunc and spanfunc, so those pointers are aimed at
// timing shims after every R_ExecuteSetViewSize. Counters nest: G_Ticker runs
// inside TryRunTics; R_RenderBSPNode (walls), R_DrawPlanes and R_DrawMasked
// inside R_RenderPlayerView, the column calls inside BSP (walls) and masked
// (sprites), the span calls inside planes; the V_ calls mostly inside
// ST_Drawer and HU_Drawer.
#include <stdint.h>
#include <stdio.h>

#include "doomtype.h"
#include "d_player.h"
#include "r_main.h"
#include "v_patch.h"

#include "kc_prof.h"

#define CYCLES (*(volatile uint32_t *)0x5000000Cu)

typedef struct {
    uint32_t calls;
    uint32_t cyc;
} prof_t;

enum { P_RPV, P_BSP, P_PLANES, P_MASKED, P_COL, P_SPAN, P_TICS, P_GTICK, P_ST, P_HU, P_V, P_DRAW, P_N };
static prof_t prof[P_N];
static const char *const prof_name[P_N] = {
    "rpv", "bsp", "planes", "masked", "col", "span", "tics", "gtick", "st", "hu", "v", "dgdraw"
};

#define TIMED(id, call)                        \
    do {                                       \
        uint32_t t0_ = CYCLES;                 \
        call;                                  \
        prof[id].cyc += CYCLES - t0_;          \
        prof[id].calls++;                      \
    } while (0)

void __real_R_RenderPlayerView(player_t *player);
void __wrap_R_RenderPlayerView(player_t *player) { TIMED(P_RPV, __real_R_RenderPlayerView(player)); }

void __real_R_RenderBSPNode(int bspnum);
void __wrap_R_RenderBSPNode(int bspnum) { TIMED(P_BSP, __real_R_RenderBSPNode(bspnum)); }

void __real_R_DrawPlanes(void);
void __wrap_R_DrawPlanes(void) { TIMED(P_PLANES, __real_R_DrawPlanes()); }

void __real_R_DrawMasked(void);
void __wrap_R_DrawMasked(void) { TIMED(P_MASKED, __real_R_DrawMasked()); }

void __real_TryRunTics(void);
void __wrap_TryRunTics(void) { TIMED(P_TICS, __real_TryRunTics()); }

void __real_G_Ticker(void);
void __wrap_G_Ticker(void) { TIMED(P_GTICK, __real_G_Ticker()); }

void __real_ST_Drawer(boolean fullscreen, boolean refresh);
void __wrap_ST_Drawer(boolean fullscreen, boolean refresh) { TIMED(P_ST, __real_ST_Drawer(fullscreen, refresh)); }

void __real_HU_Drawer(void);
void __wrap_HU_Drawer(void) { TIMED(P_HU, __real_HU_Drawer()); }

void __real_V_DrawPatch(int x, int y, patch_t *patch);
void __wrap_V_DrawPatch(int x, int y, patch_t *patch) { TIMED(P_V, __real_V_DrawPatch(x, y, patch)); }

void __real_V_DrawPatchDirect(int x, int y, patch_t *patch);
void __wrap_V_DrawPatchDirect(int x, int y, patch_t *patch) { TIMED(P_V, __real_V_DrawPatchDirect(x, y, patch)); }

void __real_V_CopyRect(int srcx, int srcy, byte *source, int width, int height, int destx, int desty);
void __wrap_V_CopyRect(int srcx, int srcy, byte *source, int width, int height, int destx, int desty) {
    TIMED(P_V, __real_V_CopyRect(srcx, srcy, source, width, height, destx, desty));
}

void __real_V_DrawBlock(int x, int y, int width, int height, byte *src);
void __wrap_V_DrawBlock(int x, int y, int width, int height, byte *src) {
    TIMED(P_V, __real_V_DrawBlock(x, y, width, height, src));
}

static void (*real_col)(void);
static void (*real_span)(void);
static void prof_col(void) { TIMED(P_COL, real_col()); }
static void prof_span(void) { TIMED(P_SPAN, real_span()); }

void kc_prof_hook_draw(void) {
    real_col = basecolfunc;
    real_span = spanfunc;
    colfunc = basecolfunc = prof_col;
    spanfunc = prof_span;
}

static uint32_t last_frame;
static uint32_t frame_no;

void kc_prof_frame(uint32_t draw_cycles) {
    uint32_t now = CYCLES;
    prof[P_DRAW].cyc += draw_cycles;
    prof[P_DRAW].calls++;
    printf("kcprof %lu total %lu", (unsigned long)frame_no, (unsigned long)(now - last_frame));
    for (int i = 0; i < P_N; i++)
        printf(" %s %lu/%lu", prof_name[i], (unsigned long)prof[i].calls, (unsigned long)prof[i].cyc);
    printf("\n");
    for (int i = 0; i < P_N; i++) prof[i] = (prof_t){ 0, 0 };
    frame_no++;
    last_frame = CYCLES;   // the report's own UART time is left out
}
