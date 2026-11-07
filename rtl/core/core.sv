// KennyCraft core, Stage 1: multi-cycle RV32I + Zmmul + custom-0 lane
// control on LANES SIMD lanes with one shared control path (Tai page, GPU
// Core; Tai_2 sections 1 and 2).
//
// Grown from Tai's multicycle core (datapath.sv in RISC-V-Core-progression).
// No pipeline registers, no forwarding, no hazard logic. One FSM walks every
// instruction through the states of the Tai page, GPU Core, SIMD state
// machine:
//
//   IF    send PC to the instruction BRAM                          1 cycle
//   ID    instruction arrives, decode once, read every lane's registers
//   EX    every lane's ALU, comparator, address generator, multiply;
//         lane control updates the mask                             1
//   MUL   second EXECUTE cycle for MUL family (registered product) 1
//   MEM   lane-serial LSU, one bus access per active lane, ascending
//         order; stores retire on the last lane's access           N + slave wait
//   WB    every lane writes rd together (the last load lane's data
//         arrives here), update PC                                  1
//
// Shared state here: PC, fetch, decode, FSM, the LANES-bit active mask (reset
// 1) and the scalar-lane mux. rtl/core/lane.sv is one lane's datapath and
// rtl/core/lsu.sv the lane-serial LSU.
//
// Lane control (custom-0). LANEID returns the lane index, LMASK clears the
// bits of lanes whose rs1 = 0, MASKSET keeps rs1[LANES-1:0] of the scalar
// lane, MASKALL sets every bit, BALLOT ({0, M & rs1 != 0}) and MASKGET ({0,
// M}) write rd in every lane, zero-extended. Lane n writes rd when
// wb_en & (M[n] | uniform_write) & (rd != 0), uniform_write being BALLOT and
// MASKGET only. Loads and stores access memory for active lanes only, so an
// inactive lane's misaligned address raises no error.
//
// Scalar lane: the lowest active lane, lane 0 when M = 0. Branch decisions and
// JALR targets come from it (the uniform checks across lanes are P5).
// custom-2 (divergence stack, P5) and custom-1 (ray unit, Stage 2) are absent
// in this build and decode as illegal.
//
// Errors (Tai_2 sections 1 and 2). An illegal instruction (caught in ID), a
// fetch outside instruction memory or from a PC that is not 4-aligned (ID), or
// a misaligned load/store in any active lane (EX, before any bus access)
// pulses err_set[ERR_ILLEGAL] with err_pc = the instruction's PC and parks the
// FSM in HALT until reset: nothing is fetched or written.
//
// Buses. imem_rdata is the instruction BRAM output for imem_addr one cycle
// earlier. On the data bus, bus_req is held until bus_ready; the access
// happens once in the bus_req && bus_ready cycle and load data is valid in
// bus_rdata the cycle after.
module core
    import kc_isa_pkg::*;
