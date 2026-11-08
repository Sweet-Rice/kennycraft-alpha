// Clock and reset driver for tb/top/t_top_frame.sv, built without --timing.
// Time runs in picoseconds (--timescale 1ns/1ps); the edges are the ones the
// SV delays of tb/ddr/unisim_sim.sv and the old `always #5 clk` made:
//   clk              100 MHz, toggles every 5 ns from 5 ns (rises at 5 ns)
//   ck_rst           low until the 20th rising edge of clk, high with it
//   ddr_ui_clk       83.33 MHz MIG ui_clk, toggles every 6 ns from 6 ns
//   ddr_mmcm_locked  ddr_clk's MMCM LOCKED, high from 500 ns
// Edges due at the same time are applied together before one eval, as the
// timing scheduler resumes every delay that ends in a time slot at once.
#include "Vt_top_frame.h"
#include "verilated.h"

#include <algorithm>
#include <cstdint>
#include <memory>

int main(int argc, char** argv) {
    constexpr uint64_t CLK_HALF = 5000, UI_HALF = 6000, LOCKED_AT = 500000;
    constexpr unsigned RESET_EDGES = 20;

    const std::unique_ptr<VerilatedContext> context{new VerilatedContext};
    context->commandArgs(argc, argv);
    const std::unique_ptr<Vt_top_frame> top{new Vt_top_frame{context.get()}};

    top->clk = 0;
    top->ck_rst = 0;
    top->ddr_ui_clk = 0;
    top->ddr_mmcm_locked = 0;
    top->eval();

    uint64_t next_clk = CLK_HALF, next_ui = UI_HALF;
    unsigned rising = 0;
    while (!context->gotFinish()) {
        uint64_t now = std::min(next_clk, next_ui);
        if (!top->ddr_mmcm_locked) now = std::min(now, LOCKED_AT);
        context->time(now);
        if (now == next_clk) {
            top->clk = !top->clk;
            if (top->clk && ++rising == RESET_EDGES) top->ck_rst = 1;
            next_clk += CLK_HALF;
        }
        if (now == next_ui) {
            top->ddr_ui_clk = !top->ddr_ui_clk;
            next_ui += UI_HALF;
        }
        if (now == LOCKED_AT) top->ddr_mmcm_locked = 1;
        top->eval();
    }
    top->final();
    return 0;
}
