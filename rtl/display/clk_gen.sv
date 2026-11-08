// Clock generation (Tai page, CPU Core, Clocking).
//   clk      100 MHz board oscillator (pin E3)
//   clk_core  1000 / CORE_DIV MHz (50 by default, 100 with CORE_DIV = 10):
//             core, memories (port A), UART, VTRACE
//   clk_pix   25 MHz: VGA timing, framebuffer port B, palette read
// One MMCME2_BASE: VCO = 100 MHz x 10 = 1000 MHz, /CORE_DIV -> core,
// /40 -> 25 MHz.
//
// rst_core and rst_pix are active high. They assert asynchronously while the
// MMCM is unlocked or rst_n (the board's ck_rst button, active low) is low,
// and release synchronously, two edges after the cause clears, in their own
// clock domain. Logic in each domain uses them as synchronous resets.
//
// Under Verilator the MMCM is replaced by a behavioural divider with the same
// ratios (clk_core = clk / 2, or clk itself with CORE_DIV = 10; clk_pix =
// clk / 4) and a locked output that rises after 16 input clocks, so `make vl`
// can run the real top.
module clk_gen #(
    parameter int CORE_DIV = 20   // MMCM CLKOUT0 divider: 20 -> 50 MHz, 10 -> 100 MHz
) (
    input  logic clk,
    input  logic rst_n,
    output logic clk_core,
    output logic clk_pix,
    output logic locked,
    output logic rst_core,
    output logic rst_pix
);
`ifdef VERILATOR
    logic [1:0] div = 2'd0;
    logic [4:0] lock_cnt = 5'd0;

    always_ff @(posedge clk) begin
        div <= div + 2'd1;
        if (!lock_cnt[4]) lock_cnt <= lock_cnt + 5'd1;
    end

    assign clk_core = (CORE_DIV == 10) ? clk : div[0];
    assign clk_pix  = div[1];
    assign locked   = lock_cnt[4];
`else
    logic clkfb_out, clkfb_in, clk0_raw, clk1_raw;

    MMCME2_BASE #(
        .BANDWIDTH        ("OPTIMIZED"),
        .CLKIN1_PERIOD    (10.0),
        .DIVCLK_DIVIDE    (1),
        .CLKFBOUT_MULT_F  (10.0),
        .CLKFBOUT_PHASE   (0.0),
        .CLKOUT0_DIVIDE_F (real'(CORE_DIV)),
        .CLKOUT0_PHASE    (0.0),
        .CLKOUT0_DUTY_CYCLE(0.5),
        .CLKOUT1_DIVIDE   (40),
        .CLKOUT1_PHASE    (0.0),
        .CLKOUT1_DUTY_CYCLE(0.5),
        .STARTUP_WAIT     ("FALSE")
    ) u_mmcm (
        .CLKIN1   (clk),
        .CLKFBIN  (clkfb_in),
        .CLKFBOUT (clkfb_out),
        .CLKFBOUTB(),
        .CLKOUT0  (clk0_raw),
        .CLKOUT0B (),
        .CLKOUT1  (clk1_raw),
        .CLKOUT1B (),
        .CLKOUT2  (),
        .CLKOUT2B (),
        .CLKOUT3  (),
        .CLKOUT3B (),
        .CLKOUT4  (),
        .CLKOUT5  (),
        .CLKOUT6  (),
        .LOCKED   (locked),
        .PWRDWN   (1'b0),
        .RST      (1'b0)
    );

    BUFG u_bufg_fb   (.I(clkfb_out), .O(clkfb_in));
    BUFG u_bufg_core (.I(clk0_raw),  .O(clk_core));
    BUFG u_bufg_pix  (.I(clk1_raw),  .O(clk_pix));
`endif

    logic arst;
    assign arst = !locked || !rst_n;

    // Async-assert, sync-release reset per domain.
    (* ASYNC_REG = "TRUE" *) logic [1:0] rst_core_sr = 2'b11;
    (* ASYNC_REG = "TRUE" *) logic [1:0] rst_pix_sr  = 2'b11;

    always_ff @(posedge clk_core or posedge arst) begin
        if (arst) rst_core_sr <= 2'b11;
        else      rst_core_sr <= {rst_core_sr[0], 1'b0};
    end

    always_ff @(posedge clk_pix or posedge arst) begin
        if (arst) rst_pix_sr <= 2'b11;
        else      rst_pix_sr <= {rst_pix_sr[0], 1'b0};
    end

    assign rst_core = rst_core_sr[1];
    assign rst_pix  = rst_pix_sr[1];
endmodule
