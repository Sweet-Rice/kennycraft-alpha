/* t_illegal: every illegal case halts with ERR.ILLEGAL and the right ERR_PC
   (Tai_2 sections 1 and 2): DIV, ECALL, a CSR read, a misaligned LW and VGET
   field 3, plus the other DIV/REM forms, EBREAK, misaligned LH/SW/SH,
   custom-0 funct3 010 (QRCP) without HAS_QRCP, custom-1/custom-2
   instructions whose unit is absent in Stage 0, an all-zero word, a fetch
   outside instruction memory, a taken JALR, branch and JAL whose target is
   not 4-aligned (halt at the jump itself, link not written, D16), an
   undefined opcode (FLW), an undefined OP funct7, an undefined LOAD funct3
   (LD), the reserved custom-1 encodings (VSET field 8, VTRACE funct7 1,
   funct3 011), and the reserved custom-0 encodings (QRCP with funct7 1 or
   rs2 != 0, funct3 100), illegal in every build. Anything Tai_2 does not
   define is illegal. The testbench writes the case number to TB_SELECT and
   resets the core once per case. Case k sits at 0x100 + 0x40*k with the
   faulting instruction first in its slot (case 15 faults at 0x8000, case 17
   at 0x544). Cases 12 (VTRACE, cap a1 = 0), 26 (VSET field 0) and 27 (VGET
   field 1) are illegal only without the ray unit; with it they run and reach
   NOT_REACHED, and the VTRACE (cap 0) and VSET leave rd alone. Case 13
   (QRCP a2, x0) is illegal only without HAS_QRCP; with it a2 becomes
   qrcp(0) = Q16_BIG. Case 31 is the legal control: FENCE/FENCE.I run, a
   not-taken branch with a misaligned target falls through, reset has
   cleared ERR/ERR_PC, unmapped and imem-region data accesses read 0 without
   an error. */
#include "kc_test.h"

    /* DIV/REM and FENCE.I are not in rv32i_zmmul; assemble them anyway. */
    .option arch, +m, +zifencei

    .section .text.start
    .globl _start
_start:
    li    t0, DMEM_BASE
    lw    t1, (TB_SELECT - DMEM_BASE)(t0)
    li    a2, 0x55              /* rd of every faulting instruction */
    li    a1, 0                 /* case 12: VTRACE step cap 0 */
    slli  t1, t1, 6
    addi  t1, t1, 0x100
    jr    t1

/* Never reached when the instruction before it halts the core. */
.macro NOT_REACHED
    li    t2, 1
    sw    t2, (TB_MARK - DMEM_BASE)(t0)
