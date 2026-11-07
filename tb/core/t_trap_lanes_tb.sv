// t_trap_lanes: runs every case of sw/t_trap_lanes.S from its own reset.
// Case 0: a misaligned address in an inactive lane raises nothing and the
// active lanes load. Cases 1..3: a misaligned load in lane 5 or lane 3, or a
// misaligned JAL target with every lane active, halt with ERR.ILLEGAL at the
// instruction (slot + 4), before any lane reaches the bus, with no rd or
// link written in any lane. With one lane that can be active only case 0
// runs.
module t_trap_lanes_tb;
    parameter string IMEM_HEX = "";
    parameter string DMEM_HEX = "";
    `include "soc_harness.svh"
    `include "lane_check.svh"

    localparam logic [31:0] W = 32'h1000_4000;

    function automatic string case_name(input int k);
        case (k)
            1: return "LW misaligned in lane 5";
            2: return "LH misaligned in lane 3, M = 0xFE";
            3: return "JAL misaligned, full mask";
            default: return "?";
        endcase
    endfunction

    initial begin
        logic [7:0] m0;
        m0 = FULL & 8'hDF;
        for (int i = 0; i < 16; i++) dmem_wr(W + 32'(4 * i), 32'hD000_0000 + 32'(i));
        watch_lo = W;
        watch_hi = W + 32'h40;

        run_case(0, 5000);
        repeat (10) @(posedge clk);
        expect_no_halt("case 0");
        for (int l = 0; l < ALANES; l++)
            expect_reg(l, A2, m0[l] ? 32'hD000_0000 + 32'(l) : 32'h55, "LW under M = 0xDF");
        expect32("case 0: bus accesses", 32'(watch_hits), 32'($countones(m0)));
        $display("  case  0  control: misaligned address in inactive lane 5, %0d lanes loaded", watch_hits);

        if (ALANES > 1) begin
            for (int k = 1; k <= 3; k++) begin
                watch_hits = 0;
                run_case(k, 2000);
                expect_halt(case_name(k), 3'b100, 32'h100 + 32'h40 * k + 32'h4);
                expect_kept(A2, 32'h55, {case_name(k), ": rd"});
                expect_kept(RA, 32'h77, {case_name(k), ": link"});
                expect32({case_name(k), ": bus accesses"}, 32'(watch_hits), 32'd0);
                $display("  case %2d  %-34s ERR=%0d ERR_PC=%08h", k, case_name(k),
                         dut.u_mmio.err, dut.u_mmio.err_pc);
            end
        end
        finish_test("t_trap_lanes");
    end
endmodule
