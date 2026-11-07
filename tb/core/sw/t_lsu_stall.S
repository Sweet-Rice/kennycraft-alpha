/* t_lsu_stall: lane-serial accesses to slaves that hold bus_ready low (Tai_2
   section 2, Loads and Stores rows; P4 review gap). With every lane active:
   SW and LW through the byte bridge to the world stub (4 bits per byte), one
   word per lane, back to back; SW, LW and LB where even lanes hit dmem and
   odd lanes the world, so dmem and world alternate on consecutive lanes; SW,
   SB, LBU and LW per lane to the texture stub; and a SW of every lane to
   CHUNK_CMD, which the testbench stalls for several cycles per write.
   Results stay in registers. */
#include "kc_test.h"
#include "kc_lanes.h"

    .section .text.start
    .globl _start
_start:
    MASKALL
    LANEID(s0)
    slli  s1, s0, 2             /* lane * 4 */

    /* world, every lane */
    li    t1, 0x0A0B0C0D
    add   s2, t1, s0
    li    t1, 0x20000100
    add   s3, t1, s1
    sw    s2, 0(s3)
    lw    a0, 0(s3)             /* s2 & 0x0F0F0F0F */

    /* even lanes dmem, odd lanes world */
    andi  t2, s0, 1
    li    t1, 0x10003000
    add   t3, t1, s1
    li    t1, 0x20000200
    add   t4, t1, s1
    neg   t5, t2
    xor   t6, t3, t4
    and   t6, t6, t5
    xor   s4, t3, t6            /* odd ? world : dmem */
    li    t1, 0x11223344
    add   s5, t1, s0
    sw    s5, 0(s4)
    lw    a1, 0(s4)
    lb    a2, 1(s4)             /* 0x33 (dmem) or 0x03 (world) */

    /* texture, every lane */
    li    t1, 0x30000040
    add   s6, t1, s1
    sw    x0, 0(s6)
    sb    s0, 2(s6)
    lbu   a3, 2(s6)             /* lane */
    lw    a4, 0(s6)             /* lane << 16 */

    /* CHUNK_CMD from every lane, stalled by the testbench */
    li    t1, MMIO_BASE + 0x30
    addi  s7, s0, 0x100
    sw    s7, 0(t1)

    li    t6, 1
    MASKSET(t6)
    li    t6, 1
    li    t2, TB_DONE
    sw    t6, 0(t2)
1:  j     1b
