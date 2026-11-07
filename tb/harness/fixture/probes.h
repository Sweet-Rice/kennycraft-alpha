#pragma once
#define KC_HAS_ERR 0
#define KC_HAS_RETIRE 0
#define KC_FB_WE(d) ((d).rootp->fixture_top__DOT__fb_we)
#define KC_FB_ADDR(d) ((d).rootp->fixture_top__DOT__fb_addr)
#define KC_FB_WDATA(d) ((d).rootp->fixture_top__DOT__fb_wdata)
#define KC_PAL_WE(d) ((d).rootp->fixture_top__DOT__pal_we)
#define KC_PAL_ADDR(d) ((d).rootp->fixture_top__DOT__pal_addr)
#define KC_PAL_WDATA(d) ((d).rootp->fixture_top__DOT__pal_wdata)
#define KC_SWAP_REQ(d) ((d).rootp->fixture_top__DOT__swap_req)
#define KC_SWAP_PENDING(d) ((d).rootp->fixture_top__DOT__swap_pending)
#define KC_FB_MODE(d) ((d).rootp->fixture_top__DOT__fb_mode)
