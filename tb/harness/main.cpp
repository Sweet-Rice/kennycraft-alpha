#include "Vkc.h"
#include "Vkc___024root.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#ifdef KC_FIXTURE
#include "fixture/ports.h"
#include "fixture/probes.h"
#else
#include "ports.h"
#include "probes.h"
#endif
#include "display.h"
#include "io.h"
#include <array>
#include <cstdio>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>

namespace {
struct Options {
    bool headless = false, expect_pass = false;
    uint64_t frames = 0, max_cycles = 0;
    std::string keys, record, png_dir = "out/frames", palette, trace, vcd;
    uint64_t vcd_start = 0, vcd_end = std::numeric_limits<uint64_t>::max();
    unsigned expected_err = 0;
    bool check_pc = false;
    uint32_t expected_pc = 0;
};
uint64_t number(const std::string& text) {
    size_t used = 0;
    if (text.empty() || text[0] == '-') throw std::runtime_error("bad number: " + text);
    const auto value = std::stoull(text, &used, 0);
    if (used != text.size()) throw std::runtime_error("bad number: " + text);
    return value;
}
Options parse(int argc, char** argv) {
    Options o;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        auto value = [&]() -> std::string {
            if (++i >= argc) throw std::runtime_error(arg + " needs a value");
            return argv[i];
        };
        if (arg == "--headless") o.headless = true;
        else if (arg == "--expect-pass") o.expect_pass = true;
        else if (arg == "--frames") { o.frames = number(value()); if (!o.frames) throw std::runtime_error("--frames must be positive"); }
        else if (arg == "--max-cycles") { o.max_cycles = number(value()); if (!o.max_cycles) throw std::runtime_error("--max-cycles must be positive"); }
        else if (arg == "--keys") o.keys = value();
        else if (arg == "--record") o.record = value();
        else if (arg == "--png-dir") o.png_dir = value();
        else if (arg == "--palette-hex") o.palette = value();
        else if (arg == "--trace") o.trace = value();
        else if (arg == "--vcd") o.vcd = value();
        else if (arg == "--vcd-window") {
            const auto s = value();
            const auto colon = s.find(':');
            if (colon == std::string::npos) throw std::runtime_error("--vcd-window needs START:END");
            o.vcd_start = number(s.substr(0, colon));
            o.vcd_end = number(s.substr(colon + 1));
            if (o.vcd_start > o.vcd_end) throw std::runtime_error("--vcd-window START exceeds END");
        } else if (arg == "--expect-err") {
            auto s = value();
            const auto at = s.find('@');
            if (at != std::string::npos) {
                const auto pc = number(s.substr(at + 1));
                if (pc > UINT32_MAX) throw std::runtime_error("ERR PC exceeds 32 bits");
                o.expected_pc = static_cast<uint32_t>(pc);
                o.check_pc = true;
                s.resize(at);
            }
            if (s == "DIVERGE") o.expected_err = 1;
            else if (s == "DIVSTACK") o.expected_err = 2;
            else if (s == "ILLEGAL") o.expected_err = 4;
            else throw std::runtime_error("--expect-err needs DIVERGE, DIVSTACK or ILLEGAL");
        } else if (arg == "--help") {
            std::cout << "kcvl [--headless] [--frames N] [--max-cycles N] [--keys FILE] [--record FILE]\n"
                         "     [--png-dir DIR] [--palette-hex FILE] [--expect-pass] [--expect-err NAME[@PC]]\n"
                         "     [--trace FILE] [--vcd FILE --vcd-window START:END]\n";
            std::exit(0);
        } else throw std::runtime_error("unknown option: " + arg);
    }
#if !KC_HAS_ERR
    if (o.expected_err) throw std::runtime_error("--expect-err needs ERR probes (see tb/harness/probes.h)");
#endif
#if !KC_HAS_RETIRE
    if (!o.trace.empty()) throw std::runtime_error("--trace needs retire probes (see tb/harness/probes.h)");
#endif
    return o;
}
}

