// Renderer set-up for KennyCraft (doom/README.md), without editing doomgeneric.
//
// Colormaps in dmem: --wrap=R_Init copies the COLORMAP lump (34 x 256 bytes)
// into dmem at KC_DMEM_COLORMAPS after R_Init and points Doom's colormaps at
// the copy. Every lookup through it is then a BRAM read instead of a D-cache
// access. The tables R_Init derived from the old pointer are rebuilt:
// zlight (R_InitLightTables, run again here). scalelight is built by
// R_ExecuteSetViewSize, which first runs in D_Display after R_Init;
// fixedcolormap, scalelightfixed, the sprites' colormaps and the fuzz effect
// read colormaps every frame.
//
// View size: the same wrap then applies KC_DETAIL (KC_DETAIL_LOW) and
// KC_SCREENBLOCKS (doom/doom.mk) the way the menu does: detailLevel,
// screenblocks and the menu's screenSize slider, then R_SetViewSize. The
// defaults (high, 10) are Doom's own, so they change nothing.
#include <stdint.h>
#include <string.h>

#include "doomtype.h"
#include "i_system.h"
#include "m_menu.h"
#include "r_local.h"
#include "w_wad.h"

#include "kc_mem.h"

// r_main.c and m_menu.c, not in their headers
void R_InitLightTables(void);
extern int screenSize;

void __real_R_Init(void);
void __wrap_R_Init(void) {
    __real_R_Init();

    int lump = W_GetNumForName("COLORMAP");
    int len = W_LumpLength(lump);
    if (len > KC_DMEM_COLORMAPS_SIZE) I_Error("kc: COLORMAP is %d bytes", len);
    memcpy((void *)KC_DMEM_COLORMAPS, colormaps, (size_t)len);
    colormaps = (lighttable_t *)KC_DMEM_COLORMAPS;
    W_ReleaseLumpNum(lump);
    R_InitLightTables();

    detailLevel = KC_DETAIL_LOW;
    screenblocks = KC_SCREENBLOCKS;
    screenSize = screenblocks - 3;
    R_SetViewSize(screenblocks, detailLevel);
}

