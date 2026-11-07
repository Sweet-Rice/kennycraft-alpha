#pragma once
#include "display.h"
#include <array>
#include <cstdint>
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

// Swap signals at rtl/display/display.sv's ports (u_display in every top).
#define KC_SWAP_REQ(d) ((d).rootp->KC_TOP_DOT(u_display__DOT__swap_req))
#define KC_SWAP_PENDING(d) ((d).rootp->KC_TOP_DOT(u_display__DOT__swap_pending))
#define KC_FB_MODE(d) ((d).rootp->KC_TOP_DOT(u_display__DOT__fb_mode))

// rtl/display/framebuffer.sv: buffer b, bank k (g_buf[b].g_bank[k].mem), 19 x 4096 B.
// The core writes buffer !front_sel_core, so that is the one an accepted swap presents.
#define KC_FB_MEM(d, b, k) \
    ((d).rootp->KC_TOP_DOT(u_display__DOT__u_fb__DOT__g_buf__BRA__##b##__KET____DOT__g_bank__BRA__##k##__KET____DOT__mem))
#define KC_FB_BUFFER(d, b) { \
    &KC_FB_MEM(d, b, 0)[0],  &KC_FB_MEM(d, b, 1)[0],  &KC_FB_MEM(d, b, 2)[0],  &KC_FB_MEM(d, b, 3)[0], \
    &KC_FB_MEM(d, b, 4)[0],  &KC_FB_MEM(d, b, 5)[0],  &KC_FB_MEM(d, b, 6)[0],  &KC_FB_MEM(d, b, 7)[0], \
    &KC_FB_MEM(d, b, 8)[0],  &KC_FB_MEM(d, b, 9)[0],  &KC_FB_MEM(d, b, 10)[0], &KC_FB_MEM(d, b, 11)[0], \
    &KC_FB_MEM(d, b, 12)[0], &KC_FB_MEM(d, b, 13)[0], &KC_FB_MEM(d, b, 14)[0], &KC_FB_MEM(d, b, 15)[0], \
    &KC_FB_MEM(d, b, 16)[0], &KC_FB_MEM(d, b, 17)[0], &KC_FB_MEM(d, b, 18)[0]}
#define KC_FB_FRONT_SEL(d) ((d).rootp->KC_TOP_DOT(u_display__DOT__front_sel_core))
#define KC_PALETTE_MEM(d) ((d).rootp->KC_TOP_DOT(u_display__DOT__u_pal__DOT__mem))

static_assert(sizeof(KC_FB_MEM(*static_cast<Vkc*>(nullptr), 0, 0)) == 4096, "framebuffer bank layout changed");
static_assert(sizeof(KC_PALETTE_MEM(*static_cast<Vkc*>(nullptr))) == 256 * sizeof(uint16_t), "palette layout changed");

// Back buffer and palette as the RTL holds them now.
inline FrameView kc_frame_view(Vkc& d) {
    static const std::array<std::array<const uint8_t*, 19>, 2> banks{{KC_FB_BUFFER(d, 0), KC_FB_BUFFER(d, 1)}};
    return FrameView{banks[KC_FB_FRONT_SEL(d) ? 0 : 1].data(), 4096, &KC_PALETTE_MEM(d)[0]};
}

#define KC_ERR(d) ((d).rootp->KC_TOP_DOT(u_soc__DOT__u_mmio__DOT__err))
#define KC_ERR_PC(d) ((d).rootp->KC_TOP_DOT(u_soc__DOT__u_mmio__DOT__err_pc))

#define KC_RETIRE_VALID(d) ((d).rootp->KC_TOP_DOT(u_soc__DOT__u_core__DOT__retire_valid))
#define KC_RETIRE_PC(d) ((d).rootp->KC_TOP_DOT(u_soc__DOT__u_core__DOT__retire_pc))
#define KC_RETIRE_INSTR(d) ((d).rootp->KC_TOP_DOT(u_soc__DOT__u_core__DOT__retire_inst))
#define KC_MASK(d) ((d).rootp->KC_TOP_DOT(u_soc__DOT__u_core__DOT__retire_mask))
#define KC_RD_WE(d, lane) (((d).rootp->KC_TOP_DOT(u_soc__DOT__u_core__DOT__retire_lane_we) >> (lane)) & 1U)
#define KC_RD_ADDR(d, lane) ((d).rootp->KC_TOP_DOT(u_soc__DOT__u_core__DOT__retire_rd_addr))
#define KC_RD_WDATA(d, lane) ((d).rootp->KC_TOP_DOT(u_soc__DOT__u_core__DOT__retire_lane_wdata)[lane])
