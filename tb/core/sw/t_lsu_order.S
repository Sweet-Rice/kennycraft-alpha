/* t_lsu_order: the lane-serial LSU (Tai_2 section 2, Loads and Stores rows;
   Stage 1 rung 4). With every lane active: per-lane SW to distinct
   addresses, SW of every lane to one address (the highest lane wins), LW of
   another lane's word, LB/LBU/LH at a different byte offset per lane, SB and
   SH per lane. Under mask 0xA5 inactive lanes neither load nor store. One LW
   with lane 0 only. The testbench pre-fills A..A+0x17F, checks memory and
   every lane's registers, and checks the bus order and LSU cycles itself.
   After TB_DONE the program runs a SW that is misaligned in lane 3 only,
   which must halt (ERR.ILLEGAL) before any lane reaches the bus; its PC
   goes to 0x1000_00E0 first. */
#include "kc_test.h"

#define LANEID(rd)      .insn r 0x0B, 0, 0, rd, x0, x0
#define MASKSET(rs)     .insn r 0x0B, 6, 0, x0, rs, x0
#define MASKALL         .insn r 0x0B, 7, 0, x0, x0, x0

#define A 0x10001000

    .section .text.start
    .globl _start
_start:
    MASKALL
    LANEID(s0)                  /* s0 = lane */
    li    s1, A
    slli  s2, s0, 2
    add   s2, s2, s1            /* s2 = A + 4 * lane */

    addi  t0, s0, 0x100
    sw    t0, 0(s2)             /* A + 4 * lane = 0x100 + lane */
    addi  t0, s0, 0x200
    sw    t0, 0x40(s1)          /* every lane, one address: highest wins */

    xori  t1, s0, 1
    slli  t1, t1, 2
    add   t1, t1, s1
    lw    a0, 0(t1)             /* the word lane ^ 1 stored */

    add   t1, s1, s0
    lb    a1, 0x80(t1)          /* bytes at A + 0x80 + lane */
    lbu   a2, 0x80(t1)
    andi  t1, s0, 3
    slli  t1, t1, 1
    add   t1, t1, s1
    lh    a3, 0x80(t1)          /* halfword at A + 0x80 + 2 * (lane & 3) */
    lhu   a4, 0x80(t1)

    add   t1, s1, s0
    addi  t0, s0, 0x30
    sb    t0, 0xC0(t1)          /* A + 0xC0 + lane = 0x30 + lane */
    slli  t1, s0, 1
    add   t1, t1, s1
    li    t0, 0x4000
    add   t0, t0, s0
    sh    t0, 0xE0(t1)          /* A + 0xE0 + 2 * lane = 0x4000 + lane */

    li    a5, 0x5555
    li    t0, 0xA5
    MASKSET(t0)                 /* lanes 0, 2, 5, 7 */
    lw    a5, 0(s2)             /* active lanes: 0x100 + lane */
    addi  t0, s0, 0x300
    sw    t0, 0x100(s2)         /* active lanes: A + 0x100 + 4 * lane */

    li    t0, 1
    MASKSET(t0)                 /* lane 0 only */
    lw    a6, 0x40(s1)          /* the same-address winner */

    la    t0, fault
    li    t1, 0x100000E0
    sw    t0, 0(t1)
    li    t0, 1
    li    t1, TB_DONE
    sw    t0, 0(t1)

    MASKALL
    xori  t1, s0, 3
    seqz  t1, t1
    slli  t1, t1, 1
    add   t1, t1, s2            /* lane 3: A + 14, others 4-aligned */
fault:
    sw    s0, 0x140(t1)
1:  j     1b
