// t_lanectl: runs sw/t_lanectl.S (the wiki crt0 prologue, then every custom-0
// instruction at LANES = 1 and the mask = 0 gating rules) and checks the
// results, the cleared .bss word and that no error was raised.
module t_lanectl_tb;
    parameter string IMEM_HEX = "";
    parameter string DMEM_HEX = "";
    `include "soc_harness.svh"

    localparam logic [31:0] RES     = 32'h1000_0100;
    localparam logic [31:0] SCRATCH = 32'h1000_0148;
    localparam logic [31:0] BSS     = 32'h1000_014C;

    int errors = 0;

    task automatic expect32(input string what, input logic [31:0] got, input logic [31:0] exp);
        if (got !== exp) begin
            $display("  FAIL %-34s got %08h expected %08h", what, got, exp);
            errors++;
        end else begin
            $display("  ok   %-34s %08h", what, got);
        end
    endtask

    initial begin
        dmem_wr(BSS, 32'hDEAD_BEEF);   // crt0 must clear .bss
        do_reset();
        run_until_done(20000);
        repeat (20) @(posedge clk);

        expect32("error LED", {31'b0, err_led}, 32'd0);
        expect32("ERR", {29'b0, dut.u_mmio.err}, 32'd0);
        expect32("crt0 sp (lane 0 stack top)", dmem_rd(RES + 0), 32'h1000_8000);
        expect32("crt0 cleared .bss", dmem_rd(BSS), 32'd0);
        expect32("MASKGET after crt0", dmem_rd(RES + 4), 32'd1);
        expect32("LANEID", dmem_rd(RES + 8), 32'd0);
        expect32("BALLOT(5)", dmem_rd(RES + 12), 32'd1);
        expect32("BALLOT(0)", dmem_rd(RES + 16), 32'd0);
        expect32("M=0: ADDI rd unchanged", dmem_rd(RES + 20), 32'h11);
        expect32("M=0: LUI rd unchanged", dmem_rd(RES + 24), 32'h22);
        expect32("M=0: MUL rd unchanged", dmem_rd(RES + 28), 32'h33);
        expect32("M=0: LW rd unchanged", dmem_rd(RES + 32), 32'h44);
        expect32("M=0: misaligned LW, no halt", dmem_rd(RES + 36), 32'h55);
        expect32("M=0: LANEID rd unchanged", dmem_rd(RES + 40), 32'h66);
        expect32("M=0: branch followed lane 0", dmem_rd(RES + 44), 32'h77);
        expect32("M=0: BALLOT writes 0", dmem_rd(RES + 48), 32'd0);
        expect32("M=0: MASKGET writes 0", dmem_rd(RES + 52), 32'd0);
        expect32("M=0: JAL link unchanged", dmem_rd(RES + 56), 32'h77);
        expect32("M=0: SW dropped", dmem_rd(SCRATCH), 32'h11);
        expect32("MASKALL after MASKSET(2)", dmem_rd(RES + 60), 32'd1);
        expect32("MASKSET(2) cleared the lane", dmem_rd(RES + 64), 32'h5A);
        expect32("LMASK(3) keeps the lane", dmem_rd(RES + 68), 32'd1);
        expect32("mask at the end", 32'(`KC_CORE.mask), 32'd1);

        if (errors != 0) $fatal(1, "FAIL: t_lanectl, %0d mismatches", errors);
        $display("PASS: t_lanectl (wiki crt0 prologue + custom-0 at LANES = 1)");
        $finish;
    end
endmodule
