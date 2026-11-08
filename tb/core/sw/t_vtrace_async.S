/* t_vtrace_async: asynchronous VTRACE (VTRACE x0) and VGET field 3 on the
   Stage 2 core (LANES = 8, divergence stack, ray unit with the harness's
   all-air world, QRCP). Under MASKALL every lane traces its own ray (SETUP:
   start x = 2 * lane, y = 5, z = 3, stepping +x and +z, y never), so some
   lanes leave the world and some stop at the cap. Per-lane results go to
   RES(k) = 0x1000_1100 + 32 k + 4 lane; the program also ORs every
   async-against-sync mismatch into s11, which must end 0 in every lane.

     A  reference: VTRACE rd, VGET 0 and 1 (RES 0..2)
     B  overlap: CYCLES, VTRACE x0, WORK (80 independent ALU instructions),
        VGET 3, 0, 1, CYCLES (RES 3..6); then the same with VTRACE rd before
        WORK (RES 7..10). VGET 3 = VTRACE rd, and the async run is faster
     C  VSET (tDelta x) right after VTRACE x0 waits: VGET 3, 0, 1 match A
        (RES 11..13)
     D  SW then LW to the world right after VTRACE x0 (the stub world of
        the harness takes both; RES 14..15), and an MMIO store (LEDS)
        right after VTRACE x0 (RES 16)
     E  VTRACE x0 with a cap of 0 and with M = 0: nothing changes
        (RES 17..19)
     F  two VTRACE x0 back to back against two VTRACE rd (RES 20..25)
     G  VTRACE x0 with cap 200, then DIV: the core halts with ERR.ILLEGAL
        while the walk is in flight; the instruction after it never runs.

   Mailbox: 0x1000_00D0 = first PC of the overlap window (WORK, right after
   B's VTRACE x0), D4 = its end (B's VGET 3), D8 = PC of the DIV, TB_MARK = 1 if
   anything after the DIV runs. */
#include "kc_test.h"
#include "kc_lanes.h"
#define VSET(f, rs)    .insn r 0x2B, 0, f, x0, rs, x0
#define VTRACE(rd, rs) .insn r 0x2B, 1, 0, rd, rs, x0
#define VGET(rd, f)    .insn r 0x2B, 2, f, rd, x0, x0
#define RES(k)         (256 + 32 * (k))
#define CAP            100
/* s11 |= a ^ b (t6 scratch) */
#define SAME(a, b)     xor t6, a, b; or s11, s11, t6

    /* DIV is not in rv32i_zmmul; assemble it anyway (case G). */
    .option arch, +m

/* Every lane's ray: start cell {z = 3, y = 5, x = 2 * lane}, tMax x =
   0x8000 + 0x100 * lane, tMax y never, tMax z 0x9000, tDelta 1.0, all
   positive. */
.macro SETUP
    slli  t0, s0, 1
    li    t1, (3 << 11) | (5 << 6)
    add   t0, t0, t1
    VSET(0, t0)
    slli  t1, s0, 8
    li    t2, 0x8000
    add   t1, t1, t2
    VSET(1, t1)
    li    t1, 0x7FFFFFFF
    VSET(2, t1)
    li    t1, 0x9000
    VSET(3, t1)
    li    t1, 0x10000
    VSET(4, t1)
    VSET(5, t1)
    VSET(6, t1)
    VSET(7, x0)
.endm

/* 80 ALU instructions that never touch the ray unit or memory */
.macro WORK
    li    s5, 0
    li    s6, 0
    .rept 20
    addi  s5, s5, 3
    xor   s6, s6, s5
    slli  s7, s5, 1
    add   s6, s6, s7
    .endr
.endm

    .section .text.start
    .globl _start
_start:
    MASKALL
    LANEID(s0)                  /* s0 = lane */
    slli  s1, s0, 2             /* s1 = 4 * lane */
    li    s2, 0x10001000
    add   s2, s2, s1            /* per-lane results: RES(k)(s2) */
    li    s3, MMIO_BASE
    li    s11, 0
    li    t0, DMEM_BASE
    la    t1, ovl_begin
    sw    t1, 0xD0(t0)
    la    t1, ovl_end
    sw    t1, 0xD4(t0)
    la    t1, halt_here
    sw    t1, 0xD8(t0)

    /* A: reference */
    SETUP
    li    t3, CAP
    VTRACE(a0, t3)
    VGET(a1, 0)
    VGET(a2, 1)
    sw    a0, RES(0)(s2)
    sw    a1, RES(1)(s2)
    sw    a2, RES(2)(s2)
    mv    s8, a0                /* s8, s9, s10: A's result, hit cell, t */
    mv    s9, a1
    mv    s10, a2

    /* B: VTRACE x0, then WORK while the walk runs */
    SETUP
    li    t3, CAP
    lw    s4, MMIO_CYCLES(s3)
    VTRACE(x0, t3)
