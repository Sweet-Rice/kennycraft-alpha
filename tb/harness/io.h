#pragma once
#include <cstdint>
#include <deque>
#include <fstream>
#include <string>
#include <utility>
#include <vector>

class IO {
public:
    IO(const std::string& keys_file, const std::string& record_file, bool live);
    void poll(uint64_t frame);
    void boundary(uint64_t frame);
    bool rx() const { return rx_line_; }
    void tick(bool tx, uint64_t cycle);
    bool quit() const { return quit_; }
    int verdict() const { return verdict_; }
private:
    void received(uint8_t byte);
    bool live_, quit_ = false, rx_line_ = true;
    std::vector<std::pair<uint64_t, uint8_t>> replay_;
    size_t replay_index_ = 0;
    std::vector<uint8_t> pending_;
    std::deque<uint8_t> queue_;
    std::ofstream record_;
    std::string line_;
    int verdict_ = -1;
    uint16_t rx_bits_ = 0;
    unsigned rx_bit_ = 10, rx_remaining_ = 0;
    bool tx_previous_ = true, tx_active_ = false;
    unsigned tx_bit_ = 0;
    uint8_t tx_byte_ = 0;
    uint64_t tx_next_ = 0;
};
