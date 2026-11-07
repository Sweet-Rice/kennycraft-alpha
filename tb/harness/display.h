#pragma once
#include <array>
#include <cstdint>
#include <string>
#if KC_SDL
#include <SDL3/SDL.h>
#endif

// Core-side swap signals, sampled before the clk_core edge.
struct DisplaySignals {
    bool swap_req;
    bool swap_pending;
    bool fb_mode;
};

// The RTL's back buffer and palette, read from the model at emit time.
// Byte i of the back buffer is banks[i / bank_bytes][i % bank_bytes].
struct FrameView {
    const uint8_t* const* banks;
    unsigned bank_bytes;
    const uint16_t* palette;    // 256 RGB444 entries
};

class Display {
public:
    Display(bool headless, const std::string& png_dir);
    ~Display();
    Display(const Display&) = delete;
    Display& operator=(const Display&) = delete;
    // True when the RTL accepts a swap this edge: swap_req && !swap_pending
    // (rtl/display/display.sv ignores swap_req while a swap is pending).
    static bool accepts_swap(const DisplaySignals& signals) {
        return signals.swap_req && !signals.swap_pending;
    }
    void emit(const FrameView& view, bool mode, uint64_t cycle);
    uint64_t frames() const { return frames_; }
private:
    std::array<uint8_t, 76800 * 3> rgb_{};
    uint64_t frames_ = 0, previous_cycle_ = 0;
    std::string png_dir_;
#if KC_SDL
    bool sdl_initialized_ = false;
    SDL_Window* window_ = nullptr;
    SDL_Renderer* renderer_ = nullptr;
    SDL_Texture* texture_ = nullptr;
    int texture_width_ = 0;
    std::array<uint32_t, 76800> pixels_{};
#endif
};