#(
    parameter int          LANES         = 1,
    parameter logic [31:0] RESET_VEC     = IMEM_BASE,
    parameter bit          HAS_DIV_STACK = 1'b0,
    parameter bit          HAS_RAY_UNIT  = 1'b0
) (
    input  logic                 clk,
    input  logic                 rst,

    output logic [31:0]          imem_addr,
    input  logic [31:0]          imem_rdata,

    output logic                 bus_req,
    output logic                 bus_we,
    output logic [31:0]          bus_addr,
    output logic [3:0]           bus_be,
    output logic [31:0]          bus_wdata,
    input  logic                 bus_ready,
    input  logic [31:0]          bus_rdata,

    output logic [ERR_WIDTH-1:0] err_set,
    output logic [31:0]          err_pc,
    output logic                 halted,
    output logic [31:0]          pc
);

    if (LANES < 1 || LANES > 8) begin : g_lanes_check
        $error("core: LANES must be 1 to 8");
    end
    if (HAS_DIV_STACK || HAS_RAY_UNIT) begin : g_unit_check
        $error("core: the divergence stack and the ray unit are not built yet");
    end

    localparam int LW = (LANES > 1) ? $clog2(LANES) : 1;

    typedef enum logic [2:0] {
        S_IF, S_ID, S_EX, S_MUL, S_MEM, S_WB, S_HALT
    } state_t;

    state_t state;

    // ------------------------------------------------------------------
    // ID: decode the BRAM output once
    // ------------------------------------------------------------------
    logic [3:0]  d_alu_ctrl;
    logic        d_alu_a_pc, d_r_we, d_res_imm, d_is_load, d_is_store, d_is_mul;
    logic        d_is_branch, d_is_jal, d_is_jalr, d_is_lane, d_uniform_wr, d_illegal;
    logic [1:0]  d_alu_b_sel;
    logic [2:0]  d_imm_sig;
    logic [31:0] d_imm;
    logic        id_fault;

    inst_decoder #(.HAS_DIV_STACK(HAS_DIV_STACK), .HAS_RAY_UNIT(HAS_RAY_UNIT)) u_dec (
        .inst(imem_rdata), .alu_ctrl(d_alu_ctrl), .alu_a_pc(d_alu_a_pc),
        .alu_b_sel(d_alu_b_sel), .imm_sig(d_imm_sig), .r_we(d_r_we),
        .res_imm(d_res_imm), .is_load(d_is_load), .is_store(d_is_store),
        .is_mul(d_is_mul), .is_branch(d_is_branch), .is_jal(d_is_jal),
        .is_jalr(d_is_jalr), .is_lane(d_is_lane), .uniform_wr(d_uniform_wr),
        .illegal(d_illegal)
    );

    immgen u_imm (.inst(imem_rdata[31:7]), .imm_sig(d_imm_sig), .imm(d_imm));

    assign id_fault = d_illegal || is_fetch_outside_imem(pc) || is_fetch_misaligned(pc);

    // ID -> EX registers (shared decode; the operands live in the lanes)
    logic [3:0]  ex_alu_ctrl;
    logic        ex_alu_a_pc, ex_r_we, ex_res_imm, ex_is_load, ex_is_store, ex_is_mul;
    logic        ex_is_branch, ex_is_jal, ex_is_jalr, ex_is_lane, ex_uniform_wr;
    logic [1:0]  ex_alu_b_sel;
    logic [2:0]  ex_funct3;
    logic [4:0]  ex_rd;
    logic [31:0] ex_imm;
    logic [31:0] ir;          // instruction in flight, for the retire wires

    always_ff @(posedge clk) begin
        if (state == S_ID) begin
            ir            <= imem_rdata;
            ex_alu_ctrl   <= d_alu_ctrl;
            ex_alu_a_pc   <= d_alu_a_pc;
            ex_alu_b_sel  <= d_alu_b_sel;
            ex_r_we       <= d_r_we && (instr_rd(imem_rdata) != 5'd0);
            ex_res_imm    <= d_res_imm;
            ex_is_load    <= d_is_load;
            ex_is_store   <= d_is_store;
            ex_is_mul     <= d_is_mul;
            ex_is_branch  <= d_is_branch;
            ex_is_jal     <= d_is_jal;
            ex_is_jalr    <= d_is_jalr;
            ex_is_lane    <= d_is_lane;
            ex_uniform_wr <= d_uniform_wr;
            ex_funct3     <= instr_funct3(imem_rdata);
            ex_rd         <= instr_rd(imem_rdata);
            ex_imm        <= d_imm;
        end
    end

    // ------------------------------------------------------------------
    // Lanes
    // ------------------------------------------------------------------
    logic [LANES-1:0] mask, mask_d;
    logic             mask_we;
    logic [31:0]      lane_y;                 // BALLOT / MASKGET result
    logic [31:0]      l_rs1 [LANES];
    logic [31:0]      l_rs2 [LANES];
    logic [31:0]      l_alu [LANES];
    logic [31:0]      l_res [LANES];
    logic [31:0]      l_wdata [LANES];
    logic [1:0]       l_addr_lo [LANES];
    logic [LANES-1:0] l_cmp, l_we, nonzero, ld_cap, mis;
    logic [31:0]      ld_value;
    logic             wb_en;

    assign wb_en = (state == S_WB) && ex_r_we;

    for (genvar i = 0; i < LANES; i++) begin : g_lane
        lane #(.ID(i)) u_lane (
            .clk,
            .id_en(state == S_ID),
            .rs1_addr(instr_rs1(imem_rdata)), .rs2_addr(instr_rs2(imem_rdata)),
            .ex_en(state == S_EX), .mul_en(state == S_MUL),
            .alu_ctrl(ex_alu_ctrl), .alu_a_pc(ex_alu_a_pc), .alu_b_sel(ex_alu_b_sel),
            .funct3(ex_funct3), .pc, .imm(ex_imm), .res_imm(ex_res_imm),
            .is_lane(ex_is_lane), .lane_y,
            .rs1(l_rs1[i]), .rs2(l_rs2[i]), .alu_y(l_alu[i]), .cmp(l_cmp[i]), .res(l_res[i]),
            .ld_cap(ld_cap[i]), .ld_value,
            .we(l_we[i]), .rd(ex_rd), .is_load(ex_is_load), .wdata(l_wdata[i])
        );

        assign nonzero[i]   = (l_rs1[i] != 32'd0);
        assign l_we[i]      = wb_en && (mask[i] || ex_uniform_wr);
        assign l_addr_lo[i] = l_alu[i][1:0];
    end

    // ------------------------------------------------------------------
    // EX: scalar lane, branch, mask
    // ------------------------------------------------------------------
    logic [LW-1:0] sl;           // scalar lane: lowest active, 0 when M = 0
    logic [31:0]   target;
    logic          take;

    always_comb begin
        sl = '0;
        for (int i = LANES - 1; i >= 0; i--)
            if (mask[i]) sl = LW'(i);
    end

    // funct3[0] inverts the comparator (BNE, BGE, BGEU).
    assign take   = ex_is_jal || ex_is_jalr || (ex_is_branch && (l_cmp[sl] ^ ex_funct3[0]));
    assign target = ex_is_jalr ? ((l_rs1[sl] + ex_imm) & ~32'd1) : (pc + ex_imm);

    always_comb begin
        lane_y  = 32'd0;
        mask_d  = mask;
        mask_we = 1'b0;
        if (ex_is_lane) begin
            unique case (ex_funct3)
                F3_LMASK: begin
                    mask_d  = mask & nonzero;
                    mask_we = 1'b1;
                end
                F3_BALLOT:  lane_y = {{(32-LANES){1'b0}}, mask & nonzero};
                F3_MASKGET: lane_y = {{(32-LANES){1'b0}}, mask};
                F3_MASKSET: begin
                    mask_d  = l_rs1[sl][LANES-1:0];
                    mask_we = 1'b1;
                end
                F3_MASKALL: begin
                    mask_d  = '1;
                    mask_we = 1'b1;
                end
                default: ;   // LANEID: each lane returns its own index
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (rst)                               mask <= LANES'(1);
        else if (state == S_EX && mask_we)     mask <= mask_d;
    end

    logic [31:0] next_pc;

    always_ff @(posedge clk) begin
        if (state == S_EX) next_pc <= take ? target : pc + 32'd4;
    end

    // ------------------------------------------------------------------
    // MEM: lane-serial LSU
    // ------------------------------------------------------------------
    logic ex_mem, ex_fault, lsu_done;

    assign ex_mem   = (ex_is_load || ex_is_store) && (mask != '0);
    assign ex_fault = ex_mem && ((mis & mask) != '0);

    lsu #(.LANES(LANES)) u_lsu (
        .clk, .rst,
        .start((state == S_EX) && ex_mem && !ex_fault), .active(mask),
        .go(state == S_MEM), .is_store(ex_is_store), .funct3(ex_funct3),
        .addr(l_res), .rs2(l_rs2), .done(lsu_done),
        .ex_addr_lo(l_addr_lo), .misaligned(mis),
        .bus_req, .bus_we, .bus_addr, .bus_be, .bus_wdata, .bus_ready, .bus_rdata,
        .ld_cap, .ld_value
    );

    // ------------------------------------------------------------------
    // FSM, PC and errors
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_IF;
            pc    <= RESET_VEC;
        end else begin
            unique case (state)
                S_IF:  state <= S_ID;
                S_ID:  state <= id_fault ? S_HALT : S_EX;
                S_EX: begin
                    if (ex_fault)                        state <= S_HALT;
                    else if (ex_is_mul)                  state <= S_MUL;
                    else if (ex_mem)                     state <= S_MEM;
                    else                                 state <= S_WB;
                end
                S_MUL: state <= S_WB;
                S_MEM: begin
                    if (lsu_done) begin
                        if (ex_is_store) begin
                            state <= S_IF;
                            pc    <= next_pc;
                        end else begin
                            state <= S_WB;
                        end
                    end
                end
                S_WB: begin
                    state <= S_IF;
                    pc    <= next_pc;
                end
                default: state <= S_HALT;
            endcase
        end
    end

    assign imem_addr = pc;
    assign halted    = (state == S_HALT);
    assign err_pc    = pc;

    always_comb begin
        err_set = '0;
        err_set[ERR_ILLEGAL] = ((state == S_ID) && id_fault) || ((state == S_EX) && ex_fault);
    end

    // ------------------------------------------------------------------
    // Retire observation wires for Verilator harnesses and traces (not used
    // by any logic). One retire per instruction: stores in the cycle the bus
    // accepts the last lane, everything else in WB. A halting instruction
    // never retires. retire_mask is the active mask at retirement. The
    // retire_rd_* wires are lane 0's write; retire_lane_we/wdata carry every
    // lane's (rd is retire_rd_addr in all of them).
    // ------------------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */
    logic             retire_valid;
    logic [31:0]      retire_pc;
    logic [31:0]      retire_inst;
    logic             retire_rd_we;
    logic [4:0]       retire_rd_addr;
    logic [31:0]      retire_rd_wdata;
    logic [LANES-1:0] retire_mask;
    logic [LANES-1:0] retire_lane_we;
    logic [31:0]      retire_lane_wdata [LANES];
    /* verilator lint_on UNUSEDSIGNAL */

    assign retire_valid      = (state == S_WB) || ((state == S_MEM) && lsu_done && ex_is_store);
    assign retire_pc         = pc;
    assign retire_inst       = ir;
    assign retire_rd_we      = l_we[0];
    assign retire_rd_addr    = ex_rd;
    assign retire_rd_wdata   = l_wdata[0];
    assign retire_mask       = mask;
    assign retire_lane_we    = l_we;
    assign retire_lane_wdata = l_wdata;

endmodule
