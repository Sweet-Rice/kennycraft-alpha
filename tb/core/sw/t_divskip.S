/* t_divskip: the jumps of the divergence stack (Tai_2 section 2, Divergence
   stack; Stage 1 rung 7). A body that would run must write 0xBAD after a
   MASKALL, so a skipped body is visible.
   1. DIF false everywhere jumps to its DELSE; DELSE restores the full else
      mask and the else body runs.
   2. DIF false everywhere without an else jumps straight to DENDIF.
   3. DIF reached with M = 0 pushes {0, 0} and skips to DELSE, which finds
      an empty else mask and skips to DENDIF; M stays 0 afterwards.
   4. Inside a then body that empties the mask with LMASK, a nested DIF
      pushes {0, 0} and skips to its DENDIF; the outer DELSE and DENDIF still
      balance and restore the full mask.
   The testbench checks the registers and that the stack ends empty. */
#include "kc_test.h"
#include "kc_lanes.h"

    .section .text.start
    .globl _start
_start:
    MASKALL
    LANEID(s0)
    li    s1, 0                 /* false */
    li    s2, 1                 /* true */
    li    a0, 0x50
    li    a1, 0x51
    li    a3, 0x53
    li    a5, 0x55
    li    a7, 0x57
    li    t3, 0x5C

    /* 1 */
    DIF(s1, else1)
    MASKALL
    li    a0, 0xBAD
else1:
    DELSE(end1)
    li    a1, 0x11              /* every lane */
end1:
    DENDIF
    MASKGET(a2)

    /* 2 */
    DIF(s1, end2)
    MASKALL
    li    a3, 0xBAD
end2:
    DENDIF
    MASKGET(a4)

    /* 3 */
    LMASK(x0)                   /* M = 0 */
    DIF(s2, else3)
    MASKALL
    li    a5, 0xBAD
else3:
    DELSE(end3)
    MASKALL
    li    a5, 0xBAD
end3:
    DENDIF
    MASKGET(a6)                 /* 0 */
    MASKALL

    /* 4 */
    DIF(s2, else4)              /* true everywhere */
    LMASK(x0)                   /* M = 0 inside the body */
    DIF(s2, end4i)              /* pushes {0, 0}, jumps */
    MASKALL
    li    a7, 0xBAD
end4i:
    DENDIF                      /* M = 0 */
    MASKGET(t3)                 /* 0 */
else4:
    DELSE(end4)                 /* else mask 0: jumps */
    MASKALL
    li    a7, 0xBAD
end4:
    DENDIF
    MASKGET(t4)                 /* full */

    li    t6, 1
    MASKSET(t6)
    li    t6, 1
    li    t2, TB_DONE
    sw    t6, 0(t2)
3:  j     3b