ovl_begin:
    WORK
ovl_end:
    VGET(a3, 3)
    VGET(a4, 0)
    VGET(a5, 1)
    lw    t4, MMIO_CYCLES(s3)
    sub   t4, t4, s4
    sw    a3, RES(3)(s2)
    sw    a4, RES(4)(s2)
    sw    a5, RES(5)(s2)
    sw    t4, RES(6)(s2)
    SAME(a3, s8)
    SAME(a4, s9)
    SAME(a5, s10)
    mv    s4, s6                /* WORK checksum, async */

    /* B': the same with VTRACE rd (the core waits for the walk) */
    SETUP
    li    t3, CAP
    lw    t5, MMIO_CYCLES(s3)
    VTRACE(a6, t3)
    WORK
    VGET(a7, 3)
    lw    t4, MMIO_CYCLES(s3)
    sub   t4, t4, t5
    sw    a6, RES(7)(s2)
    sw    a7, RES(8)(s2)
    sw    s6, RES(9)(s2)
    sw    t4, RES(10)(s2)
    SAME(a6, s8)
    SAME(a7, s8)
    SAME(s6, s4)

    /* C: VSET right after VTRACE x0 waits for the walk */
    SETUP
    li    t3, CAP
    li    t4, 0x40000
    VTRACE(x0, t3)
    VSET(4, t4)                 /* would bend every lane's x steps mid-walk */
    VGET(a3, 3)
    VGET(a4, 0)
    VGET(a5, 1)
    sw    a3, RES(11)(s2)
    sw    a4, RES(12)(s2)
    sw    a5, RES(13)(s2)
    SAME(a3, s8)
    SAME(a4, s9)
    SAME(a5, s10)

    /* D: world SW and LW, then an MMIO store, right after VTRACE x0 */
    SETUP
    li    t3, CAP
    li    t4, 0x20000000
    add   t4, t4, s1            /* world word 0x2000_0000 + 4 * lane */
    li    t5, 0x04030201
    li    t1, 0x01010101
    mul   t1, t1, s0
    add   t5, t5, t1            /* nibbles 1 + lane .. 4 + lane */
    VTRACE(x0, t3)
    sw    t5, 0(t4)
    lw    a3, 0(t4)
    VGET(a4, 3)
    sw    a3, RES(14)(s2)
    sw    a4, RES(15)(s2)
    SAME(a3, t5)
    SAME(a4, s8)
    SETUP
    li    t3, CAP
    addi  t5, s0, 0x40
    VTRACE(x0, t3)
    sw    t5, MMIO_LEDS(s3)     /* lane 7 last: LEDS = 0x47 */
    VGET(a5, 3)
    sw    a5, RES(16)(s2)
    SAME(a5, s8)

    /* E: VTRACE x0 with a cap of 0 and with M = 0 change nothing */
    SETUP
    li    t3, CAP
    VTRACE(x0, t3)
    li    t3, 0
    VTRACE(x0, t3)              /* cap 0 */
    VGET(a3, 3)
    li    t3, CAP
    MASKSET(x0)                 /* M = 0 */
    VTRACE(x0, t3)
    MASKALL
    VGET(a4, 3)
    VGET(a5, 0)
    sw    a3, RES(17)(s2)
    sw    a4, RES(18)(s2)
    sw    a5, RES(19)(s2)
    SAME(a3, s8)
    SAME(a4, s8)
    SAME(a5, s9)

    /* F: a second VTRACE x0 while the first is in flight waits for it */
    SETUP
    li    t3, 30
    li    t4, 40
    VTRACE(a0, t3)
    VTRACE(a1, t4)              /* continues from the first walk's cell */
    VGET(a2, 0)
    VGET(a3, 1)
    sw    a1, RES(20)(s2)
    sw    a2, RES(21)(s2)
    sw    a3, RES(22)(s2)
    SETUP
    VTRACE(x0, t3)
    VTRACE(x0, t4)
    VGET(a4, 3)
    VGET(a5, 0)
    VGET(a6, 1)
    sw    a4, RES(23)(s2)
    sw    a5, RES(24)(s2)
    sw    a6, RES(25)(s2)
    SAME(a4, a1)
    SAME(a5, a2)
    SAME(a6, a3)

    /* G: ERR halt while a walk is in flight */
    SETUP
    li    t3, 200
    li    t0, DMEM_BASE
    VTRACE(x0, t3)
halt_here:
    div   a0, a0, a1            /* illegal: halts at once */
    li    t2, 1
    sw    t2, (TB_MARK - DMEM_BASE)(t0)
1:  j     1b
