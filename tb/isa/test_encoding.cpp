// Verilator harness for rtl/isa_decode_check.sv (P0).
//
// 1. Every row of the Tai_2 section 1 encoding table: the example hex must
//    decode to the table's opcode, funct3, funct7, rd, rs1, rs2 and B-type
//    immediate, the hex rebuilt from those fields must equal the example hex,
//    and is_illegal must be 0.
// 2. Named illegal and legal cases: the "Illegal custom encodings" list, the
//    illegal base ISA words (DIV family, ECALL, EBREAK, CSR) and encodings
//    Tai_2 never defines (undefined opcodes, funct3, funct7), which are
//    illegal because anything not explicitly defined is illegal.
// 3. Exhaustive sweep of every opcode x funct3 x funct7 x has_ray_unit x
//    has_div_stack x has_qrcp against a reference model written from Tai_2
//    section 1, with rs2 = 0 and rs2 != 0 (QRCP needs rs2 = 0).
//
// Exits 0 only if every check passes.

#include "Visa_decode_check.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <memory>

namespace {

int g_fail = 0;
int g_checks = 0;

std::unique_ptr<Visa_decode_check> dut;

void apply(uint32_t instr, bool has_ray, bool has_div = true, bool has_qrcp = false) {
    dut->instr = instr;
    dut->has_ray_unit = has_ray;
    dut->has_div_stack = has_div;
    dut->has_qrcp = has_qrcp;
    dut->eval();
}

void expect(bool ok, const char* what, const char* name, uint32_t instr,
            uint32_t got, uint32_t want) {
    ++g_checks;
    if (!ok) {
        ++g_fail;
        std::printf("FAIL %-8s %-10s instr=0x%08X got=0x%X want=0x%X\n", name, what,
                    instr, got, want);
    }
}

#define EXPECT_EQ(field, want)                                                  \
    expect(static_cast<uint32_t>(dut->field) == static_cast<uint32_t>(want),    \
           #field, name, instr, static_cast<uint32_t>(dut->field),             \
           static_cast<uint32_t>(want))

// Independent encoders, written from the RISC-V R/B formats in Tai_2.
uint32_t enc_r(uint32_t op, uint32_t f3, uint32_t f7, uint32_t rd, uint32_t rs1,
               uint32_t rs2) {
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op;
}

uint32_t enc_b(uint32_t op, uint32_t f3, uint32_t rs1, uint32_t rs2, int32_t imm) {
    uint32_t u = static_cast<uint32_t>(imm);
    return (((u >> 12) & 1) << 31) | (((u >> 5) & 0x3F) << 25) | (rs2 << 20) |
           (rs1 << 15) | (f3 << 12) | (((u >> 1) & 0xF) << 8) | (((u >> 11) & 1) << 7) |
           op;
}

constexpr uint32_t A0 = 10;
constexpr uint32_t A1 = 11;

struct Row {
    const char* name;
    uint32_t hex;     // Tai_2 "Example hex" column
    uint32_t opcode;  // Tai_2 columns
    uint32_t funct3;
    uint32_t funct7;  // R-type rows only
    uint32_t rd;      // R-type rows only
    uint32_t rs1;
    uint32_t rs2;
    bool btype;
    int32_t imm;      // B-type rows only
    uint32_t id;      // isa_decode_check instr_id (table order)
    bool ray;         // needs the ray unit (custom-1)
    bool qrcp;        // needs HAS_QRCP (QRCP)
};

// Tai_2 section 1, "Custom instruction formats", one entry per row, using the
// example operands of the Example hex column.
const Row kRows[] = {
    {"LANEID",  0x0000050B, 0x0B, 0, 0, A0, 0,  0, false, 0,  1,  false, false},
    {"LMASK",   0x0005900B, 0x0B, 1, 0, 0,  A1, 0, false, 0,  2,  false, false},
    {"QRCP",    0x0005A50B, 0x0B, 2, 0, A0, A1, 0, false, 0,  3,  false, true},
    {"BALLOT",  0x0005B50B, 0x0B, 3, 0, A0, A1, 0, false, 0,  4,  false, false},
    {"MASKGET", 0x0000550B, 0x0B, 5, 0, A0, 0,  0, false, 0,  5,  false, false},
    {"MASKSET", 0x0005E00B, 0x0B, 6, 0, 0,  A1, 0, false, 0,  6,  false, false},
    {"MASKALL", 0x0000700B, 0x0B, 7, 0, 0,  0,  0, false, 0,  7,  false, false},
    {"VSET",    0x0605802B, 0x2B, 0, 3, 0,  A1, 0, false, 0,  8,  true,  false},
    {"VTRACE",  0x0005952B, 0x2B, 1, 0, A0, A1, 0, false, 0,  9,  true,  false},
    {"VGET",    0x0200252B, 0x2B, 2, 1, A0, 0,  0, false, 0,  10, true,  false},
    {"DIF",     0x0005885B, 0x5B, 0, 0, 0,  A1, 0, true,  16, 11, false, false},
    {"DELSE",   0x0000145B, 0x5B, 1, 0, 0,  0,  0, true,  8,  12, false, false},
    {"DENDIF",  0x0000205B, 0x5B, 2, 0, 0,  0,  0, false, 0,  13, false, false},
};

void check_table() {
    for (const Row& r : kRows) {
        const char* name = r.name;
        const uint32_t instr = r.hex;
        const int fail_before = g_fail;
        const uint32_t rebuilt = r.btype ? enc_b(r.opcode, r.funct3, r.rs1, r.rs2, r.imm)
                                         : enc_r(r.opcode, r.funct3, r.funct7, r.rd,
                                                 r.rs1, r.rs2);
        expect(rebuilt == r.hex, "rebuilt", name, instr, rebuilt, r.hex);

        for (int unit = 0; unit < 4; ++unit) {
            const bool ray = unit & 1;
            const bool qrcp = unit & 2;
            apply(instr, ray, true, qrcp);
            EXPECT_EQ(opcode, r.opcode);
            EXPECT_EQ(funct3, r.funct3);
            EXPECT_EQ(rs1, r.rs1);
            EXPECT_EQ(rs2, r.rs2);
            EXPECT_EQ(is_custom, 1);
            EXPECT_EQ(is_btype, r.btype);
            if (r.btype) {
                EXPECT_EQ(b_imm, static_cast<uint32_t>(r.imm));
                // funct7 and rd hold the immediate bits on B-type rows.
                const uint32_t u = static_cast<uint32_t>(r.imm);
                EXPECT_EQ(funct7, (((u >> 12) & 1) << 6) | ((u >> 5) & 0x3F));
                EXPECT_EQ(rd, (((u >> 1) & 0xF) << 1) | ((u >> 11) & 1));
            } else {
                EXPECT_EQ(funct7, r.funct7);
                EXPECT_EQ(rd, r.rd);
            }
            const bool legal = (ray || !r.ray) && (qrcp || !r.qrcp);
            EXPECT_EQ(illegal, !legal);
            EXPECT_EQ(instr_id, legal ? r.id : 0);
        }
        std::printf("row %-8s 0x%08X %s\n", r.name, r.hex,
                    g_fail == fail_before ? "ok" : "FAIL");
    }
}

// Reference model of Tai_2 section 1: everything it does not define is
// illegal. Fields marked 0 in the custom table are ignored, except QRCP's
// rs2, which must be 0.
bool ref_illegal(uint32_t op, uint32_t f3, uint32_t f7, uint32_t rs2, bool ray, bool div,
                 bool qrcp) {
    switch (op) {
    case 0x37: case 0x17: case 0x6F: return false;          // LUI, AUIPC, JAL
    case 0x67: return f3 != 0;                               // JALR
    case 0x63: return f3 == 2 || f3 == 3;                    // BRANCH
    case 0x03: return f3 == 3 || f3 == 6 || f3 == 7;         // LOAD
    case 0x23: return f3 > 2;                                // STORE
    case 0x13:                                               // OP-IMM
        if (f3 == 1) return f7 != 0;                         // SLLI
        if (f3 == 5) return f7 != 0 && f7 != 0x20;           // SRLI, SRAI
        return false;
    case 0x33:                                               // OP
        if (f7 == 0) return false;
        if (f7 == 0x20) return f3 != 0 && f3 != 5;           // SUB, SRA
        if (f7 == 1) return f3 >= 4;                         // Zmmul; DIV/REM
        return true;
    case 0x0F: return f3 > 1;                                // FENCE, FENCE.I
    case 0x0B: return f3 == 4 || f7 != 0 || (f3 == 2 && (!qrcp || rs2 != 0));
    case 0x2B:
        if (!ray) return true;
        if (f3 >= 3) return true;
        if (f3 == 0) return f7 >= 8;                         // VSET fields 0..7
        if (f3 == 1) return f7 != 0;
        return f7 >= 2;                                      // VGET fields 0..1
    case 0x5B: return f3 >= 3 || !div;
    default: return true;                                    // SYSTEM and undefined
    }
}

void check_illegal_list() {
    struct Case {
        const char* name;
        uint32_t instr;
        bool ray;
        bool want_illegal;
        bool qrcp;    // HAS_QRCP build (false when omitted)
    };
    const Case cases[] = {
        // custom-0 with funct3 100, or funct7 != 0; funct3 010 (QRCP)
        // without HAS_QRCP, or with rs2 != 0
        {"C0_F3_010", enc_r(0x0B, 2, 0, A0, A1, 0), true, true},
        {"QRCP_RS2",  enc_r(0x0B, 2, 0, A0, A1, 1), true, true, true},
        {"QRCP_RS2_31", enc_r(0x0B, 2, 0, A0, A1, 31), true, true, true},
        {"QRCP_F7_1", enc_r(0x0B, 2, 1, A0, A1, 0), true, true, true},
        {"QRCP_F7_40", enc_r(0x0B, 2, 0x40, A0, A1, 0), true, true, true},
        {"C0_F3_100_QRCP", enc_r(0x0B, 4, 0, A0, A1, 0), true, true, true},
        {"C0_F3_100", enc_r(0x0B, 4, 0, A0, A1, 0), true, true},
        {"C0_F7_1",   enc_r(0x0B, 0, 1, A0, 0, 0), true, true},
        {"C0_F7_40",  enc_r(0x0B, 3, 0x40, A0, A1, 0), true, true},
        // custom-1 with funct3 011..111
        {"C1_F3_011", enc_r(0x2B, 3, 0, A0, A1, 0), true, true},
        {"C1_F3_111", enc_r(0x2B, 7, 0, A0, A1, 0), true, true},
        // VTRACE with funct7 != 0
        {"VTRACE_F7", enc_r(0x2B, 1, 1, A0, A1, 0), true, true},
        // VGET with funct7 >= 2 (field 2 reserved for fog)
        {"VGET_F2",   enc_r(0x2B, 2, 2, A0, 0, 0), true, true},
        {"VGET_F127", enc_r(0x2B, 2, 127, A0, 0, 0), true, true},
        // custom-2 with funct3 011..111
        {"C2_F3_011", enc_r(0x5B, 3, 0, 0, 0, 0), true, true},
        {"C2_F3_111", enc_r(0x5B, 7, 0, 0, 0, 0), true, true},
        // custom-1 in a build without the ray unit
        {"VSET_NORAY",   0x0605802B, false, true},
        {"VTRACE_NORAY", 0x0005952B, false, true},
        {"VGET_NORAY",   0x0200252B, false, true},
        // Base ISA illegal words
        {"DIV",    enc_r(0x33, 4, 1, A0, A1, A0), true, true},
        {"DIVU",   enc_r(0x33, 5, 1, A0, A1, A0), true, true},
        {"REM",    enc_r(0x33, 6, 1, A0, A1, A0), true, true},
        {"REMU",   enc_r(0x33, 7, 1, A0, A1, A0), true, true},
        {"ECALL",  0x00000073, true, true},
        {"EBREAK", 0x00100073, true, true},
        {"CSRRW",  0x34051073, true, true},  // csrw mscratch, a0
        {"CSRRS",  0xC0002573, true, true},  // csrr a0, cycle (rdcycle)
        {"CSRRC",  0x3005B073, true, true},  // csrc mstatus, a1
        {"CSRRWI", 0x34045073, true, true},  // csrwi mscratch, 8
        {"CSRRSI", 0x30046073, true, true},  // csrsi mstatus, 8
        {"CSRRCI", 0x30047073, true, true},  // csrci mstatus, 8
        // Legal neighbours that must stay legal
        {"MUL",    enc_r(0x33, 0, 1, A0, A1, A0), false, false},
        {"MULH",   enc_r(0x33, 1, 1, A0, A1, A0), false, false},
        {"MULHSU", enc_r(0x33, 2, 1, A0, A1, A0), false, false},
        {"MULHU",  enc_r(0x33, 3, 1, A0, A1, A0), false, false},
        {"ADD",    enc_r(0x33, 0, 0, A0, A1, A0), false, false},
        {"SUB",    enc_r(0x33, 0, 0x20, A0, A1, A0), false, false},
        {"FENCE",  0x0FF0000F, false, false},
        {"FENCE.I", 0x0000100F, false, false},
        {"LW",     0x0005A503, false, false},  // lw a0, 0(a1)
        {"SW",     0x00A5A023, false, false},  // sw a0, 0(a1)
        {"BEQ",    0x00B50463, false, false},  // beq a0, a1, +8
        {"JAL",    0x008000EF, false, false},  // jal ra, +8
        // Fields marked 0 in the table are ignored by the decoder
        {"LANEID_JUNK", enc_r(0x0B, 0, 0, A0, 31, 31), false, false},
        {"MASKALL_JUNK", enc_r(0x0B, 7, 0, 31, 31, 31), false, false},
        {"VGET_JUNK", enc_r(0x2B, 2, 1, A0, 31, 31), true, false},
        {"DENDIF_JUNK", enc_r(0x5B, 2, 127, 31, 31, 31), false, false},
        {"QRCP",      0x0005A50B, false, false, true},
        {"QRCP_RD0",  enc_r(0x0B, 2, 0, 0, A1, 0), false, false, true},
        {"QRCP_X0",   enc_r(0x0B, 2, 0, 31, 0, 0), true, false, true},
        {"LANEID_JUNK_QRCP", enc_r(0x0B, 0, 0, A0, 31, 31), false, false, true},
        {"DELSE_JUNK", enc_b(0x5B, 1, 31, 31, -8), false, false},
        {"VSET_F7", enc_r(0x2B, 0, 7, 0, A1, 0), true, false},
        {"VGET_F0", enc_r(0x2B, 2, 0, A0, 0, 0), true, false},
        // Not defined by Tai_2, so illegal
        {"VSET_F8",   enc_r(0x2B, 0, 8, 0, A1, 0), true, true},
        {"VSET_F127", enc_r(0x2B, 0, 127, 0, A1, 0), true, true},
        {"ZERO",      0x00000000, true, true},
        {"C.LI",      0x00004505, true, true},              // 16-bit word
        {"FLW",       0x0005A507, true, true},              // opcode 0x07
        {"AMOADD.W",  0x00B5A52F, true, true},              // opcode 0x2F
        {"OP_F7_10",  enc_r(0x33, 0, 0x10, A0, A1, A0), true, true},
        {"SLT_F7_20", enc_r(0x33, 2, 0x20, A0, A1, A0), true, true},
        {"LD",        0x0005B503, true, true},              // LOAD funct3 011
        {"LOAD_F3_6", 0x0005E503, true, true},
        {"SD",        0x00A5B023, true, true},              // STORE funct3 011
        {"JALR_F3_1", 0x000590E7, true, true},
        {"BR_F3_2",   0x00B52463, true, true},
        {"SLLI_F7_20", 0x40159513, true, true},
        {"SRLI_F7_10", 0x2015D513, true, true},
        {"MISC_F3_2", 0x0000200F, true, true},
        // Legal neighbours of the new cases
        {"SRAI",      0x4015D513, true, false},
        {"SLLI",      0x00159513, true, false},
        {"LHU",       0x0005D503, true, false},
        {"BGEU",      0x00B57463, true, false},
    };
    for (const Case& c : cases) {
        const char* name = c.name;
        const uint32_t instr = c.instr;
        apply(instr, c.ray, true, c.qrcp);
        EXPECT_EQ(illegal, c.want_illegal);
    }
    std::printf("illegal list: %zu named cases checked\n", sizeof(cases) / sizeof(cases[0]));
}

void sweep_all() {
    // rd, rs1, rs2 per variant: three with rs2 != 0, one with rs2 = 0
    const uint32_t regs[][3] = {{0, 1, 2}, {A0, A0 ^ 1, A0 ^ 2}, {31, 30, 29}, {A0, A1, 0}};
    unsigned n = 0;
    for (uint32_t op = 0; op < 128; ++op)
        for (uint32_t f3 = 0; f3 < 8; ++f3)
            for (uint32_t f7 = 0; f7 < 128; ++f7)
                for (const auto& r : regs)
                    for (int unit = 0; unit < 8; ++unit) {
                        const bool ray = unit & 1;
                        const bool div = unit & 2;
                        const bool qrcp = unit & 4;
                        const char* name = "sweep";
                        const uint32_t instr = enc_r(op, f3, f7, r[0], r[1], r[2]);
                        apply(instr, ray, div, qrcp);
                        EXPECT_EQ(illegal, ref_illegal(op, f3, f7, r[2], ray, div, qrcp));
                        ++n;
                    }
    std::printf("full sweep: %u encodings checked\n", n);
}

}  // namespace

int main(int argc, char** argv) {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    auto ctx = std::make_unique<VerilatedContext>();
    ctx->commandArgs(argc, argv);
    dut = std::make_unique<Visa_decode_check>(ctx.get());

    check_table();
    check_illegal_list();
    sweep_all();

    dut->final();
    dut.reset();  // the model must die before its context
    if (g_fail) {
        std::printf("test_encoding: FAIL (%d of %d checks failed)\n", g_fail, g_checks);
        return 1;
    }
    std::printf("test_encoding: PASS (%d checks)\n", g_checks);
    return 0;
}
