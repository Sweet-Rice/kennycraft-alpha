// t_lsu_order: runs sw/t_lsu_order.S (Stage 1 rung 4) and checks memory and
// every lane's registers against Tai_2 section 2 for the lanes that can be
// active (ALANES). A bus monitor checks every load/store against a model of
// the coalescing LSU: the lowest pending lane goes first, with every other
// pending lane in the same physical word when that word is in dmem or the
// framebuffer and no pending lane targets MMIO; otherwise one access per
// lane, in lane order. It checks the access count, order, address and byte
// enables, and the LSU cycles (MEM cycles, plus WB for loads, where the last
// access's data lands): one per access, plus one for loads; on core_pipe
// (PIPELINED), whose LSU registers the bus request and the read data, one
// more, and for loads two more. The TB_SELECT
// poll's loads are checked but not listed, so the list indices stay fixed.
// It also counts UART_RX pops.
module t_lsu_order_tb;
    parameter string IMEM_HEX = "";
    parameter string DMEM_HEX = "";
    `include "soc_harness.svh"

    localparam logic [31:0] A        = 32'h1000_1000;
    localparam logic [31:0] FAULT_PC = 32'h1000_00E0;

    int errors = 0;

    task automatic expect32(input string what, input logic [31:0] got, input logic [31:0] exp);
        if (got !== exp) begin
            $display("  FAIL %-30s got %08h expected %08h", what, got, exp);
            errors++;
        end
    endtask

    // ------------------------------------------------------------------
    // Bus monitor
    // ------------------------------------------------------------------
    int          acc_lane [$];
    logic [31:0] acc_addr [$];
    logic [3:0]  acc_be [$];
    int          mem_cycles = 0;
    int          checked = 0;
    // Per monitored load/store, in program order: active lanes, accesses,
    // LSU cycles.
    int          mon_n [$], mon_acc [$], mon_cyc [$];
    int          pops = 0;

    always @(posedge clk) if (!rst && dut.rx_pop) pops++;

    // Physical word of a coalescable address: dmem aliases every 32 KB
    // (word addr[14:2]), the framebuffer decodes addr[16:2].
    function automatic logic [18:0] phys_word(input logic [31:0] a);
        return {a[31:28], (a[31:28] == 4'h1) ? {2'b0, a[14:2]} : a[16:2]};
    endfunction

    function automatic logic [3:0] lane_be(input logic [2:0] f3, input logic [1:0] lo);
        case (f3[1:0])
            2'b00:   return 4'b0001 << lo;
            2'b01:   return lo[1] ? 4'b1100 : 4'b0011;
            default: return 4'b1111;
        endcase
    endfunction

    always @(posedge clk) begin
        if (!rst) begin
            if (`KC_CORE.state == 3'd4) mem_cycles <= mem_cycles + 1;
            if (`KC_CORE.bus_req && `KC_CORE.bus_ready) begin
                acc_lane.push_back(int'(`KC_CORE.u_lsu.cur));
                acc_addr.push_back(`KC_CORE.bus_addr);
                acc_be.push_back(`KC_CORE.bus_be);
            end
            if (`KC_CORE.retire_valid || `KC_CORE.err_set != 0) begin
                logic [6:0]       opc;
                logic [2:0]       f3;
                logic [LANES-1:0] pend, grp;
                logic [3:0]       be;
                logic             merge;
                int               n, k, c, cyc;
                logic             is_ld;
                opc   = `KC_CORE.retire_inst[6:0];
                f3    = `KC_CORE.retire_inst[14:12];
                is_ld = (opc == 7'h03);
                if (`KC_CORE.err_set != 0) begin
                    if (acc_lane.size() != 0) begin
                        $display("  FAIL halting instruction reached the bus");
                        errors++;
                    end
                end else if (is_ld || opc == 7'h23) begin
                    n    = $countones(`KC_CORE.retire_mask);
                    pend = `KC_CORE.retire_mask;
                    k    = 0;
                    while (pend != '0) begin
                        c = 0;
                        while (!pend[c]) c++;
                        merge = 1'b1;
                        for (int l = 0; l < LANES; l++)
                            if (pend[l] && `KC_CORE.l_res[l][31:28] == 4'h5) merge = 1'b0;
                        grp = LANES'(1) << c;
                        if (merge && (`KC_CORE.l_res[c][31:28] == 4'h1 || `KC_CORE.l_res[c][31:28] == 4'h4))
                            for (int l = 0; l < LANES; l++)
                                if (pend[l] && phys_word(`KC_CORE.l_res[l]) == phys_word(`KC_CORE.l_res[c]))
                                    grp[l] = 1'b1;
                        be = '0;
                        for (int l = 0; l < LANES; l++)
                            if (grp[l]) be |= lane_be(f3, `KC_CORE.l_res[l][1:0]);
                        if (k >= acc_lane.size() || acc_lane[k] != c) begin
                            $display("  FAIL pc %08h access %0d is not lane %0d", `KC_CORE.retire_pc, k, c);
                            errors++;
                        end else if (acc_addr[k] != `KC_CORE.l_res[c]) begin
                            $display("  FAIL pc %08h lane %0d address %08h, lane computed %08h",
                                     `KC_CORE.retire_pc, c, acc_addr[k], `KC_CORE.l_res[c]);
                            errors++;
                        end else if (acc_be[k] != be) begin
                            $display("  FAIL pc %08h access %0d (lanes %b) byte enables %b, expected %b",
                                     `KC_CORE.retire_pc, k, grp, acc_be[k], be);
                            errors++;
                        end
                        pend &= ~grp;
                        k++;
                    end
                    if (acc_lane.size() != k) begin
                        $display("  FAIL pc %08h made %0d bus accesses for %0d active lanes, expected %0d",
                                 `KC_CORE.retire_pc, acc_lane.size(), n, k);
                        errors++;
                    end
                    // Stores retire in their last MEM cycle (not yet counted
                    // here), loads in WB: either way one more cycle.
                    // core_pipe (PIPELINED) registers the bus request
                    // (rtl/core_pipe/lsu_pipe.sv): one more MEM cycle, to
                    // load the first group, before its first access; and
                    // the read data: one more for loads.
                    cyc = mem_cycles + 1;
                    if (n != 0 && cyc != k + int'(is_ld) + int'(PIPELINED) * (1 + int'(is_ld))) begin
                        $display("  FAIL pc %08h took %0d LSU cycles for %0d accesses", `KC_CORE.retire_pc, cyc, k);
                        errors++;
                    end
                    if (!(is_ld && `KC_CORE.l_res[0] == 32'h1000_00F0)) begin
                        mon_n.push_back(n);
                        mon_acc.push_back(acc_lane.size());
                        mon_cyc.push_back(cyc);
                    end
                    checked++;
                end
                acc_lane.delete();
                acc_addr.delete();
                acc_be.delete();
                mem_cycles <= 0;
            end
        end
    end

    task automatic expect_acc(input int idx, input int exp, input string what);
        if (idx >= mon_acc.size()) begin
            $display("  FAIL #%0d %s: not monitored", idx, what);
            errors++;
        end else begin
            expect32($sformatf("#%0d %s: accesses", idx, what), mon_acc[idx], exp);
        end
    endtask

    // ------------------------------------------------------------------
    // Expected values
    // ------------------------------------------------------------------
    function automatic logic [31:0] prefill(input int k);
        case (k)
            32: return 32'h8382_8180;
            33: return 32'h8786_8584;
            48, 49, 56, 57, 58, 59: return 32'h0;
            120: return 32'h807F_01FF;
            121: return 32'h00FE_7E81;
            default: return 32'hA000 + k;
        endcase
    endfunction

    initial begin
        logic [7:0]  full, m;
        logic [31:0] w, h;
        logic [7:0]  b8;
        int          j;
        full = 8'((1 << ALANES) - 1);
        m    = 8'hA5 & full;

        for (int k = 0; k < 128; k++) dmem_wr(A + 4 * k, prefill(k));
        dmem_wr(32'h1000_00F0, 32'd0);
        do_reset();
        for (int i = 0; i < 8; i++) uart_send(8'h61 + 8'(i));
        repeat (10) @(posedge clk);
        dmem_wr(32'h1000_00F0, 32'd1);
        run_until_done(20000);
        repeat (50) @(posedge clk);

        for (int k = 0; k < 8; k++)
            expect32($sformatf("SW lane %0d", k), dmem_rd(A + 4 * k),
                     (k < ALANES) ? 32'h100 + k : prefill(k));
        expect32("SW same address", dmem_rd(A + 32'h40), 32'h200 + ALANES - 1);
        expect32("lane 0 LW of the winner", lane_x[0][16], 32'h200 + ALANES - 1);

        for (int i = 0; i < ALANES; i++) begin
            j = i ^ 1;
            expect32($sformatf("lane %0d LW lane^1", i), lane_x[i][10],
                     (j < ALANES) ? 32'h100 + j : prefill(j));
            expect32($sformatf("lane %0d LB", i),  lane_x[i][11], 32'hFFFF_FF80 + i);
            expect32($sformatf("lane %0d LBU", i), lane_x[i][12], 32'h80 + i);
            j = i & 3;
            h = {16'h0, 8'(32'h81 + 2 * j), 8'(32'h80 + 2 * j)};
            expect32($sformatf("lane %0d LH", i),  lane_x[i][13], {16'hFFFF, h[15:0]});
            expect32($sformatf("lane %0d LHU", i), lane_x[i][14], h);
            expect32($sformatf("lane %0d LW under 0xA5", i), lane_x[i][15],
                     m[i] ? 32'h100 + i : 32'h5555);
        end
        for (int k = 0; k < 2; k++) begin
            w = 0;
            for (int b = 0; b < 4; b++)
                if (4 * k + b < ALANES) w[8 * b +: 8] = 8'(32'h30 + 4 * k + b);
            expect32($sformatf("SB word %0d", k), dmem_rd(A + 32'hC0 + 4 * k), w);
        end
        for (int k = 0; k < 4; k++) begin
            w = 0;
            for (int b = 0; b < 2; b++)
                if (2 * k + b < ALANES) w[16 * b +: 16] = 16'(32'h4000 + 2 * k + b);
            expect32($sformatf("SH word %0d", k), dmem_rd(A + 32'hE0 + 4 * k), w);
        end
        for (int k = 0; k < 8; k++)
            expect32($sformatf("SW under 0xA5 lane %0d", k), dmem_rd(A + 32'h100 + 4 * k),
                     m[k] ? 32'h300 + k : prefill(64 + k));

        // Coalescing cases
        for (int i = 0; i < ALANES; i++) begin
            expect32($sformatf("lane %0d uniform LW", i), lane_x[i][19], 32'h100);
            expect32($sformatf("lane %0d LW shared pairs", i), lane_x[i][20], prefill(104 + ((5 * i) & 3)));
            b8 = 8'(prefill(120 + i / 4) >> (8 * (i % 4)));
            expect32($sformatf("lane %0d LB mixed sign", i), lane_x[i][21], {{24{b8[7]}}, b8});
            expect32($sformatf("lane %0d LBU mixed sign", i), lane_x[i][22], {24'b0, b8});
            expect32($sformatf("lane %0d LW under mask 0", i), lane_x[i][23], 32'h7777);
            expect32($sformatf("lane %0d UART_RX", i), lane_x[i][24], 32'h61 + i);
            expect32($sformatf("lane %0d LW UART_STATUS / dmem", i), lane_x[i][25],
                     (i == 1 || i == 2) ? 32'(ALANES < 8) : 32'h200 + ALANES - 1);
            expect32($sformatf("fb byte %0d", i), {24'b0, fb_mem[32'h100 + i]}, 32'h90 + i);
            expect32($sformatf("lane %0d fb uniform LW", i), lane_x[i][26],
                     {fb_mem[32'h103], fb_mem[32'h102], fb_mem[32'h101], fb_mem[32'h100]});
        end
        for (int k = 0; k < 4; k++) begin
            j = (k + 4 < ALANES) ? k + 4 : k;
            expect32($sformatf("SW shared pairs word %0d", k), dmem_rd(A + 32'h1C0 + 4 * k),
                     (j < ALANES) ? 32'h700 + j : prefill(112 + k));
        end
        w = prefill(116);
        for (int i = 0; i < ALANES; i++) w[8 * (i / 2) +: 8] = 8'(32'h50 + i);
        expect32("SB same bytes, highest lane wins", dmem_rd(A + 32'h1D0), w);
        expect32("SW under mask 0", dmem_rd(A + 32'h1F0), prefill(124));
        expect32("UART_RX pops", pops, ALANES);
        expect32("RX bytes left", {31'b0, dut.u_uart.rx_avail}, 32'(ALANES < 8));

        // The SW misaligned in lane 3 only
        if (ALANES > 3) begin
            expect32("misaligned lane 3: error LED", {31'b0, err_led}, 32'd1);
            expect32("misaligned lane 3: ERR", {29'b0, dut.u_mmio.err}, 32'd4);
            expect32("misaligned lane 3: ERR_PC", dut.u_mmio.err_pc, dmem_rd(FAULT_PC));
            for (int k = 0; k < 8; k++)
                expect32($sformatf("misaligned: no store lane %0d", k),
                         dmem_rd(A + 32'h140 + 4 * k), prefill(80 + k));
        end else begin
            expect32("no lane 3: error LED", {31'b0, err_led}, 32'd0);
            for (int k = 0; k < 8; k++)
                expect32($sformatf("final SW lane %0d", k), dmem_rd(A + 32'h140 + 4 * k),
                         (k < ALANES) ? 32'(k) : prefill(80 + k));
        end

        if (checked < 10) begin
            $display("  FAIL bus monitor saw only %0d loads/stores", checked);
            errors++;
        end
        // Accesses per monitored load/store (the model above checks each
        // one; these pin the expected coalescing of the program's cases).
        $display("  LSU accesses and cycles (MEM + WB for loads, MEM for stores):");
        foreach (mon_n[i])
            $display("    #%0d: %0d active lane(s), %0d access(es), %0d cycle(s)", i, mon_n[i], mon_acc[i], mon_cyc[i]);
        expect_acc(0,  ALANES,                 "SW consecutive words");
        expect_acc(1,  1,                      "SW every lane one word");
        expect_acc(2,  ALANES,                 "LW lane^1 words");
        expect_acc(3,  (ALANES + 3) / 4,       "LB consecutive bytes");
        expect_acc(4,  (ALANES + 3) / 4,       "LBU consecutive bytes");
        expect_acc(5,  (ALANES < 3) ? 1 : 2,   "LH 2 * (lane & 3)");
        expect_acc(6,  (ALANES < 3) ? 1 : 2,   "LHU 2 * (lane & 3)");
        expect_acc(7,  (ALANES + 3) / 4,       "SB consecutive bytes");
        expect_acc(8,  (ALANES + 1) / 2,       "SH consecutive halfwords");
        expect_acc(9,  $countones(m),          "LW under 0xA5");
        expect_acc(10, $countones(m),          "SW under 0xA5");
        expect_acc(11, 1,                      "LW lane 0 only");
        expect_acc(12, 1,                      "LW uniform");
        expect_acc(13, (ALANES < 4) ? ALANES : 4, "LW lanes share words in pairs");
        expect_acc(14, (ALANES < 4) ? ALANES : 4, "SW lanes share words in pairs");
        expect_acc(15, 1,                      "SB lane pairs on one byte");
        expect_acc(16, (ALANES + 3) / 4,       "LB mixed sign");
        expect_acc(17, (ALANES + 3) / 4,       "LBU mixed sign");
        expect_acc(18, 0,                      "LW under mask 0");
        expect_acc(19, 0,                      "SW under mask 0");
        expect_acc(20, ALANES,                 "LW UART_RX (lane-serial)");
        expect_acc(21, (ALANES <= 3) ? ALANES : 4, "LW UART_STATUS lanes 1, 2, dmem rest");
        expect_acc(22, (ALANES + 3) / 4,       "SB fb consecutive bytes");
        expect_acc(23, 1,                      "LW fb uniform");

        if (errors != 0) $fatal(1, "FAIL: t_lsu_order, %0d mismatches", errors);
        $display("PASS: t_lsu_order (LANES = %0d, %0d can be active, %0d loads/stores monitored)",
                 LANES, ALANES, checked);
        $finish;
    end
endmodule
