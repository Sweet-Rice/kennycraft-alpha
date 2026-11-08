# t_qrcp: QRCP rd, rs1 (D22) on the Stage 2 core with HAS_QRCP = 1, as a
# self-checking UART test (PASS / FAIL n) for the bench and the board. Under
# MASKALL every lane takes six inputs of its own (edge classes, saturating
# values, negatives, powers of two and neighbours) and XORs each QRCP result
# with fixed.c qrcp() of that input; QRCP x0 must write nothing; QRCP under
# the mask 0xA5 must leave inactive lanes' rd alone; QRCP with rd = rs1 must
# read rs1 first. A second pass sends one input through every seed ROM
# bucket, x = (256 + i) << 8 for i = 0..255 (32 QRCPs per lane), against
# sw/tests/t_qrcp_buckets.inc, generated from fixed.c qrcp() by
# `make qrcp-bench-inc` (tb-qrcp-model checks it is current). Each lane
# stores its ORs of XORs and its masked result, and lane 0 checks all eight
# after SCALAR.
    .include "sw/tests/test.inc"

    .globl main
    .section .text
main:
    .insn r 0x0B, 7, 0, x0, x0, x0      # MASKALL
    .insn r 0x0B, 0, 0, s0, x0, x0      # LANEID s0
    slli  s1, s0, 2
    la    t0, qr_in
    add   t0, t0, s1
    lw    s2, 0(t0)
    lw    s3, 32(t0)
    lw    s4, 64(t0)
    lw    s5, 96(t0)
    lw    s6, 128(t0)
    lw    s7, 160(t0)

    .insn r 0x0B, 2, 0, a2, s2, x0      # QRCP a2, s2
    .insn r 0x0B, 2, 0, a3, s3, x0
    .insn r 0x0B, 2, 0, a4, s4, x0
    .insn r 0x0B, 2, 0, a5, s5, x0
    .insn r 0x0B, 2, 0, a6, s6, x0
    .insn r 0x0B, 2, 0, a7, s7, x0
    .insn r 0x0B, 2, 0, x0, s5, x0      # QRCP x0: no write

    lui   a1, 0x5A5A0
    or    a1, a1, s0                    # a1 = 0x5A5A0000 | lane
    li    t1, 0xA5
    .insn r 0x0B, 6, 0, x0, t1, x0      # MASKSET 0xA5: lanes 0, 2, 5, 7
    .insn r 0x0B, 2, 0, a1, s3, x0      # active lanes only
    .insn r 0x0B, 7, 0, x0, x0, x0      # MASKALL
    .insn r 0x0B, 2, 0, s7, s7, x0      # rd = rs1

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

    # Seed ROM pass: lane l takes x = (256 + 8k + l) << 8 for k = 0..31, so
    # the 8 lanes cover every bucket m[15:8] = 8k + l once (qr_bkt_exp).
    la    t0, qr_bkt_exp
    add   t0, t0, s1
    addi  t1, s0, 256
    slli  t1, t1, 8                     # k = 0
    li    s10, 0
    li    t4, 0
    li    t5, 32
4:  .insn r 0x0B, 2, 0, a3, t1, x0      # QRCP a3, t1
    lw    t2, 0(t0)
    xor   t2, t2, a3
    or    s10, s10, t2
    li    t3, 8 << 8
    add   t1, t1, t3                    # next k
    addi  t0, t0, 32
    addi  t4, t4, 1
    bne   t4, t5, 4b                    # uniform: same count in every lane

    la    t0, qr_err
    add   t0, t0, s1
    sw    s9, 0(t0)                     # per-lane OR of XORs
    sw    a1, 32(t0)                    # per-lane masked result
    sw    s10, 64(t0)                   # per-lane seed ROM pass OR of XORs
    SCALAR

    # Lane 0 checks every lane: qr_err[l] = 0, qr_err[8 + l] = qr_mask[l],
    # qr_err[16 + l] = 0
    la    s2, qr_err
    la    s3, qr_mask
    li    s4, 0
    li    s5, 8
1:  lw    t0, 0(s2)
    beqz  t0, 2f
    addi  a0, s4, 1                     # FAIL 1..8: lane 0..7 result mismatch
    j     .Lqr_fail
2:  lw    t0, 32(s2)
    lw    t1, 0(s3)
    beq   t0, t1, 3f
    addi  a0, s4, 11                    # FAIL 11..18: lane 0..7 masked rd
    j     .Lqr_fail
3:  lw    t0, 64(s2)
    beqz  t0, 5f
    addi  a0, s4, 21                    # FAIL 21..28: lane 0..7 seed ROM pass
    j     .Lqr_fail
5:  addi  s2, s2, 4
    addi  s3, s3, 4
    addi  s4, s4, 1
    bne   s4, s5, 1b
    PASS
.Lqr_fail:
    j     .Lbench_fail

    .section .data
    .balign 4
qr_in:
    .word 0x00000000, 0x00000001, 0x00000003, 0x00000004, 0xFFFFFFFF, 0xFFFF0000, 0x80000000, 0x7FFFFFFF
    .word 0x00010000, 0x0000FFFF, 0x00010001, 0x00020000, 0x00008000, 0x00000005, 0x00000007, 0x00000008
    .word 0x00012345, 0x00ABCDEF, 0x01000000, 0x3FFFFFFF, 0x40000000, 0x00000400, 0x0001FFFF, 0x000003FF
    .word 0x00001800, 0x00002000, 0x00001FFF, 0x00002001, 0x00000006, 0x00000002, 0xFFFFFFFC, 0x00C0FFEE
    .word 0x00031415, 0x00002718, 0x0BADF00D, 0x00F00000, 0x00000100, 0x000000FF, 0x7FFF0000, 0x00010100
    .word 0x00004000, 0x00004001, 0x00003FFF, 0x12345678, 0x0000A000, 0x00000009, 0x00000011, 0x00000801
qr_exp:                                 # fixed.c qrcp() of qr_in
    .word 0x40000000, 0x40000000, 0x40000000, 0x3FFFC000, 0x40000000, 0x40000000, 0x40000000, 0x00000002
    .word 0x0000FFFF, 0x00010000, 0x0000FFFF, 0x00007FFF, 0x0001FFFE, 0x33334000, 0x24924000, 0x1FFFE000
    .word 0x0000E100, 0x0000017D, 0x000000FF, 0x00000004, 0x00000003, 0x003FFFC0, 0x00008000, 0x00401000
    .word 0x000AAAA0, 0x0007FFF8, 0x00080040, 0x0007FFC0, 0x2AAA8000, 0x40000000, 0x40000000, 0x00000153
    .word 0x00005328, 0x00068C60, 0x00000015, 0x00000111, 0x00FFFF00, 0x01010000, 0x00000002, 0x0000FF01
    .word 0x0003FFFC, 0x0003FFF0, 0x00040010, 0x0000000E, 0x0001999A, 0x1C71C000, 0x0F0F0000, 0x001FFC00
qr_mask:                                # a1 after QRCP under 0xA5: row 1 result or the preset
    .word 0x0000FFFF, 0x5A5A0001, 0x0000FFFF, 0x5A5A0003, 0x5A5A0004, 0x33334000, 0x5A5A0006, 0x1FFFE000
qr_err:
    .space 96, 0xFF
    .include "sw/tests/t_qrcp_buckets.inc"
