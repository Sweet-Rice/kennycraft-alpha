// KennyCraft pipelined core (P8, Tai_2 section 7; Tai page, CPU Core,
// Pipelining plan and GPU Core, Pipelining notes): the same ISA, ports,
// parameters and retired-instruction trace as the multi-cycle rtl/core/core.sv,
// in five stages. rtl/core_pipe/lane_pipe.sv is one lane's datapath; the
// leaf modules (alu, reg_module, divstack, inst_decoder, immgen) are
// rtl/core's, unchanged; QRCP is rtl/core_pipe/qrcp_pipe.sv, the
// two-cycle multiplier rtl/core_pipe/mul_pipe.sv and the LSU, rtl/core/lsu.sv with a
// registered bus request, rtl/core_pipe/lsu_pipe.sv.
//
//   IF   imem_addr = pc_f, a register (a redirect writes it: flush 4), and
//        the branch target buffer lookup of pc_f (rtl/core_pipe/btb.sv)
//        that picks the next pc_f; f_tgt - pc_f for ID's target check
//   F2   the imem BRAM read: imem_rdata (or q_hold, latched in the first
//        cycle F2 waits, since the BRAM keeps reading pc_f) goes into the
//        register d_raw, so the BRAM's clock-to-out ends there and ID
//        decodes a register
//   ID   d_raw (or d_hold, latched in the first cycle ID waits), decode,
//        every lane's register read with the WB bypass. Illegal words and
//        fetches outside imem become a fault flag that halts in EX
//   EX   per-lane forwarding (MEM, else WB), ALU, branch compare, scalar
//        lane, uniform checks, divergence stack, mask, lane control, ray
//        unit configuration and start (registered strobes: the ray unit
//        takes them in the next cycle), misaligned check
//   MEM  the only stage that takes more than one cycle; EX, ID and IF wait
//        for it. QRCP 8 cycles (seven qrcp_pipe stages, result), VTRACE rd
//        (rd != x0) until done plus one (the walk starts in its first MEM
//        cycle), loads and stores with an active
//        lane: one cycle to load the bus request register
//        (rtl/core_pipe/lsu_pipe.sv), one per LSU bus access (one per group
//        of coalesced lanes), plus one (a store's tail) or two (a load's
//        read data, registered in the LSU), except a store whose bus lanes
//        all go to dmem or the framebuffer (no extra cycle); MUL 2;
//        everything else 1.
//        Retirement happens here
//   WB   every lane writes rd
//
// Hazards. Forwarding MEM -> EX and WB -> EX for every lane, gated by that
// lane's write enable, so an inactive lane sees its older value. A load or
// MUL in EX whose rd ID reads holds ID for one cycle (load-use, mul-use):
// neither result is forwarded from MEM, so the reader takes it from WB.
// Branches, JAL and JALR resolve in EX; so do LMASK, MASKSET, MASKALL, DIF,
// DELSE and DENDIF, so the mask and divergence stack that EX reads are
// always those of every older instruction (Tai page, GPU Core, Pipelining
// notes: read in ID, written in EX). The redirect is registered: flush is
// high the cycle after a redirecting (or halting) instruction leaves EX,
// while it is in MEM. That cycle it kills the instruction then in EX
// (e_valid is e_vreg && !flush: no side effect, MEM gets a bubble), drops
// ID and F2 and the fetch in flight, and loads pc_f from m_next (flush 4).
// branch compare, uniform checks and target thus end in registers (flush,
// m_next, m_halt) instead of reaching IF and ID's enables. MEM holds the
// redirecting instruction for one cycle (it is no load, store, QRCP or
// VTRACE rd, or it halted), and the killed one cannot hold EX
// (e_vt_hold reads e_valid), so the pipe always advances under flush.
//
// Branch prediction. IF looks pc_f up in the BTB; on a hit with a counter
// of 2 or 3 (predicted taken) the next pc_f is the entry's target, else
// pc_f + 4. The prediction and target ride with the instruction (the
// target as f_tgt - pc_f); ID checks that against the B / J immediate into
// the e_pok flag. A conditional branch
// or JAL in EX redirects (flush 4) only when the prediction was wrong: taken
// without e_pok, or predicted taken and not taken. JALR, DIF/DELSE/DENDIF
// and the mask writers are never predicted. The BTB is written the cycle
// after EX (u_req), unless the branch halted (m_halt, a register). Only the
// fetch path depends on it: pc, retire order and values do not.
//
// Asynchronous VTRACE (VTRACE x0) starts the walk like VTRACE rd (the ray
// unit strobes are registered: VSET and VTRACE reach it the cycle after EX)
// and leaves MEM in one cycle. vt_pend is high from VTRACE's EX until
// vt_done; while it is high a custom-1 instruction waits in EX (e_vt_hold:
// EX, ID and IF hold, MEM gets a bubble), so VSET cannot change the rays, a
// second VTRACE cannot start and VGET reads the finished results (a VGET
// right after a VSET waits one cycle too, for VSET's cell); and a lane's
// world access or MMIO store waits in MEM (vt_block, bus_req low), since the
// ray unit owns the world port while busy and WIN_ORIGIN / SLOT_VALID steer
// its reads.
//
// Retirement (the retire_* wires, pc). An instruction retires in its last
// MEM cycle, a store with an active lane in the cycle the bus accepts its
// last lane, like the multi-cycle core. retire_mask is the mask register:
// while an instruction is in MEM, EX has not run anything younger. pc is the
// architectural PC (the next PC of the last retired instruction), so it
// steps through the same values as the multi-cycle pc; the fetch PC is pc_f.
//
// Halts. EX detects them (an ID fault: ILLEGAL; else DIVERGE, DIVSTACK,
// ILLEGAL, as in core.sv), runs no side effect, flushes EX, ID and IF the
// next cycle and stops fetching (pc_f freezes). A JALR's DIVERGE is found
// in MEM, from registers (m_jd): a JALR always redirects, so the same flush
// covers it. The halt marker pulses err_set in MEM, after every older
// instruction has retired. err_pc is pc, as in core.sv: then the faulting
// instruction's PC, and it stays there while halted.
//
// state is an observation for the testbenches only: 4 (the multi-cycle
// S_MEM code) while MEM walks the LSU, 6 (S_HALT) after a halt,
// 0 otherwise.
module core_pipe
    import kc_isa_pkg::*;
