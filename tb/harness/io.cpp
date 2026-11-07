#include "io.h"
#include <SDL3/SDL.h>
#include <cctype>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>

static int map_key(SDL_Keycode key) {
    switch (key) {
        case SDLK_W:     return 0x77;
        case SDLK_A:     return 0x61;
        case SDLK_S:     return 0x73;
        case SDLK_D:     return 0x64;
        case SDLK_SPACE: return 0x20;
        case SDLK_LEFT:  return 0x10;
        case SDLK_RIGHT: return 0x11;
        case SDLK_UP:    return 0x12;
        case SDLK_DOWN:  return 0x13;
        case SDLK_J:     return 0x6A;
        case SDLK_K:     return 0x6B;
        case SDLK_1:     return 0x31;
        case SDLK_2:     return 0x32;
        case SDLK_3:     return 0x33;
        case SDLK_4:     return 0x34;
        case SDLK_5:     return 0x35;
        case SDLK_6:     return 0x36;
        case SDLK_7:     return 0x37;
        case SDLK_8:     return 0x38;
        case SDLK_9:     return 0x39;
        default:         return -1;
    }
}

IO::IO(const std::string& keys_file, const std::string& record_file, bool live)
    : live_(live) {
    if (!record_file.empty()) {
        record_.open(record_file);
        if (!record_.is_open()) {
            throw std::runtime_error("cannot open record file: " + record_file);
        }
    }

    if (!keys_file.empty()) {
        std::ifstream file(keys_file);
        if (!file.is_open()) {
            throw std::runtime_error("cannot open keys file: " + keys_file);
        }

        std::string raw_line;
        uint64_t lineno = 0;
        bool has_prev = false;
        uint64_t prev_frame = 0;

        while (std::getline(file, raw_line)) {
            ++lineno;

            size_t comment_pos = raw_line.find('#');
            std::string text = (comment_pos != std::string::npos) ? raw_line.substr(0, comment_pos) : raw_line;

            std::istringstream iss(text);
            std::vector<std::string> tokens;
            std::string tok;
            while (iss >> tok) {
                tokens.push_back(tok);
            }

            if (tokens.empty()) {
                continue;
            }

            if (tokens.size() != 2) {
                throw std::runtime_error("keys " + keys_file + ":" + std::to_string(lineno) + ": bad entry");
            }

            const std::string& ftok = tokens[0];
            if (ftok.empty()) {
                throw std::runtime_error("keys " + keys_file + ":" + std::to_string(lineno) + ": bad entry");
            }
            for (char c : ftok) {
                if (!std::isdigit(static_cast<unsigned char>(c))) {
                    throw std::runtime_error("keys " + keys_file + ":" + std::to_string(lineno) + ": bad entry");
                }
            }
            char* endp = nullptr;
            errno = 0;
            unsigned long long frame_val = std::strtoull(ftok.c_str(), &endp, 10);
            if (errno != 0 || endp == ftok.c_str() || *endp != '\0') {
                throw std::runtime_error("keys " + keys_file + ":" + std::to_string(lineno) + ": bad entry");
            }

            if (has_prev && frame_val < prev_frame) {
                throw std::runtime_error("keys " + keys_file + ":" + std::to_string(lineno) + ": bad entry");
            }

            const std::string& btok = tokens[1];
            if (btok.size() < 3 || btok[0] != '0' || (btok[1] != 'x' && btok[1] != 'X')) {
                throw std::runtime_error("keys " + keys_file + ":" + std::to_string(lineno) + ": bad entry");
            }
            for (size_t i = 2; i < btok.size(); ++i) {
                if (!std::isxdigit(static_cast<unsigned char>(btok[i]))) {
                    throw std::runtime_error("keys " + keys_file + ":" + std::to_string(lineno) + ": bad entry");
                }
            }
            endp = nullptr;
            errno = 0;
            unsigned long byte_val = std::strtoul(btok.c_str() + 2, &endp, 16);
            if (errno != 0 || endp == (btok.c_str() + 2) || *endp != '\0' || byte_val > 255) {
                throw std::runtime_error("keys " + keys_file + ":" + std::to_string(lineno) + ": bad entry");
            }

            replay_.emplace_back(frame_val, static_cast<uint8_t>(byte_val));
            prev_frame = frame_val;
            has_prev = true;
        }

        if (file.bad()) {
            throw std::runtime_error("error reading keys file: " + keys_file);
        }
    }
}

