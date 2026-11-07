    .include "sw/tests/test.inc"

    .globl main
    .section .text
main:
    # Activate all 8 lanes
    .insn r 0x0B, 7, 0, x0, x0, x0      # MASKALL

    # Condition is true (1) across all active lanes so each DIF enters its then-body
    li   a0, 1

    # Divergence stack has 8 entries. Push 8 entries onto the stack:
    .insn b 0x5B, 0, a0, x0, .Lend1     # DIF 1 (sp = 1)
    .insn b 0x5B, 0, a0, x0, .Lend2     # DIF 2 (sp = 2)
    .insn b 0x5B, 0, a0, x0, .Lend3     # DIF 3 (sp = 3)
    .insn b 0x5B, 0, a0, x0, .Lend4     # DIF 4 (sp = 4)
    .insn b 0x5B, 0, a0, x0, .Lend5     # DIF 5 (sp = 5)
    .insn b 0x5B, 0, a0, x0, .Lend6     # DIF 6 (sp = 6)
    .insn b 0x5B, 0, a0, x0, .Lend7     # DIF 7 (sp = 7)
    .insn b 0x5B, 0, a0, x0, .Lend8     # DIF 8 (sp = 8)

    # The 9th DIF finds sp == 8 and must halt immediately with ERR.DIVSTACK.
    .globl err_site
err_site:
    .insn b 0x5B, 0, a0, x0, .Lend9     # DIF 9 (overflow!)

    # If hardware failed to halt, execution reaches FAIL:
    FAIL 1

.Lend9:
    .insn r 0x5B, 2, 0, x0, x0, x0      # DENDIF
.Lend8:
    .insn r 0x5B, 2, 0, x0, x0, x0      # DENDIF
.Lend7:
    .insn r 0x5B, 2, 0, x0, x0, x0      # DENDIF
.Lend6:
    .insn r 0x5B, 2, 0, x0, x0, x0      # DENDIF
.Lend5:
    .insn r 0x5B, 2, 0, x0, x0, x0      # DENDIF
.Lend4:
    .insn r 0x5B, 2, 0, x0, x0, x0      # DENDIF
.Lend3:
    .insn r 0x5B, 2, 0, x0, x0, x0      # DENDIF
.Lend2:
    .insn r 0x5B, 2, 0, x0, x0, x0      # DENDIF
.Lend1:
    .insn r 0x5B, 2, 0, x0, x0, x0      # DENDIF

    FAIL 2
