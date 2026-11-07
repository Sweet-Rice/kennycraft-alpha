#pragma once
#define KC_HAS_ERR 1
#define KC_HAS_RETIRE 1
#ifndef KC_LANES
#define KC_LANES 1
#endif

#define KC_GLUE2(a, b) a##b
#define KC_GLUE(a, b) KC_GLUE2(a, b)

#ifndef CHIP_TOP
#define CHIP_TOP bench_chip
#endif

#define KC_TOP_DOT(member) KC_GLUE(CHIP_TOP, KC_GLUE(__DOT__, member))

#define KC_FB_WE(d) ((d).rootp->KC_TOP_DOT(fb_we))
#define KC_FB_ADDR(d) ((d).rootp->KC_TOP_DOT(fb_addr))
#define KC_FB_WDATA(d) ((d).rootp->KC_TOP_DOT(fb_wdata))
#define KC_PAL_WE(d) ((d).rootp->KC_TOP_DOT(pal_we))
#define KC_PAL_ADDR(d) ((d).rootp->KC_TOP_DOT(pal_addr))
#define KC_PAL_WDATA(d) ((d).rootp->KC_TOP_DOT(pal_wdata))
#define KC_SWAP_REQ(d) ((d).rootp->KC_TOP_DOT(swap_req))
#define KC_SWAP_PENDING(d) ((d).rootp->KC_TOP_DOT(swap_pending))
#define KC_FB_MODE(d) ((d).rootp->KC_TOP_DOT(fb_mode))

#define KC_ERR(d) ((d).rootp->KC_TOP_DOT(u_soc__DOT__u_mmio__DOT__err))
#define KC_ERR_PC(d) ((d).rootp->KC_TOP_DOT(u_soc__DOT__u_mmio__DOT__err_pc))

#define KC_RETIRE_VALID(d) ((d).rootp->KC_TOP_DOT(u_soc__DOT__u_core__DOT__retire_valid))
#define KC_RETIRE_PC(d) ((d).rootp->KC_TOP_DOT(u_soc__DOT__u_core__DOT__retire_pc))
#define KC_RETIRE_INSTR(d) ((d).rootp->KC_TOP_DOT(u_soc__DOT__u_core__DOT__retire_inst))
#define KC_MASK(d) ((d).rootp->KC_TOP_DOT(u_soc__DOT__u_core__DOT__retire_mask))
#define KC_RD_WE(d, lane) (((d).rootp->KC_TOP_DOT(u_soc__DOT__u_core__DOT__retire_lane_we) >> (lane)) & 1U)
#define KC_RD_ADDR(d, lane) ((d).rootp->KC_TOP_DOT(u_soc__DOT__u_core__DOT__retire_rd_addr))
#define KC_RD_WDATA(d, lane) ((d).rootp->KC_TOP_DOT(u_soc__DOT__u_core__DOT__retire_lane_wdata)[lane])
