#pragma once
#include <array>
#include <cstdint>
#include <string>
#include <SDL3/SDL.h>

struct DisplaySignals {
    bool fb_we;
    uint32_t fb_addr;
    uint8_t fb_wdata;
    bool pal_we;
    uint8_t pal_addr;
    uint16_t pal_wdata;
    bool swap_req;
    bool swap_pending;
    bool fb_mode;
};

class Display {
public:
    Display(bool headless, const std::string& png_dir, const std::string& palette_hex);
    ~Display();
    Display(const Display&) = delete;
    Display& operator=(const Display&) = delete;
    bool sample(const DisplaySignals& signals, uint64_t cycle);
    uint64_t frames() const { return frames_; }
private:
    void emit(bool mode, uint64_t cycle);
    std::array<std::array<uint8_t, 76800>, 2> buffers_{};
    std::array<uint16_t, 256> palette_{};
    std::array<uint32_t, 76800> pixels_{};
    std::array<uint8_t, 76800 * 3> rgb_{};
    unsigned front_ = 0;
    bool previous_swap_ = false, previous_pending_ = false;
    uint64_t frames_ = 0, previous_cycle_ = 0;
    std::string png_dir_;
    bool sdl_initialized_ = false;
    SDL_Window* window_ = nullptr;
    SDL_Renderer* renderer_ = nullptr;
    SDL_Texture* texture_ = nullptr;
    int texture_width_ = 0;
};
