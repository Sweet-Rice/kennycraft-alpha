/* t_pipe_stress: back-to-back hazards for the pipelined core (P8), on the
   Stage 2 core (LANES = 8, divergence stack, ray unit, QRCP).

   The fast pass runs every sequence with no gap between producer and
   consumer, so core_pipe forwards (MEM -> EX, WB -> EX, WB -> ID), stalls
   (load-use, MUL, QRCP, VTRACE, the lane-serial LSU) and flushes (branches,
   JALR, mask writers, DIF/DELSE/DENDIF), and stores each result per lane
   to res[k]. The slow pass recomputes every result with SLOW (three NOPs:
   the producer has left WB before the consumer reads the register file)
   between dependent instructions and ORs (fast ^ slow) into s11 in every
   lane; s11 = 0 at the end in every lane. Wrong-path markers also set s11.

   Covered: load-use chains, a store of a just-loaded value, MUL into use,
   into store data and into a branch, QRCP after load-use and chained,
   VSET from just-computed values, VTRACE with a forwarded cap, VGET right
   after, VTRACE with cap 0 (no write) and under a partial mask, BALLOT,
   LMASK, MASKGET and MASKSET from forwarded values, DIF/DELSE/DENDIF on a
   loaded condition, JALR through a loaded target and use of its link,
   QRCP into an ALU op, a branch, store data, another QRCP and a JALR
   target, back-to-back QRCPs (independent and two apart), and QRCP plus a
   dependent op under a partial mask;
   mul-use (MUL leaves MEM in one cycle and is forwarded only from WB): a
   MUL right before a dependent ALU op (rs1 and rs2), branch (taken and not),
   JALR target, store data, store address, load address, QRCP and VSET;
   MUL -> MULH -> MULHSU -> MULHU chains; MULH/MULHSU/MULHU into ALU ops;
   dependents at distance 2; MUL and its dependent under a partial mask,
   where the inactive lanes keep their old rd. A stale operand there takes
   a wrong path (s11), a decoy address, or a different value. */
#include "kc_test.h"
#include "kc_lanes.h"
#define VSET(f, rs)    .insn r 0x2B, 0, f, x0, rs, x0
#define VTRACE(rd, rs) .insn r 0x2B, 1, 0, rd, rs, x0
#define VGET(rd, f)    .insn r 0x2B, 2, f, rd, x0, x0
#define SLOW           nop; nop; nop
#define RES(k)         (256 + 32 * (k))
/* s11 |= res[k] ^ reg (t6 scratch) */
#define CHECK(k, reg)  lw t6, RES(k)(s2); SLOW; xor t6, t6, reg; SLOW; or s11, s11, t6

    .section .text.start
    .globl _start
_start:
    MASKALL
    LANEID(s0)
    slli  s1, s0, 2
    li    s2, 0x10001000
    add   s2, s2, s1            /* per-lane scratch: s2 = 0x10001000 + 4 * lane */
    li    s9, 0
    li    s11, 0

    /* ---------------- fast pass ---------------- */
    /* load-use chains, store of a just-loaded value */
    addi  t0, s0, 7
    sw    t0, 0(s2)
    lw    t1, 0(s2)
    addi  t2, t1, 1
    lw    t3, 0(s2)
    sw    t3, 32(s2)
    lw    t4, 32(s2)
    add   t5, t4, t3
    lw    a0, 0(s2)
    beq   a0, t0, 1f
    li    s11, 0xbad
1:  sw    t2, RES(0)(s2)
    sw    t5, RES(1)(s2)
    /* MUL into use, MUL into store data, MUL into branch */
    mul   a1, t5, t5
    add   a2, a1, s0
    mulh  a3, a2, t0
    sw    a3, 64(s2)
    mulhu a4, a1, a1
    mul   a5, a4, a2
    bne   a5, a5, 2f
    lw    a6, 64(s2)
    mul   a7, a6, a6