void IO::poll(uint64_t frame) {
    (void)frame;
    if (!live_) {
        return;
    }

    SDL_Event event;
    while (SDL_PollEvent(&event)) {
        if (event.type == SDL_EVENT_QUIT || event.type == SDL_EVENT_WINDOW_CLOSE_REQUESTED) {
            quit_ = true;
        } else if (event.type == SDL_EVENT_KEY_DOWN) {
            if (event.key.repeat) {
                continue;
            }
            if (event.key.key == SDLK_ESCAPE) {
                quit_ = true;
                continue;
            }
            int code = map_key(event.key.key);
            if (code >= 0) {
                pending_.push_back(static_cast<uint8_t>(code | 0x80));
            }
        } else if (event.type == SDL_EVENT_KEY_UP) {
            int code = map_key(event.key.key);
            if (code >= 0) {
                pending_.push_back(static_cast<uint8_t>(code));
            }
        }
    }
}

void IO::boundary(uint64_t frame) {
    while (replay_index_ < replay_.size() && replay_[replay_index_].first <= frame) {
        queue_.push_back(replay_[replay_index_].second);
        replay_index_++;
    }

    for (uint8_t byte : pending_) {
        queue_.push_back(byte);
        if (record_.is_open()) {
            char hex_buf[8];
            snprintf(hex_buf, sizeof(hex_buf), "%02X", byte);
            record_ << frame << " 0x" << hex_buf << "\n";
        }
    }

    if (record_.is_open() && !pending_.empty()) {
        record_.flush();
    }
    pending_.clear();
}

void IO::tick(bool tx, uint64_t cycle) {
    // 1. Advance UART RX
    if (rx_remaining_ > 0) {
        --rx_remaining_;
        if (rx_remaining_ == 0) {
            rx_bit_++;
            if (rx_bit_ < 10) {
                rx_line_ = (rx_bits_ >> rx_bit_) & 1;
                rx_remaining_ = 50;
            }
        }
    }
    if (rx_bit_ >= 10) {
        if (!queue_.empty()) {
            uint8_t byte = queue_.front();
            queue_.pop_front();
            rx_bits_ = static_cast<uint16_t>((byte << 1) | (1 << 9));
            rx_bit_ = 0;
            rx_line_ = false;
            rx_remaining_ = 50;
        } else {
            rx_line_ = true;
            rx_remaining_ = 0;
        }
    }

    // 2. Decode UART TX
    if (tx_active_) {
        if (cycle == tx_next_) {
            if (tx_bit_ == 0) {
                if (!tx) {
                    tx_bit_ = 1;
                    tx_next_ = cycle + 50;
                } else {
                    tx_active_ = false;
                }
            } else if (tx_bit_ <= 8) {
                if (tx) {
                    tx_byte_ |= static_cast<uint8_t>(1 << (tx_bit_ - 1));
                }
                tx_bit_++;
                tx_next_ = cycle + 50;
            } else if (tx_bit_ == 9) {
                if (tx) {
                    received(tx_byte_);
                }
                tx_active_ = false;
            }
        }
    } else {
        if (tx_previous_ && !tx) {
            tx_active_ = true;
            tx_bit_ = 0;
            tx_byte_ = 0;
            tx_next_ = cycle + 25;
        }
    }
    tx_previous_ = tx;
}

void IO::received(uint8_t byte) {
    if ((byte >= 0x20 && byte <= 0x7E) || byte == '\n') {
        std::cout << static_cast<char>(byte);
    } else {
        char buf[16];
        snprintf(buf, sizeof(buf), "\\x%02X", byte);
        std::cout << buf;
    }
    std::cout.flush();

    if (byte == '\n') {
        if (!line_.empty() && line_.back() == '\r') {
            line_.pop_back();
        }
        if (line_ == "PASS") {
            verdict_ = 0;
        } else if (line_.rfind("FAIL", 0) == 0) {
            verdict_ = 1;
        }
        line_.clear();
    } else {
        line_.push_back(static_cast<char>(byte));
    }
}
