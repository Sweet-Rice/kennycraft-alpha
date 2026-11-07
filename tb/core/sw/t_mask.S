/* t_mask: LMASK (Tai_2 section 2, LMASK row; Stage 1 rung 5). A lane stays
   active only if its rs1 != 0 (any bit, bit 31 included); an inactive lane
   never wakes up, even with rs1 != 0; LMASK x0 empties the mask and a
   second LMASK cannot refill it. After each LMASK an LI shows which lanes
   write rd and MASKGET (every lane) shows M. Results stay in registers. */
#include "kc_test.h"
#include "kc_lanes.h"

    .section .text.start
    .globl _start
_start:
    MASKALL
    LANEID(s0)                  /* s0 = lane */
    andi  s1, s0, 1             /* odd lanes */
    slli  s2, s0, 29            /* lanes 1..7 nonzero, lane 4 = 0x8000_0000 */
    srli  s3, s0, 2             /* lanes 4..7 */
    li    a0, 0x11
    li    a1, 0x22
    li    a2, 0x33
    li    a3, 0x44
    li    a4, 0x55

    LMASK(s2)                   /* M1 = full & 0xFE */
    li    a0, 0xA0
    MASKGET(t0)
    LMASK(s1)                   /* M2 = M1 & 0xAA */
    li    a1, 0xA1
    MASKGET(t1)
    LMASK(s3)                   /* M3 = M2 & 0xF0: lanes 4, 6 stay off */
    li    a2, 0xA2
    MASKGET(t2)
    LMASK(x0)                   /* M = 0 */
    li    a3, 0xA3              /* no lane writes */
    MASKGET(t3)
    LMASK(s2)                   /* still 0 */
    MASKGET(t4)
    MASKALL
    li    a4, 0xA4
    MASKGET(t5)

    li    t6, 1
    MASKSET(t6)
    li    t6, 1
    li    a5, TB_DONE
    sw    t6, 0(a5)
1:  j     1b
