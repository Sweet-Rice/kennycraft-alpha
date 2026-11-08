/* t_qrcp: QRCP rd, rs1 (D22, Tai_2 sections 1 and 2) on a core built with
   HAS_QRCP = 1. Under MASKALL every lane takes six inputs of its own from
   qr_in (row r, lane l at qr_in + 32 r + 4 l: edge classes, saturating
   values, negatives, powers of two and their neighbours) into a2..a7. Then
   QRCP x0 (nothing written), QRCP under the partial mask 0xA5 (inactive
   lanes keep their a1 preset) and QRCP with rd = rs1 (s7). The program
   ORs every result's XOR with qr_exp (fixed.c qrcp() of the same input)
   into s9; the testbench checks s9 = 0 and every register in every lane. */
#include "kc_test.h"
#include "kc_lanes.h"

    .section .text.start
    .globl _start
_start:
    MASKALL
    LANEID(s0)                  /* s0 = lane */
    slli  s1, s0, 2             /* s1 = 4 * lane */
    la    t0, qr_in
    add   t0, t0, s1
    lw    s2, 0(t0)
    lw    s3, 32(t0)
    lw    s4, 64(t0)
    lw    s5, 96(t0)
    lw    s6, 128(t0)
    lw    s7, 160(t0)

    QRCP(a2, s2)
    QRCP(a3, s3)
    QRCP(a4, s4)
    QRCP(a5, s5)
    QRCP(a6, s6)
    QRCP(a7, s7)
    QRCP(x0, s5)                /* rd = x0: no write */

    lui   a1, 0x5A5A0
    or    a1, a1, s0            /* a1 = 0x5A5A0000 | lane in every lane */
    li    t1, 0xA5
    MASKSET(t1)                 /* lanes 0, 2, 5, 7 */
    QRCP(a1, s3)                /* active lanes only */
    MASKALL
    QRCP(s7, s7)                /* rd = rs1 */

    la    t0, qr_exp
    add   t0, t0, s1
    li    s9, 0
    lw    t2, 0(t0)
    xor   t2, t2, a2
    or    s9, s9, t2
    lw    t2, 32(t0)
    xor   t2, t2, a3
    or    s9, s9, t2
    lw    t2, 64(t0)
    xor   t2, t2, a4
    or    s9, s9, t2
    lw    t2, 96(t0)
    xor   t2, t2, a5
    or    s9, s9, t2
    lw    t2, 128(t0)
    xor   t2, t2, a6
    or    s9, s9, t2
    lw    t2, 160(t0)
    xor   t3, t2, a7
    or    s9, s9, t3
    xor   t3, t2, s7
    or    s9, s9, t3

    li    t1, 1
    MASKSET(t1)
    li    t6, 1
    li    t5, TB_DONE
    sw    t6, 0(t5)
1:  j     1b

    .data
    .balign 4
qr_in:
    .word 0x00000000, 0x00000001, 0x00000003, 0x00000004, 0xFFFFFFFF, 0xFFFF0000, 0x80000000, 0x7FFFFFFF
    .word 0x00010000, 0x0000FFFF, 0x00010001, 0x00020000, 0x00008000, 0x00000005, 0x00000007, 0x00000008
    .word 0x00012345, 0x00ABCDEF, 0x01000000, 0x3FFFFFFF, 0x40000000, 0x00000400, 0x0001FFFF, 0x000003FF
    .word 0x00001800, 0x00002000, 0x00001FFF, 0x00002001, 0x00000006, 0x00000002, 0xFFFFFFFC, 0x00C0FFEE
    .word 0x00031415, 0x00002718, 0x0BADF00D, 0x00F00000, 0x00000100, 0x000000FF, 0x7FFF0000, 0x00010100
    .word 0x00004000, 0x00004001, 0x00003FFF, 0x12345678, 0x0000A000, 0x00000009, 0x00000011, 0x00000801
qr_exp:                         /* fixed.c qrcp() of qr_in */
    .word 0x40000000, 0x40000000, 0x40000000, 0x3FFFC000, 0x40000000, 0x40000000, 0x40000000, 0x00000002
    .word 0x0000FFFF, 0x00010000, 0x0000FFFF, 0x00007FFF, 0x0001FFFE, 0x33334000, 0x24924000, 0x1FFFE000
    .word 0x0000E100, 0x0000017D, 0x000000FF, 0x00000004, 0x00000003, 0x003FFFC0, 0x00008000, 0x00401000
    .word 0x000AAAA0, 0x0007FFF8, 0x00080040, 0x0007FFC0, 0x2AAA8000, 0x40000000, 0x40000000, 0x00000153
    .word 0x00005328, 0x00068C60, 0x00000015, 0x00000111, 0x00FFFF00, 0x01010000, 0x00000002, 0x0000FF01
    .word 0x0003FFFC, 0x0003FFF0, 0x00040010, 0x0000000E, 0x0001999A, 0x1C71C000, 0x0F0F0000, 0x001FFC00
