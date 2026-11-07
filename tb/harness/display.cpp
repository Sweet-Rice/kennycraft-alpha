#include "display.h"
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <string>

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "third_party/stb_image_write.h"

namespace {

void validate_and_clear_png_dir(const std::string& png_dir) {
    if (png_dir.empty()) {
        throw std::runtime_error("png directory path cannot be empty");
    }

    std::filesystem::path p(png_dir);
    std::filesystem::path norm = p.lexically_normal();
    std::string norm_str = norm.string();

    if (norm_str == "/" || norm_str == "." || norm_str == "..") {
        throw std::runtime_error("hazardous png directory path: " + png_dir);
    }
    if (norm.has_root_path() && norm == norm.root_path()) {
        throw std::runtime_error("hazardous png directory path (root directory): " + png_dir);
    }

    if (norm.is_absolute()) {
        auto it = norm.begin();
        ++it; // Skip root "/"
        if (it != norm.end()) {
            auto next_it = it;
            ++next_it;
            if (next_it == norm.end()) {
                const std::string first = it->string();
                if (first == "bin" || first == "sbin" || first == "etc" ||
                    first == "usr" || first == "dev" || first == "proc" ||
                    first == "sys" || first == "boot" || first == "root" ||
                    first == "Users" || first == "home") {
                    throw std::runtime_error("hazardous png directory path: " + png_dir);
                }
            }
        }
    }

    std::error_code ec;
    std::filesystem::create_directories(p, ec);
    if (ec) {
        throw std::runtime_error("failed to create png directory " + png_dir + ": " + ec.message());
    }

    for (const auto& entry : std::filesystem::directory_iterator(p, ec)) {
        if (ec) {
            throw std::runtime_error("failed to iterate png directory " + png_dir + ": " + ec.message());
        }
        if (entry.is_regular_file()) {
            const std::string name = entry.path().filename().string();
            if (name.rfind("frame_", 0) == 0 &&
                name.size() >= 10 &&
                name.compare(name.size() - 4, 4, ".png") == 0) {
                std::filesystem::remove(entry.path(), ec);
                if (ec) {
                    throw std::runtime_error("failed to remove frame " + entry.path().string() + ": " + ec.message());
                }
            }
        }
    }
}

} // namespace

Display::Display(bool headless, const std::string& png_dir)
    : png_dir_(png_dir) {

    validate_and_clear_png_dir(png_dir_);

    if (!headless) {
#if KC_SDL
        if (!SDL_Init(SDL_INIT_VIDEO)) {
            throw std::runtime_error(std::string("failed to initialize SDL: ") + SDL_GetError());
        }
        sdl_initialized_ = true;

        if (!SDL_CreateWindowAndRenderer("KennyCraft (Verilator)", 640, 480, 0, &window_, &renderer_)) {
            std::string err = SDL_GetError();
            SDL_QuitSubSystem(SDL_INIT_VIDEO);
            sdl_initialized_ = false;
            throw std::runtime_error(std::string("failed to create SDL window and renderer: ") + err);
        }
#else
        throw std::runtime_error("built without SDL3; run with --headless");
#endif
    }
}

Display::~Display() {
#if KC_SDL
    if (texture_) {
        SDL_DestroyTexture(texture_);
        texture_ = nullptr;
    }
    if (renderer_) {
        SDL_DestroyRenderer(renderer_);
        renderer_ = nullptr;
    }
    if (window_) {
        SDL_DestroyWindow(window_);
        window_ = nullptr;
    }
    if (sdl_initialized_) {
        SDL_QuitSubSystem(SDL_INIT_VIDEO);
        sdl_initialized_ = false;
    }
#endif
}

void Display::emit(const FrameView& view, bool mode, uint64_t cycle) {
    frames_++;

    const int width = mode ? 160 : 320;
    const int height = mode ? 120 : 240;

    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const size_t out_idx = static_cast<size_t>(y * width + x);
            const unsigned fb_idx = static_cast<unsigned>(y * 320 + x);
            const uint8_t pal_idx = view.banks[fb_idx / view.bank_bytes][fb_idx % view.bank_bytes];
            const uint16_t c12 = view.palette[pal_idx];

            const uint8_t r = static_cast<uint8_t>(((c12 >> 8) & 0x0F) * 17);
            const uint8_t g = static_cast<uint8_t>(((c12 >> 4) & 0x0F) * 17);
            const uint8_t b = static_cast<uint8_t>((c12 & 0x0F) * 17);

#if KC_SDL
            if (renderer_) {
                pixels_[out_idx] = (static_cast<uint32_t>(r) << 16) |
                                   (static_cast<uint32_t>(g) << 8) |
                                   static_cast<uint32_t>(b);
            }
#endif

            rgb_[out_idx * 3 + 0] = r;
            rgb_[out_idx * 3 + 1] = g;
            rgb_[out_idx * 3 + 2] = b;
        }
    }

    char filename[64];
    std::snprintf(filename, sizeof(filename), "frame_%05llu.png", static_cast<unsigned long long>(frames_));
    std::filesystem::path png_path = std::filesystem::path(png_dir_) / filename;

    int write_ok = stbi_write_png(png_path.string().c_str(), width, height, 3, rgb_.data(), width * 3);
    if (!write_ok) {
        throw std::runtime_error("failed to write PNG: " + png_path.string());
    }

#if KC_SDL
    if (renderer_ != nullptr) {
        if (texture_ == nullptr || texture_width_ != width) {
            if (texture_ != nullptr) {
                SDL_DestroyTexture(texture_);
                texture_ = nullptr;
            }
            texture_ = SDL_CreateTexture(renderer_, SDL_PIXELFORMAT_XRGB8888, SDL_TEXTUREACCESS_STREAMING, width, height);
            if (!texture_) {
                throw std::runtime_error(std::string("failed to create SDL texture: ") + SDL_GetError());
            }
            texture_width_ = width;
            if (!SDL_SetTextureScaleMode(texture_, SDL_SCALEMODE_NEAREST)) {
                throw std::runtime_error(std::string("failed to set SDL texture scale mode: ") + SDL_GetError());
            }
        }

        if (!SDL_UpdateTexture(texture_, nullptr, pixels_.data(), width * static_cast<int>(sizeof(uint32_t)))) {
            throw std::runtime_error(std::string("failed to update SDL texture: ") + SDL_GetError());
        }

        if (!SDL_RenderClear(renderer_)) {
            throw std::runtime_error(std::string("failed to clear SDL renderer: ") + SDL_GetError());
        }

        if (!SDL_RenderTexture(renderer_, texture_, nullptr, nullptr)) {
            throw std::runtime_error(std::string("failed to render SDL texture: ") + SDL_GetError());
        }

        if (!SDL_RenderPresent(renderer_)) {
            throw std::runtime_error(std::string("failed to present SDL renderer: ") + SDL_GetError());
        }
    }
#endif

    const uint64_t delta_cycles = cycle - previous_cycle_;
    previous_cycle_ = cycle;
    const double fps = (delta_cycles > 0) ? (50000000.0 / static_cast<double>(delta_cycles)) : 0.0;

    char log_buf[128];
    std::snprintf(log_buf, sizeof(log_buf), "frame %llu cycles %llu (+%llu) fps@50MHz %.1f\n",
                  static_cast<unsigned long long>(frames_),
                  static_cast<unsigned long long>(cycle),
                  static_cast<unsigned long long>(delta_cycles),
                  fps);
    std::cout << log_buf << std::flush;
}
