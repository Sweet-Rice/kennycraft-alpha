// KennyCraft Stage 0 SoC on the 50 MHz core clock: core, imem, dmem, address
// decoder, MMIO, UART, and BRAM stubs for the regions whose hardware is not
// merged yet. top adds clk_gen and the display around it.
//
//   imem   32 KB BRAM, $readmemh(IMEM_HEX), fetch only, reset vector 0
//   dmem   32 KB BRAM, $readmemh(DMEM_HEX)
//   gpu    68 KB BRAM (17,408 x 32, byte enables), no init file: tile
//          rasterizer mesh pages and command lists (D17)
//   world  EXT_WORLD = 0: 128 K x 4-bit BRAM stub (one copy of the window,
//          low 4 bits = block type, upper bits read 0, no remap).
//          EXT_WORLD = 1: the world_* port goes to world_remap (P2b).
//   tex    16 K x 4-bit BRAM stub (16 types x 3 faces x 16 x 16 texels at
//          4 bits fit in 12,288; the rest of the 16 K is spare), initial
//          contents from TEX_HEX when not empty (one texel per line, e.g.
//          game/gen/textures.hex)
//   fb, palette, FB_SWAP, VSYNC, FRAME_COUNT, FB_MODE  ports to display (P1)
//   0x2C..0x3C  ddr_reg_* port to the chunk engine (P2b)
module kc_soc
    import kc_isa_pkg::*;