2:  sw    a5, RES(2)(s2)
    sw    a7, RES(3)(s2)
    sw    a3, RES(4)(s2)
    /* QRCP after load-use and into use, chained */
    lw    s3, 0(s2)
    slli  s3, s3, 16
    sw    s3, 96(s2)
    lw    s4, 96(s2)
    QRCP(s5, s4)
    add   s6, s5, s4
    QRCP(s7, s6)
    QRCP(s8, s7)
    sw    s5, RES(5)(s2)
    sw    s6, RES(6)(s2)
    sw    s8, RES(7)(s2)
    /* ray unit: VSET from just-computed per-lane values, VTRACE with a cap
       from the previous instruction, VGET right after, use right after */
    slli  t0, s0, 3
    addi  t0, t0, 3
    VSET(0, t0)
    li    t1, 0x8000
    add   t1, t1, s1
    VSET(1, t1)
    li    t1, 0x9000
    VSET(2, t1)
    li    t1, 0xA000
    VSET(3, t1)
    li    t1, 0x10000
    VSET(4, t1)
    VSET(5, t1)
    VSET(6, t1)
    andi  t1, s0, 7
    VSET(7, t1)
    li    t2, 12
    VTRACE(a0, t2)
    VGET(a1, 0)
    VGET(a2, 1)
    add   a3, a0, a1
    xor   a3, a3, a2
    sw    a3, RES(8)(s2)
    lw    t2, RES(8)(s2)
    andi  t2, t2, 0
    VTRACE(a4, t2)              /* cap 0: no write, a4 keeps the MULHU value */
    li    t3, 0x5A
    MASKSET(t3)
    li    t2, 40
    VTRACE(a5, t2)
    VGET(a6, 1)
    add   a7, a5, a6
    MASKALL
    sw    a4, RES(9)(s2)
    sw    a7, RES(10)(s2)
    /* mask ops from forwarded values */
    andi  t0, s0, 1
    BALLOT(t1, t0)
    LMASK(t0)
    MASKGET(t2)
    addi  t3, t2, 1
    MASKALL
    sw    t1, RES(11)(s2)
    sw    t3, RES(12)(s2)
    /* DIF/DELSE/DENDIF on a loaded condition */
    lw    t4, 0(s2)
    andi  t4, t4, 2
    DIF(t4, 3f)
    addi  s9, s9, 5
    lw    s10, 0(s2)
    DELSE(4f)
3:  addi  s9, s9, 9
4:  DENDIF
    sw    s9, RES(13)(s2)
    /* JALR through a loaded target, link used right after */
    la    t0, 5f
    sw    t0, 192(s2)
    lw    t1, 192(s2)
    jalr  ra, 0(t1)
fast_link:
    li    s11, 0xbad
5:  add   s9, s9, ra
    sw    s9, RES(14)(s2)
    /* QRCP into an ALU op, a branch, store data, another QRCP and a JALR
       target; back-to-back QRCPs; QRCP and a dependent op under a partial
       mask */
    lw    t0, 0(s2)
    slli  t0, t0, 12              /* (lane + 7) << 12 */
    QRCP(t1, t0)
    addi  t2, t1, 3               /* QRCP -> ALU */
    QRCP(t3, t0)
    beq   t3, t1, qr_br           /* QRCP -> branch, taken in every lane */
    li    s11, 0xbad
qr_br:
    QRCP(t4, t2)
    sw    t4, RES(16)(s2)         /* QRCP -> store data */
    QRCP(t5, t4)                  /* QRCP -> QRCP */
    QRCP(a1, t0)                  /* back to back, independent */
    QRCP(a0, t5)                  /* QRCP two back */
    sw    t2, RES(15)(s2)
    sw    t5, RES(17)(s2)
    sw    a1, RES(18)(s2)
    sw    a0, RES(19)(s2)
    lui   a5, 0x40000             /* qrcp(0x40000000) = 3 (t_qrcp.S qr_exp) */
    QRCP(a2, a5)
    .option push
    .option norelax               /* else ld relaxes the base to x0 (< 2 KB) */
    jalr  ra, %lo(qr_jt - 3)(a2)  /* QRCP -> JALR, to qr_jt (below 2 KB) */
    .option pop
qr_link:
    li    s11, 0xbad
qr_jt:
    sw    ra, RES(20)(s2)
    lui   a3, 0x5A5A0
    or    a3, a3, s0              /* preset, kept by the inactive lanes */
    mv    a4, a3
    li    a6, 0x5A
    MASKSET(a6)
    QRCP(a3, t0)                  /* lanes 1, 3, 4, 6 */
    add   a4, a3, a3              /* QRCP -> ALU under the mask */
    MASKALL
    sw    a3, RES(21)(s2)
    sw    a4, RES(22)(s2)
    /* mul-use: the product reaches the WB forward only */
    li    a0, 0x9234567B
    xor   a0, a0, s1            /* negative, per lane */
    li    a1, 0x6543210F
    add   a1, a1, s0            /* positive, per lane */
    li    a2, 0xFEDCBA98
    sub   a2, a2, s1            /* negative, per lane */
    li    a4, 1
    li    t0, 0
    mul   t0, a0, a1            /* into an ALU op, then rs2 at distance 2 */
    add   t1, t0, a2
    sub   t2, a2, t0
    sw    t1, RES(23)(s2)
    sw    t2, RES(24)(s2)
    li    t4, 0                 /* into a branch: not taken, then taken */
    mul   t4, a0, a1
    bne   t4, t0, mu_br_bad
    li    t4, 0
    mul   t4, a1, a0
    beq   t0, t4, mu_br_ok
mu_br_bad:
    li    s11, 0xbad
