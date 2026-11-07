/* t_branch_uniform: the uniform check on branch outcomes (Tai_2 section 2,
   branch row and Errors; Stage 1 rung 6). The testbench writes the case
   number to TB_SELECT and resets the core once per case.
   Case 0 (no halt): every branch type with lane-dependent operands but one
   outcome; a branch under M = 0xF0 whose inactive lanes disagree, decided by
   scalar lane 4; one under M = 0x0C decided by lane 2; one under M = 0 where
   lanes disagree and lane 0 decides. Each outcome is recorded after MASKALL
   as 1 (taken) or 2 (not taken) in every lane.
   Cases 1..9 sit at 0x100 + 0x40*k as MASKSET, then the faulting branch at
   +4: BEQ, BNE, BLT, BGE, BLTU, BGEU with lane-dependent outcomes under the
   full mask (1..6), a branch whose two active lanes of 0x24 disagree (7), a
   divergent branch with a misaligned target, which is ERR.DIVERGE only (8),
   and a uniform taken branch with a misaligned target under M = 0xF0, which
   is ERR.ILLEGAL (D16) (9). */
#include "kc_test.h"
#include "kc_lanes.h"

.macro NOT_REACHED
    li    t2, 1
    sw    t2, (TB_MARK - DMEM_BASE)(t0)
99: j     99b
.endm

/* Record the outcome of the preceding branch to 1f: taken -> 1, else 2 */
.macro RECORD rd
    MASKALL
    li    \rd, 2
    j     2f
1:  MASKALL
    li    \rd, 1
2:
.endm

    .section .text.start
    .globl _start
_start:
    MASKALL
    LANEID(s0)                  /* s0 = lane */
    li    s1, 8
    li    s2, 4
    li    s3, 2
    li    s4, 0xFF
    li    s5, 0xF0
    li    s6, 0x0C
    li    s7, 0x24
    li    s8, 0
    li    t0, DMEM_BASE
    lw    t1, (TB_SELECT - DMEM_BASE)(t0)
    slli  t1, t1, 6
    addi  t1, t1, 0x100
    jr    t1

    .org 0x100                  /* 0: control */
    j     case0
    .org 0x140                  /* 1: BEQ, lane 0 taken */
    MASKSET(s4)
    beq   s0, x0, 1f
1:  NOT_REACHED
    .org 0x180                  /* 2: BNE, lanes 1..7 taken */
    MASKSET(s4)
    bne   s0, x0, 1f
1:  NOT_REACHED
    .org 0x1c0                  /* 3: BLT, lanes 0..3 taken */
    MASKSET(s4)
    blt   s0, s2, 1f
1:  NOT_REACHED
    .org 0x200                  /* 4: BGE, lanes 4..7 taken */
    MASKSET(s4)
    bge   s0, s2, 1f
1:  NOT_REACHED
    .org 0x240                  /* 5: BLTU, lanes 0, 1 taken */
    MASKSET(s4)
    bltu  s0, s3, 1f
1:  NOT_REACHED
    .org 0x280                  /* 6: BGEU, lanes 2..7 taken */
    MASKSET(s4)
    bgeu  s0, s3, 1f
1:  NOT_REACHED
    .org 0x2c0                  /* 7: M = 0x24, lane 2 taken, lane 5 not */
    MASKSET(s7)
    bltu  s0, s2, 1f
1:  NOT_REACHED
    .org 0x300                  /* 8: BEQ s0, x0, +6: divergent and misaligned */
    MASKSET(s4)
    .word 0x00040363
    NOT_REACHED
    .org 0x340                  /* 9: M = 0xF0, BNE s0, x0, +6: taken, misaligned */
    MASKSET(s5)
    .word 0x00041363
    NOT_REACHED

    .org 0x400
case0:
    beq   s0, s0, 1f            /* taken */
    RECORD a0
    bne   s0, s0, 1f            /* not taken */
    RECORD a1
    blt   s0, s1, 1f            /* taken */
    RECORD a2
    bge   s0, s1, 1f            /* not taken */
    RECORD a3
    bltu  s0, s1, 1f            /* taken */
    RECORD a4
    bgeu  s0, s1, 1f            /* not taken */
    RECORD a5
    MASKSET(s5)                 /* lanes 4..7: not taken (lanes 0..3 would take) */
    bltu  s0, s2, 1f
    RECORD a6
    MASKSET(s6)                 /* lanes 2, 3: taken (lanes 0, 1 would not) */
    bgeu  s0, s3, 1f
    RECORD a7
    MASKSET(s8)                 /* M = 0: lane 0 takes, the others would not */
    beqz  s0, 1f
    RECORD t3

    li    t6, 1
    MASKSET(t6)
    li    t6, 1
    sw    t6, (TB_DONE - DMEM_BASE)(t0)
3:  j     3b
