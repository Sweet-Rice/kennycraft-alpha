// t_branch_uniform: runs every case of sw/t_branch_uniform.S (Stage 1 rung
// 6) from its own reset. Case 0 must not halt and must record each
// branch's outcome as the active lanes (or lane 0 when M = 0) decided it.
// Cases 1..9 must halt at the branch (ERR_PC = slot + 4) with ERR.DIVERGE,
// except case 9 (uniform, misaligned target), which is ERR.ILLEGAL. With
// one lane that can be active (LANES = 1, or LANE0_ONLY) nothing can
// diverge, so only case 0 runs.
module t_branch_uniform_tb;
    parameter string IMEM_HEX = "";
    parameter string DMEM_HEX = "";
    `include "soc_harness.svh"
    `include "lane_check.svh"

    localparam int NCASES = 9;

    function automatic string case_name(input int k);
        case (k)
            1: return "BEQ divergent";   2: return "BNE divergent";
            3: return "BLT divergent";   4: return "BGE divergent";
            5: return "BLTU divergent";  6: return "BGEU divergent";
            7: return "M = 0x24, lanes 2/5 disagree";
            8: return "divergent + misaligned target";
            9: return "uniform taken, misaligned target, M = 0xF0";
            default: return "?";
        endcase
    endfunction

    // Outcome recorded by case 0: 1 taken, 2 not taken. m is the mask the
    // branch ran under; taken_lo/taken_hi give each lane's own outcome.
    function automatic logic [31:0] outcome(input logic [7:0] m, input logic [7:0] lane_taken);
        return lane_taken[scalar_lane(m)] ? 32'd1 : 32'd2;
    endfunction

    initial begin
        logic [7:0] m_f0, m_0c;
        m_f0 = FULL & 8'hF0;
        m_0c = FULL & 8'h0C;

        run_case(0, 10000);
        repeat (10) @(posedge clk);
        expect_no_halt("case 0");
        expect_masked(A0, FULL, 32'd1, 32'hx, "BEQ uniform taken");
        expect_masked(A1, FULL, 32'd2, 32'hx, "BNE uniform not taken");
        expect_masked(A2, FULL, 32'd1, 32'hx, "BLT uniform taken");
        expect_masked(A3, FULL, 32'd2, 32'hx, "BGE uniform not taken");
        expect_masked(A4, FULL, 32'd1, 32'hx, "BLTU uniform taken");
        expect_masked(A5, FULL, 32'd2, 32'hx, "BGEU uniform not taken");
        // lane < 4 under M = 0xF0, lane >= 2 under M = 0x0C, lane == 0 under M = 0
        expect_masked(A6, FULL, outcome(m_f0, 8'h0F), 32'hx, "BLTU under M = 0xF0");
        expect_masked(A7, FULL, outcome(m_0c, 8'hFC), 32'hx, "BGEU under M = 0x0C");
        expect_masked(T3, FULL, 32'd1, 32'hx, "BEQZ under M = 0 (lane 0)");
        $display("  case  0  control: uniform branches, scalar lane %0d decides under %02h, %0d under %02h, lane 0 under 0",
                 scalar_lane(m_f0), m_f0, scalar_lane(m_0c), m_0c);

        if (ALANES > 1) begin
            for (int k = 1; k <= NCASES; k++) begin
                logic [31:0] pc;
                pc = 32'h100 + 32'h40 * k + 32'h4;
                run_case(k, 2000);
                expect_halt(case_name(k), (k == 9) ? 3'b100 : 3'b001, pc);
                $display("  case %2d  %-44s ERR=%0d ERR_PC=%08h", k, case_name(k),
                         dut.u_mmio.err, dut.u_mmio.err_pc);
            end
        end
        finish_test("t_branch_uniform");
    end
endmodule