99: j     99b
.endm

    .org 0x100                  /* 0: DIV */
    div    a2, a0, a1
    NOT_REACHED
    .org 0x140                  /* 1: DIVU */
    divu   a2, a0, a1
    NOT_REACHED
    .org 0x180                  /* 2: REM */
    rem    a2, a0, a1
    NOT_REACHED
    .org 0x1c0                  /* 3: REMU */
    remu   a2, a0, a1
    NOT_REACHED
    .org 0x200                  /* 4: ECALL */
    ecall
    NOT_REACHED
    .org 0x240                  /* 5: EBREAK */
    ebreak
    NOT_REACHED
    .org 0x280                  /* 6: CSR read, csrrs a2, cycle, x0 (no Zicsr) */
    .insn i 0x73, 2, a2, x0, -1024
    NOT_REACHED
    .org 0x2c0                  /* 7: misaligned LW */
    lw     a2, 2(t0)
    NOT_REACHED
    .org 0x300                  /* 8: misaligned LH */
    lh     a2, 1(t0)
    NOT_REACHED
    .org 0x340                  /* 9: misaligned SW over TB_MARK, must not store */
    sw     t0, (TB_MARK - DMEM_BASE + 1)(t0)
    NOT_REACHED
    .org 0x380                  /* 10: misaligned SH, must not store */
    sh     t0, (TB_MARK - DMEM_BASE + 1)(t0)
    NOT_REACHED
    .org 0x3c0                  /* 11: VGET a2, field 3 (reserved) */
    .insn r 0x2B, 2, 3, a2, x0, x0
    NOT_REACHED
    .org 0x400                  /* 12: VTRACE, cap 0; illegal without the ray unit */
    .insn r 0x2B, 1, 0, a2, a1, x0
    NOT_REACHED
    .org 0x440                  /* 13: QRCP a2, x0; illegal without HAS_QRCP */
    .insn r 0x0B, 2, 0, a2, x0, x0
    NOT_REACHED
    .org 0x480                  /* 14: DENDIF, no divergence unit in Stage 0 */
    .insn r 0x5B, 2, 0, x0, x0, x0
    NOT_REACHED
    .org 0x4c0                  /* 15: fetch outside instruction memory */
    li     a3, 0x8000
    jr     a3
    .org 0x500                  /* 16: all-zero word (not an RV32I instruction) */
    .word  0
    NOT_REACHED
    .org 0x540                  /* 17: JALR to a target with bit 1 set */
    li     a3, 0x542
    jalr   a2, 0(a3)            /* halts here, a2 not linked */
    NOT_REACHED
    .org 0x580                  /* 18: undefined opcode 0x07 (flw a2, 0(a1)) */
    .insn i 0x07, 2, a2, 0(a1)
    NOT_REACHED
    .org 0x5c0                  /* 19: OP with undefined funct7 0x10 */
    .insn r 0x33, 0, 0x10, a2, a0, a1
    NOT_REACHED
    .org 0x600                  /* 20: LOAD with undefined funct3 011 (ld) */
    .insn i 0x03, 3, a2, 0(t0)
    NOT_REACHED
    .org 0x640                  /* 21: taken BEQ x0, x0, +6 */
    .word  0x00000363
    NOT_REACHED
    .org 0x680                  /* 22: JAL a2, +6 (link not written) */
    .word  0x0060066F
    NOT_REACHED
    .org 0x6c0                  /* 23: VSET field 8 (reserved) */
    .insn r 0x2B, 0, 8, x0, a1, x0
    NOT_REACHED
    .org 0x700                  /* 24: VTRACE with funct7 1 (reserved) */
    .insn r 0x2B, 1, 1, a2, a1, x0
    NOT_REACHED
    .org 0x740                  /* 25: custom-1 funct3 011 (reserved) */
    .insn r 0x2B, 3, 0, a2, a1, x0
    NOT_REACHED
    .org 0x780                  /* 26: VSET field 0; illegal without the ray unit */
    .insn r 0x2B, 0, 0, x0, a1, x0
    NOT_REACHED
    .org 0x7c0                  /* 27: VGET field 1; illegal without the ray unit */
    .insn r 0x2B, 2, 1, a2, x0, x0
    NOT_REACHED
    .org 0x800                  /* 28: QRCP with funct7 1 (reserved) */
    .insn r 0x0B, 2, 1, a2, a1, x0
    NOT_REACHED
    .org 0x840                  /* 29: QRCP with rs2 = a1 (reserved) */
    .insn r 0x0B, 2, 0, a2, a1, a1
    NOT_REACHED
    .org 0x880                  /* 30: custom-0 funct3 100 (reserved) */
    .insn r 0x0B, 4, 0, a2, a1, x0
    NOT_REACHED
    .org 0x8c0                  /* 31: legal control */
    fence
    fence.i
    .word  0x00001363           /* BNE x0, x0, +6: not taken, no error */
    li     s0, MMIO_BASE
    lw     a4, MMIO_ERR(s0)
    sw     a4, 0xE0(t0)         /* ERR after reset */
    lw     a4, MMIO_ERR_PC(s0)
    sw     a4, 0xE4(t0)         /* ERR_PC after reset */
    li     a5, 0x80000000       /* region 0x8: first unmapped region */
    sw     a4, 0(a5)            /* unmapped: dropped */
    lw     a4, 0(a5)
    sw     a4, 0xEC(t0)
    lw     a4, 0(zero)          /* imem region is fetch only: reads 0 */
    sw     a4, 0xD8(t0)
    li     a4, 1
    sw     a4, (TB_DONE - DMEM_BASE)(t0)
1:  j      1b