mu_br_ok:
    la    t5, mu_jr_bad         /* into a JALR target (stale: the marker) */
    la    t4, mu_jr_ok
    mul   t5, t4, a4
    jalr  ra, 0(t5)
mu_jr_bad:
    li    s11, 0xbad
mu_jr_ok:
    li    t3, 0
    mul   t3, a0, a2            /* into store data */
    sw    t3, RES(27)(s2)
    sw    a2, 128(s2)           /* decoy at the stale address */
    addi  a6, s2, RES(28)
    addi  t3, s2, 128
    mul   t3, a6, a4            /* into a store address */
    sw    a1, 0(t3)
    addi  t3, s2, 128
    mul   t3, a6, a4            /* into a load address */
    lw    t4, 0(t3)
    sw    t4, RES(29)(s2)
    andi  a7, a1, 0x7FF
    addi  a7, a7, 0x100
    li    t3, 0x10000
    mul   t3, a7, a7            /* into QRCP */
    QRCP(t4, t3)
    sw    t4, RES(30)(s2)
    slli  a6, s0, 3
    addi  a6, a6, 3
    andi  a7, s0, 7
    addi  t3, a6, 1
    mul   t3, a6, a4            /* into VSET: start cell, step signs */
    VSET(0, t3)
    xori  t3, a7, 5
    mul   t3, a7, a4
    VSET(7, t3)
    li    t2, 12
    VTRACE(a3, t2)
    VGET(a5, 0)
    add   a3, a3, a5
    sw    a3, RES(31)(s2)
    mul   t0, a0, a1            /* MUL -> MUL -> MULH -> MULHSU -> MULHU */
    mul   t1, t0, a2
    mulh  t2, t1, t0
    mulhsu t3, t2, a0
    mulhu t4, a2, t3
    sw    t4, RES(32)(s2)
    sw    t2, RES(33)(s2)
    mulh  t0, a0, a2            /* MULH, MULHSU, MULHU into ALU ops */
    add   t1, t0, a1
    mulhsu t2, a2, a1
    sub   t3, a0, t2
    mulhu t4, a0, a2
    xor   t5, t4, t1
    sw    t1, RES(34)(s2)
    sw    t3, RES(35)(s2)
    sw    t5, RES(36)(s2)
    mul   t0, a1, a1            /* distance 2: rs1, store data */
    addi  t1, a0, 1
    xor   t2, t0, t1
    mulhu t3, a0, a1
    nop
    sw    t3, RES(38)(s2)
    sw    t2, RES(37)(s2)
    addi  a3, s0, 0x111         /* partial mask: inactive lanes keep rd */
    addi  a5, s0, 0x222
    li    t3, 0x5A
    MASKSET(t3)
    mul   a3, a0, a1
    add   a5, a3, s0
    MASKALL
    sw    a3, RES(39)(s2)
    sw    a5, RES(40)(s2)

    /* ---------------- slow pass ---------------- */
    li    s9, 0
    SLOW
    addi  t0, s0, 7
    SLOW
    sw    t0, 0(s2)
    SLOW
    lw    t1, 0(s2)
    SLOW
    addi  t2, t1, 1
    SLOW
    CHECK(0, t2)
    lw    t3, 0(s2)
    SLOW
    add   t5, t3, t3
    SLOW
    CHECK(1, t5)

    mul   a1, t5, t5
    SLOW
    add   a2, a1, s0
    SLOW
    mulh  a3, a2, t0
    SLOW
    CHECK(4, a3)
    mulhu a4, a1, a1
    SLOW
    mul   a5, a4, a2
    SLOW
    CHECK(2, a5)
    mul   a7, a3, a3
    SLOW
    CHECK(3, a7)

    lw    s3, 0(s2)
    SLOW
    slli  s3, s3, 16
    SLOW
    QRCP(s5, s3)
    SLOW
    CHECK(5, s5)
    add   s6, s5, s3
    SLOW
    CHECK(6, s6)
    QRCP(s7, s6)
    SLOW
    QRCP(s8, s7)
    SLOW
    CHECK(7, s8)

    slli  t0, s0, 3
    SLOW
    addi  t0, t0, 3
    SLOW
    VSET(0, t0)
    li    t1, 0x8000
    SLOW
    add   t1, t1, s1
    SLOW
    VSET(1, t1)
    li    t1, 0x9000
    SLOW
    VSET(2, t1)
    li    t1, 0xA000
    SLOW
    VSET(3, t1)
    li    t1, 0x10000
    SLOW
    VSET(4, t1)
    VSET(5, t1)
    VSET(6, t1)
    andi  t1, s0, 7
    SLOW
    VSET(7, t1)
    li    t2, 12
    SLOW
    VTRACE(a0, t2)
    SLOW
    VGET(a1, 0)
    VGET(a2, 1)
    SLOW
    add   a3, a0, a1
    SLOW
    xor   a3, a3, a2
    SLOW
    CHECK(8, a3)
    li    t2, 0
    SLOW
    VTRACE(a4, t2)              /* cap 0: a4 keeps the slow MULHU value */
    SLOW
    CHECK(9, a4)
    li    t3, 0x5A
    SLOW
    MASKSET(t3)
    li    t2, 40
    SLOW
    VTRACE(a5, t2)
    SLOW
    VGET(a6, 1)
    SLOW
    add   a7, a5, a6
    SLOW
    MASKALL
    CHECK(10, a7)

    andi  t0, s0, 1
    SLOW
    BALLOT(t1, t0)
    SLOW
    LMASK(t0)
    MASKGET(t2)
    SLOW
    addi  t3, t2, 1
    MASKALL
    CHECK(11, t1)
    CHECK(12, t3)

    lw    t4, 0(s2)
    SLOW
    andi  t4, t4, 2
    SLOW
    DIF(t4, 6f)
    addi  s9, s9, 5
    DELSE(7f)
