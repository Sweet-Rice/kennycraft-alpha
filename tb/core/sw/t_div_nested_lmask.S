/* t_div_nested_lmask: mask changes inside if/else bodies are undone by
   DENDIF (Tai_2 section 2, Divergence stack; Stage 1 rung 7). From the full
   mask, DIF on lanes 0..5; the then body narrows to odd lanes with LMASK,
   runs a nested DIF (lanes >= 3) whose body empties the mask with LMASK x0
   and whose DENDIF restores the odd-lane mask; DELSE ignores the LMASK and
   sets the else mask (lanes 6, 7), whose body wakes lanes 0..3 with
   MASKSET; the final DENDIF restores the full mask. Results stay in
   registers. */
#include "kc_test.h"
#include "kc_lanes.h"

    .section .text.start
    .globl _start
_start:
    MASKALL
    LANEID(s0)
    sltiu s1, s0, 6             /* lanes 0..5 */
    andi  s2, s0, 1             /* odd */
    sltiu s5, s0, 3
    xori  s5, s5, 1             /* lanes >= 3 */
    li    s3, 0x0F
    li    a0, 0x50
    li    a1, 0x51
    li    t4, 0x5D
    li    t5, 0x5E
    li    a3, 0x53
    li    a4, 0x54

    DIF(s1, else1)
    LMASK(s2)                   /* odd lanes of 0x3F */
    li    a0, 0x11
    DIF(s5, end2)
    LMASK(x0)
    li    a4, 0xBAD             /* no lane */
end2:
    DENDIF                      /* back to the odd lanes */
    li    a3, 0x33
    MASKGET(t3)
else1:
    DELSE(end1)                 /* else mask from DIF, LMASK undone */
    MASKGET(t4)
    MASKSET(s3)                 /* wakes lanes 0..3 */
    li    a1, 0x22
    MASKGET(t5)
end1:
    DENDIF
    MASKGET(a2)                 /* full */

    li    t6, 1
    MASKSET(t6)
    li    t6, 1
    li    t2, TB_DONE
    sw    t6, 0(t2)
3:  j     3b
