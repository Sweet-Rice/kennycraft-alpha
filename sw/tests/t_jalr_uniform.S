    .include "sw/tests/test.inc"

    .globl main
    .section .text
main:
    # Activate all 8 lanes
    .insn r 0x0B, 7, 0, x0, x0, x0      # MASKALL

    # 1. Uniform JALR: all active lanes compute the exact same target address
    la   t0, .Luniform_jalr_ok
    jalr ra, t0, 0
    FAIL 1
.Luniform_jalr_ok:

    # 2. Intentional divergent JALR:
    # Each lane computes target = .Ldivergent_jump_table + lane * 4.
    # Targets disagree across active lanes, so uniform check halts with
    # ERR.DIVERGE and ERR_PC = err_site.
    .insn r 0x0B, 0, 0, a0, x0, x0      # LANEID a0
    slli a0, a0, 2
    la   t0, .Ldivergent_jump_table
    add  t0, t0, a0

    .globl err_site
err_site:
    jalr ra, t0, 0

    # If hardware failed to halt, fallthrough fails:
    FAIL 2

.Ldivergent_jump_table:
    j .Lunexpected_jump
    j .Lunexpected_jump
    j .Lunexpected_jump
    j .Lunexpected_jump
    j .Lunexpected_jump
    j .Lunexpected_jump
    j .Lunexpected_jump
    j .Lunexpected_jump

.Lunexpected_jump:
    FAIL 3