6:  addi  s9, s9, 9
7:  DENDIF
    CHECK(13, s9)
    la    t0, fast_link
    SLOW
    add   s9, s9, t0
    SLOW
    CHECK(14, s9)

    lw    t0, 0(s2)
    SLOW
    slli  t0, t0, 12
    SLOW
    QRCP(t1, t0)
    SLOW
    addi  t2, t1, 3
    SLOW
    CHECK(15, t2)
    QRCP(t4, t2)
    SLOW
    CHECK(16, t4)
    QRCP(t5, t4)
    SLOW
    CHECK(17, t5)
    QRCP(a1, t0)
    SLOW
    CHECK(18, a1)
    QRCP(a0, t5)
    SLOW
    CHECK(19, a0)
    la    t1, qr_link
    SLOW
    CHECK(20, t1)
    lui   a3, 0x5A5A0
    SLOW
    or    a3, a3, s0
    SLOW
    mv    a4, a3
    li    a6, 0x5A
    SLOW
    MASKSET(a6)
    QRCP(a3, t0)
    SLOW
    add   a4, a3, a3
    SLOW
    MASKALL
    CHECK(21, a3)
    CHECK(22, a4)
    li    a0, 0x9234567B
    li    a1, 0x6543210F
    li    a2, 0xFEDCBA98
    li    a4, 1
    SLOW
    xor   a0, a0, s1
    add   a1, a1, s0
    sub   a2, a2, s1
    SLOW
    mul   t0, a0, a1
    mul   t3, a0, a2
    SLOW
    add   t1, t0, a2
    sub   t2, a2, t0
    SLOW
    CHECK(23, t1)
    CHECK(24, t2)
    CHECK(27, t3)
    CHECK(28, a1)
    CHECK(29, a1)
    andi  a7, a1, 0x7FF
    SLOW
    addi  a7, a7, 0x100
    SLOW
    mul   t3, a7, a7
    SLOW
    QRCP(t4, t3)
    SLOW
    CHECK(30, t4)
    slli  a6, s0, 3
    andi  a7, s0, 7
    li    t2, 12
    SLOW
    addi  a6, a6, 3
    SLOW
    VSET(0, a6)
    VSET(7, a7)
    VTRACE(a3, t2)
    SLOW
    VGET(a5, 0)
    SLOW
    add   a3, a3, a5
    SLOW
    CHECK(31, a3)
    mul   t0, a0, a1
    SLOW
    mul   t1, t0, a2
    SLOW
    mulh  t2, t1, t0
    SLOW
    mulhsu t3, t2, a0
    SLOW
    mulhu t4, a2, t3
    SLOW
    CHECK(32, t4)
    CHECK(33, t2)
    mulh  t0, a0, a2
    mulhsu t2, a2, a1
    mulhu t4, a0, a2
    SLOW
    add   t1, t0, a1
    sub   t3, a0, t2
    SLOW
    xor   t5, t4, t1
    SLOW
    CHECK(34, t1)
    CHECK(35, t3)
    CHECK(36, t5)
    mul   t0, a1, a1
    addi  t1, a0, 1
    mulhu t3, a0, a1
    SLOW
    xor   t2, t0, t1
    SLOW
    CHECK(37, t2)
    CHECK(38, t3)
    addi  a3, s0, 0x111
    addi  a5, s0, 0x222
    li    t3, 0x5A
    SLOW
    MASKSET(t3)
    mul   a3, a0, a1
    SLOW
    add   a5, a3, s0
    SLOW
    MASKALL
    CHECK(39, a3)
    CHECK(40, a5)

    li    t1, 1
    MASKSET(t1)
    li    t6, 1
    li    t5, TB_DONE
    sw    t6, 0(t5)
8:  j     8b

    .data
    .word 0
