/* t_lsu_order: the LSU (Tai_2 section 2, Loads and Stores rows; Stage 1
   rung 4; Tai page, GPU Core, Lane-serial LSU with word coalescing). With
   every lane active: per-lane SW to distinct addresses, SW of every lane to
   one address (the highest lane wins), LW of another lane's word,
   LB/LBU/LH at a different byte offset per lane, SB and SH per lane. Under
   mask 0xA5 inactive lanes neither load nor store. One LW with lane 0 only.
   Then, with every lane active: a uniform LW, an LW and an SW where lanes
   share words in pairs ({0,4} {1,5} {2,6} {3,7}), an SB where lane pairs
   write the same byte, LB/LBU of mixed-sign bytes, a load and a store under
   mask 0, UART_RX read by every lane (one pop per lane, in lane order), an
   LW where lanes 1 and 2 read UART_STATUS and the rest one dmem word, and
   an SB to consecutive framebuffer bytes followed by a uniform framebuffer
   LW. The testbench pre-fills A..A+0x1FF, sends eight UART bytes before it
   writes TB_SELECT, checks memory and every lane's registers, and checks
   the bus accesses and LSU cycles itself.
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

    MASKALL
    lw    s3, 0(s1)             /* uniform: lane 0's 0x100 in every lane */
    li    t2, 5
    mul   t1, s0, t2
    andi  t1, t1, 3
    slli  t1, t1, 2
    add   t1, t1, s1            /* A + 4 * ((5 * lane) & 3) */
    lw    s4, 0x1A0(t1)         /* lanes k and k + 4 share word k */
    addi  t0, s0, 0x700
    sw    t0, 0x1C0(t1)         /* word k: lane k + 4 wins over lane k */
    srli  t1, s0, 1
    add   t1, t1, s1
    addi  t0, s0, 0x50
    sb    t0, 0x1D0(t1)         /* byte lane >> 1: the odd lane wins */
    add   t1, s1, s0
    lb    s5, 0x1E0(t1)         /* bytes ff 01 7f 80 81 7e fe 00 */
    lbu   s6, 0x1E0(t1)

    li    s7, 0x7777
    MASKSET(x0)                 /* no lane */
    lw    s7, 0(s2)             /* no access, s7 kept */
    sw    s0, 0x1F0(s1)         /* no access */
    MASKALL

    li    t1, TB_SELECT
1:  lw    t4, 0(t1)
    beqz  t4, 1b                /* wait until the testbench has sent 8 bytes */
    li    t3, MMIO_BASE
    lw    s8, MMIO_UART_RX(t3)  /* lane n pops byte n */
    addi  t1, s0, -1
    sltiu t1, t1, 2             /* lanes 1 and 2 */
    li    t2, MMIO_BASE + MMIO_UART_STATUS - (A + 0x40)
    mul   t1, t1, t2
    add   t1, t1, s1
    lw    s9, 0x40(t1)          /* lanes 1, 2: UART_STATUS, others A + 0x40 */

    li    t3, 0x40000000        /* framebuffer */
    add   t1, t3, s0
    addi  t0, s0, 0x90
    sb    t0, 0x100(t1)         /* bytes 0x100 + lane */
    lw    s10, 0x100(t3)        /* uniform */
    li    t0, 1
    MASKSET(t0)                 /* lane 0 only */

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
