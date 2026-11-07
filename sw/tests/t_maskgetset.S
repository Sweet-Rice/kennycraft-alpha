    .include "sw/tests/test.inc"

    .globl main
    .section .text
main:
    # 1. Startup mask from crt0 should be scalar mask 0x01
    .insn r 0x0B, 5, 0, a0, x0, x0      # MASKGET a0
    EXPECT_EQ a0, 0x01, 1

    # 2. MASKALL sets all 8 mask bits (0xFF)
    .insn r 0x0B, 7, 0, x0, x0, x0      # MASKALL
    .insn r 0x0B, 5, 0, a0, x0, x0      # MASKGET a0
    EXPECT_EQ a0, 0xFF, 2

    # 3. Truncation: MASKSET keeps only low 8 bits (LANES=8)
    li   a1, 0xDEADBE3C                 # low byte = 0x3C (lanes 2, 3, 4, 5)
    .insn r 0x0B, 6, 0, x0, a1, x0      # MASKSET a1
    .insn r 0x0B, 5, 0, a0, x0, x0      # MASKGET a0
    EXPECT_EQ a0, 0x3C, 3

    # 4. Lowest-active scalar lane:
    # Current mask is 0x3C (lanes 2, 3, 4, 5 active).
    # Lowest active lane is lane 2. Lanes 0 and 1 are inactive.
    # Each active lane computes 1 << lane into a2:
    # lane 2 -> 1<<2 = 0x04; lane 3 -> 1<<3 = 0x08, etc.
    .insn r 0x0B, 0, 0, a3, x0, x0      # LANEID a3
    li   t0, 1
    sll  a2, t0, a3
    # MASKSET reads a2 from the scalar lane (lowest active lane = lane 2 -> 0x04)
    .insn r 0x0B, 6, 0, x0, a2, x0      # MASKSET a2
    .insn r 0x0B, 5, 0, a0, x0, x0      # MASKGET a0
    EXPECT_EQ a0, 0x04, 4

    # 5. MASKGET writes to ALL lanes (active and inactive):
    # Prime sentinel in s0 in all lanes first
    .insn r 0x0B, 7, 0, x0, x0, x0      # MASKALL
    .insn r 0x0B, 0, 0, a3, x0, x0      # LANEID a3
    addi s0, a3, 0x80
    # Set mask to 0x04 (only lane 2 active)
    li   t0, 0x04
    .insn r 0x0B, 6, 0, x0, t0, x0      # MASKSET t0
    # MASKGET s0 writes 0x04 into s0 in every lane
    .insn r 0x0B, 5, 0, s0, x0, x0      # MASKGET s0
    # Wake all lanes to store each lane's s0 to dmem
    .insn r 0x0B, 7, 0, x0, x0, x0      # MASKALL
    .insn r 0x0B, 0, 0, a3, x0, x0      # LANEID a3
    slli t1, a3, 2
    la   t2, maskget_data
    add  t2, t2, t1
    sw   s0, 0(t2)

    # Return to scalar mask
    SCALAR

    la   t2, maskget_data
    lw   a0, 0(t2)
    EXPECT_EQ a0, 0x04, 5
    lw   a0, 4(t2)
    EXPECT_EQ a0, 0x04, 6
    lw   a0, 8(t2)
    EXPECT_EQ a0, 0x04, 7
    lw   a0, 12(t2)
    EXPECT_EQ a0, 0x04, 8
    lw   a0, 16(t2)
    EXPECT_EQ a0, 0x04, 9
    lw   a0, 20(t2)
    EXPECT_EQ a0, 0x04, 10
    lw   a0, 24(t2)
    EXPECT_EQ a0, 0x04, 11
    lw   a0, 28(t2)
    EXPECT_EQ a0, 0x04, 12

    # 6. Round trip: restore scalar mask 0x01
    li   t0, 1
    .insn r 0x0B, 6, 0, x0, t0, x0      # MASKSET t0
    .insn r 0x0B, 5, 0, a0, x0, x0      # MASKGET a0
    EXPECT_EQ a0, 0x01, 13

    PASS

    .section .bss
    .balign 4
maskget_data:
    .space 32
