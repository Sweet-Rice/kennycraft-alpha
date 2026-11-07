    .include "sw/tests/test.inc"

    .globl main
    .section .text
main:
    # Start under MASKALL (M = 0xFF)
    .insn r 0x0B, 7, 0, x0, x0, x0      # MASKALL
    .insn r 0x0B, 0, 0, a0, x0, x0      # LANEID a0
    la   s1, mask_records

    # Point 0: before any DIF (M = 0xFF)
    .insn r 0x0B, 5, 0, s0, x0, x0      # MASKGET s0
    sw   s0, 0(s1)

    # Level 1 DIF: condition true for lanes 0..3
    slti a1, a0, 4
    .insn b 0x5B, 0, a1, x0, .Louter_else   # DIF a1, .Louter_else

    # Point 1: inside Level 1 then (M = 0x0F)
    .insn r 0x0B, 5, 0, s0, x0, x0      # MASKGET s0
    sw   s0, 4(s1)

    # Level 2 DIF: condition true for lanes 0..1
    slti a2, a0, 2
    .insn b 0x5B, 0, a2, x0, .Linner1_else  # DIF a2, .Linner1_else

    # Point 2: inside Level 2 then (M = 0x03)
    .insn r 0x0B, 5, 0, s0, x0, x0      # MASKGET s0
    sw   s0, 8(s1)

.Linner1_else:
    .insn b 0x5B, 1, x0, x0, .Linner1_endif # DELSE .Linner1_endif

    # Point 3: inside Level 2 else (M = 0x0C)
    .insn r 0x0B, 5, 0, s0, x0, x0      # MASKGET s0
    sw   s0, 12(s1)

.Linner1_endif:
    .insn r 0x5B, 2, 0, x0, x0, x0      # DENDIF

    # Point 4: back in Level 1 then (M = 0x0F)
    .insn r 0x0B, 5, 0, s0, x0, x0      # MASKGET s0
    sw   s0, 16(s1)

.Louter_else:
    .insn b 0x5B, 1, x0, x0, .Louter_endif  # DELSE .Louter_endif

    # Point 5: inside Level 1 else (M = 0xF0)
    .insn r 0x0B, 5, 0, s0, x0, x0      # MASKGET s0
    sw   s0, 20(s1)

    # Level 2 DIF in else: condition true for lanes 4..5
    slti a3, a0, 6
    .insn b 0x5B, 0, a3, x0, .Linner2_else  # DIF a3, .Linner2_else

    # Point 6: inside Level 2 then in else (M = 0x30)
    .insn r 0x0B, 5, 0, s0, x0, x0      # MASKGET s0
    sw   s0, 24(s1)

.Linner2_else:
    .insn b 0x5B, 1, x0, x0, .Linner2_endif # DELSE .Linner2_endif

    # Point 7: inside Level 2 else in else (M = 0xC0)
    .insn r 0x0B, 5, 0, s0, x0, x0      # MASKGET s0
    sw   s0, 28(s1)

.Linner2_endif:
    .insn r 0x5B, 2, 0, x0, x0, x0      # DENDIF

    # Point 8: back in Level 1 else (M = 0xF0)
    .insn r 0x0B, 5, 0, s0, x0, x0      # MASKGET s0
    sw   s0, 32(s1)

.Louter_endif:
    .insn r 0x5B, 2, 0, x0, x0, x0      # DENDIF

    # Point 9: after outer DENDIF (M = 0xFF restored)
    .insn r 0x0B, 5, 0, s0, x0, x0      # MASKGET s0
    sw   s0, 36(s1)

    # Return to scalar mask
    SCALAR

    # Validate recorded mask at each point
    la   s1, mask_records

    lw   a0, 0(s1)
    EXPECT_EQ a0, 0xFF, 1

    lw   a0, 4(s1)
    EXPECT_EQ a0, 0x0F, 2

    lw   a0, 8(s1)
    EXPECT_EQ a0, 0x03, 3

    lw   a0, 12(s1)
    EXPECT_EQ a0, 0x0C, 4

    lw   a0, 16(s1)
    EXPECT_EQ a0, 0x0F, 5

    lw   a0, 20(s1)
    EXPECT_EQ a0, 0xF0, 6

    lw   a0, 24(s1)
    EXPECT_EQ a0, 0x30, 7

    lw   a0, 28(s1)
    EXPECT_EQ a0, 0xC0, 8

    lw   a0, 32(s1)
    EXPECT_EQ a0, 0xF0, 9

    lw   a0, 36(s1)
    EXPECT_EQ a0, 0xFF, 10

    PASS

    .section .bss
    .balign 4
mask_records:
    .space 40
