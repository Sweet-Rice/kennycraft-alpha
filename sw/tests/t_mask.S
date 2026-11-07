    .include "sw/tests/test.inc"

    .globl main
    .section .text
main:
    # Scalar setup: initialize 8 slots to sentinel 0xDEADBEEF
    la   a1, mask_slots
    li   t0, 0xDEADBEEF
    sw   t0, 0(a1)
    sw   t0, 4(a1)
    sw   t0, 8(a1)
    sw   t0, 12(a1)
    sw   t0, 16(a1)
    sw   t0, 20(a1)
    sw   t0, 24(a1)
    sw   t0, 28(a1)

    # Wake all lanes
    .insn r 0x0B, 7, 0, x0, x0, x0      # MASKALL

    # Read lane ID
    .insn r 0x0B, 0, 0, a0, x0, x0      # LANEID a0

    # Invert lane & 1 so even lanes have 1, odd lanes have 0
    andi t0, a0, 1
    xori t0, t0, 1

    # LMASK keeps nonzero lanes active -> mask becomes 0x55 (lanes 0, 2, 4, 6)
    .insn r 0x0B, 1, 0, x0, t0, x0      # LMASK t0

    # Record mask via MASKGET (broadcasts to all lanes)
    .insn r 0x0B, 5, 0, s0, x0, x0      # MASKGET s0

    # Active lanes store 0x10 + lane to their respective slots
    addi a2, a0, 0x10
    la   a1, mask_slots
    slli a3, a0, 2
    add  a1, a1, a3
    sw   a2, 0(a1)

    # Return to scalar mask
    SCALAR

    # Verify mask was 0x55
    EXPECT_EQ s0, 0x55, 1

    # Verify only even lanes' slots changed
    la   a1, mask_slots

    lw   a0, 0(a1)
    EXPECT_EQ a0, 0x10, 2

    lw   a0, 4(a1)
    EXPECT_EQ a0, 0xDEADBEEF, 3

    lw   a0, 8(a1)
    EXPECT_EQ a0, 0x12, 4

    lw   a0, 12(a1)
    EXPECT_EQ a0, 0xDEADBEEF, 5

    lw   a0, 16(a1)
    EXPECT_EQ a0, 0x14, 6

    lw   a0, 20(a1)
    EXPECT_EQ a0, 0xDEADBEEF, 7

    lw   a0, 24(a1)
    EXPECT_EQ a0, 0x16, 8

    lw   a0, 28(a1)
    EXPECT_EQ a0, 0xDEADBEEF, 9

    PASS

    .section .bss
    .balign 4
mask_slots:
    .space 32
