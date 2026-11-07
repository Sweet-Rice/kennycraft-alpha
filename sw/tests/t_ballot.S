    .include "sw/tests/test.inc"

    .globl main
    .section .text
main:
    # Wake all lanes to prime s1 with a unique per-lane sentinel
    .insn r 0x0B, 7, 0, x0, x0, x0      # MASKALL
    .insn r 0x0B, 0, 0, a0, x0, x0      # LANEID a0
    addi s1, a0, 0x100                  # sentinel in s1

    # Evaluate lane & 1 in every lane, so inactive lanes 5 and 7 hold a
    # nonzero predicate that a BALLOT ignoring the mask would count (0xAA)
    andi a1, a0, 1

    # Restrict active mask to 0x0F (lanes 0..3 active, lanes 4..7 inactive)
    li   t0, 0x0F
    .insn r 0x0B, 6, 0, x0, t0, x0      # MASKSET t0

    # BALLOT s1, a1:
    # Active lanes where a1 != 0 are lanes 1 and 3 -> (1<<1) | (1<<3) = 0x0A.
    # Inactive lanes 4..7 contribute 0, even though lanes 5 and 7 have a1 = 1.
    # rd (s1) is written in EVERY lane, active or not.
    .insn r 0x0B, 3, 0, s1, a1, x0      # BALLOT s1, a1

    # Wake all lanes to store each lane's s1 into memory
    .insn r 0x0B, 7, 0, x0, x0, x0      # MASKALL
    .insn r 0x0B, 0, 0, a0, x0, x0      # LANEID a0
    slli a2, a0, 2
    la   a3, ballot_results
    add  a3, a3, a2
    sw   s1, 0(a3)

    # Return to scalar mask
    SCALAR

    # Verify that ALL 8 lanes (including inactive lanes 4..7) received 0x0A
    la   a3, ballot_results

    lw   a0, 0(a3)
    EXPECT_EQ a0, 0x0A, 1

    lw   a0, 4(a3)
    EXPECT_EQ a0, 0x0A, 2

    lw   a0, 8(a3)
    EXPECT_EQ a0, 0x0A, 3

    lw   a0, 12(a3)
    EXPECT_EQ a0, 0x0A, 4

    lw   a0, 16(a3)
    EXPECT_EQ a0, 0x0A, 5

    lw   a0, 20(a3)
    EXPECT_EQ a0, 0x0A, 6

    lw   a0, 24(a3)
    EXPECT_EQ a0, 0x0A, 7

    lw   a0, 28(a3)
    EXPECT_EQ a0, 0x0A, 8

    PASS

    .section .bss
    .balign 4
ballot_results:
    .space 32
