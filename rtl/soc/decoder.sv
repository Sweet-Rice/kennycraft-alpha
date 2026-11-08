// Data-side address decoder on address bits 31:28 (Shared page, Memory map).
//
// Bus. req is held until ready; the access happens once in the req && ready
// cycle and read data is valid in rdata the following cycle. Every region
// port uses the same handshake (BRAM ports accept at once).
//
//   0x0  imem    fetch only: loads read 0, stores are dropped
//   0x1  dmem    32 KB, word port with byte enables (dmem_*), aliases every 32 KB
//   0x2  world   byte port (world_*), split by byte_bridge, 17-bit index
//   0x3  tex     byte port (tex_*), split by byte_bridge, 14-bit index
//   0x4  fb      word port with byte enables to the back framebuffer (fb_*)
//   0x5  mmio    register port (mmio_*), byte offset addr[7:0]
//   0x6  palette write only, one entry per word: pal_addr = addr[9:2], low 12 bits
//   0x7  gpu     68 KB, word port with byte enables (gpu_*); offsets 0x11000
//                and up are unmapped (no aliasing)
//   0x8..0xF     unmapped: loads read 0, stores are dropped, no error
//
// Byte-wide regions (world, textures) take every enabled byte lane in turn,
// so LW/SW work there too (four accesses) and LB/SB take one.
module decoder
    import kc_isa_pkg::*;
(
    input  logic        clk,
    input  logic        rst,

    // Core data bus
    input  logic        req,
    input  logic        we,
    // Bits 27:17 are not decoded except by the gpu bounds check: the other
    // regions alias through their 256 MB.
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] addr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [3:0]  be,
    input  logic [31:0] wdata,
    output logic        ready,
    output logic [31:0] rdata,

    // Data memory (32 KB, word addressed)
    output logic [3:0]  dmem_we,
    output logic [12:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    input  logic [31:0] dmem_rdata,

    // GPU memory (68 KB, word addressed)
    output logic [3:0]  gpu_we,
    output logic [14:0] gpu_addr,
    output logic [31:0] gpu_wdata,
    input  logic [31:0] gpu_rdata,

    // World window
    output logic        world_req,
    output logic        world_we,
    output logic [16:0] world_addr,
    output logic [7:0]  world_wdata,
    input  logic        world_ready,
    input  logic [7:0]  world_rdata,

    // Textures
    output logic        tex_req,
    output logic        tex_we,
    output logic [13:0] tex_addr,
    output logic [7:0]  tex_wdata,
    input  logic        tex_ready,
    input  logic [7:0]  tex_rdata,

    // Back framebuffer (P1 display core-side port, 1-cycle read latency)
    output logic        fb_we,
    output logic        fb_re,
    output logic [16:0] fb_addr,
    output logic [3:0]  fb_be,
    output logic [31:0] fb_wdata,
    input  logic [31:0] fb_rdata,

    // MMIO
    output logic        mmio_req,
    output logic        mmio_we,
    output logic [7:0]  mmio_addr,
    output logic [31:0] mmio_wdata,
    input  logic        mmio_ready,
    input  logic [31:0] mmio_rdata,

    // Palette (P1 display core-side port)
    output logic        pal_we,
    output logic [7:0]  pal_addr,
    output logic [11:0] pal_wdata
);

    typedef enum logic [2:0] {
        R_NONE, R_DMEM, R_WORLD, R_TEX, R_FB, R_MMIO, R_GPU
    } region_t;

    region_t sel, sel_q;

    always_comb begin
        unique case (addr[31:28])
            REG_DMEM:  sel = R_DMEM;
            REG_WORLD: sel = R_WORLD;
            REG_TEX:   sel = R_TEX;
            REG_FB:    sel = R_FB;
            REG_MMIO:  sel = R_MMIO;
            REG_GPU:   sel = ({4'b0, addr[27:0]} < GPU_BYTES) ? R_GPU : R_NONE;
            default:   sel = R_NONE;  // imem (fetch only), palette (write only), unmapped
        endcase
    end

    // ------------------------------------------------------------------
    // Word regions
    // ------------------------------------------------------------------
    assign dmem_we    = (req && we && sel == R_DMEM) ? be : 4'b0;
    assign dmem_addr  = addr[14:2];
    assign dmem_wdata = wdata;

    assign gpu_we     = (req && we && sel == R_GPU) ? be : 4'b0;
    assign gpu_addr   = addr[16:2];
    assign gpu_wdata  = wdata;

    assign mmio_req   = req && (sel == R_MMIO);
    assign mmio_we    = we;
    assign mmio_addr  = addr[7:0];
    assign mmio_wdata = wdata;

    assign pal_we     = req && we && (addr[31:28] == REG_PAL);
    assign pal_addr   = addr[9:2];
    assign pal_wdata  = wdata[11:0];

    // ------------------------------------------------------------------
    // Byte regions
    // ------------------------------------------------------------------
    logic        world_bus_ready, tex_bus_ready;
    logic [31:0] world_bus_rdata, tex_bus_rdata;

    byte_bridge #(.AW(17)) u_world_bridge (
        .clk, .rst,
        .req(req && sel == R_WORLD), .we, .addr(addr[16:2]), .be, .wdata,
        .ready(world_bus_ready), .rdata(world_bus_rdata),
        .b_req(world_req), .b_we(world_we), .b_addr(world_addr), .b_wdata(world_wdata),
        .b_ready(world_ready), .b_rdata(world_rdata)
    );

    byte_bridge #(.AW(14)) u_tex_bridge (
        .clk, .rst,
        .req(req && sel == R_TEX), .we, .addr(addr[13:2]), .be, .wdata,
        .ready(tex_bus_ready), .rdata(tex_bus_rdata),
        .b_req(tex_req), .b_we(tex_we), .b_addr(tex_addr), .b_wdata(tex_wdata),
        .b_ready(tex_ready), .b_rdata(tex_rdata)
    );

    // The framebuffer is a word port with byte enables, always ready: an SW
    // or a merged group of lane stores (rtl/core/lsu.sv) writes four pixels.
    assign fb_we    = req && we && (sel == R_FB);
    assign fb_re    = req && !we && (sel == R_FB);
    assign fb_addr  = addr[16:0];
    assign fb_be    = be;
    assign fb_wdata = wdata;

    // ------------------------------------------------------------------
    // Handshake and read mux
    // ------------------------------------------------------------------
    always_comb begin
        unique case (sel)
            R_WORLD: ready = world_bus_ready;
            R_TEX:   ready = tex_bus_ready;
            R_MMIO:  ready = mmio_ready;
            default: ready = req;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst)                sel_q <= R_NONE;
        else if (req && ready)  sel_q <= we ? R_NONE : sel;
    end

    always_comb begin
        unique case (sel_q)
            R_DMEM:  rdata = dmem_rdata;
            R_GPU:   rdata = gpu_rdata;
            R_WORLD: rdata = world_bus_rdata;
            R_TEX:   rdata = tex_bus_rdata;
            R_FB:    rdata = fb_rdata;
            R_MMIO:  rdata = mmio_rdata;
            default: rdata = '0;
        endcase
    end

endmodule