#(
    parameter int    LANES     = 1,
    parameter int    CLK_HZ    = 50_000_000,
    parameter int    BAUD      = 1_000_000,
    parameter string IMEM_HEX  = "kc_imem.hex",
    parameter string DMEM_HEX  = "kc_dmem.hex",
    parameter string TEX_HEX   = "",
    parameter bit    EXT_WORLD = 1'b0,
    parameter bit    HAS_DIV_STACK = 1'b0   // custom-2 divergence stack in the core
) (
    input  logic        clk,
    input  logic        rst,

    // UART pins
    output logic        uart_tx,
    input  logic        uart_rx,

    // Board LEDs (MMIO LEDS) and the error LED (core halted on an error)
    output logic [7:0]  leds,
    output logic        err_led,

    // Display core-side port (P1)
    output logic        fb_we,
    output logic        fb_re,
    output logic [16:0] fb_addr,
    output logic [7:0]  fb_wdata,
    input  logic [7:0]  fb_rdata,
    output logic        pal_we,
    output logic [7:0]  pal_addr,
    output logic [11:0] pal_wdata,
    output logic        swap_req,
    input  logic        swap_pending,
    input  logic        vblank,
    input  logic [31:0] frame_count,
    output logic        fb_mode,

    // Chunk engine registers (P2b)
    output logic        ddr_reg_en,
    output logic        ddr_reg_we,
    output logic [5:0]  ddr_reg_off,
    output logic [31:0] ddr_reg_wdata,
    input  logic [31:0] ddr_reg_rdata,
    input  logic        ddr_reg_stall,

    // World window port (used when EXT_WORLD = 1)
    output logic        world_req,
    output logic        world_we,
    output logic [16:0] world_addr,
    output logic [7:0]  world_wdata,
    input  logic        world_ready,
    input  logic [7:0]  world_rdata
);

    localparam int IMEM_WORDS = IMEM_BYTES / 4;
    localparam int DMEM_WORDS = DMEM_BYTES / 4;
    localparam int GPU_WORDS  = GPU_BYTES / 4;

    // ------------------------------------------------------------------
    // Core
    // ------------------------------------------------------------------
    logic [31:0]          imem_addr, imem_rdata;
    logic                 bus_req, bus_we, bus_ready;
    logic [31:0]          bus_addr, bus_wdata, bus_rdata;
    logic [3:0]           bus_be;
    logic [ERR_WIDTH-1:0] err_set;
    logic [31:0]          err_pc, pc;

    core #(.LANES(LANES), .HAS_DIV_STACK(HAS_DIV_STACK)) u_core (
        .clk, .rst,
        .imem_addr, .imem_rdata,
        .bus_req, .bus_we, .bus_addr, .bus_be, .bus_wdata, .bus_ready, .bus_rdata,
        .err_set, .err_pc, .halted(err_led), .pc
    );

    // ------------------------------------------------------------------
    // Memories
    // ------------------------------------------------------------------
    memory_arr #(.W(32), .D(IMEM_WORDS), .INIT_FILE(IMEM_HEX)) u_imem (
        .clk, .we(4'b0), .addr(imem_addr[$clog2(IMEM_BYTES)-1:2]),
        .wdata(32'b0), .rdata(imem_rdata)
    );

    logic [3:0]  dmem_we;
    logic [12:0] dmem_addr;
    logic [31:0] dmem_wdata, dmem_rdata;

    memory_arr #(.W(32), .D(DMEM_WORDS), .INIT_FILE(DMEM_HEX)) u_dmem (
        .clk, .we(dmem_we), .addr(dmem_addr), .wdata(dmem_wdata), .rdata(dmem_rdata)
    );

    // GPU memory as a 16 K-word bank (offsets 0x0_0000..0x0_FFFF) and a
    // 1 K-word bank (0x1_0000..0x1_0FFF). One 17 K-deep array makes Vivado
    // build 32 K x 1 slices (32 BRAM36); the split maps to 16 + 1. The decoder
    // only enables writes inside the 68 KB, so gpu_addr[13:10] is 0 whenever
    // the 1 K bank is written. The bank select is registered with the read.
    localparam int GPU_LO_WORDS = 16 * 1024;
    localparam int GPU_HI_WORDS = GPU_WORDS - GPU_LO_WORDS;

    logic [3:0]  gpu_we;
    logic [14:0] gpu_addr;
    logic [31:0] gpu_wdata, gpu_rdata, gpu_lo_rdata, gpu_hi_rdata;
    logic        gpu_hi_q;

    memory_arr #(.W(32), .D(GPU_LO_WORDS)) u_gpu_lo (
        .clk, .we(gpu_addr[14] ? 4'b0 : gpu_we), .addr(gpu_addr[13:0]),
        .wdata(gpu_wdata), .rdata(gpu_lo_rdata)
    );

    memory_arr #(.W(32), .D(GPU_HI_WORDS)) u_gpu_hi (
        .clk, .we(gpu_addr[14] ? gpu_we : 4'b0), .addr(gpu_addr[9:0]),
        .wdata(gpu_wdata), .rdata(gpu_hi_rdata)
    );

    always_ff @(posedge clk) gpu_hi_q <= gpu_addr[14];
    assign gpu_rdata = gpu_hi_q ? gpu_hi_rdata : gpu_lo_rdata;

    // ------------------------------------------------------------------
    // Address decoder
    // ------------------------------------------------------------------
    logic        w_req, w_we, w_ready;
    logic [16:0] w_addr;
    logic [7:0]  w_wdata, w_rdata;
    logic        tex_req, tex_we, tex_ready;
    logic [13:0] tex_addr;
    logic [7:0]  tex_wdata, tex_rdata;
    logic        mmio_req, mmio_we, mmio_ready;
    logic [7:0]  mmio_addr;
    logic [31:0] mmio_wdata, mmio_rdata;

    decoder u_decoder (
        .clk, .rst,
        .req(bus_req), .we(bus_we), .addr(bus_addr), .be(bus_be), .wdata(bus_wdata),
        .ready(bus_ready), .rdata(bus_rdata),
        .dmem_we, .dmem_addr, .dmem_wdata, .dmem_rdata,
        .gpu_we, .gpu_addr, .gpu_wdata, .gpu_rdata,
        .world_req(w_req), .world_we(w_we), .world_addr(w_addr), .world_wdata(w_wdata),
        .world_ready(w_ready), .world_rdata(w_rdata),
        .tex_req, .tex_we, .tex_addr, .tex_wdata, .tex_ready, .tex_rdata,
        .fb_we, .fb_re, .fb_addr, .fb_wdata, .fb_rdata,
        .mmio_req, .mmio_we, .mmio_addr, .mmio_wdata, .mmio_ready, .mmio_rdata,
        .pal_we, .pal_addr, .pal_wdata
    );

    // ------------------------------------------------------------------
    // World: internal stub or external port
    // ------------------------------------------------------------------
    if (EXT_WORLD) begin : g_world_ext
        assign world_req   = w_req;
        assign world_we    = w_we;
        assign world_addr  = w_addr;
        assign world_wdata = w_wdata;
        assign w_ready     = world_ready;
        assign w_rdata     = world_rdata;
    end else begin : g_world_stub
        logic [3:0] stub_rdata;

        memory_arr #(.W(4), .D(1 << 17), .NBE(1)) u_world (
            .clk, .we(w_req && w_we), .addr(w_addr), .wdata(w_wdata[3:0]),
            .rdata(stub_rdata)
        );

        assign world_req   = 1'b0;
        assign world_we    = 1'b0;
        assign world_addr  = '0;
        assign world_wdata = '0;
        assign w_ready     = w_req;
        assign w_rdata     = {4'b0, stub_rdata};

        /* verilator lint_off UNUSEDSIGNAL */
        logic       unused_world;
        /* verilator lint_on UNUSEDSIGNAL */
        assign unused_world = world_ready ^ (^world_rdata) ^ (^w_wdata[7:4]);
    end

    // ------------------------------------------------------------------
    // Texture stub
    // ------------------------------------------------------------------
    logic [3:0] tex_stub_rdata;

    memory_arr #(.W(4), .D(1 << 14), .NBE(1), .INIT_FILE(TEX_HEX)) u_tex (
        .clk, .we(tex_req && tex_we), .addr(tex_addr), .wdata(tex_wdata[3:0]),
        .rdata(tex_stub_rdata)
    );
    assign tex_ready = tex_req;
    assign tex_rdata = {4'b0, tex_stub_rdata};

    // ------------------------------------------------------------------
    // MMIO and UART
    // ------------------------------------------------------------------
    logic       tx_start, tx_busy, rx_pop, rx_avail;
    logic [7:0] tx_data, rx_data;

    mmio u_mmio (
        .clk, .rst,
        .req(mmio_req), .we(mmio_we), .addr(mmio_addr[7:2]), .wdata(mmio_wdata),
        .ready(mmio_ready), .rdata(mmio_rdata),
        .err_set, .err_pc_in(err_pc),
        .uart_tx_start(tx_start), .uart_tx_data(tx_data), .uart_tx_busy(tx_busy),
        .uart_rx_pop(rx_pop), .uart_rx_avail(rx_avail), .uart_rx_data(rx_data),
        .swap_req, .swap_pending, .vblank, .frame_count, .fb_mode,
        .leds,
        .ddr_reg_en, .ddr_reg_we, .ddr_reg_off, .ddr_reg_wdata,
        .ddr_reg_rdata, .ddr_reg_stall
    );

    uart #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .RX_DEPTH(16)) u_uart (
        .clk, .rst,
        .tx_data, .tx_start, .tx_busy, .tx(uart_tx),
        .rx(uart_rx), .rx_pop, .rx_avail, .rx_data
    );

    /* verilator lint_off UNUSEDSIGNAL */
    logic unused;
    /* verilator lint_on UNUSEDSIGNAL */
    assign unused = (^pc) ^ (^imem_addr[31:15]) ^ (^imem_addr[1:0]) ^ (^tex_wdata[7:4]) ^ (^mmio_addr[1:0]);

endmodule
