// R_DrawColumn and R_DrawSpan on 8 lanes (doom/kc_draw8.S). kc_render.c
// points colfunc/basecolfunc and spanfunc here after every
// R_ExecuteSetViewSize in high detail; low detail, fuzz and translated
// columns stay Doom's scalar functions. Lane 0 does the per-call set-up
// below exactly as Doom does, the kernels the per-pixel loop.
#include <stdint.h>

#include "doomtype.h"
#include "r_local.h"

#include "kc_draw.h"

// r_draw.c, not in its header
extern byte *ylookup[];
extern int columnofs[];

void kc_col8(fixed_t frac, fixed_t step, const byte *source, const lighttable_t *colormap,
             byte *dest, int count);
void kc_span8(uint32_t position, uint32_t step, const byte *source,
              const lighttable_t *colormap, byte *dest, int count);

void kc_R_DrawColumn(void) {
    int count = dc_yh - dc_yl;
    if (count < 0) return;
    fixed_t frac = dc_texturemid + (dc_yl - centery) * dc_iscale;
    kc_col8(frac, dc_iscale, dc_source, dc_colormap, ylookup[dc_yl] + columnofs[dc_x], count + 1);
}

void kc_R_DrawSpan(void) {
    uint32_t position = (((uint32_t)ds_xfrac << 10) & 0xffff0000u)
                      | (((uint32_t)ds_yfrac >> 6) & 0x0000ffffu);
    uint32_t step = (((uint32_t)ds_xstep << 10) & 0xffff0000u)
                  | (((uint32_t)ds_ystep >> 6) & 0x0000ffffu);
    kc_span8(position, step, ds_source, ds_colormap, ylookup[ds_y] + columnofs[ds_x1],
             ds_x2 - ds_x1 + 1);
}
