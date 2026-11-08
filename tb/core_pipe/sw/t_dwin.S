/* t_dwin: loads and stores in the dmem window (dmem 0x6000 to 0x7FFF, kc_isa_pkg
   DWIN_*), which core_pipe serves from eight distributed-RAM banks (bank =
   addr[12:10]) and the multi-cycle core from the dmem BRAM, on the Stage 2
   core. Every loaded value lands in a register, so the retire-trace
   comparison of the two cores (tracediff-core-pipe-t_dwin) checks them all;
   t_dwin_tb.sv checks memory and each lane's checksum s10.

   Cases, 8 lanes unless noted:
     1  each lane in its own bank (the crt0 stack layout): SW, then LW, LB,
        LBU, LH, LHU, SH, SB back to back, load-use on every load
     2  every lane in the same bank, eight different words (eight beats)
     3  SB to consecutive bytes: lanes 0-3 share one word, 4-7 the next
     4  SB of every lane to the same byte (the highest lane wins), SH of
        every lane to the same halfword
     5  even lanes in the window, odd lanes in the dmem BRAM, same instruction
     6  32 KB aliases: store at the window + 0x8000, load at + 0x10000
     7  the window edges: 0x1000_5FFC (BRAM) and 0x1000_6000 (window) per lane
     8  initial contents from the dmem image (.data placed at 0x1000_6E00)
     9  a store and a load under the partial mask 0xA5
    10  window load used as the next load's address
   Each lane stores s10 to RES + 4 * lane at the end. */
#include "kc_test.h"
#include "kc_lanes.h"
#define RES 0x10001000

    .section .text.start
    .globl _start
_start:
    MASKALL
    LANEID(s0)
    slli  s1, s0, 10
    li    s2, 0x10008000
    sub   s2, s2, s1
    addi  s2, s2, -64           /* lane slot: bank 7 - lane */
    li    s10, 0

    /* 1: one bank per lane */
    li    t0, 0x81828384
    add   t0, t0, s0
    sw    t0, 0(s2)
    lw    t1, 0(s2)
    add   s10, s10, t1
    lb    t2, 0(s2)
    add   s10, s10, t2
    lbu   t2, 3(s2)
    add   s10, s10, t2
    lh    t2, 2(s2)
    add   s10, s10, t2
    lhu   t2, 0(s2)
    add   s10, s10, t2
    sw    zero, 4(s2)
    sh    t0, 6(s2)
    sb    s0, 4(s2)
    lw    t3, 4(s2)
    add   s10, s10, t3
    sw    t3, 8(s2)
    lw    t4, 8(s2)
    xor   s10, s10, t4

    /* 2: same bank (1), eight words */
    li    s3, 0x10006400
    slli  t4, s0, 2
    add   s3, s3, t4
    slli  t5, s0, 8
    addi  t5, t5, 0x5A
    sw    t5, 0(s3)
    lw    t6, 0(s3)
    add   s10, s10, t6
    lw    t6, 28(s3)            /* lane l reads word 7 + l of the bank */
    add   s10, s10, t6

    /* 3: consecutive bytes, two words */
    li    s4, 0x10006800
    add   s4, s4, s0
    addi  t0, s0, 0x40
    sb    t0, 0(s4)
    andi  t1, s4, -4
    lw    t2, 0(t1)
    add   s10, s10, t2
    lbu   t2, 0(s4)
    add   s10, s10, t2

    /* 4: one byte, one halfword, every lane */
    li    s5, 0x10006C00
    sw    zero, 0(s5)
    sb    t0, 1(s5)
    lw    t1, 0(s5)
    add   s10, s10, t1
    sh    t5, 2(s5)
    lw    t1, 0(s5)
    add   s10, s10, t1

    /* 5: even lanes window, odd lanes BRAM */
    andi  t2, s0, 1
    neg   t2, t2                /* odd: all ones */
    li    t3, 0x10002000
    slli  t4, s0, 2
    add   t3, t3, t4
    addi  t4, s2, 12
    xor   t3, t3, t4
    and   t3, t3, t2
    xor   t3, t3, t4            /* odd ? 0x10002000 + 4 * lane : s2 + 12 */
    addi  t5, s0, 0x300
    sw    t5, 0(t3)
    lw    t6, 0(t3)
    add   s10, s10, t6
    lh    t6, 2(t3)
    add   s10, s10, t6

    /* 6: aliases */
    li    t4, 0x8000
    add   t5, s2, t4
    addi  t0, s0, 0x77
    sw    t0, 16(t5)
    li    t4, 0x10000
    add   t6, s2, t4
    lw    t1, 16(t6)
    add   s10, s10, t1
    lw    t1, 16(s2)
    add   s10, s10, t1

    /* 7: window edges */
    li    t3, 0x10005FFC
    addi  t0, s0, 0x123
    sw    t0, 0(t3)             /* every lane, same BRAM word: lane 7 wins */
    sw    t0, 4(t3)             /* same window word: lane 7 wins */
    lw    t1, 0(t3)
    lw    t2, 4(t3)
    add   s10, s10, t1
    add   s10, s10, t2

    /* 8: initial contents */
    la    t3, win_init
    lw    t1, 0(t3)
    lw    t2, 4(t3)
    add   s10, s10, t1
    add   s10, s10, t2

    /* 9: partial mask */
    li    t1, 0xA5
    MASKSET(t1)
    addi  t0, s0, 0x600
    sw    t0, 20(s2)
    sb    t0, 0x10(s5)
    lw    t1, 20(s2)
    MASKALL
    lw    t2, 20(s2)
    add   s10, s10, t2
    lw    t2, 0x10(s5)
    add   s10, s10, t2

    /* 10: window load as the next load's address */
    sw    s2, 24(s2)
    lw    t3, 24(s2)
    lw    t4, 0(t3)
    add   s10, s10, t4

    slli  t0, s0, 2
    li    t1, RES
    add   t1, t1, t0
    sw    s10, 0(t1)

    li    t1, 1
    MASKSET(t1)
    li    t6, 1
    li    t5, TB_DONE
    sw    t6, 0(t5)
1:  j     1b

    .data
    .word 0
    .org 0x6E00 - 0x100
win_init:
    .word 0x13579BDF, 0x2468ACE0
