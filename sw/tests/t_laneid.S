    .include "sw/tests/test.inc"

    .globl main
    .section .text
main:
    # Activate all 8 lanes
    .insn r 0x0B, 7, 0, x0, x0, x0      # MASKALL

    # Read lane ID into a0 in each active lane
    .insn r 0x0B, 0, 0, a0, x0, x0      # LANEID a0

    # Store lane ID to dmem[lane]: lane_data + lane * 4
    la   a1, lane_data
    slli a2, a0, 2
    add  a1, a1, a2
    sw   a0, 0(a1)

    # Return to scalar mask 1
    SCALAR

    # Validate each lane's stored value in dmem
    la   a1, lane_data

    lw   a0, 0(a1)
    EXPECT_EQ a0, 0, 1

    lw   a0, 4(a1)
    EXPECT_EQ a0, 1, 2

    lw   a0, 8(a1)
    EXPECT_EQ a0, 2, 3

    lw   a0, 12(a1)
    EXPECT_EQ a0, 3, 4

    lw   a0, 16(a1)
    EXPECT_EQ a0, 4, 5

    lw   a0, 20(a1)
    EXPECT_EQ a0, 5, 6

    lw   a0, 24(a1)
    EXPECT_EQ a0, 6, 7

    lw   a0, 28(a1)
    EXPECT_EQ a0, 7, 8

    PASS

    .section .bss
    .balign 4
lane_data:
    .space 32