#(
    parameter int          LANES         = 1,
    parameter logic [31:0] RESET_VEC     = IMEM_BASE,
    parameter bit          HAS_DIV_STACK = 1'b0,
    parameter bit          HAS_RAY_UNIT  = 1'b0,
    parameter bit          HAS_QRCP      = 1'b0,
    parameter bit          HAS_ICACHE    = 1'b0
) (
    input  logic                 clk,
    input  logic                 rst,

    output logic [31:0]          imem_addr,
    input  logic [31:0]          imem_rdata,
    input  logic                 imem_ack,   // HAS_ICACHE: imem_rdata is valid

    output logic                 bus_req,
    output logic                 bus_we,
    output logic [31:0]          bus_addr,
    output logic [3:0]           bus_be,
    output logic [31:0]          bus_wdata,
    output logic [31:0]          bus_pf_addr,   // next cycle's likely bus_addr (lsu_pipe)
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
    input  logic [31:0]          vt_t_hit    [LANES],

    // dmem window banks (rtl/mem/dmem_win.sv, rtl/core_pipe/win_lsu.sv)
    output logic [3:0]           win_we    [DWIN_BANKS],
    output logic [7:0]           win_addr  [DWIN_BANKS],
    output logic [31:0]          win_wdata [DWIN_BANKS],
    input  logic [31:0]          win_rdata [DWIN_BANKS]
);

    if (LANES < 1 || LANES > 8) begin : g_lanes_check
        $error("core_pipe: LANES must be 1 to 8");
    end

    localparam int LW = (LANES > 1) ? $clog2(LANES) : 1;

    // ------------------------------------------------------------------
    // Pipeline control
    // ------------------------------------------------------------------
    logic adv;        // MEM takes EX's instruction: EX, ID and IF move on
    logic lu;         // load-use / mul-use: ID waits, EX gets a bubble
    logic flush;      // a redirect or halt left EX last cycle: kill EX, ID, IF
    logic stop;       // halted: nothing more is fetched
    logic m_valid, m_done, m_ready;
    logic e_vreg, e_valid, e_go, e_halt, e_redirect;
    logic [31:0] e_next;

    logic e_vt_hold;  // custom-1 in EX while a walk is in flight: EX waits

    assign m_ready = !m_valid || m_done;
    assign adv     = m_ready && !e_vt_hold;
    assign e_go    = e_valid && adv;
    assign e_valid = e_vreg && !flush;

    always_ff @(posedge clk) begin
        if (rst) flush <= 1'b0;
        else     flush <= e_go && (e_halt || e_redirect);
    end

    // ------------------------------------------------------------------
    // IF / F2 / ID
    // ------------------------------------------------------------------
    logic [31:0] pc_f, q_pc, q_hold, q_inst, d_pc, d_raw, d_hold, d_inst;
    // ICF: the I-cache fetch is built (HAS_ICACHE). KC_TB_ICACHE_FETCH, a
    // testbench-only define (tb-core-pipe-t_pipe_stress-ack), builds it on
    // the imem BRAM with imem_ack also dropped about one cycle in four by
    // an LFSR: the BRAM reads whatever is presented, so an acknowledged
    // word is always right, and the fetch unit's hold / re-present path runs.
    logic f_ack;
