// World window memory (D17, Tai page, Memory & Display): two copies of
// 131,072 x 4 bits, physical addresses {y[4:0], z[5:0], x[5:0]} after
// world_remap. Each copy is one true dual-port BRAM array on the core clock.
//
//   port A  VTRACE while vt_busy, else the core (core_req), else the chunk
//           engine. Writes (core stores, engine LOADs) go to both copies at the
//           same address; core and engine reads come from copy 0 (a_rdata,
//           one cycle after the address).
//   port B  VTRACE only.
//
// VTRACE (WORLD_LATENCY = 2). Copy n serves lanes 4n..4n+3. vtrace takes a
// step every 2 cycles from its start edge, so vt_paddr holds one step's
// address A for the first two busy cycles and for each later pair. vt_phase
// alternates 0, 1 from the first busy cycle, i.e. it is 0 in the first cycle
// of A and 1 in the second:
//   phase 0  ports A and B of copy n read lanes 4n and 4n+1 at A;
//   phase 1  they read lanes 4n+2 and 4n+3 at A, and the phase-1 edge copies
//            the phase-0 data into hold_a / hold_b;
//   next     (phase 0 of the next step's address) every lane's vt_rdata is
//            A's data: 4n, 4n+1 from hold, 4n+2, 4n+3 straight from the BRAM
//            outputs. vtrace checks here. The next edge overwrites the
//            outputs, so lanes 4n+2, 4n+3 are valid for this cycle only.
// world_remap registers each lane's slot-valid bit every cycle from that
// lane's current address and applies it the next cycle. In the check cycle
// it comes from phase 1, still address A, so it matches both the hold data
// (read in phase 0 at A) and the output data (phase 1 at A), even though
// vt_paddr already shows the next step. A lane that finishes at a check moves
// its address back mid-step, but it never reads again. A walk is an odd number
// of busy cycles ending in phase 0, and busy low clears the phase, so every
// walk starts in phase 0.
//
// The chunk engine only drives eng_we / eng_re while vt_busy and core_req are
// both 0 (chunk_engine grant), so it never loses port A mid-access.
module world_mem #(
    parameter int LANES = 8
) (
    input  logic        clk,

    // VTRACE (physical addresses from world_remap)
    input  logic        vt_busy,
    input  logic [16:0] vt_paddr [LANES],
    output logic [3:0]  vt_rdata [LANES],

    // core (physical address from world_remap)
    input  logic        core_req,
    input  logic        core_we,
    input  logic [16:0] core_paddr,
    input  logic [3:0]  core_wdata,

    // chunk engine (physical addresses)
    input  logic        eng_we,
    input  logic [16:0] eng_addr,
    input  logic [3:0]  eng_wdata,

    // copy 0 port A read data (core and engine)
    output logic [3:0]  a_rdata
);
    localparam int COPIES = LANES / 4;

    logic vt_phase = 1'b0;

    always_ff @(posedge clk) vt_phase <= vt_busy && !vt_phase;

    logic [16:0] a_addr_w;
    logic        a_we;
    logic [3:0]  a_wdata;

    always_comb begin
        a_addr_w = core_req ? core_paddr : eng_addr;
        a_we     = !vt_busy && (core_req ? core_we : eng_we);
        a_wdata  = core_req ? core_wdata : eng_wdata;
    end

    logic [3:0] dout_a [COPIES];

    for (genvar c = 0; c < COPIES; c++) begin : g_copy
        (* ram_style = "block" *) logic [3:0] mem [131072];

        logic [16:0] addr_a, addr_b;
        logic [3:0]  dout_b, hold_a, hold_b;

        assign addr_a = vt_busy ? vt_paddr[4*c + (vt_phase ? 2 : 0)] : a_addr_w;
        assign addr_b = vt_paddr[4*c + (vt_phase ? 3 : 1)];

        always_ff @(posedge clk) begin
            if (a_we) mem[addr_a] <= a_wdata;
            dout_a[c] <= mem[addr_a];
        end

        always_ff @(posedge clk) dout_b <= mem[addr_b];

        always_ff @(posedge clk) begin
            if (vt_busy && vt_phase) begin
                hold_a <= dout_a[c];
                hold_b <= dout_b;
            end
        end

        assign vt_rdata[4*c]     = hold_a;
        assign vt_rdata[4*c + 1] = hold_b;
        assign vt_rdata[4*c + 2] = dout_a[c];
        assign vt_rdata[4*c + 3] = dout_b;
    end

    assign a_rdata = dout_a[0];

endmodule
