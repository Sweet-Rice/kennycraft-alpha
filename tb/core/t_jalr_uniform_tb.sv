// t_jalr_uniform: runs every case of sw/t_jalr_uniform.S (Stage 1 rung 6)
// from its own reset. Case 0 must not halt: JALR targets from the scalar
// lane (lane 0 when M = 0), targets equal after clearing bit 0 are uniform,
// JAL and JALR link only in active lanes. Cases 1..5 must halt at the jump
// (ERR_PC = slot + 4) with ERR.DIVERGE (1..3) or ERR.ILLEGAL (4, 5: D16 with
// lanes 1..7 active) and ra unlinked in every lane. With one lane that can
// be active only case 0 runs.
module t_jalr_uniform_tb;
    parameter string IMEM_HEX = "";
    parameter string DMEM_HEX = "";
    `include "soc_harness.svh"
    `include "lane_check.svh"

    localparam int NCASES = 5;

    function automatic string case_name(input int k);
        case (k)
            1: return "JALR, lane targets differ";
            2: return "JALR, M = 0x24, lanes 2/5 differ";
            3: return "JALR, divergent + misaligned";
            4: return "JALR uniform misaligned, M = 0xFE";
            5: return "JAL misaligned, M = 0xFE";
            default: return "?";
        endcase
    endfunction

    initial begin
        logic [7:0] m_f0, m_a5;
        m_f0 = FULL & 8'hF0;
        m_a5 = FULL & 8'hA5;

        run_case(0, 10000);
        repeat (10) @(posedge clk);
        expect_no_halt("case 0");
        expect_masked(A0, FULL, 32'd1, 32'hx, "uniform JALR landed");
        for (int l = 0; l < ALANES; l++) expect_reg(l, RA, lane_x[0][T4], "uniform JALR link");
        expect_masked(A1, FULL, 32'd1, 32'hx, "targets equal after & ~1");
        expect_masked(A3, FULL, (m_f0 != 0) ? 32'd1 : 32'd2, 32'hx, "JALR under M = 0xF0 landed");
        expect_masked(A2, m_f0, lane_x[0][T5], 32'h52, "JALR link under M = 0xF0");
        expect_masked(A5, FULL, 32'd1, 32'hx, "JALR under M = 0 (lane 0) landed");
        expect_masked(A4, 8'h00, 32'hx, 32'h54, "JALR link under M = 0");
        expect_masked(A7, FULL, 32'd1, 32'hx, "JAL under M = 0xA5 landed");
        expect_masked(A6, m_a5, lane_x[0][S11], 32'h56, "JAL link under M = 0xA5");
        $display("  case  0  control: JALR scalar lane %0d under %02h links %02h, JAL links %02h",
                 scalar_lane(m_f0), m_f0, m_f0, m_a5);

        if (ALANES > 1) begin
            for (int k = 1; k <= NCASES; k++) begin
                run_case(k, 2000);
                expect_halt(case_name(k), (k >= 4) ? 3'b100 : 3'b001, 32'h100 + 32'h40 * k + 32'h4);
                expect_masked(RA, 8'h00, 32'hx, 32'h77, {case_name(k), ": ra not linked"});
                $display("  case %2d  %-36s ERR=%0d ERR_PC=%08h", k, case_name(k),
                         dut.u_mmio.err, dut.u_mmio.err_pc);
            end
        end
        finish_test("t_jalr_uniform");
    end
endmodule
