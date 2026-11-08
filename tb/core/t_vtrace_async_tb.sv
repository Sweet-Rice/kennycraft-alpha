// t_vtrace_async: runs sw/t_vtrace_async.S on the Stage 2 core (LANES = 8,
// divergence stack, ray unit, QRCP; PIPELINED selects the core) and checks
// asynchronous VTRACE (VTRACE x0) and VGET field 3.
//
// Results, per lane (RES k, see the program): VGET 3 after VTRACE x0 equals
// VTRACE rd of the same rays, VGET 0 and 1 after an async walk equal the
// reference, VSET right after VTRACE x0 leaves the walk alone, the world
// word stored and loaded right after VTRACE x0 reads back, VTRACE x0 with a
// cap of 0 or M = 0 changes nothing, two VTRACE x0 back to back equal two
// VTRACE rd, the program's own check s11 = 0, LEDS = 0x47. Reference walk:
// every lane hits the cap (100 steps) except lane 7, which leaves the world
// at step 99, and nothing is hit (all air).
//
// Monitors: every WORK instruction of the overlap window retires while the
// ray unit is busy, and VTRACE x0 retires as a 1-cycle instruction (4 cycles
// after the instruction before it on the multi-cycle core, 1 on core_pipe);
// the async run with WORK is faster than VTRACE rd + WORK (CYCLES); no VSET
// or VTRACE strobe, world access or MMIO store reaches the ray unit or the
// bus while it is busy, and each of those waits at least once; the DIV of
// case G halts with ERR.ILLEGAL while the walk is in flight, the walk then
// finishes, nothing retires after the halt and the PC stays put.
module t_vtrace_async_tb;
    parameter string IMEM_HEX = "";
    parameter string DMEM_HEX = "";
    `include "soc_harness.svh"

    localparam logic [31:0] RES_BASE = 32'h1000_1100;
    localparam logic [31:0] MB_OVL_B = 32'h1000_00D0;
    localparam logic [31:0] MB_OVL_E = 32'h1000_00D4;
    localparam logic [31:0] MB_HALT  = 32'h1000_00D8;
    localparam logic [31:0] TB_MARK  = 32'h1000_00F4;
    localparam int          NWORK    = 38;   // WORK: two LI and 36 ALU

    function automatic logic [31:0] res(input int k, input int l);
        return dmem_rd(RES_BASE + 32'(32 * k + 4 * l));
    endfunction

    int errors = 0;

    task automatic expect32(input string what, input logic [31:0] got, input logic [31:0] exp);
        if (got !== exp) begin
            $display("  FAIL %-36s got %08h expected %08h", what, got, exp);
            errors++;
        end
    endtask

    task automatic expect_true(input string what, input bit ok);
        if (!ok) begin
            $display("  FAIL %s", what);
            errors++;
        end
    endtask

    wire busy = g_vtrace.vt_busy;

    function automatic bit is_vtrace_x0(input logic [31:0] inst);
        return inst[6:0] == 7'h2B && inst[14:12] == 3'b001 && inst[11:7] == 5'd0;
    endfunction

    // Bus and ray-unit strobes while the ray unit is busy
    int viol_world = 0, viol_mmio_st = 0, viol_cfg = 0, viol_start = 0;
    int world_acc = 0, world_wait = 0, mmio_wait = 0, ray_hold = 0;
    always @(posedge clk) if (!rst) begin
        if (dut.bus_req && dut.bus_addr[31:28] == 4'h2) begin
            world_acc <= world_acc + 1;
            if (busy) viol_world <= viol_world + 1;
        end
        if (dut.bus_req && dut.bus_we && dut.bus_addr[31:28] == 4'h5 && busy)
            viol_mmio_st <= viol_mmio_st + 1;
        if (vt_cfg_we && busy) viol_cfg <= viol_cfg + 1;
        if (vt_start && busy)  viol_start <= viol_start + 1;
        if (`KC_CORE.state == 4'd4 && `KC_CORE.vt_block) begin
            if (dut.bus_addr[31:28] == 4'h2) world_wait <= world_wait + 1;
            if (dut.bus_addr[31:28] == 4'h5) mmio_wait <= mmio_wait + 1;
        end
    end

    // A custom-1 instruction that waited for a walk: it retires with the
    // ray unit idle right after an instruction that retired while it was
    // busy (no custom-1 instruction can start a walk or strobe while busy).
    bit last_busy = 1'b0;
    always @(posedge clk) if (!rst && `KC_CORE.retire_valid) begin
        if (`KC_CORE.retire_inst[6:0] == 7'h2B && last_busy && !busy) ray_hold <= ray_hold + 1;
        last_busy <= busy;
    end

    // Retirements: the overlap window, VTRACE x0 latency, after the halt
    int          ovl_total = 0, ovl_busy = 0, busy_retires = 0, after_halt = 0;
    int          vt0_lat = -1;
    int unsigned last_retire = 0;
    bit          halted_seen = 1'b0, busy_at_halt = 1'b0, done_after_halt = 1'b0;
    logic [31:0] err_at_halt;
    always @(posedge clk) if (!rst) begin
        if (`KC_CORE.retire_valid) begin
            if (busy) busy_retires <= busy_retires + 1;
            if (`KC_CORE.retire_pc >= dmem_rd(MB_OVL_B) && `KC_CORE.retire_pc < dmem_rd(MB_OVL_E)) begin
                ovl_total <= ovl_total + 1;
                if (busy) ovl_busy <= ovl_busy + 1;
            end
            if (`KC_CORE.retire_pc == dmem_rd(MB_OVL_B) - 32'd4 &&
                is_vtrace_x0(`KC_CORE.retire_inst))
                vt0_lat <= int'(cycle - last_retire);
            if (halted_seen) after_halt <= after_halt + 1;
            last_retire <= cycle;
        end
        if (`KC_CORE.err_set != '0 && !halted_seen) begin
            halted_seen  <= 1'b1;
            busy_at_halt <= busy;
            err_at_halt  <= 32'(`KC_CORE.err_set);
        end
        if (halted_seen && vt_done) done_after_halt <= 1'b1;
    end

    initial begin
        logic [31:0] pc_halt, d_async, d_sync;

        do_reset();
        run_until_done(40000);
        pc_halt = `KC_CORE.pc;
        repeat (1200) @(posedge clk);

        // G: halt while the walk is in flight
        expect32("halted (error LED)", {31'b0, err_led}, 32'd1);
        expect32("err_set at the halt", err_at_halt, 32'd4);
        expect32("ERR", {29'b0, dut.u_mmio.err}, 32'd4);
        expect32("ERR_PC = the DIV", dut.u_mmio.err_pc, dmem_rd(MB_HALT));
        expect32("PC frozen", `KC_CORE.pc, pc_halt);
        expect32("ray unit busy at the halt", {31'b0, busy_at_halt}, 32'd1);
        expect32("walk finished after the halt", {31'b0, done_after_halt}, 32'd1);
        expect32("ray unit idle at the end", {31'b0, busy}, 32'd0);
        expect32("retired after the halt", 32'(after_halt), 32'd0);
        expect32("instruction after the DIV", dmem_rd(TB_MARK), 32'd0);

        for (int l = 0; l < LANES; l++) begin
            string       p;
            logic [31:0] ra, rf;
            p  = $sformatf("lane %0d", l);
            ra = res(0, l);
            rf = res(20, l);
            // A: the reference walk
            expect32({p, " A steps"}, {24'd0, ra[15:8]}, (l == 7) ? 32'd99 : 32'd100);
            expect32({p, " A hit"}, {31'd0, ra[0]}, 32'd0);
            expect32({p, " A result high half"}, {16'd0, ra[31:16]}, 32'd0);
            // B: VGET 3 / 0 / 1 after VTRACE x0, and VTRACE rd + VGET 3
            expect32({p, " B VGET 3 = VTRACE rd"}, res(3, l), res(0, l));
            expect32({p, " B VGET 0"}, res(4, l), res(1, l));
            expect32({p, " B VGET 1"}, res(5, l), res(2, l));
            expect32({p, " B' VTRACE rd"}, res(7, l), res(0, l));
            expect32({p, " B' VGET 3"}, res(8, l), res(0, l));
            // C: VSET right after VTRACE x0
            expect32({p, " C VGET 3"}, res(11, l), res(0, l));
            expect32({p, " C VGET 0"}, res(12, l), res(1, l));
            expect32({p, " C VGET 1"}, res(13, l), res(2, l));
            // D: world SW / LW and an MMIO store right after VTRACE x0
            expect32({p, " D world LW"}, res(14, l), 32'h0403_0201 + 32'h0101_0101 * l);
            expect32({p, " D VGET 3"}, res(15, l), res(0, l));
            expect32({p, " D VGET 3 after LEDS"}, res(16, l), res(0, l));
            // E: cap 0 and M = 0
            expect32({p, " E VGET 3 after cap 0"}, res(17, l), res(0, l));
            expect32({p, " E VGET 3 after M = 0"}, res(18, l), res(0, l));
            expect32({p, " E VGET 0 after M = 0"}, res(19, l), res(1, l));
            // F: two VTRACE x0 against two VTRACE rd
            expect32({p, " F VGET 3"}, res(23, l), res(20, l));
            expect32({p, " F VGET 0"}, res(24, l), res(21, l));
            expect32({p, " F VGET 1"}, res(25, l), res(22, l));
            expect32({p, " F steps of the second walk"}, {24'd0, rf[15:8]}, 32'd40);
            expect32({p, " self-check s11"}, lane_x[l][27], 32'd0);
        end
        expect32("LEDS", {24'd0, leds}, 32'h47);

        // Overlap
        d_async = res(6, 0);
        d_sync  = res(10, 0);
        expect32("WORK retired in the window", 32'(ovl_total), 32'(NWORK));
        expect32("WORK retired while busy", 32'(ovl_busy), 32'(NWORK));
        expect32("VTRACE x0 retire spacing", 32'(vt0_lat), PIPELINED ? 32'd1 : 32'd4);
        expect_true($sformatf("async (%0d cycles) faster than sync (%0d)", d_async, d_sync),
                    d_async < d_sync);

        // Interlocks
        expect32("world accesses while busy", 32'(viol_world), 32'd0);
        expect32("MMIO stores while busy", 32'(viol_mmio_st), 32'd0);
        expect32("VSET strobes while busy", 32'(viol_cfg), 32'd0);
        expect32("VTRACE starts while busy", 32'(viol_start), 32'd0);
        expect_true("world accesses happened", world_acc > 0);
        expect_true("a world access waited", world_wait > 0);
        expect_true("an MMIO store waited", mmio_wait > 0);
        expect_true("a custom-1 instruction waited", ray_hold > 0);

        $display("  overlap: VTRACE x0 + WORK %0d cycles, VTRACE rd + WORK %0d cycles, %0d saved",
                 d_async, d_sync, d_sync - d_async);
        $display("  %0d of %0d WORK instructions retired while busy, %0d retirements while busy in all",
                 ovl_busy, ovl_total, busy_retires);
        $display("  waits: world %0d cycles, MMIO store %0d cycles, %0d custom-1 instructions",
                 world_wait, mmio_wait, ray_hold);

        if (errors != 0) $fatal(1, "FAIL: t_vtrace_async, %0d mismatches", errors);
        $display("PASS: t_vtrace_async (LANES = %0d, PIPELINED = %0d)", LANES, PIPELINED);
        $finish;
    end
endmodule
