/* t_jalr_uniform: the uniform check on JALR targets and the link writes of
   JAL/JALR (Tai_2 section 2, JAL and JALR rows and Errors; Stage 1 rung 6).
   The testbench writes the case number to TB_SELECT and resets the core
   once per case.
   Case 0 (no halt): a uniform JALR under the full mask links in every lane;
   lane targets that differ only in bit 0 are one target; under M = 0xF0 the
   target comes from scalar lane 4 although lanes 0..3 hold another one, and
   only lanes 4..7 link; under M = 0 lane 0's target wins and nothing links;
   JAL under M = 0xA5 links in lanes 0, 2, 5, 7 only. Each landing spot
   records 1 (expected) or 2 (wrong target) after MASKALL.
   Cases 1..5 sit at 0x100 + 0x40*k as MASKSET, then the faulting jump at
   +4, and ra (preset 0x77) must stay unlinked in every lane: lane-dependent
   targets under the full mask (1), lanes 2 and 5 of M = 0x24 disagree (2),
   divergent targets of which some are misaligned, ERR.DIVERGE only (3), a
   uniform misaligned JALR target with lanes 1..7 active, ERR.ILLEGAL (4),
   JAL to a misaligned target with lanes 1..7 active, ERR.ILLEGAL (5). */
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
    li    ra, 0x77
    li    a2, 0x52
    li    a4, 0x54
    li    a6, 0x56
    li    s4, 0xFF
    li    s5, 0xFE
    li    s7, 0x24
    li    s1, 0xF0
    li    t3, 0xA5
    la    t1, tgt
    slli  t2, s0, 2
    add   s6, t1, t2            /* s6 = tgt + 4 * lane */
    slli  t2, s0, 1
    add   s9, t1, t2            /* s9 = tgt + 2 * lane: odd lanes misaligned */
    addi  s10, t1, 2            /* s10 = tgt + 2 in every lane */
    li    t0, DMEM_BASE
    lw    t1, (TB_SELECT - DMEM_BASE)(t0)
    slli  t1, t1, 6
    addi  t1, t1, 0x100
    jr    t1

    .org 0x100                  /* 0: control */
    j     case0
    .org 0x140                  /* 1: full mask, target per lane */
    MASKSET(s4)
    jalr  ra, 0(s6)
    NOT_REACHED
    .org 0x180                  /* 2: M = 0x24, lanes 2 and 5 disagree */
    MASKSET(s7)
    jalr  ra, 0(s6)
    NOT_REACHED
    .org 0x1c0                  /* 3: divergent, odd lanes misaligned */
    MASKSET(s4)
    jalr  ra, 0(s9)
    NOT_REACHED
    .org 0x200                  /* 4: M = 0xFE, uniform misaligned JALR */
    MASKSET(s5)
    jalr  ra, 0(s10)
    NOT_REACHED
    .org 0x240                  /* 5: M = 0xFE, JAL ra, +6 */
    MASKSET(s5)
    .word 0x006000EF
    NOT_REACHED

    .org 0x300
tgt:                            /* lane targets of cases 1..4, never reached */
    .rept 16
    NOT_REACHED
    .endr

    .org 0x600
case0:
    la    s2, l1
    la    t4, r1
    jalr  ra, 0(s2)             /* 1: uniform, every lane links */
r1: NOT_REACHED
l1: MASKALL
    li    a0, 1

    la    s3, l2
    andi  t1, s0, 1
    add   s3, s3, t1            /* l2 or l2 + 1: one target after & ~1 */
    jalr  x0, 0(s3)             /* 2 */
    NOT_REACHED
l2: MASKALL
    li    a1, 1

    la    s8, l3
    la    t1, bad3
    sub   t1, t1, s8
    sltiu t2, s0, 4
    neg   t2, t2
    and   t1, t1, t2
    add   s8, s8, t1            /* lanes 0..3: bad3, lanes 4..7: l3 */
    la    t5, r3
    MASKSET(s1)                 /* M = 0xF0 */
    jalr  a2, 0(s8)             /* 3: scalar lane 4, links in 4..7 */
r3: NOT_REACHED
l3: MASKALL
    li    a3, 1
    j     c4
bad3:
    MASKALL
    li    a3, 2

c4: la    s9, bad4
    la    t1, l4
    sub   t1, t1, s9
    sltiu t2, s0, 1
    neg   t2, t2
    and   t1, t1, t2
    add   s9, s9, t1            /* lane 0: l4, others: bad4 */
    MASKSET(x0)                 /* M = 0 */
    jalr  a4, 0(s9)             /* 4: lane 0 decides, no link */
    NOT_REACHED
l4: MASKALL
    li    a5, 1
    j     c5
bad4:
    MASKALL
    li    a5, 2

c5: la    s11, r5
    MASKSET(t3)                 /* M = 0xA5 */
    jal   a6, l5                /* 5: links in lanes 0, 2, 5, 7 */
r5: NOT_REACHED
l5: MASKALL
    li    a7, 1

    li    t6, 1
    MASKSET(t6)
    li    t6, 1
    sw    t6, (TB_DONE - DMEM_BASE)(t0)
3:  j     3b
