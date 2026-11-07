/* t_divstack: DIF / DELSE / DENDIF (Tai_2 section 2, Divergence stack;
   Tai page, GPU Core, Divergence walkthrough; Stage 1 rung 7). From the full
   mask, the condition is true on lanes 0, 1 and 4: the then body runs under
   0x13 with a nested if/else on odd lanes and a uniform branch that is
   checked against the body's mask only (lanes 5..7 would disagree), the
   else body under 0xEC, and DENDIF restores 0xFF. Then an if/else whose
   condition is true everywhere: DELSE finds an empty else mask and jumps
   to DENDIF, so the else body never runs. Results stay in registers. */
#include "kc_test.h"
#include "kc_lanes.h"

    .section .text.start
    .globl _start
_start:
    MASKALL
    LANEID(s0)                  /* s0 = lane */
    li    t0, 0x13
    srl   t0, t0, s0
    andi  s1, t0, 1             /* s1 = lane in {0, 1, 4} */
    andi  s2, s0, 1             /* s2 = odd lane */
    li    s3, 1
    li    s5, 5
    li    a0, 0x50
    li    a1, 0x51
    li    a2, 0x52
    li    a3, 0x53
    li    a4, 0x54
    li    a5, 0x55
    li    a6, 0x56
    li    a7, 0x57
    li    s9, 0x5B
    MASKGET(t3)

    DIF(s1, else1)
    MASKGET(a0)                 /* then mask, in every lane */
    li    a1, 0x11
    DIF(s2, else2)              /* nested: odd lanes of the then mask */
    li    a2, 0x22
else2:
    DELSE(end2)
    li    a3, 0x33
end2:
    DENDIF
    MASKGET(a4)                 /* the then mask again */
    bltu  s0, s5, 1f            /* taken in lanes 0..4: uniform over 0x13 */
    li    a5, 2
    j     2f
1:  li    a5, 1
2:
else1:
    DELSE(end1)
    MASKGET(a6)                 /* else mask */
    li    a7, 0x77
end1:
    DENDIF
    MASKGET(t4)                 /* 0xFF */

    DIF(s3, else3)              /* true everywhere */
    li    t5, 0x66
else3:
    DELSE(end3)                 /* else mask 0: jumps to end3 */
    MASKALL
    li    s9, 0xBAD
end3:
    DENDIF
    MASKGET(s4)

    li    t6, 1
    MASKSET(t6)
    li    t6, 1
    li    t2, TB_DONE
    sw    t6, 0(t2)
3:  j     3b
