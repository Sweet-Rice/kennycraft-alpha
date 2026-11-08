// KennyCraft pipelined core (P8, Tai_2 section 7; Tai page, CPU Core,
// Pipelining plan and GPU Core, Pipelining notes): the same ISA, ports,
// parameters and retired-instruction trace as the multi-cycle rtl/core/core.sv,
// in five stages. rtl/core_pipe/lane_pipe.sv is one lane's datapath; the
// leaf modules (alu, reg_module, mul, qrcp, divstack, lsu, inst_decoder,
// immgen) are rtl/core's, unchanged.
//
//   IF   imem_addr = pc_f, a register (a redirect writes it: flush 2)
//   ID   the BRAM output (or d_hold, latched in the first cycle ID waits,
//        since the BRAM keeps reading pc_f), decode, every lane's register
//        read with the WB bypass. Illegal words and fetches outside imem
//        become a fault flag that halts in EX
//   EX   per-lane forwarding (MEM, else WB), ALU, branch compare, scalar
//        lane, uniform checks, divergence stack, mask, lane control, ray
//        unit configuration and start, misaligned check
//   MEM  the only stage that takes more than one cycle; EX, ID and IF wait
//        for it. MUL 2 cycles, QRCP 6 (load, four steps, result), VTRACE
//        until done plus one, loads and stores with an active lane: one
//        cycle per lane-serial bus access plus one. Retirement happens here
//   WB   every lane writes rd
//
// Hazards. Forwarding MEM -> EX and WB -> EX for every lane, gated by that
// lane's write enable, so an inactive lane sees its older value. A load in
// EX whose rd ID reads holds ID for one cycle (load-use). Branches, JAL and
// JALR resolve in EX (predict not taken) and flush ID and IF; so do LMASK,
// MASKSET, MASKALL, DIF, DELSE and DENDIF, so the mask and divergence stack
// that EX reads are always those of every older instruction (Tai page, GPU
// Core, Pipelining notes: read in ID, written in EX).
//
// Retirement (the retire_* wires, pc). An instruction retires in its last
// MEM cycle, a store with an active lane in the cycle the bus accepts its
// last lane, like the multi-cycle core. retire_mask is the mask register:
// while an instruction is in MEM, EX has not run anything younger. pc is the
// architectural PC (the next PC of the last retired instruction), so it
// steps through the same values as the multi-cycle pc; the fetch PC is pc_f.
//
// Halts. EX detects them (an ID fault: ILLEGAL; else DIVERGE, DIVSTACK,
// ILLEGAL, as in core.sv), runs no side effect, flushes ID and IF and stops
// fetching (pc_f freezes). The halt marker pulses err_set in MEM, after every
// older instruction has retired. err_pc is pc, as in core.sv: then the
// faulting instruction's PC, and it stays there while halted.
//
// state is an observation for the testbenches only: 4 (the multi-cycle
// S_MEM code) while MEM walks the lane-serial LSU, 6 (S_HALT) after a halt,
// 0 otherwise.
module core_pipe
    import kc_isa_pkg::*;
