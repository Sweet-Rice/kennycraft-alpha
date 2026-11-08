// t_cpi_pipe: tb/core/sw/t_cpi.S (CYCLES around N copies of each instruction
// class) on the pipelined core, checked against the stall model of P8 instead
// of the multi-cycle state machine that tb/core/t_cpi_tb.sv checks.
//
// Per class (bus = bus cycles of one access, as in the multi-cycle core:
// 1 for dmem, MMIO and byte accesses, 4 for words through the byte bridge):
//   ALU, LUI, AUIPC, not-taken branch, FENCE, MASKGET    CPI_ALU
//   MUL, MULHU (independent: no mul-use stall)          CPI_MUL
//   taken branch, JAL, JALR (flush 3: registered redirect) CPI_TAKEN
//   MASKALL (mask writers flush like taken branches)    CPI_MASK
//   load                                                LD_BASE + bus
//   store                                               ST_BASE + bus
//   store to dmem or the framebuffer                    ST_BASE + bus - ST_FAST
// (core_pipe ends a store's MEM in the cycle the bus accepts its last group
// when that group goes to an always-ready port: dmem or the framebuffer.)
// Slots 8 and 10 run each copy once, so the BTB has no entry for it and the
// taken branch or JAL flushes (CPI_TAKEN). Slots 25 and 26 time loops (LI,
// N passes of ADDI (+ JAL) + BNEZ, the back edge taken N - 1 times): the
// first pass's BNEZ and JAL are BTB misses (CPI_TAKEN), every later one is
// predicted taken to the right target (CPI_PRED), and the last BNEZ is
// predicted taken but falls through (CPI_TAKEN: flush 3).
// The defaults are the pipelined core's; the multi-cycle core passes with
// -GCPI_ALU=3 -GCPI_MUL=4 -GCPI_TAKEN=3 -GCPI_PRED=3 -GCPI_MASK=3
// -GLD_BASE=3 -GST_BASE=2 -GST_FAST=0.
module t_cpi_pipe_tb;
    parameter string IMEM_HEX = "";
    parameter string DMEM_HEX = "";
    parameter int    CPI_ALU   = 1;
    parameter int    CPI_MUL   = 1;
    parameter int    CPI_TAKEN = 4;
    parameter int    CPI_PRED  = 1;   // predicted taken branch or JAL (BTB hit)
    parameter int    CPI_MASK  = 4;
    parameter int    LD_BASE   = 1;   // load: M cycles beyond the bus cycles
    parameter int    ST_BASE   = 1;   // store: same
    parameter int    ST_FAST   = 1;   // store to dmem / fb: cycles fewer
    `include "soc_harness.svh"

    localparam int          N       = 32;
    localparam int          NSLOTS  = 27;
    localparam logic [31:0] RESULTS = 32'h1000_0100;

    function automatic string slot_name(input int k);
        case (k)
            1: return "ALU (add)";            2: return "ALU imm (addi)";
            3: return "LUI";                  4: return "AUIPC";
            5: return "MUL";                  6: return "MULHU";
            7: return "branch not taken";     8: return "branch taken";
            9: return "JALR";                 10: return "JAL";
            11: return "load LW dmem";        12: return "load LBU dmem";
            13: return "store SW dmem";       14: return "store SB dmem";
            15: return "load LW MMIO";        16: return "load LBU world";
            17: return "load LW world";       18: return "store SB world";
            19: return "store SW world";      20: return "load LW textures";
            21: return "store SB framebuffer"; 22: return "FENCE";
            23: return "lane ctl (MASKGET)"; 24: return "lane ctl (MASKALL)";
            25: return "loop pass, BNEZ";    26: return "loop pass, JAL+BNEZ";
            default: return "?";
        endcase
    endfunction

    function automatic int expected_cpi(input int k);
        case (k)
            5, 6:           return CPI_MUL;
            8, 9, 10:       return CPI_TAKEN;
            24:             return CPI_MASK;
            11, 12, 15, 16: return LD_BASE + 1;
            17, 20:         return LD_BASE + 4;   // four byte reads
            13, 14, 21:     return ST_BASE + 1 - ST_FAST;
            18:             return ST_BASE + 1;
            19:             return ST_BASE + 4;   // four byte writes
            default:        return CPI_ALU;
        endcase
    endfunction

    // Cycles of slot k
    function automatic int expected_delta(input int k);
        case (k)
            // LI and N ADDI; BNEZ: first taken, N - 2 predicted, last falls through
            25:      return (N + 1) * CPI_ALU + 2 * CPI_TAKEN + (N - 2) * CPI_PRED;
            // the same plus N JAL: first a miss, N - 1 predicted
            26:      return expected_delta(25) + CPI_TAKEN + (N - 1) * CPI_PRED;
            default: return expected_cpi(k) * N;
        endcase
    endfunction

    initial begin
        int base, delta, auipc_cycles, errors;
        real cpi;
        errors = 0;
        do_reset();
        run_until_done(100000);
        if (err_led) $fatal(1, "FAIL: core halted, ERR_PC=%08h", dut.u_mmio.err_pc);

        base = int'(dmem_rd(RESULTS));
        auipc_cycles = int'(dmem_rd(RESULTS + 4 * 4)) - base;
        $display("  PIPELINED = %0d, CYCLES overhead (empty slot) = %0d, N = %0d",
                 PIPELINED, base, N);
        $display("  %-22s %-6s %s", "class", "CPI", "expected cycles");
        for (int k = 1; k < NSLOTS; k++) begin
            delta = int'(dmem_rd(RESULTS + 4 * k)) - base;
            if (k == 9) delta -= auipc_cycles;   // AUIPC + JALR pairs
            cpi = real'(delta) / N;
            $display("  %-22s %-6.2f %0d", slot_name(k), cpi, expected_delta(k));
            if (delta != expected_delta(k)) begin
                $display("  FAIL %s: expected %0d cycles", slot_name(k), expected_delta(k));
                errors++;
            end
        end
        if (errors != 0) $fatal(1, "FAIL: t_cpi_pipe, %0d classes off", errors);
        $display("PASS: t_cpi_pipe");
        $finish;
    end
endmodule
