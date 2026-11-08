// t_pipe_stress: runs tb/core_pipe/sw/t_pipe_stress.S (back-to-back hazards,
// P8) on the Stage 2 core (LANES = 8, divergence stack, ray unit, QRCP) and
// checks, in every lane: the program's own fast-against-slow check (s11 = 0)
// and the results that do not need a model of the ray unit or QRCP (load-use,
// BALLOT, LMASK + MASKGET under the odd-lane mask, DIF/DELSE, the presets
// that the lanes outside the 0x5A mask keep across QRCP, MUL into an ALU
// op, through a store and load address, MUL under the partial mask 0x5A,
// whose inactive lanes keep their old rd, the predicted loops, the stores
// that leave MEM at their accept, the window bank-conflict and mixed stores
// of slots 59 to 61, VGET of the cell right after VSET (slot 62), the
// instructions killed in EX by the registered redirect, slots 64 to 67, and
// the LSU's registered bus request and read data, slots 68 to 72: load-use
// at distance 1 and 2 after a store of the same word, a world store then
// load, MMIO stores and loads in lane order). At each FB_SWAP request every
// lane's framebuffer word must hold the store before it, not the one after.
// Built for both cores; tracediff-core-pipe-t_pipe_stress compares their
// retire traces, the only pipelined trace coverage of VSET/VTRACE/VGET with
// forwarding.
module t_pipe_stress_tb;
    parameter string IMEM_HEX = "";
    parameter string DMEM_HEX = "";
    `include "soc_harness.svh"

    localparam logic [31:0] SCRATCH = 32'h1000_1000;
    // Slot 60: the highest lane that stores to each lane's word
    localparam int MIX_LAST [8] = '{4, 5, 7, 3, 4, 5, 6, 7};

    int errors = 0;

    task automatic expect32(input string what, input logic [31:0] got, input logic [31:0] exp);
        if (got !== exp) begin
            $display("  FAIL %-28s got %08h expected %08h", what, got, exp);
            errors++;
        end
    endtask

    // Slots 0 to 63 from 0x1000_1000, 64 and up from 0x1000_3000 (the
    // program's s2 and gp bases), 4 bytes per lane, 32 per slot.
    function automatic logic [31:0] res(input int l, input int k);
        return (k < 64) ? dmem_rd(SCRATCH + 32'(4 * l) + 32'(32 * k))
                        : dmem_rd(32'h1000_3000 + 32'(4 * l) + 32'(32 * (k - 64)));
    endfunction

    // The program's framebuffer store, FB_SWAP store, framebuffer store:
    // lane l's word at 0x180 + 4 l holds 0x11 + l when the swap is requested.
    localparam int FB_SWAP_WORD = 32'h180;

    always @(posedge clk) begin
        if (!rst && swap_req)
            for (int l = 0; l < ALANES; l++)
                expect32($sformatf("lane %0d fb word at swap_req", l),
                         {fb_mem[FB_SWAP_WORD + 4 * l + 3], fb_mem[FB_SWAP_WORD + 4 * l + 2],
                          fb_mem[FB_SWAP_WORD + 4 * l + 1], fb_mem[FB_SWAP_WORD + 4 * l]},
                         32'(l + 32'h11));
    end

    initial begin
        logic [7:0]  full, odd, qm, p5a;
        logic [31:0] a0, a1, a2, prod, base, hv;
        full = 8'((1 << ALANES) - 1);
        odd  = 8'hAA & full;
        qm   = 8'h5A & full;
        p5a  = 8'h5A & full;

        do_reset();
        run_until_done(40000);
        repeat (10) @(posedge clk);

        expect32("error LED", {31'b0, err_led}, 32'd0);
        for (int l = 0; l < ALANES; l++) begin
            expect32($sformatf("lane %0d fast == slow (s11)", l), lane_x[l][27], 32'd0);
            expect32($sformatf("lane %0d load-use +1", l), res(l, 0), 32'(l + 8));
            expect32($sformatf("lane %0d load + load", l), res(l, 1), 32'(2 * (l + 7)));
            expect32($sformatf("lane %0d BALLOT", l), res(l, 11), 32'(odd));
            expect32($sformatf("lane %0d MASKGET + 1 (odd lanes)", l), res(l, 12),
                     odd[l] ? 32'(odd) + 32'd1 : 32'h5A);
            expect32($sformatf("lane %0d DIF/DELSE", l), res(l, 13), ((l + 7) & 2) != 0 ? 32'd5 : 32'd9);
            if (!qm[l]) begin
                expect32($sformatf("lane %0d QRCP outside 0x5A", l), res(l, 21), 32'h5A5A_0000 | 32'(l));
                expect32($sformatf("lane %0d QRCP use outside 0x5A", l), res(l, 22), 32'h5A5A_0000 | 32'(l));
            end
            a0   = 32'h9234_567B ^ 32'(4 * l);
            a1   = 32'h6543_210F + 32'(l);
            a2   = 32'hFEDC_BA98 - 32'(4 * l);
            prod = a0 * a1;
            expect32($sformatf("lane %0d MUL -> add", l), res(l, 23), prod + a2);
            expect32($sformatf("lane %0d MUL -> sw/lw address", l), res(l, 28), a1);
            expect32($sformatf("lane %0d MUL -> lw address", l), res(l, 29), a1);
            expect32($sformatf("lane %0d MUL, partial mask", l), res(l, 39),
                     p5a[l] ? prod : 32'(l + 'h111));
            expect32($sformatf("lane %0d MUL -> add, partial mask", l), res(l, 40),
                     p5a[l] ? prod + 32'(l) : 32'(l + 'h222));
            expect32($sformatf("lane %0d loop, 6 passes", l), res(l, 41), 32'(6 * (l + 3)));
            expect32($sformatf("lane %0d branch after MASKSET", l), res(l, 43), 32'd20);
            expect32($sformatf("lane %0d loop on a loaded count", l), res(l, 44), 32'(4 * (l + 7)));
            expect32($sformatf("lane %0d dmem SW then LW", l), res(l, 45), 32'(l + 32'h31));
            expect32($sformatf("lane %0d dmem SW one word", l), res(l, 46), 32'(ALANES - 1 + 32'h41));
            expect32($sformatf("lane %0d dmem SB then LBU", l), res(l, 47), 32'(l + 32'h51));
            expect32($sformatf("lane %0d fb SW then LW", l), res(l, 48), 32'(l + 32'h61));
            expect32($sformatf("lane %0d fb SB then LBU", l), res(l, 49), 32'(l + 32'h71));
            expect32($sformatf("lane %0d SW then SW", l), res(l, 50), 32'(l + 32'h91));
            expect32($sformatf("lane %0d dmem SW then fb SW", l), res(l, 51), 32'(l + 32'h81));
            expect32($sformatf("lane %0d fb SW after dmem SW", l), res(l, 52), 32'(l + 32'h91));
            expect32($sformatf("lane %0d SW, MASKSET, branch", l), res(l, 53),
                     (l < 4) ? 32'(l + 32'hA1) : 32'd0);
            expect32($sformatf("lane %0d SW before MASKSET", l), res(l, 54), 32'(l + 32'hA1));
            expect32($sformatf("lane %0d SW, jump", l), res(l, 55), 32'(l + 32'hA1));
            expect32($sformatf("lane %0d fb SW after FB_SWAP", l), res(l, 56), 32'(l + 32'h21));
            expect32($sformatf("lane %0d window/bus SW", l), res(l, 57), 32'(l + 32'hB1));
            expect32($sformatf("lane %0d window/bus SB", l), res(l, 58), 32'(l + 32'hC1));
            expect32($sformatf("lane %0d window conflict SW, LW", l), res(l, 59),
                     32'(((l & 1) != 0 ? l : ((ALANES - 1) & ~1)) + 32'hD2));
            expect32($sformatf("lane %0d window/bus conflict SW", l), res(l, 60),
                     32'(MIX_LAST[l] + 32'hE1));
            expect32($sformatf("lane %0d MMIO lane + dmem SW", l), res(l, 61),
                     (l == 0) ? 32'd0 : 32'(l + 32'hF1));
            base = 32'(l) * 32'h841 + 32'd1;
            expect32($sformatf("lane %0d VSET 0 then VGET 0", l), res(l, 62),
                     p5a[l] ? 3 * base + 32'h222 : 2 * base);
            expect32($sformatf("lane %0d SW killed in EX", l), res(l, 64), 32'(l + 32'hD1));
            // MASKGET writes every lane (uniform), so all lanes see 0x0F
            expect32($sformatf("lane %0d MASKALL killed in EX", l), res(l, 65), 32'h0F);
            expect32($sformatf("lane %0d DIF killed in EX, run once", l), res(l, 66), 32'(full));
            expect32($sformatf("lane %0d loop head SW killed in EX", l), res(l, 67), 32'd1);
            expect32($sformatf("lane %0d dmem SW, LW, use at 1 and 2", l), res(l, 68),
                     32'(3 * l + 32'h1C6));
            hv = 32'hFFFF_EDCB + 32'(l);   // LH of the stored halfword
            expect32($sformatf("lane %0d fb SH, LH, use at 1 and 2", l), res(l, 69),
                     (32'd0 - hv) + (hv ^ 32'(l + 5)));
            expect32($sformatf("lane %0d world SB, LBU, use", l), res(l, 70), 32'(l + 32'h13));
            expect32($sformatf("lane %0d MMIO SW, LW in lane order", l), res(l, 71),
                     32'(32'hF1 + ALANES - 1));
            expect32($sformatf("lane %0d MMIO LW, SW, LW", l), res(l, 72),
                     32'(32'hF1 + 2 * (ALANES - 1) + l));
        end
        expect32("FB_SWAP requests (fast, slow)", 32'(swap_req_count), 32'd2);
        expect32("mask at the end", 32'(`KC_CORE.mask), 32'd1);
        // lane 1 is active under the partial mask 0x5A
        $display("  lane 1: VTRACE/VGET mix %08h, partial-mask VTRACE + VGET %08h, QRCP chain %08h",
                 res(1, 8), res(1, 10), res(1, 7));

        if (errors != 0) $fatal(1, "FAIL: t_pipe_stress, %0d mismatches", errors);
        $display("PASS: t_pipe_stress (LANES = %0d, PIPELINED = %0d)", LANES, PIPELINED);
        $finish;
    end
endmodule
