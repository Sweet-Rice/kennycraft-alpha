// dmem window in distributed RAM (kc_isa_pkg DWIN_*): dmem offsets 0x6000 to
// 0x7FFF, the per-lane stacks, as DWIN_BANKS independent LUT RAMs of
// DWIN_DEPTH x 32 bits with byte enables. Bank b holds the words whose
// address bits 12:10 are b (addr[9:2] within the bank), so the pipelined
// core's LSU serves one access per bank in the same cycle (rtl/core_pipe/
// win_lsu.sv). Reads are asynchronous: rdata[b] is word addr[b] in the same
// cycle. Writes land on the clock edge.
//
// With PIPELINED = 1 every dmem access in the window comes here and the
// window part of the dmem BRAM is never used; with PIPELINED = 0 nothing
// drives this module and synthesis removes it. Initial contents are the
// window part of INIT_FILE, the dmem image, so the window starts out exactly
// as the BRAM would. The game images have nothing there (.bss ends far
// below), and fpga/patch_bit.sh patches only the BRAM.
module dmem_win
    import kc_isa_pkg::*;
#(
    parameter string INIT_FILE = ""
) (
    input  logic        clk,
    input  logic [3:0]  we    [DWIN_BANKS],
    input  logic [7:0]  addr  [DWIN_BANKS],
    input  logic [31:0] wdata [DWIN_BANKS],
    output logic [31:0] rdata [DWIN_BANKS]
);

    for (genvar b = 0; b < DWIN_BANKS; b++) begin : g_bank
        (* ram_style = "distributed" *) logic [31:0] mem [DWIN_DEPTH];

        initial begin
            if (INIT_FILE != "") begin
                logic [31:0] img [DMEM_BYTES / 4];
                $readmemh(INIT_FILE, img);
                for (int i = 0; i < DWIN_DEPTH; i++)
                    mem[i] = img[DWIN_BASE_WORD + b * DWIN_DEPTH + i];
            end
        end

        always_ff @(posedge clk)
            for (int k = 0; k < 4; k++)
                if (we[b][k]) mem[addr[b]][k*8 +: 8] <= wdata[b][k*8 +: 8];

        assign rdata[b] = mem[addr[b]];
    end

endmodule