`ifdef KC_TB_ICACHE_FETCH
    localparam bit ICF = 1'b1;
    logic [31:0] tb_lfsr;
    always_ff @(posedge clk)
        if (rst) tb_lfsr <= 32'h1D87_2C35;
        else     tb_lfsr <= {tb_lfsr[30:0], tb_lfsr[31] ^ tb_lfsr[21] ^ tb_lfsr[1] ^ tb_lfsr[0]};
    assign f_ack = imem_ack && (tb_lfsr[3] || tb_lfsr[17]);
`else
    localparam bit ICF = HAS_ICACHE;
    assign f_ack = imem_ack;
`endif
    logic        q_valid, d_valid, d_hold_v, d_ready;
    // F2's word (HAS_ICACHE, g_ifetch below; constants otherwise): q_hv
    // q_hold has it, q_ok it is here, q_adv F2 moves on (hands it, or
    // nothing, to ID and takes pc_f), q_miss it is missing
    logic        q_hv, q_ok, q_adv, q_miss, f_wait, f_stale;
    logic [31:0] q_nx;

    // IF, F2 and ID advance together (d_ready) and wait together, so one
    // flag says both hold their instruction: q_hold and d_hold load every
    // cycle until the first cycle they wait, then keep it. With HAS_ICACHE
    // F2 also waits for its word (q_hv: q_hold has it).
    assign imem_addr = pc_f;
    assign q_inst    = q_hv ? q_hold : imem_rdata;
    assign d_inst    = d_hold_v ? d_hold : d_raw;
    assign d_ready   = !d_valid || (adv && !lu);
    assign q_adv     = d_ready && (!q_valid || q_ok);
    assign q_miss    = q_valid && !q_ok;

    // Branch target buffer: the prediction for pc_f (rtl/core_pipe/btb.sv)
    logic        f_hit, f_pred, q_hit, q_pred, d_hit, d_pred, e_hit, e_pred, e_pok;
    logic [1:0]  f_ctr, q_ctr, d_ctr, e_ctr;
    logic [31:0] f_tgt, q_off, d_off;
    logic        u_req, u_hit, u_taken;
    logic [1:0]  u_ctr;
    logic [31:0] u_tgt;

    // pc_f: a redirect writes it (m_next, the cycle the redirecting
    // instruction is in MEM), otherwise it steps with ID (to the predicted
    // target or pc_f + 4) until a halt stops fetching. After a halt pc_f
    // is never decoded again, and it stops moving once stop is set. With
    // HAS_ICACHE a missing F2 word sends pc_f back to q_pc (f_wait), and
    // F2 moving on then steps it to q_nx, q's own next PC.
    always_ff @(posedge clk) begin
        if (rst)                    pc_f <= RESET_VEC;
        else if (flush)             pc_f <= m_next;
        else if (q_adv && !stop)    pc_f <= f_wait ? q_nx : (f_pred ? f_tgt : pc_f + 32'd4);
        else if (q_miss && !f_wait) pc_f <= q_pc;
    end

    // d_off is the predicted target minus d_pc: ID's check d_pc + d_imm ==
    // target is then d_imm == d_off, with no adder after the decoder.
    always_ff @(posedge clk) begin
        if (rst) begin
            q_valid  <= 1'b0;
            d_valid  <= 1'b0;
            d_hold_v <= 1'b0;
            stop     <= 1'b0;
        end else if (flush) begin
            q_valid  <= 1'b0;
            d_valid  <= 1'b0;
            d_hold_v <= 1'b0;
            if (m_hlt) stop <= 1'b1;
        end else if (d_ready) begin
            if (q_adv && !f_wait) begin
                q_pc     <= pc_f;
                q_hit    <= f_hit;
                q_pred   <= f_pred;
                q_ctr    <= f_ctr;
                q_off    <= f_tgt - pc_f;
                q_valid  <= !stop;
            end else if (q_adv) begin
                q_valid  <= 1'b0;   // pc_f was q_pc: nothing behind q yet
            end
            d_pc     <= q_pc;
            d_hit    <= q_hit;
            d_pred   <= q_pred;
            d_ctr    <= q_ctr;
            d_off    <= q_off;
            d_valid  <= q_valid && q_ok;
            d_hold_v <= 1'b0;
        end else begin
            d_hold_v <= 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        d_raw <= q_inst;
        if (!q_hv)     q_hold <= imem_rdata;
        if (!d_hold_v) d_hold <= d_raw;
    end

    // I-cache fetch (HAS_ICACHE). imem_rdata is F2's word when imem_ack is
    // high and the address presented last cycle was q_pc. Normally it was;
    // when the word is missing (q_miss) pc_f goes back to q_pc and stays
    // there (f_wait) until the word comes, ignoring the answer of the one
    // cycle after (f_stale: it is for the address presented in the miss
    // cycle). The word is latched in q_hold (q_hv) if ID waits. When F2
    // moves on in f_wait, ID gets q, F2 a bubble and pc_f q_nx (the next PC
    // chosen when q was fetched, so q's prediction stays the one followed):
    // a miss costs the cycles until imem_ack plus three. A fetch above
    // 0x0FFF_FFFF needs no answer (its fault halts in EX). A redirect
    // (flush) cancels all of it.
    if (ICF) begin : g_ifetch
        assign q_ok = q_hv || is_fetch_outside_icache(q_pc) || (f_ack && !f_stale);

        always_ff @(posedge clk) begin
            if (rst || flush) begin
                q_hv    <= 1'b0;
                f_wait  <= 1'b0;
                f_stale <= 1'b0;
            end else begin
                f_stale <= q_miss && !f_wait;
                if (q_adv) begin
                    q_hv   <= 1'b0;
                    f_wait <= 1'b0;
                end else begin
                    if (q_ok)   q_hv   <= 1'b1;
                    if (q_miss) f_wait <= 1'b1;
                end
            end
            if (q_adv && !f_wait) q_nx <= f_pred ? f_tgt : pc_f + 32'd4;
        end
    end else begin : g_no_ifetch
        assign q_ok    = 1'b1;
        assign q_hv    = d_hold_v;
        assign f_wait  = 1'b0;
        assign f_stale = 1'b0;
        assign q_nx    = '0;

        /* verilator lint_off UNUSEDSIGNAL */
        logic unused_ifetch;
        /* verilator lint_on UNUSEDSIGNAL */
        assign unused_ifetch = f_ack ^ (^q_nx) ^ f_stale;
    end

    logic [3:0]  d_alu_ctrl;
    logic        d_alu_a_pc, d_r_we, d_res_imm, d_is_load, d_is_store, d_is_mul;
    logic        d_is_branch, d_is_jal, d_is_jalr, d_is_lane, d_is_div, d_is_ray, d_is_qrcp;
    logic        d_uniform_wr, d_illegal;
    logic [1:0]  d_alu_b_sel;
    logic [2:0]  d_imm_sig;
    logic [31:0] d_imm, d_imm_b, d_imm_j;
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
    // Operands an instruction reads, for the load-use / mul-use stall only
    assign d_uses1 = (d_opc != OPC_LUI) && (d_opc != OPC_AUIPC) && (d_opc != OPC_JAL);
    assign d_uses2 = (d_opc == OPC_BRANCH) || (d_opc == OPC_STORE) || (d_opc == OPC_OP);
    // immgen's B and J immediates (a branch decodes imm_sig B, JAL J)
    assign d_imm_b = {{20{d_inst[31]}}, d_inst[7], d_inst[30:25], d_inst[11:8], 1'b0};
    assign d_imm_j = {{12{d_inst[31]}}, d_inst[19:12], d_inst[20], d_inst[30:21], 1'b0};

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
        if (rst)      e_vreg <= 1'b0;
        else if (adv) e_vreg <= d_valid && !lu && !flush;
    end

    always_ff @(posedge clk) begin
        if (adv) begin
            e_pc         <= d_pc;
            e_inst       <= d_inst;
            e_fault      <= d_illegal || (ICF ? is_fetch_outside_icache(d_pc)
                                              : is_fetch_outside_imem(d_pc));
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
            // Only conditional branches and JAL are predicted; e_pok: the
            // predicted target is the real one (so EX needs no compare)
            e_pred       <= d_pred && (d_is_branch || d_is_jal);
            e_pok        <= d_pred && ((d_is_branch && (d_imm_b == d_off)) ||
                                       (d_is_jal && (d_imm_j == d_off)));
            e_hit        <= d_hit;
            e_ctr        <= d_ctr;
        end
    end

    // The product is ready in MEM's second cycle and written to w_res, too
    // late for the MEM -> EX forward, so a MUL's reader waits like a load's.
    assign lu = d_valid && e_valid && (e_is_load || e_is_mul) && e_r_we &&
                ((d_uses1 && (d_rs1 == e_rd)) || (d_uses2 && (d_rs2 == e_rd)));

    // ------------------------------------------------------------------
    // MEM / WB registers that the lanes' forwarding needs
    // ------------------------------------------------------------------
    logic [LANES-1:0] mask;
    logic             m_halt, m_jchk, m_hlt, m_r_we, m_nowr, m_uniform_wr, m_wr;
    logic [4:0]       m_rd, w_rd;
    logic [LANES-1:0] m_we, w_we;

    // MEM writes rd in lane i when the lane is active after the
    // instruction's own EX (the mask register now) or the write is uniform.
    assign m_wr = m_valid && !m_hlt && m_r_we && !m_nowr;
    for (genvar i = 0; i < LANES; i++) begin : g_m_we
        assign m_we[i] = m_wr && (mask[i] || m_uniform_wr);
    end

    // ------------------------------------------------------------------
    // Lanes
    // ------------------------------------------------------------------
    logic [31:0]      lane_y;
    logic [31:0]      l_rs1 [LANES];
    logic [31:0]      l_ea [LANES];   // rs1 + imm: load/store address, JALR sum
    logic [31:0]      l_res [LANES];
    logic [31:0]      l_mrs2 [LANES];
    logic [31:0]      l_wdata [LANES];
    logic [31:0]      ray_y [LANES];
    logic [31:0]      vt_y [LANES];
    logic [LANES-1:0] l_cmp, nonzero, ld_cap, mis;
    logic [31:0]      ld_value [LANES];
    // Load data for the lanes: the bus LSU's (ld_cap / ld_value, two cycles
    // after an access) or the dmem window's (win_srv / win_val, the cycle the
    // lane is served). A lane is either a bus lane or a window lane.
    logic [LANES-1:0] l_cap, win_srv, win_lane;
    logic [31:0]      l_ldv [LANES];
    logic [31:0]      win_val [LANES];
    logic             e_vget, e_stash, e_vtrace, e_nowr;
    logic             m_is_load, m_is_store, m_mul, m_qr, m_vt;
    logic [2:0]       m_funct3, m_cnt;
    logic             qr_s0, vt_wr;

    // Forwarding selects, registered. fm*[i]: MEM writes rd in lane i and
    // rd = EX's rs*, the whole m_we[i] term: loaded when MEM loads (m_ready)
    // from the instruction entering it (a bubble when e_vt_hold), with the
    // mask now (no instruction that writes rd writes the mask, and the mask
    // only changes when MEM loads). A halting instruction may select itself:
    // flush kills the reader in EX the next cycle. fw* = (w_rd == e_rs*)
    // one cycle early; w_rd loads m_rd every cycle.
    logic [LANES-1:0] fm1, fm2;
    logic fw1, fw2, d_wb1, d_wb2, e_fwd;
    assign e_fwd = e_valid && !e_vt_hold && e_r_we && !e_nowr;
    always_ff @(posedge clk) begin
        if (rst) begin
            fm1 <= '0;
            fm2 <= '0;
        end else if (m_ready) begin
            for (int i = 0; i < LANES; i++) begin
                fm1[i] <= e_fwd && (e_rd == d_rs1) && (mask[i] || e_uniform_wr);
                fm2[i] <= e_fwd && (e_rd == d_rs2) && (mask[i] || e_uniform_wr);
            end
        end
        fw1 <= (m_rd == (adv ? d_rs1 : e_rs1));
        fw2 <= (m_rd == (adv ? d_rs2 : e_rs2));
    end
    assign d_wb1 = (w_rd == d_rs1);
    assign d_wb2 = (w_rd == d_rs2);

    assign e_stash = e_is_mul || e_is_qrcp;

    for (genvar i = 0; i < LANES; i++) begin : g_lane
        lane_pipe #(.ID(i), .HAS_QRCP(HAS_QRCP)) u_lane (
            .clk,
            .rs1_addr(d_rs1), .rs2_addr(d_rs2), .d_wb1, .d_wb2, .adv,
            .fm1(fm1[i]), .fm2(fm2[i]), .fw1, .fw2,
            .ex_go(e_go), .alu_ctrl(e_alu_ctrl), .alu_a_pc(e_alu_a_pc),
            .alu_b_sel(e_alu_b_sel), .funct3(e_funct3), .pc(e_pc), .imm(e_imm),
            .res_imm(e_res_imm), .is_lane(e_is_lane), .lane_y, .ray_en(e_vget),
            .ray_y(ray_y[i]), .stash(e_stash), .is_jalr(e_is_jalr),
            .rs1(l_rs1[i]), .ea(l_ea[i]), .cmp(l_cmp[i]),
            .mul_op(m_funct3[1:0]), .m_is_load, .m_mul, .qr_s0, .m_qr,
            .vt_wr, .vt_y(vt_y[i]), .ld_cap(l_cap[i]), .ld_value(l_ldv[i]),
            .res(l_res[i]), .m_rs2(l_mrs2[i]), .wdata(l_wdata[i]),
            .w_we(w_we[i]), .w_rd
        );

        assign nonzero[i] = (l_rs1[i] != 32'd0);
        assign mis[i]     = is_misaligned(e_funct3, l_ea[i][1:0]);
        assign l_cap[i]   = ld_cap[i] || (win_srv[i] && m_is_load);
        assign l_ldv[i]   = win_srv[i] ? win_val[i] : ld_value[i];
    end

    // ------------------------------------------------------------------
    // EX: scalar lane, branch, uniform checks, divergence stack, mask
    // ------------------------------------------------------------------
    logic [LW-1:0]    sl;           // scalar lane: lowest active, 0 when M = 0
    logic [31:0]      target;
    logic             take;
    logic [LANES-1:0] l_taken;
    logic [31:0]      l_jt [LANES];
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
        assign l_jt[i]    = l_ea[i] & ~32'd1;
    end

    // A JALR's uniform-target check (DIVERGE) is MEM's (m_jdiv below): a
    // JALR always redirects, so flush kills everything younger whether or
    // not it halts, and the check reads registers (each lane's rs1 + imm in
    // m_rs2, the scalar lane's target in m_next) instead of the adders.
    assign e_diverge = e_is_branch && ((l_taken & mask) != '0) && ((l_taken & mask) != mask);

    // A DIF/DELSE/DENDIF halts only on e_fault, DIVSTACK, or a jump to a
    // target with bit 1 set (no DIVERGE, no load/store): e_div_halt is
    // e_halt for them without the lane ALU / uniform-check cone.
    logic [31:0] b_target;    // e_pc + e_imm: branch, JAL, DIF/DELSE target
    logic        e_div_halt;

    if (HAS_DIV_STACK) begin : g_divstack
        divstack #(.LANES(LANES)) u_divstack (
            .clk, .rst,
            .op(e_funct3), .mask, .cond(nonzero),
            .step(e_go && e_is_div && !e_div_halt),
            .err(ds_err), .mask_d(ds_mask), .jump(ds_jump)
        );
    end else begin : g_no_divstack
        assign ds_err  = 1'b0;
        assign ds_mask = '0;
        assign ds_jump = 1'b0;
    end

    assign e_divstack = e_is_div && ds_err;
    assign b_target   = e_pc + e_imm;
    assign e_div_halt = e_fault || ds_err || (ds_jump && b_target[1]);

    assign take   = e_is_jal || e_is_jalr || (e_is_branch && l_taken[sl]) ||
                    (e_is_div && ds_jump);
    assign target = e_is_jalr ? l_jt[sl] : b_target;
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

    // A branch or JAL redirects when its prediction was wrong (taken but not
    // predicted to its target, or predicted taken and not taken). For JALR
    // and custom-2 e_pred = e_pok = 0, so this is take || mask_we for them.
    // e_pok and e_pred are registers, so take reaches flush through one LUT
    // of (take, e_pok, e_pred, mask_we) where it used to be take || mask_we.
    assign e_redirect = mask_we || (take ? !e_pok : e_pred);

    // Mask writers are lane control (halts only on e_fault) and custom-2
    // (e_div_halt), so the write skips the lane ALU / uniform-check cone.
    always_ff @(posedge clk) begin
        if (rst) mask <= LANES'(1);
        else if (e_go && mask_we && !e_fault && !(e_is_div && e_div_halt)) mask <= mask_d;
    end

    // ------------------------------------------------------------------
    // Ray unit (custom-1)
    // ------------------------------------------------------------------
    logic vt_pend;    // a walk is in flight: from VTRACE's EX to vt_done

    if (HAS_RAY_UNIT) begin : g_ray
        logic [7:0] cap;
        logic       e_vset_go, e_vt_go;

        assign e_vtrace  = e_is_ray && (e_funct3 == F3_VTRACE);
        assign e_vget    = e_is_ray && (e_funct3 == F3_VGET);
        assign cap       = l_rs1[sl][7:0];
        assign e_nowr    = e_vtrace && (cap == 8'd0);

        // A custom-1 instruction halts only on e_fault (DIVERGE, DIVSTACK
        // and the EX ILLEGAL cases need a branch, JALR, DIF/DELSE/DENDIF or
        // a load/store), so the strobes skip the forward/uniform-check cone.
        assign e_vset_go = e_go && !e_fault && e_is_ray && (e_funct3 == F3_VSET);
        assign e_vt_go   = e_go && !e_fault && e_vtrace;

        // The strobes and their operands are registered: VSET and VTRACE
        // reach the ray unit the cycle after their EX, so adv (e_go) feeds
        // only two flops here, not the ray unit's clock enables. The operand
        // registers load every cycle; the strobe says when they hold a
        // custom-1 instruction's. A VSET after a VSET or a VTRACE after a
        // VSET keeps its order. VGET field 0 reads the cell that VSET field 0
        // writes, so a VGET waits in EX while a VSET strobe is out
        // (vt_cfg_we); VTRACE sets vt_pend in its EX cycle, so any custom-1
        // instruction after it waits as before.
        assign e_vt_hold = e_valid && e_is_ray && (vt_pend || (e_vget && vt_cfg_we));

        always_ff @(posedge clk) begin
            if (rst) begin
                vt_cfg_we <= 1'b0;
                vt_start  <= 1'b0;
            end else begin
                vt_cfg_we <= e_vset_go;
                vt_start  <= e_vt_go;
            end
            vt_cfg_field <= e_field;
            vt_lane_mask <= mask;
            vt_cfg_data  <= l_rs1;
            vt_max_steps <= cap;
        end
        assign vt_wr        = m_valid && m_vt && vt_done;

        // VGET field 3 returns the VTRACE result, fields 0 and 1 the hit
        // cell and t_hit (field 2 and 4 up are illegal).
        for (genvar i = 0; i < LANES; i++) begin : g_y
            assign ray_y[i] = e_field[1] ? {16'd0, vt_result[i]} :
                              e_field[0] ? vt_t_hit[i] : {15'd0, vt_hit_cell[i]};
            assign vt_y[i]  = {16'd0, vt_result[i]};
        end

        always_ff @(posedge clk) begin
            if (rst)          vt_pend <= 1'b0;
            else if (e_vt_go) vt_pend <= 1'b1;
            else if (vt_done) vt_pend <= 1'b0;
        end
    end else begin : g_no_ray
        assign e_vtrace     = 1'b0;
        assign e_vget       = 1'b0;
        assign e_vt_hold    = 1'b0;
        assign vt_pend      = 1'b0;
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
    logic                 m_walk, m_sret, m_vt_tail, m_mem, lsu_done, lsu_idle, win_fin;
    logic                 retire_valid;

    always_ff @(posedge clk) begin
        if (rst) begin
            m_valid <= 1'b0;
            m_walk  <= 1'b0;
        end else if (m_ready) begin
            m_valid <= e_valid && !e_vt_hold;
            m_walk  <= e_lsu_go;
        end else if (lsu_idle) begin
            m_walk  <= 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        if (m_ready) begin
            m_halt       <= e_halt;
            m_jchk       <= e_is_jalr && !e_fault;
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
            m_vt         <= e_vtrace && e_r_we;   // VTRACE x0 does not wait
            m_cnt        <= '0;
            m_sret       <= 1'b0;
            m_vt_tail    <= 1'b0;
        end else begin
            if (m_cnt != 3'd7) m_cnt <= m_cnt + 3'd1;
            if (retire_valid)  m_sret <= 1'b1;
            if (vt_wr)         m_vt_tail <= 1'b1;
        end
    end

    // A JALR's uniform-target check (DIVERGE), the cycle after its EX: each
    // active lane's rs1 + imm (m_rs2) against the scalar lane's target
    // (m_next, bit 0 clear), as the multi-cycle core's jt_diff. The JALR
    // redirected, so flush kills the instruction behind it and ID this
    // cycle and the halt stays precise. m_hlt is m_halt with it; m_err_x
    // puts DIVERGE ahead of the target's ILLEGAL (an ID fault, ILLEGAL
    // only, has m_jchk low). The mask is the JALR's: nothing behind it ran.
    logic [LANES-1:0] m_jdiff;
    logic             m_jd;
    logic [ERR_WIDTH-1:0] m_err_x;

    for (genvar i = 0; i < LANES; i++) begin : g_jdiff
        assign m_jdiff[i] = mask[i] && (l_mrs2[i][31:1] != m_next[31:1]);
    end
    assign m_jd  = m_valid && m_jchk && (m_jdiff != '0);
    assign m_hlt = m_halt || m_jd;

    always_comb begin
        m_err_x = m_err;
        if (m_jd) begin
            m_err_x               = '0;
            m_err_x[ERR_DIVERGE] = 1'b1;
        end
    end

    // BTB update, the cycle after a conditional branch or JAL leaves EX:
    // m_halt (a register) is then its e_halt, so a halting one writes
    // nothing and the write enable stays out of the halt cone. m_pc is its PC.
    always_ff @(posedge clk) begin
        if (rst) u_req <= 1'b0;
        else     u_req <= e_go && (e_is_branch || e_is_jal);
        if (e_go) begin
            u_tgt   <= b_target;
            u_hit   <= e_hit;
            u_ctr   <= e_ctr;
            u_taken <= take;
        end
    end

    btb #(.HAS_ICACHE(ICF)) u_btb (
        .clk, .rst,
        .f_pc(pc_f), .f_hit, .f_taken(f_pred), .f_ctr, .f_target(f_tgt),
        .u_we(u_req && !m_halt), .u_pc(m_pc), .u_target(u_tgt), .u_hit, .u_ctr,
        .u_taken
    );

    // QRCP: seven qrcp_pipe stages, then the result in the eighth cycle
    // (m_cnt stops at 7).
    assign qr_s0  = m_valid && m_qr && (m_cnt == 3'd0);

    // A load or store is done when the bus LSU has no lane left and no read
    // data in flight (none pending, its request register empty and no read
    // accepted last cycle: a store, the cycle after its last access; a load,
    // two cycles after, when its data leaves the LSU's read register) and
    // the dmem window serves its last lanes (or has none).
    //
    // A store whose bus lanes all go to dmem or the framebuffer is done in
    // the cycle its last group goes out (st_fast): rtl/soc/decoder.sv answers
    // ready = req for both (BRAM / strobe ports) and vt_block never holds
    // them, so such a store sends one group per cycle, the first in MEM's
    // second cycle (rtl/core_pipe/lsu_pipe.sv loads its request register in
    // the first). Loads keep the extra cycles (their data arrives then); a
    // store with a world, texture, MMIO, palette or unmapped lane waits for
    // the bus LSU to be idle.
    //
    // m_done drives adv, the clock enable of EX, ID and IF, so it reads only
    // registers: m_bidle (lsu_idle), m_bfast (st_fast) and win_fin (win_lsu's
    // fin) hold this cycle's value, computed a cycle ahead.
    //   m_bidle: no active lane outside the window (e_busl, on the addresses
    //   start sees) at the start, then lsu_pipe's idle_nx.
    //   m_bfast: never in MEM's first cycle (no group on the bus yet), then
    //   lsu_pipe's fast_nx, from the MEM-stage address registers.
    logic [LANES-1:0] e_busl, ex_win;
    logic             m_bidle, m_bfast, lsu_idle_nx, lsu_fast_nx;

    assign e_busl = mask & ~ex_win;

    always_ff @(posedge clk) begin
        if (m_ready) begin
            m_bidle <= (e_busl == '0);
            m_bfast <= 1'b0;
        end else begin
            m_bidle <= lsu_idle_nx;
            m_bfast <= lsu_fast_nx;
        end
    end

    always_comb begin
        if (m_halt)          m_done = 1'b1;
        else if (m_mem)      m_done = (m_bidle || m_bfast) && win_fin;
        else if (m_qr)       m_done = (m_cnt == 3'd7);
        else if (m_mul)      m_done = (m_cnt == 3'd1);
        else if (m_vt)       m_done = m_vt_tail;
        else                 m_done = 1'b1;
    end

    // While a walk is in flight the access in the bus request register waits
    // (bus_req low) if it touches the world, whose port A the ray unit owns
    // while busy, or is an MMIO store, which could move WIN_ORIGIN or
    // SLOT_VALID under the walk. vt_pend, m_is_store and bus_addr (the
    // request register) are registers, so bus_ready still feeds only
    // registered state. No access is in progress when a walk starts.
    logic vt_block;
    assign vt_block = vt_pend && ((bus_addr[31:28] == REG_WORLD) ||
                                  ((bus_addr[31:28] == REG_MMIO) && m_is_store));

    // The misaligned check is EX's (mis above). The LSU registers the bus
    // request (rtl/core_pipe/lsu_pipe.sv).
    lsu_pipe #(.LANES(LANES)) u_lsu (
        .clk, .rst,
        .start(e_lsu_go), .active(mask),
        .go(m_walk), .hold(vt_block), .is_store(m_is_store), .funct3(m_funct3),
        .addr(l_res), .rs2(l_mrs2), .done(lsu_done), .skip(win_lane), .idle(lsu_idle),
        .idle_nx(lsu_idle_nx), .fast_nx(lsu_fast_nx),
        .bus_req, .bus_we, .bus_addr, .bus_be, .bus_wdata, .bus_pf_addr, .bus_ready, .bus_rdata,
        .ld_cap, .ld_value
    );

    // The dmem window's lanes, all served in parallel, one per bank per
    // cycle (rtl/core_pipe/win_lsu.sv).
    win_lsu #(.LANES(LANES)) u_win (
        .clk, .rst,
        .start(e_lsu_go), .active(mask), .ex_addr(l_ea),
        .go(m_valid && m_mem && !m_halt), .is_store(m_is_store), .funct3(m_funct3),
        .addr(l_res), .rs2(l_mrs2),
        .ex_win, .win(win_lane), .served(win_srv), .fin(win_fin), .value(win_val),
        .b_we(win_we), .b_addr(win_addr), .b_wdata(win_wdata), .b_rdata(win_rdata)
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

    assign err_set = (m_valid && m_hlt) ? m_err_x : '0;
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

    assign state = halted ? 4'd6 : (m_walk && !lsu_idle) ? 4'd4 : 4'd0;

    // A store retires in the cycle the bus accepts its last lane, as on the
    // multi-cycle core, or, with no bus lane left, in the cycle the window
    // serves its last lanes; m_sret marks it retired. A store with a world,
    // texture, MMIO or unmapped lane then spends one more cycle in MEM; a
    // dmem or framebuffer store leaves in its retiring cycle (m_bfast is
    // st_fast, which implies lsu_done, so m_done and st_ret rise together
    // and m_sret never sets).
    logic st_ret;
    assign st_ret = !m_sret && (lsu_done || lsu_idle) && win_fin;

    assign retire_valid      = m_valid && !m_hlt &&
                               ((m_mem && m_is_store) ? st_ret : m_done);
    assign retire_pc         = m_pc;
    assign retire_inst       = m_inst;
    assign retire_lane_we    = retire_valid ? m_we : '0;
    assign retire_rd_we      = retire_lane_we[0];
    assign retire_rd_addr    = m_rd;
    assign retire_rd_wdata   = l_wdata[0];
    assign retire_mask       = mask;
    assign retire_lane_wdata = l_wdata;

endmodule
