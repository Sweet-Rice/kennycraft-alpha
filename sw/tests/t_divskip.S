    .include "sw/tests/test.inc"

    .globl main
    .section .text
main:
    # -------------------------------------------------------------
    # Case 1: All-false condition.
    # DIF condition is 0 across all lanes.
    # DIF must skip the then-body and jump directly to DELSE.
    # DELSE must then activate the else-body (top.else = 0xFF).
    # -------------------------------------------------------------
    .insn r 0x0B, 7, 0, x0, x0, x0      # MASKALL
    li   a1, 0
    .insn b 0x5B, 0, a1, x0, .Lcase1_else   # DIF a1, .Lcase1_else

    # Then body: should be skipped!
    la   t0, skip_flags
    li   t1, 1
    sw   t1, 0(t0)

.Lcase1_else:
    .insn b 0x5B, 1, x0, x0, .Lcase1_endif  # DELSE .Lcase1_endif

    # Else body: should execute!
    la   t0, skip_flags
    li   t1, 1
    sw   t1, 4(t0)

.Lcase1_endif:
    .insn r 0x5B, 2, 0, x0, x0, x0      # DENDIF

    # -------------------------------------------------------------
    # Case 2: All-true condition.
    # DIF condition is 1 across all lanes.
    # Then-body must execute (M = 0xFF).
    # DELSE sees top.else == 0, so DELSE must jump directly to DENDIF!
    # -------------------------------------------------------------
    .insn r 0x0B, 7, 0, x0, x0, x0      # MASKALL
    li   a1, 1
    .insn b 0x5B, 0, a1, x0, .Lcase2_else   # DIF a1, .Lcase2_else

    # Then body: should execute!
    la   t0, skip_flags
    li   t1, 1
    sw   t1, 8(t0)

.Lcase2_else:
    .insn b 0x5B, 1, x0, x0, .Lcase2_endif  # DELSE .Lcase2_endif

    # Else body: should be skipped!
    la   t0, skip_flags
    li   t1, 1
    sw   t1, 12(t0)

.Lcase2_endif:
    .insn r 0x5B, 2, 0, x0, x0, x0      # DENDIF

    # -------------------------------------------------------------
    # Case 3: All-false condition with NO DELSE (DIF directly to DENDIF).
    # DIF condition is 0 across all lanes.
    # DIF must jump directly to DENDIF.
    # -------------------------------------------------------------
    .insn r 0x0B, 7, 0, x0, x0, x0      # MASKALL
    li   a1, 0
    .insn b 0x5B, 0, a1, x0, .Lcase3_endif   # DIF a1, .Lcase3_endif

    # Then body: should be skipped!
    la   t0, skip_flags
    li   t1, 1
    sw   t1, 16(t0)

.Lcase3_endif:
    .insn r 0x5B, 2, 0, x0, x0, x0      # DENDIF

    # Return to scalar mask
    SCALAR

    # Validate execution flags
    la   t0, skip_flags

    # Case 1: then-body skipped (0), else-body executed (1)
    lw   a0, 0(t0)
    EXPECT_EQ a0, 0, 1
    lw   a0, 4(t0)
    EXPECT_EQ a0, 1, 2

    # Case 2: then-body executed (1), else-body skipped (0)
    lw   a0, 8(t0)
    EXPECT_EQ a0, 1, 3
    lw   a0, 12(t0)
    EXPECT_EQ a0, 0, 4

    # Case 3: then-body skipped (0)
    lw   a0, 16(t0)
    EXPECT_EQ a0, 0, 5

    PASS

    .section .bss
    .balign 4
skip_flags:
    .space 20
