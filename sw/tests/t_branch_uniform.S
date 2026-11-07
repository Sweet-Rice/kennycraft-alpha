    .include "sw/tests/test.inc"

    .globl main
    .section .text
main:
    # Activate all 8 lanes
    .insn r 0x0B, 7, 0, x0, x0, x0      # MASKALL

    # 1. Uniform branch taken: all active lanes agree (42 == 42)
    li   a0, 42
    li   a1, 42
    beq  a0, a1, .Luniform_taken_ok
    FAIL 1
.Luniform_taken_ok:

    # 2. Uniform branch not taken: all active lanes agree (42 != 99)
    li   a1, 99
    bne  a0, a1, .Luniform_nottaken_ok
    FAIL 2
.Luniform_nottaken_ok:

    # 3. Intentional divergent branch:
    # lane & 1 is 0 for even lanes and 1 for odd lanes.
    # Comparing against 0 will evaluate to taken in even lanes, not taken in odd lanes.
    # Uniform check must fail and halt with ERR.DIVERGE and ERR_PC = err_site.
    .insn r 0x0B, 0, 0, a0, x0, x0      # LANEID a0
    andi a1, a0, 1

    .globl err_site
err_site:
    beqz a1, .Ldivergent_target

    # If hardware fails to halt on divergence, both fallthrough and jump fail:
    FAIL 3

.Ldivergent_target:
    FAIL 4
