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
   a wrong path (s11), a decoy address, or a different value.
   Branch prediction (core_pipe's BTB): a loop back edge predicted taken
   that falls through on its last pass, JAL in a loop (the back edge's
   target, so two predictions in a row) with its link used right after, a
   branch right after MASKSET whose outcome depends on the new scalar lane,
   and a predicted back edge on a just-loaded counter whose target is a
   load used right after.
   Stores that leave MEM in the cycle their last group goes to dmem or the
   framebuffer: a load of the same word right after (dmem and framebuffer,
   one, two and eight groups), a store right after, a mask writer and a
   taken branch right after, a framebuffer store then an FB_SWAP store (the
   testbench checks the framebuffer at swap_req), and dmem window lanes
   mixed with bus lanes (the window done first, and the bus done first).
   MEM completion computed a cycle ahead (window bank conflicts, store
   groups): a window store where a lane shares the word of its bank's lowest
   lane past a conflicting lane between them, then a load of the same words;
   a store of window lanes in three cycles mixed with dmem lanes in two
   groups, then a load; an MMIO lane followed by dmem lanes (the last group
   in dmem, done when the bus is idle), then a load.
   Registered ray-unit strobes: VGET of the cell right after the VSET that
   writes it (full mask and under 0x5A); eight VSETs back to back, VTRACE x0
   right after the last, VGET right after VTRACE x0, VSET right after VGET,
   VTRACE rd right after that VSET and VGET right after it. */
#include "kc_test.h"
#include "kc_lanes.h"
#define VSET(f, rs)    .insn r 0x2B, 0, f, x0, rs, x0
#define VTRACE(rd, rs) .insn r 0x2B, 1, 0, rd, rs, x0
#define VGET(rd, f)    .insn r 0x2B, 2, f, rd, x0, x0
#define SLOW           nop; nop; nop
#define RES(k)         (32 * (k) - 2048)   /* 0x10001000 + 4 * lane + 32 * k */
/* s11 |= res[k] ^ reg (t6 scratch) */
#define CHECK(k, reg)  lw t6, RES(k)(s2); SLOW; xor t6, t6, reg; SLOW; or s11, s11, t6

    .section .text.start
    .globl _start
_start:
    MASKALL
    LANEID(s0)
    slli  s1, s0, 2
    li    s2, 0x10001800
    add   s2, s2, s1            /* per-lane scratch: s2 = 0x10001800 + 4 * lane */
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
    /* BTB: loop back edge, predicted taken from the second pass on, falls
       through on the last (predicted taken: flush) */
    li    t0, 6
    li    t1, 0
20: add   t1, t1, s0
    addi  t1, t1, 3
    addi  t0, t0, -1
    bnez  t0, 20b
    sw    t1, RES(41)(s2)
    /* BTB: JAL in a loop, link used right after; the back edge's target is
       the JAL, so the fetch follows two predictions in a row */
    li    t0, 5
    li    t2, 0
21: jal   a0, 22f
fast_jal_link:
    li    s11, 0xbad
22: add   t2, t2, a0
    addi  t0, t0, -1
    bnez  t0, 21b
    sw    t2, RES(42)(s2)
    /* BTB: branch right after a mask writer. Pass k runs BLT under the mask
       1 << k, so lane k decides: taken for k = 1..3, falls through at 4 */
    li    t5, 1
    li    t3, 0
    li    t4, 4
23: MASKALL
    addi  t3, t3, 1
    slli  t5, t5, 1
    MASKSET(t5)
    blt   s0, t4, 23b
    MASKALL
    add   t3, t3, t5
    sw    t3, RES(43)(s2)
    /* BTB: predicted back edge on a just-loaded counter (load-use), whose
       target is a load used right after */
    li    t0, 4
    sw    t0, 128(s2)
    li    t1, 0
24: lw    t3, 0(s2)
    add   t1, t1, t3
    lw    t4, 128(s2)
    addi  t4, t4, -1
    sw    t4, 128(s2)
    lw    t0, 128(s2)
    bnez  t0, 24b
    sw    t1, RES(44)(s2)

    /* stores that leave MEM at their last group's accept (dmem, framebuffer) */
    li    s4, 0x800
    add   s4, s4, s2            /* per-lane dmem word: s4 = s2 + 0x800 */
    li    s3, 0x10001900
    add   s3, s3, s0            /* per-lane dmem byte: 0x10001900 + lane */
    li    s5, 0x40000100
    add   s5, s5, s1            /* per-lane framebuffer word */
    li    s6, 0x40000140
    add   s6, s6, s0            /* per-lane framebuffer byte */
    /* store, then a load of the same word: dmem eight groups, one group
       (every lane on one word, the highest lane wins), two groups (bytes) */
    addi  t0, s0, 0x31
    sw    t0, 0(s4)
    lw    t1, 0(s4)
    li    a0, 0x10001A00
    addi  t2, s0, 0x41
    sw    t2, 0(a0)
    lw    t3, 0(a0)
    addi  t4, s0, 0x51
    sb    t4, 0(s3)
    lbu   t5, 0(s3)
    sw    t1, RES(45)(s2)
    sw    t3, RES(46)(s2)
    sw    t5, RES(47)(s2)
    /* framebuffer: eight groups, two groups */
    addi  t0, s0, 0x61
    sw    t0, 0(s5)
    lw    t1, 0(s5)
    addi  t2, s0, 0x71
    sb    t2, 0(s6)
    lbu   t3, 0(s6)
    sw    t1, RES(48)(s2)
    sw    t3, RES(49)(s2)
    /* store then store: same words, then dmem then framebuffer */
    addi  t0, s0, 0x81
    addi  t1, s0, 0x91
    sw    t0, 32(s4)
    sw    t1, 32(s4)
    sw    t0, 64(s4)
    sw    t1, 32(s5)
    lw    t2, 32(s4)
    lw    t3, 64(s4)
    lw    t4, 32(s5)
    sw    t2, RES(50)(s2)
    sw    t3, RES(51)(s2)
    sw    t4, RES(52)(s2)
    /* store, then a mask writer and a taken branch; store, then a jump */
    li    t1, 0
    li    t3, 0x0F
    addi  t0, s0, 0xA1
    sw    t0, 96(s4)
    MASKSET(t3)
    beq   x0, x0, 9f
    li    s11, 0xbad
9:  lw    t1, 96(s4)            /* lanes 0 to 3 only */
    MASKALL
    lw    t2, 96(s4)
    sw    t0, 128(s4)
    j     10f
    li    s11, 0xbad
10: lw    t4, 128(s4)
    sw    t1, RES(53)(s2)
    sw    t2, RES(54)(s2)
    sw    t4, RES(55)(s2)
    /* framebuffer store, FB_SWAP store (1 from lane 0 only), framebuffer
       store: the testbench checks every lane's first value at swap_req */
    seqz  t1, s0
    li    a0, MMIO_BASE
    addi  t0, s0, 0x11
    addi  t2, s0, 0x21
    li    s7, 0x40000180
    add   s7, s7, s1
    sw    t0, 0(s7)
    sw    t1, MMIO_FB_SWAP(a0)
    sw    t2, 0(s7)
    lw    t3, 0(s7)
    sw    t3, RES(56)(s2)
    /* dmem window lanes (even) mixed with bus lanes (odd). First a window
       bank per lane (window done in one cycle, bus in four groups), then
       every window lane in bank 0 (four cycles) and the bus lanes on one
       word (one group) */
    andi  t0, s0, 1
    neg   t0, t0                /* -1 in odd lanes */
    li    a0, 0x10006040
    slli  t1, s0, 10
    add   a0, a0, t1            /* window: 0x10006040 + 0x400 * lane */
    addi  a1, s4, 160           /* bus: own dmem word */
    xor   t2, a1, a0
    and   t2, t2, t0
    xor   s8, a0, t2
    addi  t3, s0, 0xB1
    sw    t3, 0(s8)
    lw    t4, 0(s8)
    sw    t4, RES(57)(s2)
    li    a0, 0x10006080
    add   a0, a0, s1            /* window bank 0, a word per lane */
    srli  t1, s0, 1
    li    a1, 0x10001A40
    add   a1, a1, t1            /* bus: a byte each of one word */
    xor   t2, a1, a0
    and   t2, t2, t0
    xor   s8, a0, t2
    addi  t3, s0, 0xC1
    sb    t3, 0(s8)
    lbu   t4, 0(s8)
    sw    t4, RES(58)(s2)
    /* window bank conflicts, every lane in bank 0: the even lanes on one
       word, each odd lane on its own. Lanes 0, 2, 4, 6 go in the first
       cycle (lane 2 shares the word of lane 0, the bank's lowest, though
       lane 1 between them conflicts), then 1, 3, 5, 7 one per cycle */
    andi  t0, s0, 1
    neg   t0, t0
    and   t1, s1, t0
    li    a0, 0x10006100
    add   s8, a0, t1
    addi  t3, s0, 0xD1
    sw    t3, 0(s8)
    lw    t4, 0(s8)
    addi  t4, t4, 1
    sw    t4, RES(59)(s2)
    /* window lanes 0, 2, 4, 6, 7 in bank 1 (three cycles: {0, 4}, {2, 7},
       {6}) with dmem lanes 1, 5 on one word and 3 on another (two groups:
       the store's bus part ends first) */
    la    a0, stress_mix
    add   a0, a0, s1
    lw    s8, 0(a0)
    addi  t3, s0, 0xE1
    sw    t3, 0(s8)
    lw    t4, 0(s8)
    sw    t4, RES(60)(s2)
    /* lane 0 stores to LEDS, lanes 1 to 7 to their own dmem word (lane
       serial: an MMIO lane is pending), then every lane loads its word */
    seqz  t0, s0
    neg   t0, t0                /* -1 in lane 0 */
    li    a0, MMIO_BASE + MMIO_LEDS
    addi  a1, s4, 192
    xor   t2, a1, a0
    and   t2, t2, t0
    xor   s8, a1, t2
    addi  t3, s0, 0xF1
    sw    t3, 0(s8)
    lw    t4, 192(s4)
    sw    t4, RES(61)(s2)
    /* VGET of the cell right after the VSET that writes it, full mask and
       under 0x5A (the inactive lanes keep their cell and their rd) */
    slli  t0, s0, 11
    slli  t1, s0, 6
    add   t0, t0, t1
    add   t0, t0, s0
    addi  t0, t0, 1             /* cell: z = y = lane, x = lane + 1 */
    addi  t2, t0, 0x111
    li    a1, 0
    li    t3, 0x5A
    VSET(0, t0)
    VGET(a0, 0)
    MASKSET(t3)
    VSET(0, t2)
    VGET(a1, 0)
    MASKALL
    VGET(a2, 0)
    add   a0, a0, a1
    add   a0, a0, a2
    sw    a0, RES(62)(s2)
    /* eight VSETs back to back, VTRACE x0 right after the last, VGET 3
       right after it (waits for the walk), VSET right after the VGET,
       VTRACE rd right after that VSET, VGET 1 right after */
    slli  t0, s0, 3
    addi  t0, t0, 5
    li    t1, 0x8000
    add   t1, t1, s1
    li    t2, 0x9000
    li    t3, 0xA000
    li    t4, 0x10000
    andi  t5, s0, 3
    li    a0, 20
    VSET(0, t0)
    VSET(1, t1)
    VSET(2, t2)
    VSET(3, t3)
    VSET(4, t4)
    VSET(5, t4)
    VSET(6, t4)
    VSET(7, t5)
    VTRACE(x0, a0)
    VGET(a1, 3)
    VSET(0, t0)
    VTRACE(a2, a0)
    VGET(a3, 1)
    add   a1, a1, a2
    xor   a1, a1, a3
    sw    a1, RES(63)(s2)

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
    addi  t1, s0, 3
    SLOW
    li    t3, 6
    SLOW
    mul   t1, t1, t3
    SLOW
    CHECK(41, t1)
    la    t3, fast_jal_link
    li    t4, 5
    SLOW
    mul   t2, t3, t4
    SLOW
    CHECK(42, t2)
    li    t3, 20                /* four passes, mask bit 1 << 4 */
    SLOW
    CHECK(43, t3)
    addi  t1, s0, 7
    SLOW
    slli  t1, t1, 2
    SLOW
    CHECK(44, t1)
    li    s4, 0x800
    SLOW
    add   s4, s4, s2
    li    s3, 0x10001900
    SLOW
    add   s3, s3, s0
    li    s5, 0x40000100
    SLOW
    add   s5, s5, s1
    li    s6, 0x40000140
    SLOW
    add   s6, s6, s0
    addi  t0, s0, 0x31
    SLOW
    sw    t0, 0(s4)
    SLOW
    lw    t1, 0(s4)
    SLOW
    CHECK(45, t1)
    li    a0, 0x10001A00
    addi  t2, s0, 0x41
    SLOW
    sw    t2, 0(a0)
    SLOW
    lw    t3, 0(a0)
    SLOW
    CHECK(46, t3)
    addi  t4, s0, 0x51
    SLOW
    sb    t4, 0(s3)
    SLOW
    lbu   t5, 0(s3)
    SLOW
    CHECK(47, t5)
    addi  t0, s0, 0x61
    SLOW
    sw    t0, 0(s5)
    SLOW
    lw    t1, 0(s5)
    SLOW
    CHECK(48, t1)
    addi  t2, s0, 0x71
    SLOW
    sb    t2, 0(s6)
    SLOW
    lbu   t3, 0(s6)
    SLOW
    CHECK(49, t3)
    addi  t0, s0, 0x81
    addi  t1, s0, 0x91
    SLOW
    sw    t0, 32(s4)
    SLOW
    sw    t1, 32(s4)
    SLOW
    sw    t0, 64(s4)
    SLOW
    sw    t1, 32(s5)
    SLOW
    lw    t2, 32(s4)
    lw    t3, 64(s4)
    lw    t4, 32(s5)
    SLOW
    CHECK(50, t2)
    CHECK(51, t3)
    CHECK(52, t4)
    li    t1, 0
    li    t3, 0x0F
    addi  t0, s0, 0xA1
    SLOW
    sw    t0, 96(s4)
    SLOW
    MASKSET(t3)
    lw    t1, 96(s4)
    SLOW
    MASKALL
    lw    t2, 96(s4)
    SLOW
    sw    t0, 128(s4)
    SLOW
    lw    t4, 128(s4)
    SLOW
    CHECK(53, t1)
    CHECK(54, t2)
    CHECK(55, t4)
    seqz  t1, s0
    li    a0, MMIO_BASE
    addi  t0, s0, 0x11
    addi  t2, s0, 0x21
    li    s7, 0x40000180
    SLOW
    add   s7, s7, s1
    SLOW
    sw    t0, 0(s7)
    SLOW
    sw    t1, MMIO_FB_SWAP(a0)
    SLOW
    sw    t2, 0(s7)
    SLOW
    lw    t3, 0(s7)
    SLOW
    CHECK(56, t3)
    andi  t0, s0, 1
    SLOW
    neg   t0, t0
    li    a0, 0x10006040
    slli  t1, s0, 10
    SLOW
    add   a0, a0, t1
    addi  a1, s4, 160
    SLOW
    xor   t2, a1, a0
    SLOW
    and   t2, t2, t0
    SLOW
    xor   s8, a0, t2
    addi  t3, s0, 0xB1
    SLOW
    sw    t3, 0(s8)
    SLOW
    lw    t4, 0(s8)
    SLOW
    CHECK(57, t4)
    li    a0, 0x10006080
    srli  t1, s0, 1
    li    a1, 0x10001A40
    SLOW
    add   a0, a0, s1
    add   a1, a1, t1
    SLOW
    xor   t2, a1, a0
    SLOW
    and   t2, t2, t0
    SLOW
    xor   s8, a0, t2
    addi  t3, s0, 0xC1
    SLOW
    sb    t3, 0(s8)
    SLOW
    lbu   t4, 0(s8)
    SLOW
    CHECK(58, t4)
    andi  t0, s0, 1
    SLOW
    neg   t0, t0
    SLOW
    and   t1, s1, t0
    li    a0, 0x10006100
    SLOW
    add   s8, a0, t1
    addi  t3, s0, 0xD1
    SLOW
    sw    t3, 0(s8)
    SLOW
    lw    t4, 0(s8)
    SLOW
    addi  t4, t4, 1
    SLOW
    CHECK(59, t4)
    la    a0, stress_mix
    SLOW
    add   a0, a0, s1
    SLOW
    lw    s8, 0(a0)
    addi  t3, s0, 0xE1
    SLOW
    sw    t3, 0(s8)
    SLOW
    lw    t4, 0(s8)
    SLOW
    CHECK(60, t4)
    seqz  t0, s0
    SLOW
    neg   t0, t0
    li    a0, MMIO_BASE + MMIO_LEDS
    addi  a1, s4, 192
    SLOW
    xor   t2, a1, a0
    SLOW
    and   t2, t2, t0
    SLOW
    xor   s8, a1, t2
    addi  t3, s0, 0xF1
    SLOW
    sw    t3, 0(s8)
    SLOW
    lw    t4, 192(s4)
    SLOW
    CHECK(61, t4)
    slli  t0, s0, 11
    slli  t1, s0, 6
    SLOW
    add   t0, t0, t1
    SLOW
    add   t0, t0, s0
    SLOW
    addi  t0, t0, 1
    SLOW
    addi  t2, t0, 0x111
    li    a1, 0
    li    t3, 0x5A
    SLOW
    VSET(0, t0)
    SLOW
    VGET(a0, 0)
    SLOW
    MASKSET(t3)
    VSET(0, t2)
    SLOW
    VGET(a1, 0)
    SLOW
    MASKALL
    VGET(a2, 0)
    SLOW
    add   a0, a0, a1
    SLOW
    add   a0, a0, a2
    SLOW
    CHECK(62, a0)
    slli  t0, s0, 3
    li    t1, 0x8000
    SLOW
    addi  t0, t0, 5
    add   t1, t1, s1
    li    t2, 0x9000
    li    t3, 0xA000
    li    t4, 0x10000
    andi  t5, s0, 3
    li    a0, 20
    SLOW
    VSET(0, t0)
    SLOW
    VSET(1, t1)
    SLOW
    VSET(2, t2)
    SLOW
    VSET(3, t3)
    SLOW
    VSET(4, t4)
    SLOW
    VSET(5, t4)
    SLOW
    VSET(6, t4)
    SLOW
    VSET(7, t5)
    SLOW
    VTRACE(x0, a0)
    SLOW
    VGET(a1, 3)
    SLOW
    VSET(0, t0)
    SLOW
    VTRACE(a2, a0)
    SLOW
    VGET(a3, 1)
    SLOW
    add   a1, a1, a2
    SLOW
    xor   a1, a1, a3
    SLOW
    CHECK(63, a1)

    li    t1, 1
    MASKSET(t1)
    li    t6, 1
    li    t5, TB_DONE
    sw    t6, 0(t5)
8:  j     8b

    .data
    .word 0
    /* t_pipe_stress slot 60: per-lane store address */
    .p2align 2
stress_mix:
    .word 0x10006420, 0x10001A80, 0x10006424, 0x10001A84
    .word 0x10006420, 0x10001A80, 0x10006428, 0x10006424
