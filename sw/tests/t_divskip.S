/*
 * t_divskip.S: DIF and DELSE jump over a body whose lanes are all inactive.
 *
 * Each body that must be skipped starts with a JAL to a FAIL. JAL's PC
 * update is shared (Tai_2 §2), so it runs even with M = 0: a DIF or DELSE
 * that falls through instead of jumping fails here, not only one that
 * leaves lanes active.
 *
 * Failure codes:
 *   1: case 1 then-body ran (DIF did not jump)
 *   2: case 1 else-body did not run
 *   3: case 2 then-body did not run
 *   4: case 2 else-body ran (DELSE did not jump)
 *   5: case 3 then-body ran (DIF did not jump)
 */

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

    # Then body: must be jumped over
    j    .Lcase1_then_ran

.Lcase1_else:
    .insn b 0x5B, 1, x0, x0, .Lcase1_endif  # DELSE .Lcase1_endif

    # Else body: should execute!
    la   t0, ran_flags
    li   t1, 1
    sw   t1, 0(t0)

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
    la   t0, ran_flags
    li   t1, 1
    sw   t1, 4(t0)

.Lcase2_else:
    .insn b 0x5B, 1, x0, x0, .Lcase2_endif  # DELSE .Lcase2_endif

    # Else body: must be jumped over
    j    .Lcase2_else_ran

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

    # Then body: must be jumped over
    j    .Lcase3_then_ran

.Lcase3_endif:
    .insn r 0x5B, 2, 0, x0, x0, x0      # DENDIF

    # Return to scalar mask
    SCALAR

    # Validate that the bodies which must run did run
    la   t0, ran_flags
    lw   a0, 0(t0)
    EXPECT_EQ a0, 1, 2
    lw   a0, 4(t0)
    EXPECT_EQ a0, 1, 3

    PASS

.Lcase1_then_ran:
    FAIL 1
.Lcase2_else_ran:
    FAIL 4
.Lcase3_then_ran:
    FAIL 5

    .section .bss
    .balign 4
ran_flags:
    .space 8
