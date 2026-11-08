// t_lsu_order: runs sw/t_lsu_order.S (Stage 1 rung 4) and checks memory and
// every lane's registers against Tai_2 section 2 for the lanes that can be
// active (ALANES). A bus monitor checks that every load/store makes exactly
// one access per active lane, lowest lane first, at that lane's address, and
// reports the LSU cycles (MEM cycles, plus WB for loads, where the last
// lane's data lands) per number of active lanes.
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
    int          mem_cycles = 0;
    int          ld_cycles [9];   // by active-lane count, -1 = not seen
    int          st_cycles [9];
    int          checked = 0;

    initial for (int n = 0; n <= 8; n++) begin
        ld_cycles[n] = -1;
        st_cycles[n] = -1;
    end

    always @(posedge clk) begin
        if (!rst) begin
            if (`KC_CORE.state == 3'd4) mem_cycles <= mem_cycles + 1;
            if (`KC_CORE.bus_req && `KC_CORE.bus_ready) begin
                acc_lane.push_back(int'(`KC_CORE.u_lsu.cur));
                acc_addr.push_back(`KC_CORE.bus_addr);
            end
            if (`KC_CORE.retire_valid || `KC_CORE.err_set != 0) begin
                logic [6:0] opc;
                int         n, k, cyc;
                logic       is_ld;
                opc   = `KC_CORE.retire_inst[6:0];
                is_ld = (opc == 7'h03);
                if (`KC_CORE.err_set != 0) begin
                    if (acc_lane.size() != 0) begin
                        $display("  FAIL halting instruction reached the bus");
                        errors++;
                    end
                end else if (is_ld || opc == 7'h23) begin
                    n = $countones(`KC_CORE.retire_mask);
                    k = 0;
                    for (int l = 0; l < LANES; l++) begin
                        if (`KC_CORE.retire_mask[l]) begin
                            if (k >= acc_lane.size() || acc_lane[k] != l) begin
                                $display("  FAIL pc %08h access %0d is not lane %0d", `KC_CORE.retire_pc, k, l);
                                errors++;
                            end else if (acc_addr[k] != `KC_CORE.l_res[l]) begin
                                $display("  FAIL pc %08h lane %0d address %08h, lane computed %08h",
                                         `KC_CORE.retire_pc, l, acc_addr[k], `KC_CORE.l_res[l]);
                                errors++;
                            end
                            k++;
                        end
                    end
                    if (acc_lane.size() != n) begin
                        $display("  FAIL pc %08h made %0d bus accesses for %0d active lanes",
                                 `KC_CORE.retire_pc, acc_lane.size(), n);
                        errors++;
                    end
                    // Stores retire in their last MEM cycle (not yet counted
                    // here), loads in WB: either way one more cycle.
                    cyc = mem_cycles + 1;
                    if (is_ld) ld_cycles[n] = cyc; else st_cycles[n] = cyc;
                    checked++;
                end
                acc_lane.delete();
                acc_addr.delete();
                mem_cycles <= 0;
            end
        end
    end

    // ------------------------------------------------------------------
    // Expected values
    // ------------------------------------------------------------------
    function automatic logic [31:0] prefill(input int k);
        case (k)
            32: return 32'h8382_8180;
            33: return 32'h8786_8584;
            48, 49, 56, 57, 58, 59: return 32'h0;
            default: return 32'hA000 + k;
        endcase
    endfunction

    initial begin
        logic [7:0]  full, m;
        logic [31:0] w, h;
        int          j;
        full = 8'((1 << ALANES) - 1);
        m    = 8'hA5 & full;

        for (int k = 0; k < 96; k++) dmem_wr(A + 4 * k, prefill(k));
        do_reset();
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
        $display("  LSU cycles (dmem, MEM + WB for loads, MEM for stores):");
        for (int n = 1; n <= 8; n++)
            if (ld_cycles[n] >= 0 || st_cycles[n] >= 0)
                $display("    %0d active lane(s): load %0d, store %0d", n, ld_cycles[n], st_cycles[n]);
        for (int n = 1; n <= 8; n++) begin
            if (ld_cycles[n] >= 0) expect32($sformatf("load cycles, %0d lanes", n), ld_cycles[n], n + 1);
            if (st_cycles[n] >= 0) expect32($sformatf("store cycles, %0d lanes", n), st_cycles[n], n);
        end

        if (errors != 0) $fatal(1, "FAIL: t_lsu_order, %0d mismatches", errors);
        $display("PASS: t_lsu_order (LANES = %0d, %0d can be active, %0d loads/stores monitored)",
                 LANES, ALANES, checked);
        $finish;
    end
endmodule
