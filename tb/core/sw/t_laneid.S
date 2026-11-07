/* t_laneid: LANEID and MASKALL on LANES lanes (Tai_2 sections 1 and 2,
   Stage 1 rung 3). Under MASKALL every lane computes from its own LANEID
   (ALU and MUL); under a partial mask only active lanes write rd while
   MASKGET writes every lane; MASKSET takes the scalar lane's rs1 (the lowest
   active lane). Results stay in registers; the testbench reads every lane's
   register file. */
#include "kc_test.h"

#define LANEID(rd)      .insn r 0x0B, 0, 0, rd, x0, x0
#define MASKGET(rd)     .insn r 0x0B, 5, 0, rd, x0, x0
#define MASKSET(rs)     .insn r 0x0B, 6, 0, x0, rs, x0
#define MASKALL         .insn r 0x0B, 7, 0, x0, x0, x0

    .section .text.start
    .globl _start
_start:
    MASKALL
    LANEID(a0)                  /* a0 = lane */
    li    t0, 3
    mul   a1, a0, t0
    addi  a1, a1, 7             /* a1 = 3 * lane + 7 */
    mul   a4, a0, a0            /* a4 = lane * lane */
    li    a2, 0x55              /* presets in every lane */
    li    a3, 0x66
    slli  a6, a0, 4
    ori   a6, a6, 1             /* a6 = lane << 4 | 1 */

    li    t0, 0xA5
    MASKSET(t0)                 /* lanes 0, 2, 5, 7 */
    li    a2, 0x99              /* active lanes only */
    LANEID(a3)                  /* active lanes only */
    MASKGET(a5)                 /* every lane: 0xA5 */

    li    t0, 0xA4
    MASKSET(t0)                 /* lanes 2, 5, 7: scalar lane 2 */
    MASKSET(a6)                 /* lane 2's a6 = 0x21: lanes 0 and 5 */
    MASKGET(a7)                 /* every lane: 0x21 */

    li    t0, 1
    MASKSET(t0)
    li    t0, 1
    li    t1, TB_DONE
    sw    t0, 0(t1)
1:  j     1b