#(
    parameter int          LANES         = 1,
    parameter logic [31:0] RESET_VEC     = IMEM_BASE,
    parameter bit          HAS_DIV_STACK = 1'b0,
    parameter bit          HAS_RAY_UNIT  = 1'b0,
    parameter bit          HAS_QRCP      = 1'b0
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
    output logic [31:0]          pc,

    // Ray unit (HAS_RAY_UNIT = 1); outputs 0 and inputs ignored otherwise
    output logic                 vt_cfg_we,
    output logic [2:0]           vt_cfg_field,
    output logic [LANES-1:0]     vt_lane_mask,
    output logic [31:0]          vt_cfg_data [LANES],
    output logic                 vt_start,
    output logic [7:0]           vt_max_steps,
    input  logic                 vt_done,
    input  logic [15:0]          vt_result   [LANES],
    input  logic [16:0]          vt_hit_cell [LANES],
    input  logic [31:0]          vt_t_hit    [LANES]
);

    if (LANES < 1 || LANES > 8) begin : g_lanes_check
        $error("core_pipe: LANES must be 1 to 8");
    end

    localparam int LW = (LANES > 1) ? $clog2(LANES) : 1;

    // ------------------------------------------------------------------
    // Pipeline control
    // ------------------------------------------------------------------
    logic adv;        // MEM takes EX's instruction: EX, ID and IF move on
    logic lu;         // load-use: ID waits, EX gets a bubble
    logic flush;      // EX redirects or halts: drop ID and the fetch in flight
    logic stop;       // halted: nothing more is fetched
    logic m_valid, m_done, m_ready;
    logic e_valid, e_go, e_halt, e_redirect;
    logic [31:0] e_next;

    assign m_ready = !m_valid || m_done;
    assign adv     = m_ready;
    assign e_go    = e_valid && adv;
    assign flush   = e_go && (e_halt || e_redirect);

    // ------------------------------------------------------------------
    // IF / ID
    // ------------------------------------------------------------------
    logic [31:0] pc_f, d_pc, d_hold, d_inst;
    logic        d_valid, d_hold_v, d_ready;

    assign imem_addr = pc_f;
    assign d_inst    = d_hold_v ? d_hold : imem_rdata;
    assign d_ready   = !d_valid || (adv && !lu);

    // pc_f: a redirect writes it, otherwise it steps with ID until a halt
    // stops fetching. A halt does not touch its select: after a halt pc_f
    // is never decoded again.
    always_ff @(posedge clk) begin
        if (rst)                     pc_f <= RESET_VEC;
        else if (e_go && e_redirect) pc_f <= e_next;
        else if (d_ready && !stop)   pc_f <= pc_f + 32'd4;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            d_valid  <= 1'b0;
            d_hold_v <= 1'b0;
            stop     <= 1'b0;
        end else if (flush) begin
            d_valid  <= 1'b0;
            d_hold_v <= 1'b0;
            if (e_halt) stop <= 1'b1;
        end else if (d_ready) begin
            d_pc     <= pc_f;
            d_valid  <= !stop;
            d_hold_v <= 1'b0;
        end else if (!d_hold_v) begin
            d_hold   <= imem_rdata;
            d_hold_v <= 1'b1;
        end
    end

    logic [3:0]  d_alu_ctrl;
    logic        d_alu_a_pc, d_r_we, d_res_imm, d_is_load, d_is_store, d_is_mul;
    logic        d_is_branch, d_is_jal, d_is_jalr, d_is_lane, d_is_div, d_is_ray, d_is_qrcp;
    logic        d_uniform_wr, d_illegal;
    logic [1:0]  d_alu_b_sel;
    logic [2:0]  d_imm_sig;
    logic [31:0] d_imm;
    logic [4:0]  d_rs1, d_rs2;
    logic [6:0]  d_opc;
    logic        d_uses1, d_uses2;

    inst_decoder #(.HAS_DIV_STACK(HAS_DIV_STACK), .HAS_RAY_UNIT(HAS_RAY_UNIT),
                   .HAS_QRCP(HAS_QRCP)) u_dec (
        .inst(d_inst), .alu_ctrl(d_alu_ctrl), .alu_a_pc(d_alu_a_pc),
        .alu_b_sel(d_alu_b_sel), .imm_sig(d_imm_sig), .r_we(d_r_we),
        .res_imm(d_res_imm), .is_load(d_is_load), .is_store(d_is_store),
        .is_mul(d_is_mul), .is_branch(d_is_branch), .is_jal(d_is_jal),
        .is_jalr(d_is_jalr), .is_lane(d_is_lane), .is_div(d_is_div), .is_ray(d_is_ray),
        .is_qrcp(d_is_qrcp), .uniform_wr(d_uniform_wr), .illegal(d_illegal)
    );

    immgen u_imm (.inst(d_inst[31:7]), .imm_sig(d_imm_sig), .imm(d_imm));

    assign d_rs1 = instr_rs1(d_inst);
    assign d_rs2 = instr_rs2(d_inst);
    assign d_opc = instr_opcode(d_inst);
    // Operands an instruction reads, for the load-use stall only
    assign d_uses1 = (d_opc != OPC_LUI) && (d_opc != OPC_AUIPC) && (d_opc != OPC_JAL);
    assign d_uses2 = (d_opc == OPC_BRANCH) || (d_opc == OPC_STORE) || (d_opc == OPC_OP);

    // ID -> EX registers (shared decode; the operands live in the lanes)
    logic [3:0]  e_alu_ctrl;
    logic        e_alu_a_pc, e_r_we, e_res_imm, e_is_load, e_is_store, e_is_mul;
    logic        e_is_branch, e_is_jal, e_is_jalr, e_is_lane, e_is_div, e_is_ray, e_uniform_wr;
    logic        e_is_qrcp, e_fault;
    logic [1:0]  e_alu_b_sel;
    logic [2:0]  e_funct3, e_field;
    logic [4:0]  e_rd, e_rs1, e_rs2;
    logic [31:0] e_imm, e_pc, e_inst;

    always_ff @(posedge clk) begin
        if (rst)      e_valid <= 1'b0;
        else if (adv) e_valid <= d_valid && !lu && !flush;
    end

    always_ff @(posedge clk) begin
        if (adv) begin
            e_pc         <= d_pc;
            e_inst       <= d_inst;
            e_fault      <= d_illegal || is_fetch_outside_imem(d_pc);
            e_alu_ctrl   <= d_alu_ctrl;
            e_alu_a_pc   <= d_alu_a_pc;
            e_alu_b_sel  <= d_alu_b_sel;
            e_r_we       <= d_r_we && (instr_rd(d_inst) != 5'd0);
            e_res_imm    <= d_res_imm;
            e_is_load    <= d_is_load;
            e_is_store   <= d_is_store;
            e_is_mul     <= d_is_mul;
            e_is_branch  <= d_is_branch;
            e_is_jal     <= d_is_jal;
            e_is_jalr    <= d_is_jalr;
            e_is_lane    <= d_is_lane;
            e_is_div     <= d_is_div;
            e_is_ray     <= d_is_ray;
            e_is_qrcp    <= d_is_qrcp;
            e_uniform_wr <= d_uniform_wr;
            e_funct3     <= instr_funct3(d_inst);
            e_field      <= d_inst[27:25];   // funct7[2:0]
            e_rd         <= instr_rd(d_inst);
            e_rs1        <= d_rs1;
            e_rs2        <= d_rs2;
            e_imm        <= d_imm;
        end
    end

    assign lu = d_valid && e_valid && e_is_load && e_r_we &&
                ((d_uses1 && (d_rs1 == e_rd)) || (d_uses2 && (d_rs2 == e_rd)));

    // ------------------------------------------------------------------
    // MEM / WB registers that the lanes' forwarding needs
    // ------------------------------------------------------------------
    logic [LANES-1:0] mask;
    logic             m_halt, m_r_we, m_nowr, m_uniform_wr, m_wr;
    logic [4:0]       m_rd, w_rd;
    logic [LANES-1:0] m_we, w_we;

    // MEM writes rd in lane i when the lane is active after the
    // instruction's own EX (the mask register now) or the write is uniform.
    assign m_wr = m_valid && !m_halt && m_r_we && !m_nowr;
    for (genvar i = 0; i < LANES; i++) begin : g_m_we
        assign m_we[i] = m_wr && (mask[i] || m_uniform_wr);
    end

    // ------------------------------------------------------------------
    // Lanes
    // ------------------------------------------------------------------
    logic [31:0]      lane_y;
    logic [31:0]      l_rs1 [LANES];
    logic [31:0]      l_alu [LANES];
    logic [31:0]      l_res [LANES];
    logic [31:0]      l_mrs2 [LANES];
    logic [31:0]      l_wdata [LANES];
    logic [31:0]      ray_y [LANES];
    logic [31:0]      vt_y [LANES];
    logic [LANES-1:0] l_cmp, nonzero, ld_cap, mis;
    logic [31:0]      ld_value;
    logic             e_vget, e_stash;
    logic             m_is_load, m_is_store, m_mul, m_qr, m_vt;
    logic [2:0]       m_funct3, m_cnt;
    logic             mul_en, qr_load, qr_en, vt_wr;
    logic [2:0]       qr_ph;

    logic fm1, fm2, fw1, fw2, d_wb1, d_wb2;
    assign fm1   = m_wr && (m_rd == e_rs1);
    assign fm2   = m_wr && (m_rd == e_rs2);
    assign fw1   = (w_rd == e_rs1);
    assign fw2   = (w_rd == e_rs2);
    assign d_wb1 = (w_rd == d_rs1);
    assign d_wb2 = (w_rd == d_rs2);

    assign e_stash = e_is_mul || e_is_qrcp;

    for (genvar i = 0; i < LANES; i++) begin : g_lane
        lane_pipe #(.ID(i), .HAS_QRCP(HAS_QRCP)) u_lane (
            .clk,
            .rs1_addr(d_rs1), .rs2_addr(d_rs2), .d_wb1, .d_wb2, .adv,
            .fm1, .fm2, .fw1, .fw2,
            .ex_go(e_go), .alu_ctrl(e_alu_ctrl), .alu_a_pc(e_alu_a_pc),
            .alu_b_sel(e_alu_b_sel), .funct3(e_funct3), .pc(e_pc), .imm(e_imm),
            .res_imm(e_res_imm), .is_lane(e_is_lane), .lane_y, .ray_en(e_vget),
            .ray_y(ray_y[i]), .stash(e_stash),
            .rs1(l_rs1[i]), .alu_y(l_alu[i]), .cmp(l_cmp[i]),
            .mul_op(m_funct3[1:0]), .m_is_load, .mul_en, .m_mul, .qr_load, .qr_en, .qr_ph, .m_qr,
            .vt_wr, .vt_y(vt_y[i]), .ld_cap(ld_cap[i]), .ld_value, .m_we(m_we[i]),
            .res(l_res[i]), .m_rs2(l_mrs2[i]), .wdata(l_wdata[i]),
            .w_we(w_we[i]), .w_rd
        );

        assign nonzero[i] = (l_rs1[i] != 32'd0);
        assign mis[i]     = is_misaligned(e_funct3, l_alu[i][1:0]);
    end

    // ------------------------------------------------------------------
    // EX: scalar lane, branch, uniform checks, divergence stack, mask
    // ------------------------------------------------------------------
    logic [LW-1:0]    sl;           // scalar lane: lowest active, 0 when M = 0
    logic [31:0]      target;
    logic             take;
    logic [LANES-1:0] l_taken;
    logic [31:0]      l_jt [LANES];
    logic [LANES-1:0] jt_diff;
    logic             e_diverge, e_divstack, e_illegal, e_mem;
    logic             ds_err, ds_jump;
    logic [LANES-1:0] ds_mask, mask_d;
    logic             mask_we;
    logic [ERR_WIDTH-1:0] e_err;

    always_comb begin
        sl = '0;
        for (int i = LANES - 1; i >= 0; i--)
            if (mask[i]) sl = LW'(i);
    end

    for (genvar i = 0; i < LANES; i++) begin : g_uniform
        assign l_taken[i] = l_cmp[i] ^ e_funct3[0];
        assign l_jt[i]    = (l_rs1[i] + e_imm) & ~32'd1;
        assign jt_diff[i] = (l_jt[i] != l_jt[sl]);
    end

    assign e_diverge = (e_is_branch && ((l_taken & mask) != '0) && ((l_taken & mask) != mask)) ||
                       (e_is_jalr && ((jt_diff & mask) != '0));

    if (HAS_DIV_STACK) begin : g_divstack
        divstack #(.LANES(LANES)) u_divstack (
            .clk, .rst,
            .op(e_funct3), .mask, .cond(nonzero),
            .step(e_go && e_is_div && !e_halt),
            .err(ds_err), .mask_d(ds_mask), .jump(ds_jump)
        );
    end else begin : g_no_divstack
        assign ds_err  = 1'b0;
        assign ds_mask = '0;
        assign ds_jump = 1'b0;
    end

    assign e_divstack = e_is_div && ds_err;

    assign take   = e_is_jal || e_is_jalr || (e_is_branch && l_taken[sl]) ||
                    (e_is_div && ds_jump);
    assign target = e_is_jalr ? l_jt[sl] : (e_pc + e_imm);
    assign e_next = take ? target : e_pc + 32'd4;

    always_comb begin
        lane_y  = 32'd0;
        mask_d  = mask;
        mask_we = 1'b0;
        if (e_is_div) begin
            mask_d  = ds_mask;
            mask_we = 1'b1;
        end else if (e_is_lane) begin
            unique case (e_funct3)
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

    // A taken jump to a target with bit 1 set halts at the jump (D16). An
    // ID fault halts with ILLEGAL only; otherwise DIVERGE, then DIVSTACK,
    // then ILLEGAL (core.sv).
    assign e_mem     = (e_is_load || e_is_store) && (mask != '0);
    assign e_illegal = !e_diverge && !e_divstack &&
                       ((e_mem && ((mis & mask) != '0)) || (take && target[1]));
    assign e_halt    = e_fault || e_diverge || e_divstack || e_illegal;

    // LSU start. A load or store halts only on e_fault or a misaligned
    // active lane (no DIVERGE, DIVSTACK or jump), so this equals
    // e_go && e_mem && !e_halt without the uniform-check cone.
    logic e_lsu_go;
    assign e_lsu_go = e_go && e_mem && !e_fault && ((mis & mask) == '0);

    always_comb begin
        e_err = '0;
        e_err[ERR_ILLEGAL]  = e_fault || e_illegal;
        e_err[ERR_DIVERGE]  = !e_fault && e_diverge;
        e_err[ERR_DIVSTACK] = !e_fault && e_divstack;
    end

    assign e_redirect = take || mask_we;

    always_ff @(posedge clk) begin
        if (rst)                             mask <= LANES'(1);
        else if (e_go && !e_halt && mask_we) mask <= mask_d;
    end

    // ------------------------------------------------------------------
    // Ray unit (custom-1)
    // ------------------------------------------------------------------
    logic e_vtrace, e_nowr;

    if (HAS_RAY_UNIT) begin : g_ray
        logic [7:0] cap;

        assign e_vtrace = e_is_ray && (e_funct3 == F3_VTRACE);
        assign e_vget   = e_is_ray && (e_funct3 == F3_VGET);
        assign cap      = l_rs1[sl][7:0];
        assign e_nowr   = e_vtrace && (cap == 8'd0);

        assign vt_lane_mask = mask;
        // A custom-1 instruction halts only on e_fault (DIVERGE, DIVSTACK
        // and the EX ILLEGAL cases need a branch, JALR, DIF/DELSE/DENDIF or
        // a load/store), so the strobes skip the forward/uniform-check cone.
        assign vt_cfg_we    = e_go && !e_fault && e_is_ray && (e_funct3 == F3_VSET);
        assign vt_cfg_field = e_field;
        assign vt_cfg_data  = l_rs1;
        assign vt_start     = e_go && !e_fault && e_vtrace;
        assign vt_max_steps = cap;
        assign vt_wr        = m_valid && m_vt && vt_done;

        for (genvar i = 0; i < LANES; i++) begin : g_y
            assign ray_y[i] = e_field[0] ? vt_t_hit[i] : {15'd0, vt_hit_cell[i]};
            assign vt_y[i]  = {16'd0, vt_result[i]};
        end
    end else begin : g_no_ray
        assign e_vtrace     = 1'b0;
        assign e_vget       = 1'b0;
        assign e_nowr       = 1'b0;
        assign vt_lane_mask = '0;
        assign vt_cfg_we    = 1'b0;
        assign vt_cfg_field = '0;
        assign vt_start     = 1'b0;
        assign vt_max_steps = '0;
        assign vt_wr        = 1'b0;
        for (genvar i = 0; i < LANES; i++) begin : g_y
            assign vt_cfg_data[i] = '0;
            assign ray_y[i]       = '0;
            assign vt_y[i]        = '0;
        end

        /* verilator lint_off UNUSEDSIGNAL */
        logic unused_ray;
        /* verilator lint_on UNUSEDSIGNAL */
        always_comb begin
            unused_ray = vt_done ^ e_is_ray ^ (^e_field);
            for (int i = 0; i < LANES; i++)
                unused_ray ^= (^vt_result[i]) ^ (^vt_hit_cell[i]) ^ (^vt_t_hit[i]);
        end
    end

    // ------------------------------------------------------------------
    // MEM
    // ------------------------------------------------------------------
    logic [ERR_WIDTH-1:0] m_err;
    logic [31:0]          m_pc, m_inst, m_next;
    logic                 m_walk, m_tail, m_vt_tail, m_mem, lsu_done;
    logic                 retire_valid;

    always_ff @(posedge clk) begin
        if (rst) begin
            m_valid <= 1'b0;
            m_walk  <= 1'b0;
        end else if (m_ready) begin
            m_valid <= e_valid;
            m_walk  <= e_lsu_go;
        end else if (lsu_done) begin
            m_walk  <= 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        if (m_ready) begin
            m_halt       <= e_halt;
            m_err        <= e_err;
            m_pc         <= e_pc;
            m_inst       <= e_inst;
            m_next       <= e_next;
            m_rd         <= e_rd;
            m_r_we       <= e_r_we;
            m_nowr       <= e_nowr;
            m_uniform_wr <= e_uniform_wr;
            m_is_load    <= e_is_load;
            m_is_store   <= e_is_store;
            m_funct3     <= e_funct3;
            m_mem        <= e_mem;
            m_mul        <= e_is_mul;
            m_qr         <= HAS_QRCP && e_is_qrcp;
            m_vt         <= e_vtrace;
            m_cnt        <= '0;
            m_tail       <= 1'b0;
            m_vt_tail    <= 1'b0;
        end else begin
            if (m_cnt != 3'd7) m_cnt <= m_cnt + 3'd1;
            if (lsu_done)      m_tail <= 1'b1;
            if (vt_wr)         m_vt_tail <= 1'b1;
        end
    end

    // MUL: the product of MEM's registered operands, ready the cycle after.
    // QRCP: load, four steps, then the result in the sixth cycle.
    assign mul_en  = m_valid && m_mul && (m_cnt == 3'd0);
    assign qr_load = m_valid && m_qr && (m_cnt == 3'd0);
    assign qr_en   = m_valid && m_qr && (m_cnt != 3'd0) && (m_cnt <= 3'd4);
    assign qr_ph   = m_cnt - 3'd1;

    always_comb begin
        if (m_halt)          m_done = 1'b1;
        else if (m_mem)      m_done = m_tail;
        else if (m_mul)      m_done = (m_cnt == 3'd1);
        else if (m_qr)       m_done = (m_cnt == 3'd5);
        else if (m_vt)       m_done = m_vt_tail;
        else                 m_done = 1'b1;
    end

    /* verilator lint_off UNUSEDSIGNAL */
    logic [LANES-1:0] lsu_mis;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [1:0] lsu_lo [LANES];
    always_comb for (int i = 0; i < LANES; i++) lsu_lo[i] = 2'b00;

    // The misaligned check is EX's (mis above); the LSU's own check would
    // look at MEM's funct3.
    lsu #(.LANES(LANES)) u_lsu (
        .clk, .rst,
        .start(e_lsu_go), .active(mask),
        .go(m_walk), .is_store(m_is_store), .funct3(m_funct3),
        .addr(l_res), .rs2(l_mrs2), .done(lsu_done),
        .ex_addr_lo(lsu_lo), .misaligned(lsu_mis),
        .bus_req, .bus_we, .bus_addr, .bus_be, .bus_wdata, .bus_ready, .bus_rdata,
        .ld_cap, .ld_value
    );

    // ------------------------------------------------------------------
    // WB
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) w_we <= '0;
        else     w_we <= m_done ? m_we : '0;
        w_rd <= m_rd;
    end

    // ------------------------------------------------------------------
    // Retirement, PC and errors
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst)               pc <= RESET_VEC;
        else if (retire_valid) pc <= m_next;
    end

    always_ff @(posedge clk) begin
        if (rst)                  halted <= 1'b0;
        else if (err_set != '0)   halted <= 1'b1;
    end

    assign err_set = (m_valid && m_halt) ? m_err : '0;
    assign err_pc  = pc;

    /* verilator lint_off UNUSEDSIGNAL */
    logic [3:0]       state;
    logic [31:0]      retire_pc;
    logic [31:0]      retire_inst;
    logic             retire_rd_we;
    logic [4:0]       retire_rd_addr;
    logic [31:0]      retire_rd_wdata;
    logic [LANES-1:0] retire_mask;
    logic [LANES-1:0] retire_lane_we;
    logic [31:0]      retire_lane_wdata [LANES];
    /* verilator lint_on UNUSEDSIGNAL */

    assign state = halted ? 4'd6 : m_walk ? 4'd4 : 4'd0;

    assign retire_valid      = m_valid && !m_halt &&
                               ((m_mem && m_is_store) ? lsu_done : m_done);
    assign retire_pc         = m_pc;
    assign retire_inst       = m_inst;
    assign retire_lane_we    = retire_valid ? m_we : '0;
    assign retire_rd_we      = retire_lane_we[0];
    assign retire_rd_addr    = m_rd;
    assign retire_rd_wdata   = l_wdata[0];
    assign retire_mask       = mask;
    assign retire_lane_wdata = l_wdata;

endmodule