int main(int argc, char** argv) {
    try {
        const Options o = parse(argc, argv);
        VerilatedContext context;
        context.commandArgs(argc, argv);
        context.traceEverOn(!o.vcd.empty());
        Vkc dut{&context};
        VerilatedVcdC waveform;
        if (!o.vcd.empty()) {
            dut.trace(&waveform, 99);
            waveform.open(o.vcd.c_str());
            if (!waveform.isOpen()) throw std::runtime_error("cannot open VCD: " + o.vcd);
        }
        std::ofstream trace;
        if (!o.trace.empty()) {
            trace.open(o.trace);
            if (!trace) throw std::runtime_error("cannot open trace: " + o.trace);
        }
        Display display{o.headless, o.png_dir, o.palette};
        IO io{o.keys, o.record, !o.headless};
        KC_UART_RX(dut) = 1;
        KC_RESET(dut) = KC_RESET_ACTIVE;
        for (unsigned i = 0; i < 20; ++i) {
            KC_CLK(dut) = 0; dut.eval(); context.timeInc(1);
            KC_CLK(dut) = 1; dut.eval(); context.timeInc(1);
        }
        KC_RESET(dut) = !KC_RESET_ACTIVE;
        io.boundary(0);
        unsigned previous_leds = KC_LEDS(dut);
#if KC_HAS_RETIRE
        bool previous_halt = false;
        uint32_t previous_pc = 0;
#endif
        int result = 0;
        for (uint64_t cycle = 0; ; ++cycle) {
            if (o.max_cycles && cycle >= o.max_cycles) {
                std::cerr << "timeout after " << cycle << " cycles\n";
                result = 2; break;
            }
            if ((cycle & 65535) == 0) io.poll(display.frames());
            if (io.quit()) break;
            KC_UART_RX(dut) = io.rx();
            KC_CLK(dut) = 0;
            dut.eval();
            const bool dump = !o.vcd.empty() && cycle >= o.vcd_start && cycle <= o.vcd_end;
            if (dump) waveform.dump(context.time());
            context.timeInc(1);
            const DisplaySignals signals{
                bool(KC_FB_WE(dut)), uint32_t(KC_FB_ADDR(dut)), uint8_t(KC_FB_WDATA(dut)),
                bool(KC_PAL_WE(dut)), uint8_t(KC_PAL_ADDR(dut)), uint16_t(KC_PAL_WDATA(dut)),
                bool(KC_SWAP_REQ(dut)), bool(KC_SWAP_PENDING(dut)), bool(KC_FB_MODE(dut))};
            const bool frame = display.sample(signals, cycle);
            if (frame) { io.poll(display.frames()); io.boundary(display.frames()); }
            io.tick(KC_UART_TX(dut), cycle);
            const unsigned leds = KC_LEDS(dut);
            if (leds != previous_leds) {
                std::cout << "leds 0x" << std::hex << leds << std::dec << '\n';
                previous_leds = leds;
            }
#if KC_HAS_ERR
            const unsigned err = KC_ERR(dut);
            if (err) {
                const uint32_t pc = KC_ERR_PC(dut);
                if (o.expected_err) result = (err == o.expected_err && (!o.check_pc || pc == o.expected_pc)) ? 0 : 1;
                else result = 3;
                std::cerr << "ERR 0x" << std::hex << err << " (";
                bool separator = false;
                for (unsigned bit = 0; bit < 3; ++bit) if (err & (1u << bit)) {
                    if (separator) std::cerr << '|';
                    std::cerr << std::array<const char*, 3>{"DIVERGE", "DIVSTACK", "ILLEGAL"}[bit];
                    separator = true;
                }
                std::cerr << ") at PC 0x" << std::setw(8) << std::setfill('0') << pc << std::dec << '\n';
                break;
            }
#endif
#if KC_HAS_RETIRE
            if (KC_RETIRE_VALID(dut)) {
                const uint32_t pc = KC_RETIRE_PC(dut), instr = KC_RETIRE_INSTR(dut);
                if (trace.is_open()) {
                    trace << std::hex << std::setfill('0') << std::setw(8) << pc << ' '
                          << std::setw(8) << instr << ' ' << std::setw(2) << unsigned(KC_MASK(dut));
                    for (unsigned lane = 0; lane < KC_LANES; ++lane) {
                        const unsigned rd = KC_RD_ADDR(dut, lane);
                        if (KC_RD_WE(dut, lane) && rd)
                            trace << ' ' << std::dec << lane << ":x" << rd << '=' << std::hex
                                  << std::setw(8) << uint32_t(KC_RD_WDATA(dut, lane));
                    }
                    trace << '\n';
                }
                if (previous_halt && pc == previous_pc && instr == 0x0000006f) {
                    std::cout << "halt: jump-to-self at PC 0x" << std::hex << std::setw(8)
                              << std::setfill('0') << pc << std::dec << '\n';
                    result = 4; break;
                }
                previous_halt = instr == 0x0000006f;
                previous_pc = pc;
            }
#endif
            KC_CLK(dut) = 1;
            dut.eval();
            if (dump) waveform.dump(context.time());
            context.timeInc(1);
            if (o.expect_pass && io.verdict() != -1) { result = io.verdict(); break; }
            if (io.quit()) break;
            if (frame && o.frames && display.frames() >= o.frames) break;
            if (context.gotFinish()) break;
        }
        dut.final();
        if (waveform.isOpen()) waveform.close();
        if (trace.is_open()) { trace.flush(); if (!trace) throw std::runtime_error("trace write failed"); }
        return result;
    } catch (const std::exception& e) {
        std::cerr << "kcvl: " << e.what() << '\n';
        return 5;
    }
}
