// t_lsu_stall: runs sw/t_lsu_stall.S and checks lane-serial loads and stores
// against slaves that hold bus_ready low: the world and texture stubs behind
// the byte bridge (4 byte cycles per word), dmem and world alternating on
// consecutive lanes, and CHUNK_CMD stalled for DDR_STALL cycles per write.
// Every lane's data must be right, dmem must hold the even lanes' words, and
// the CHUNK_CMD writes must arrive once per lane in ascending lane order.
module t_lsu_stall_tb;
    parameter string IMEM_HEX = "";
    parameter string DMEM_HEX = "";
    `include "soc_harness.svh"
    `include "lane_check.svh"

    localparam int DDR_STALL = 6;

    logic [31:0] chunk_log [$];
    int          bus_wait = 0;     // cycles with bus_req held and bus_ready low

    always @(posedge clk) begin
        if (!rst && ddr_reg_en && ddr_reg_we && ddr_reg_off == 6'h30 && !ddr_reg_stall)
            chunk_log.push_back(ddr_reg_wdata);
        if (!rst && `KC_CORE.bus_req && !`KC_CORE.bus_ready) bus_wait <= bus_wait + 1;
    end

    initial begin
        ddr_cmd_stall = DDR_STALL;
        do_reset();
        run_until_done(20000);
        repeat (10) @(posedge clk);
        expect_no_halt("t_lsu_stall");

        for (int l = 0; l < ALANES; l++) begin
            logic [31:0] v, w;
            v = 32'h0A0B_0C0D + 32'(l);
            w = 32'h1122_3344 + 32'(l);
            expect_reg(l, A0, v & 32'h0F0F_0F0F, "world LW after SW");
            expect_reg(l, A1, (l % 2 != 0) ? (w & 32'h0F0F_0F0F) : w, "dmem/world LW");
            expect_reg(l, A2, (l % 2 != 0) ? 32'h03 : 32'h33, "dmem/world LB");
            expect_reg(l, A3, 32'(l), "texture LBU after SB");
            expect_reg(l, A4, 32'(l) << 16, "texture LW");
            if (l % 2 == 0) expect32($sformatf("dmem word of lane %0d", l),
                                     dmem_rd(32'h1000_3000 + 32'(4 * l)), w);
        end
        expect32("CHUNK_CMD writes", 32'(chunk_log.size()), 32'(ALANES));
        for (int i = 0; i < chunk_log.size() && i < ALANES; i++)
            expect32($sformatf("CHUNK_CMD write %0d", i), chunk_log[i], 32'h100 + 32'(i));
        if (ddr_stalled_cycles < DDR_STALL * ALANES) begin
            $display("  FAIL CHUNK_CMD stalled only %0d cycles", ddr_stalled_cycles);
            errors++;
        end
        $display("  %0d CHUNK_CMD writes, %0d stall cycles, %0d bus wait cycles in total",
                 chunk_log.size(), ddr_stalled_cycles, bus_wait);
        finish_test("t_lsu_stall");
    end
endmodule
