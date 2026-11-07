/* t_div_cond: the DIF condition is rs1 != 0 per lane, not one bit of rs1
   (Tai_2 section 2, Divergence stack; Stage 1 rung 7). Every lane loads its
   condition from conds[lane]: lanes 0, 2, 5 and 6 hold nonzero values with
   bit 0 clear, lane 3 holds 1, lanes 1, 4 and 7 hold 0, so the then mask is
   0x6D (a cond = rs1[0] decoder would give 0x08). An if/else records both
   masks. Then a DIF whose condition is 0x100 in every lane must run its
   then body and skip the else body. Results stay in registers. */
#include "kc_test.h"
#include "kc_lanes.h"

    .section .text.start
    .globl _start
_start:
    MASKALL
    LANEID(s0)
    la    t1, conds
    slli  t2, s0, 2
    add   t1, t1, t2
    lw    s1, 0(t1)             /* s1 = conds[lane] */
    li    s3, 0x100             /* nonzero, bit 0 clear, every lane */
    li    a0, 0x50
    li    a1, 0x51
    li    a2, 0x52
    li    a3, 0x53
    li    t5, 0x5E
    li    s9, 0x5B

    DIF(s1, else1)
    MASKGET(a0)                 /* then mask */
    li    a1, 0x11
else1:
    DELSE(end1)
    MASKGET(a2)                 /* else mask */
    li    a3, 0x33
end1:
    DENDIF
    MASKGET(a4)                 /* the full mask again */

    DIF(s3, else2)              /* true everywhere */
    li    t5, 0x66
else2:
    DELSE(end2)                 /* else mask 0: jumps to end2 */
    MASKALL
    li    s9, 0xBAD
end2:
    DENDIF
    MASKGET(a5)

    li    t6, 1
    MASKSET(t6)
    li    t6, 1
    li    t2, TB_DONE
    sw    t6, 0(t2)
3:  j     3b

    .data
conds:
    .word 0x80000000, 0x00000000, 0x00000002, 0x00000001
    .word 0x00000000, 0xFFFFFFFE, 0x00010000, 0x00000000
