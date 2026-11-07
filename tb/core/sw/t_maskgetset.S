/* t_maskgetset: MASKGET and MASKSET (Tai_2 sections 1 and 2; Stage 1 rung
   5). MASKGET writes M into every lane, MASKSET takes the scalar lane's
   rs1[LANES-1:0] (the lowest active lane, lane 0 when M = 0), drops the
   upper bits and can wake inactive lanes; MASKGET x0 writes nothing.
   Results stay in registers. */
#include "kc_test.h"
#include "kc_lanes.h"

    .section .text.start
    .globl _start
_start:
    MASKALL
    LANEID(s0)                  /* s0 = lane */
    li    t0, 0x11
    mul   s1, s0, t0
    li    t0, 0xFFFF0000
    or    s1, s1, t0            /* s1 = 0xFFFF0000 | lane * 0x11 */
    addi  s2, s0, 0x0C          /* s2 = lane + 0x0C */
    li    s3, 0xF8
    li    s4, 0x100
    li    s5, 1
    li    a2, 0x52

    MASKSET(s3)                 /* M = 0xF8, scalar lane 3 */
    MASKGET(a0)
    MASKSET(s1)                 /* lane 3: 0x33, wakes lanes 0, 1 */
    MASKGET(a1)
    li    a2, 0x77              /* lanes of 0x33 */
    MASKSET(s1)                 /* lane 0: 0x00 */
    MASKGET(a3)
    MASKSET(s2)                 /* M = 0: lane 0's 0x0C */
    MASKGET(a4)
    MASKGET(x0)
    MASKALL
    MASKGET(a5)
    MASKSET(s4)                 /* rs1 = 0x100: bits above LANES-1 dropped */
    MASKGET(a6)
    MASKSET(s5)                 /* M = 0 at LANES = 8: lane 0's 1 */
    MASKGET(a7)

    li    t6, 1
    li    t5, TB_DONE
    sw    t6, 0(t5)
1:  j     1b
