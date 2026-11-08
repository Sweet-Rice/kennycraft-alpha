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
//   HAS_DDR_MEM = 1 (Doom on the board, PIPELINED = 1 only): fetches at
//          0x8000..0x0FFF_FFFF go to rtl/mem/icache.sv (the core's imem_ack
//          waits for it), region 0x7 is a 64 KB scratch BRAM and region 0x8
//          the D-cache (rtl/mem/dcache.sv) over DDR3; both caches refill
//          through rtl/soc/line_arb.sv on the ddr_* line port (to
//          rtl/ddr/ddr_line_bridge.sv). HAS_DDR_MEM = 0: ddr_* are tied off.
//   vt_*   HAS_RAY_UNIT = 1: the core's custom-1 port to the ray unit
//          (rtl/vtrace/vtrace.sv in rtl/top.sv); 0 / ignored otherwise
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
    parameter bit    HAS_DIV_STACK = 1'b0,  // custom-2 divergence stack in the core
    parameter bit    HAS_RAY_UNIT  = 1'b0,  // custom-1 ray unit (vt_* ports)
    parameter bit    HAS_QRCP      = 1'b0,  // QRCP in every lane (D22)
    parameter bit    PIPELINED     = 1'b0,  // 5-stage core_pipe instead of core
    parameter int    FB_RD_LAT     = 1,     // fb port A read latency (display FB_RD_LAT)
    parameter bit    HAS_DDR_MEM   = 1'b0   // I-cache, D-cache, scratch over DDR3 (Doom)
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
    output logic [3:0]  fb_be,
    output logic [14:0] fb_addr,
    output logic [31:0] fb_wdata,
    input  logic [31:0] fb_rdata,
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
    input  logic [7:0]  world_rdata,

    // Ray unit (HAS_RAY_UNIT = 1)
    output logic             vt_cfg_we,
    output logic [2:0]       vt_cfg_field,
    output logic [LANES-1:0] vt_lane_mask,
    output logic [31:0]      vt_cfg_data [LANES],
    output logic             vt_start,
    output logic [7:0]       vt_max_steps,
    input  logic             vt_done,
    input  logic [15:0]      vt_result   [LANES],
    input  logic [16:0]      vt_hit_cell [LANES],
    input  logic [31:0]      vt_t_hit    [LANES],

    // DDR3 line port to rtl/ddr/ddr_line_bridge.sv (HAS_DDR_MEM = 1)
    output logic             ddr_cmd_valid,
    input  logic             ddr_cmd_ready,
    output logic             ddr_cmd_store,
    output logic [23:0]      ddr_cmd_line,
    output logic             ddr_wr_valid,
    input  logic             ddr_wr_ready,
    output logic [127:0]     ddr_wr_data,
    input  logic             ddr_rd_valid,
    output logic             ddr_rd_ready,
    input  logic [127:0]     ddr_rd_data
);

    if (HAS_DDR_MEM && !PIPELINED) begin : g_bad_ddr_mem
        $error("kc_soc: HAS_DDR_MEM = 1 needs PIPELINED = 1 (the multi-cycle core has no I-cache fetch)");
    end

    localparam int IMEM_WORDS = IMEM_BYTES / 4;
    localparam int DMEM_WORDS = DMEM_BYTES / 4;

    // ------------------------------------------------------------------
    // Core
    // ------------------------------------------------------------------
    logic [31:0]          imem_addr, imem_rdata, imem_bram_rdata;
    logic                 imem_ack;
    logic                 bus_req, bus_we, bus_ready;
    logic [31:0]          bus_addr, bus_wdata, bus_rdata;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0]          bus_pf_addr;   // the D-cache's read hint, index bits only
    /* verilator lint_on UNUSEDSIGNAL */
    logic [3:0]           bus_be;
    logic [ERR_WIDTH-1:0] err_set;
    logic [31:0]          err_pc, pc;

    // dmem window (pipelined core only): the core's per-bank port to dmem_win
    logic [3:0]           win_we    [DWIN_BANKS];
    logic [7:0]           win_addr  [DWIN_BANKS];
    logic [31:0]          win_wdata [DWIN_BANKS];
    logic [31:0]          win_rdata [DWIN_BANKS];

    // Both branches are named g_core so the core sits at g_core.u_core
    // whichever is built: PIPELINED = 1 builds the 5-stage core_pipe (P8,
    // rtl/core_pipe), PIPELINED = 0 the multi-cycle core.
    if (PIPELINED) begin : g_core
        core_pipe #(.LANES(LANES), .HAS_DIV_STACK(HAS_DIV_STACK), .HAS_RAY_UNIT(HAS_RAY_UNIT),
                    .HAS_QRCP(HAS_QRCP), .HAS_ICACHE(HAS_DDR_MEM)) u_core (
            .clk, .rst,
            .imem_addr, .imem_rdata, .imem_ack,
            .bus_req, .bus_we, .bus_addr, .bus_be, .bus_wdata, .bus_pf_addr, .bus_ready, .bus_rdata,
            .err_set, .err_pc, .halted(err_led), .pc,
            .vt_cfg_we, .vt_cfg_field, .vt_lane_mask, .vt_cfg_data, .vt_start, .vt_max_steps,
            .vt_done, .vt_result, .vt_hit_cell, .vt_t_hit,
            .win_we, .win_addr, .win_wdata, .win_rdata
        );
    end else begin : g_core
        core #(.LANES(LANES), .HAS_DIV_STACK(HAS_DIV_STACK), .HAS_RAY_UNIT(HAS_RAY_UNIT),
               .HAS_QRCP(HAS_QRCP), .HAS_ICACHE(HAS_DDR_MEM)) u_core (
            .clk, .rst,
            .imem_addr, .imem_rdata, .imem_ack,
            .bus_req, .bus_we, .bus_addr, .bus_be, .bus_wdata, .bus_ready, .bus_rdata,
            .err_set, .err_pc, .halted(err_led), .pc,
            .vt_cfg_we, .vt_cfg_field, .vt_lane_mask, .vt_cfg_data, .vt_start, .vt_max_steps,
            .vt_done, .vt_result, .vt_hit_cell, .vt_t_hit
        );
        assign bus_pf_addr = bus_addr;
        /* verilator lint_off UNUSEDSIGNAL */
        logic unused_win;
        /* verilator lint_on UNUSEDSIGNAL */
        always_comb begin
            unused_win = 1'b0;
            for (int b = 0; b < DWIN_BANKS; b++) begin
                win_we[b]    = '0;
                win_addr[b]  = '0;
                win_wdata[b] = '0;
                unused_win  ^= ^win_rdata[b];
            end
        end
    end

    // ------------------------------------------------------------------
    // Memories
    // ------------------------------------------------------------------
    memory_arr #(.W(32), .D(IMEM_WORDS), .INIT_FILE(IMEM_HEX)) u_imem (
        .clk, .we(4'b0), .addr(imem_addr[$clog2(IMEM_BYTES)-1:2]),
        .wdata(32'b0), .rdata(imem_bram_rdata)
    );

    logic [3:0]  dmem_we;
    logic [12:0] dmem_addr;
    logic [31:0] dmem_wdata, dmem_rdata;

    memory_arr #(.W(32), .D(DMEM_WORDS), .INIT_FILE(DMEM_HEX)) u_dmem (
        .clk, .we(dmem_we), .addr(dmem_addr), .wdata(dmem_wdata), .rdata(dmem_rdata)
    );

    // The top 8 KB of dmem in distributed RAM for the pipelined core's
    // lane-parallel stack accesses (kc_isa_pkg DWIN_*); unused, and removed
    // by synthesis, with the multi-cycle core.
    dmem_win #(.INIT_FILE(DMEM_HEX)) u_dwin (
        .clk, .we(win_we), .addr(win_addr), .wdata(win_wdata), .rdata(win_rdata)
    );

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

    logic [3:0]   scr_we;
    logic [13:0]  scr_addr;
    logic [31:0]  scr_wdata, scr_rdata;
    logic         dc_req, dc_we, dc_ready;
    logic [27:0]  dc_addr;
    logic [3:0]   dc_be;
    logic [31:0]  dc_wdata, dc_rdata;

    decoder #(.FB_RD_LAT(FB_RD_LAT), .HAS_DDR_MEM(HAS_DDR_MEM)) u_decoder (
        .clk, .rst,
        .req(bus_req), .we(bus_we), .addr(bus_addr), .be(bus_be), .wdata(bus_wdata),
        .ready(bus_ready), .rdata(bus_rdata),
        .dmem_we, .dmem_addr, .dmem_wdata, .dmem_rdata,
        .world_req(w_req), .world_we(w_we), .world_addr(w_addr), .world_wdata(w_wdata),
        .world_ready(w_ready), .world_rdata(w_rdata),
        .tex_req, .tex_we, .tex_addr, .tex_wdata, .tex_ready, .tex_rdata,
        .fb_we, .fb_re, .fb_be, .fb_addr, .fb_wdata, .fb_rdata,
        .mmio_req, .mmio_we, .mmio_addr, .mmio_wdata, .mmio_ready, .mmio_rdata,
        .pal_we, .pal_addr, .pal_wdata,
        .scr_we, .scr_addr, .scr_wdata, .scr_rdata,
        .dc_req, .dc_we, .dc_addr, .dc_be, .dc_wdata, .dc_ready, .dc_rdata
    );

    // ------------------------------------------------------------------
    // DDR3 memory (HAS_DDR_MEM = 1): fetch mux, I-cache, D-cache, scratch
    // ------------------------------------------------------------------
    if (HAS_DDR_MEM) begin : g_ddr_mem
        // A fetch below 0x8000 reads the imem BRAM, 0x8000..0x0FFF_FFFF the
        // I-cache; above that the BRAM answers (ack 1) and the core halts on
        // the fetch outside instruction memory. The mux follows the address
        // the core presented in the previous cycle (the BRAM / I-cache latency).
        logic        fetch_ic, fetch_ic_q, ic_ack;
        logic [31:0] ic_rdata;
        logic        i_req, i_gnt, i_valid, d_req, d_we, d_gnt, d_valid;
        logic [27:4] i_addr, d_addr;
        logic [127:0] i_data, d_wdata, d_data;

        assign fetch_ic = (imem_addr[31:28] == 4'h0) && (imem_addr[27:15] != '0);
        always_ff @(posedge clk) fetch_ic_q <= !rst && fetch_ic;

        assign imem_rdata = fetch_ic_q ? ic_rdata : imem_bram_rdata;
        assign imem_ack   = fetch_ic_q ? ic_ack : 1'b1;

        icache u_icache (
            .clk, .rst,
            .req(fetch_ic), .addr(imem_addr), .rdata(ic_rdata), .ack(ic_ack),
            .rf_req(i_req), .rf_addr(i_addr), .rf_gnt(i_gnt), .rf_valid(i_valid), .rf_data(i_data)
        );

        dcache u_dcache (
            .clk, .rst,
            .req(dc_req), .we(dc_we), .addr(dc_addr), .be(dc_be), .wdata(dc_wdata),
            .ready(dc_ready), .rdata(dc_rdata), .pf_addr(bus_pf_addr[14:4]),
            .lp_req(d_req), .lp_we(d_we), .lp_addr(d_addr), .lp_wdata(d_wdata),
            .lp_gnt(d_gnt), .lp_valid(d_valid), .lp_rdata(d_data)
        );

        line_arb u_line_arb (
            .clk, .rst,
            .i_req, .i_addr, .i_gnt, .i_valid, .i_data,
            .d_req, .d_we, .d_addr, .d_wdata, .d_gnt, .d_valid, .d_data,
            .cmd_valid(ddr_cmd_valid), .cmd_ready(ddr_cmd_ready), .cmd_store(ddr_cmd_store),
            .cmd_line(ddr_cmd_line), .wr_valid(ddr_wr_valid), .wr_ready(ddr_wr_ready),
            .wr_data(ddr_wr_data), .rd_valid(ddr_rd_valid), .rd_ready(ddr_rd_ready),
            .rd_data(ddr_rd_data)
        );

        memory_arr #(.W(32), .D(16384)) u_scratch (
            .clk, .we(scr_we), .addr(scr_addr), .wdata(scr_wdata), .rdata(scr_rdata)
        );
    end else begin : g_no_ddr_mem
        assign imem_rdata    = imem_bram_rdata;
        assign imem_ack      = 1'b1;
        assign dc_ready      = dc_req;
        assign dc_rdata      = '0;
        assign scr_rdata     = '0;
        assign ddr_cmd_valid = 1'b0;
        assign ddr_cmd_store = 1'b0;
        assign ddr_cmd_line  = '0;
        assign ddr_wr_valid  = 1'b0;
        assign ddr_wr_data   = '0;
        assign ddr_rd_ready  = 1'b0;

        /* verilator lint_off UNUSEDSIGNAL */
        logic unused_ddr_mem;
        /* verilator lint_on UNUSEDSIGNAL */
        assign unused_ddr_mem = ddr_cmd_ready ^ ddr_wr_ready ^ ddr_rd_valid ^ (^ddr_rd_data) ^
                                (^scr_we) ^ (^scr_addr) ^ (^scr_wdata) ^ dc_we ^ (^dc_addr) ^
                                (^dc_be) ^ (^dc_wdata);
    end

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

    // CYCLES ticks every 20 ns whatever the core clock (50 or 100 MHz)
    mmio #(.CYCLE_DIV(CLK_HZ / 50_000_000)) u_mmio (
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
