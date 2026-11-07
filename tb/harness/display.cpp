#include "display.h"
#include <cstdio>
#include <cctype>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
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

void load_palette_hex(const std::string& palette_hex, std::array<uint16_t, 256>& palette) {
    if (palette_hex.empty()) {
        return;
    }

    std::ifstream file(palette_hex);
    if (!file.is_open()) {
        throw std::runtime_error("failed to open palette hex file: " + palette_hex);
    }

    std::stringstream buffer;
    buffer << file.rdbuf();
    const std::string content = buffer.str();

    // Strip comments (// and /* ... */)
    std::string clean;
    clean.reserve(content.size());
    size_t i = 0;
    while (i < content.size()) {
        if (content[i] == '/' && i + 1 < content.size() && content[i + 1] == '/') {
            i += 2;
            while (i < content.size() && content[i] != '\n') {
                ++i;
            }
        } else if (content[i] == '/' && i + 1 < content.size() && content[i + 1] == '*') {
            i += 2;
            bool closed = false;
            while (i + 1 < content.size()) {
                if (content[i] == '*' && content[i + 1] == '/') {
                    closed = true;
                    i += 2;
                    break;
                }
                ++i;
            }
            if (!closed) {
                throw std::runtime_error("unclosed block comment in palette hex file: " + palette_hex);
            }
        } else {
            clean.push_back(content[i++]);
        }
    }

    std::istringstream iss(clean);
    std::string token;
    size_t current_addr = 0;
    size_t words_loaded = 0;

    while (iss >> token) {
        if (token.empty()) {
            continue;
        }

        if (token[0] == '@') {
            std::string addr_str = token.substr(1);
            if (addr_str.empty()) {
                throw std::runtime_error("empty address directive in palette hex file: " + palette_hex);
            }
            std::string addr_clean;
            for (char c : addr_str) {
                if (c == '_') continue;
                if (!std::isxdigit(static_cast<unsigned char>(c))) {
                    throw std::runtime_error("invalid hex character in palette address directive: " + token);
                }
                addr_clean.push_back(c);
            }
            if (addr_clean.empty()) {
                throw std::runtime_error("invalid address directive in palette hex file: " + token);
            }
            unsigned long parsed_addr = std::stoul(addr_clean, nullptr, 16);
            if (parsed_addr >= 256) {
                throw std::runtime_error("palette address directive out of range (>= 256): " + token);
            }
            current_addr = static_cast<size_t>(parsed_addr);
        } else {
            std::string word_clean;
            for (char c : token) {
                if (c == '_') continue;
                if (!std::isxdigit(static_cast<unsigned char>(c))) {
                    throw std::runtime_error("invalid hex token in palette file: " + token);
                }
                word_clean.push_back(c);
            }
            if (word_clean.empty()) {
                throw std::runtime_error("invalid hex token in palette file: " + token);
            }
            if (current_addr >= 256) {
                throw std::runtime_error("palette hex file exceeds 256 entries");
            }
            unsigned long val = std::stoul(word_clean, nullptr, 16);
            palette[current_addr] = static_cast<uint16_t>(val & 0x0FFF);
            current_addr++;
            words_loaded++;
        }
    }

    if (words_loaded == 0) {
        throw std::runtime_error("palette hex file contains no data: " + palette_hex);
    }
}

} // namespace

Display::Display(bool headless, const std::string& png_dir, const std::string& palette_hex)
    : png_dir_(png_dir) {

    validate_and_clear_png_dir(png_dir_);
    load_palette_hex(palette_hex, palette_);

    if (!headless) {
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
    }
}

Display::~Display() {
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
}

bool Display::sample(const DisplaySignals& signals, uint64_t cycle) {
    if (previous_pending_ && !signals.swap_pending) {
        front_ ^= 1;
    }

    // A cleared pending flag exposes the newly selected back buffer this cycle.
    if (signals.fb_we && signals.fb_addr < 76800) {
        buffers_[front_ ^ 1][signals.fb_addr] = signals.fb_wdata;
    }

    if (signals.pal_we) {
        palette_[signals.pal_addr] = static_cast<uint16_t>(signals.pal_wdata & 0x0FFF);
    }

    bool frame_emitted = false;
    if (!previous_swap_ && signals.swap_req) {
        emit(signals.fb_mode, cycle);
        frame_emitted = true;
    }

    previous_swap_ = signals.swap_req;
    previous_pending_ = signals.swap_pending;

    return frame_emitted;
}

void Display::emit(bool mode, uint64_t cycle) {
    frames_++;

    const int width = mode ? 160 : 320;
    const int height = mode ? 120 : 240;

    const auto& back_buf = buffers_[front_ ^ 1];

    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const size_t out_idx = static_cast<size_t>(y * width + x);
            const size_t fb_idx = static_cast<size_t>(y * 320 + x);
            const uint8_t pal_idx = back_buf[fb_idx];
            const uint16_t c12 = palette_[pal_idx];

            const uint8_t r = static_cast<uint8_t>(((c12 >> 8) & 0x0F) * 17);
            const uint8_t g = static_cast<uint8_t>(((c12 >> 4) & 0x0F) * 17);
            const uint8_t b = static_cast<uint8_t>((c12 & 0x0F) * 17);

            if (renderer_) {
                pixels_[out_idx] = (static_cast<uint32_t>(r) << 16) |
                                   (static_cast<uint32_t>(g) << 8) |
                                   static_cast<uint32_t>(b);
            }

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
