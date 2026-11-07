/* t_div_halts: uniform checks inside a DIF body, halt priorities and the
   reserved custom-2 encodings (Tai_2 sections 1 and 2, Errors; Stage 1
   rung 7, HAS_DIV_STACK = 1). The testbench writes the case number to
   TB_SELECT and resets the core once per case; case k sits at 0x100 +
   0x80*k. Every DIF body runs under s1 = lane in {0, 1, 4} (0x13).
   0  control: in the body a branch (lane < 5) and a JALR (lanes 0..4 land
      on l0j, lanes 5..7 on tgt) that disagree only outside the body mask;
      no halt, the JALR links in the body lanes.
   1  branch on the odd lane in the body (lane 1 vs 0, 4): ERR.DIVERGE.
   2  JALR to tgt + 4 * lane in the body: ERR.DIVERGE, ra not linked.
   3  case 1 with a misaligned target (+6): ERR.DIVERGE, not ILLEGAL.
   4  DELSE on an empty stack jumping to a misaligned label: ERR.DIVSTACK.
   5  eight nested DIFs, then a DIF false everywhere (t = 0) jumping to a
      misaligned label: ERR.DIVSTACK at the ninth DIF.
   6..10  custom-2 funct3 011..111: ERR.ILLEGAL. */
#include "kc_test.h"
#include "kc_lanes.h"

.macro NOT_REACHED
    li    t2, 1
    sw    t2, (TB_MARK - DMEM_BASE)(t0)
99: j     99b
.endm

    .section .text.start
    .globl _start
_start:
    MASKALL
    LANEID(s0)                  /* s0 = lane */
    li    t1, 0x13
    srl   t1, t1, s0
    andi  s1, t1, 1             /* s1 = lane in {0, 1, 4} */
    andi  s2, s0, 1             /* s2 = odd lane */
    sltiu s3, s0, 5             /* s3 = lane < 5 */
    li    s4, 1                 /* true */
    li    s5, 0                 /* false */
    la    t1, tgt
    slli  t2, s0, 2
    add   s6, t1, t2            /* s6 = tgt + 4 * lane */
    la    t2, l0j
    sub   t2, t2, t1
    neg   t3, s3
    and   t2, t2, t3
    add   s7, t1, t2            /* s7 = lane < 5 ? l0j : tgt */
    li    ra, 0x77
    li    a1, 0x51
    li    a2, 0x52
    li    a3, 0x53
    li    t0, DMEM_BASE
    lw    t1, (TB_SELECT - DMEM_BASE)(t0)
    slli  t1, t1, 7
    addi  t1, t1, 0x100
    jr    t1

    .org 0x100                  /* 0: control */
    j     case0

    .org 0x180                  /* 1: divergent branch in the body */
    DIF(s1, 1f)
    bnez  s2, 1f
1:  NOT_REACHED

    .org 0x200                  /* 2: divergent JALR in the body */
    DIF(s1, 1f)
    jalr  ra, 0(s6)
1:  NOT_REACHED

    .org 0x280                  /* 3: bnez s2, +6 in the body */
    DIF(s1, 1f)
    .word 0x00091363
1:  NOT_REACHED

    .org 0x300                  /* 4: DELSE +6, empty stack */
    .word 0x0000135B
    NOT_REACHED

    .org 0x380                  /* 5: eight DIFs, then DIF s5, +6 */
    .rept 8
    DIF(s4, 1f)
    .endr
1:  .word 0x000A835B
    NOT_REACHED

    .org 0x400                  /* 6 */
    .insn r 0x5B, 3, 0, x0, x0, x0
    NOT_REACHED
    .org 0x480                  /* 7 */
    .insn r 0x5B, 4, 0, x0, x0, x0
    NOT_REACHED
    .org 0x500                  /* 8 */
    .insn r 0x5B, 5, 0, x0, x0, x0
    NOT_REACHED
    .org 0x580                  /* 9 */
    .insn r 0x5B, 6, 0, x0, x0, x0
    NOT_REACHED
    .org 0x600                  /* 10 */
    .insn r 0x5B, 7, 0, x0, x0, x0
    NOT_REACHED

    .org 0x700
tgt:                            /* lane targets, never reached */
    .rept 8
    NOT_REACHED
    .endr

    .org 0x800
case0:
    la    t4, r0                /* the JALR's link value */
    DIF(s1, else0)
    beqz  s3, bad0              /* not taken in the body, taken in 5..7 */
    li    a3, 1
    jalr  a1, 0(s7)
r0: NOT_REACHED
l0j:
    li    a2, 1
    j     else0
bad0:
    NOT_REACHED
else0:
    DELSE(end0)
end0:
    DENDIF
    MASKGET(a0)

    li    t6, 1
    MASKSET(t6)
    li    t6, 1
    sw    t6, (TB_DONE - DMEM_BASE)(t0)
3:  j     3b
