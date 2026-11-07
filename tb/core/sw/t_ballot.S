/* t_ballot: BALLOT (Tai_2 section 2, BALLOT row; Stage 1 rung 5). rd =
   {0, M & (rs1 != 0)}, written in every lane, active or not; rs1 = x0
   gives 0; with M = 0 every lane gets 0; rd = x0 writes nothing. Results
   stay in registers. */
#include "kc_test.h"
#include "kc_lanes.h"

    .section .text.start
    .globl _start
_start:
    MASKALL
    LANEID(s0)                  /* s0 = lane */
    andi  s1, s0, 1             /* odd lanes */
    slli  s2, s0, 29            /* lanes 1..7, bit 31 in lane 4 */
    li    s3, 0x0F
    li    s4, 0
    li    s5, 1
    li    a0, 0x50
    li    a1, 0x51
    li    a2, 0x52
    li    a3, 0x53
    li    a4, 0x54
    li    a5, 0x55

    BALLOT(a0, s1)              /* full mask: odd lanes */
    BALLOT(a1, s2)              /* full mask: lanes 1..7 */
    MASKSET(s3)                 /* M = 0x0F */
    BALLOT(a2, s0)              /* lanes 1..3, written in lanes 4..7 too */
    BALLOT(a3, x0)              /* 0 everywhere */
    BALLOT(x0, s0)              /* no write */
    MASKSET(s4)                 /* M = 0 */
    BALLOT(a4, s2)              /* 0 everywhere */
    MASKSET(s5)                 /* lane 0 */
    BALLOT(a5, s5)              /* 1 everywhere */

    li    t6, 1
    li    t5, TB_DONE
    sw    t6, 0(t5)
1:  j     1b
