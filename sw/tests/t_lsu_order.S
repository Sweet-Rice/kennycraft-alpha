    .include "sw/tests/test.inc"

    .globl main
    .section .text
main:
    # Test 1: Under MASKALL (all lanes 0..7 active), all lanes store their
    # LANEID to target_addr. Lane 7 writes last in ascending order and wins.
    .insn r 0x0B, 7, 0, x0, x0, x0      # MASKALL
    .insn r 0x0B, 0, 0, a0, x0, x0      # LANEID a0
    la   s0, target_addr
    sw   a0, 0(s0)

    # Validate in scalar mode
    SCALAR
    la   s0, target_addr
    lw   a1, 0(s0)
    EXPECT_EQ a1, 7, 1

    # Test 2: Mask 0x35 (lanes 0, 2, 4, 5 active).
    # Highest active lane is lane 5, which must win the store to target_addr.
    li   t0, 0x35
    .insn r 0x0B, 6, 0, x0, t0, x0      # MASKSET t0
    .insn r 0x0B, 0, 0, a0, x0, x0      # LANEID a0
    la   s0, target_addr
    sw   a0, 0(s0)

    # Validate in scalar mode
    SCALAR
    la   s0, target_addr
    lw   a1, 0(s0)
    EXPECT_EQ a1, 5, 2

    # Test 3: Mask 0x4B (lanes 0, 1, 3, 6 active).
    # Highest active lane is lane 6, which must win the store to target_addr.
    li   t0, 0x4B
    .insn r 0x0B, 6, 0, x0, t0, x0      # MASKSET t0
    .insn r 0x0B, 0, 0, a0, x0, x0      # LANEID a0
    la   s0, target_addr
    sw   a0, 0(s0)

    # Validate in scalar mode
    SCALAR
    la   s0, target_addr
    lw   a1, 0(s0)
    EXPECT_EQ a1, 6, 3

    PASS

    .section .bss
    .balign 4
target_addr:
    .space 4
