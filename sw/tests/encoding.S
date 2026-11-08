/*
 * Every custom instruction of Tai_2 section 1, assembled with the exact .insn
 * line from the encoding table and the operands of its Example hex column.
 * scripts/check_encoding.py assembles this file and compares each word of the
 * objdump output against the example hex, in table order.
 *
 * Layout (word index: instruction):
 *   0-12  the 13 table rows, in table order
 *   13    nop, DELSE target (DELSE at 11, +8)
 *   14    nop, DIF target   (DIF at 10, +16)
 */

    .text
    .globl encoding_table
encoding_table:
    .insn r 0x0B, 0, 0, a0, x0, x0          # LANEID a0         0x0000050B
    .insn r 0x0B, 1, 0, x0, a1, x0          # LMASK a1          0x0005900B
    .insn r 0x0B, 2, 0, a0, a1, x0          # QRCP a0, a1       0x0005A50B
    .insn r 0x0B, 3, 0, a0, a1, x0          # BALLOT a0, a1     0x0005B50B
    .insn r 0x0B, 5, 0, a0, x0, x0          # MASKGET a0        0x0000550B
    .insn r 0x0B, 6, 0, x0, a1, x0          # MASKSET a1        0x0005E00B
    .insn r 0x0B, 7, 0, x0, x0, x0          # MASKALL           0x0000700B
    .insn r 0x2B, 0, 3, x0, a1, x0          # VSET 3, a1        0x0605802B
    .insn r 0x2B, 1, 0, a0, a1, x0          # VTRACE a0, a1     0x0005952B
    .insn r 0x2B, 2, 1, a0, x0, x0          # VGET a0, 1        0x0200252B
    .insn b 0x5B, 0, a1, x0, dif_target     # DIF a1, +16       0x0005885B
    .insn b 0x5B, 1, x0, x0, delse_target   # DELSE +8          0x0000145B
    .insn r 0x5B, 2, 0, x0, x0, x0          # DENDIF            0x0000205B
delse_target:
    nop
dif_target:
    nop
