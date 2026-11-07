#pragma once
#include "display.h"
#include <array>
#include <cstdint>
#define KC_HAS_ERR 0
#define KC_HAS_RETIRE 0
#define KC_SWAP_REQ(d) ((d).rootp->fixture_top__DOT__swap_req)
#define KC_SWAP_PENDING(d) ((d).rootp->fixture_top__DOT__swap_pending)
#define KC_FB_MODE(d) ((d).rootp->fixture_top__DOT__fb_mode)

// One 76,800-byte bank per buffer; the fixture draws into buffer !front_sel.
inline FrameView kc_frame_view(Vkc& d) {
    auto& root = *d.rootp;
    static const std::array<const uint8_t*, 2> banks{
        &root.fixture_top__DOT__fb_mem[0][0], &root.fixture_top__DOT__fb_mem[1][0]};
    return FrameView{&banks[root.fixture_top__DOT__front_sel ? 0 : 1], 76800,
                     &root.fixture_top__DOT__pal_mem[0]};
}
