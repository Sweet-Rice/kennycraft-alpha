    .include "sw/tests/test.inc"

    .globl main
    .section .text
main:
    # -------------------------------------------------------------
    # Test 1: LMASK inside a THEN-body is undone by DENDIF.
    # -------------------------------------------------------------
    .insn r 0x0B, 7, 0, x0, x0, x0      # MASKALL (M = 0xFF)
    .insn r 0x0B, 0, 0, a0, x0, x0      # LANEID a0
    la   s1, recorded_masks

    # DIF on lane < 4 -> then-mask is 0x0F
    slti a1, a0, 4
    .insn b 0x5B, 0, a1, x0, .Ldiv1_endif   # DIF a1, .Ldiv1_endif (no else)

    # Inside then-body: mask is 0x0F
    .insn r 0x0B, 5, 0, s0, x0, x0      # MASKGET s0
    sw   s0, 0(s1)

    # LMASK selecting only even lanes (lanes 0, 2) -> mask becomes 0x05
    andi a2, a0, 1
    xori a2, a2, 1
    .insn r 0x0B, 1, 0, x0, a2, x0      # LMASK a2

    .insn r 0x0B, 5, 0, s0, x0, x0      # MASKGET s0
    sw   s0, 4(s1)

.Ldiv1_endif:
    .insn r 0x5B, 2, 0, x0, x0, x0      # DENDIF

    # DENDIF must restore top.saved (0xFF), undoing the nested LMASK
    .insn r 0x0B, 5, 0, s0, x0, x0      # MASKGET s0
    sw   s0, 8(s1)

    # -------------------------------------------------------------
    # Test 2: LMASK inside an ELSE-body is also undone by DENDIF.
    # -------------------------------------------------------------
    slti a1, a0, 4
    .insn b 0x5B, 0, a1, x0, .Ldiv2_else    # DIF a1, .Ldiv2_else

    # Then body: empty, falls through to DELSE
.Ldiv2_else:
    .insn b 0x5B, 1, x0, x0, .Ldiv2_endif   # DELSE .Ldiv2_endif

    # Inside else-body: mask is 0xF0 (lanes 4..7)
    .insn r 0x0B, 5, 0, s0, x0, x0      # MASKGET s0
    sw   s0, 12(s1)

    # LMASK selecting even lanes (lanes 4, 6) -> mask becomes 0x50
    andi a2, a0, 1
    xori a2, a2, 1
    .insn r 0x0B, 1, 0, x0, a2, x0      # LMASK a2

    .insn r 0x0B, 5, 0, s0, x0, x0      # MASKGET s0
    sw   s0, 16(s1)

.Ldiv2_endif:
    .insn r 0x5B, 2, 0, x0, x0, x0      # DENDIF

    # DENDIF must restore top.saved (0xFF)
    .insn r 0x0B, 5, 0, s0, x0, x0      # MASKGET s0
    sw   s0, 20(s1)

    # Return to scalar mask
    SCALAR

    # Validate recorded masks
    la   s1, recorded_masks

    # Test 1 validations:
    lw   a0, 0(s1)
    EXPECT_EQ a0, 0x0F, 1
    lw   a0, 4(s1)
    EXPECT_EQ a0, 0x05, 2
    lw   a0, 8(s1)
    EXPECT_EQ a0, 0xFF, 3

    # Test 2 validations:
    lw   a0, 12(s1)
    EXPECT_EQ a0, 0xF0, 4
    lw   a0, 16(s1)
    EXPECT_EQ a0, 0x50, 5
    lw   a0, 20(s1)
    EXPECT_EQ a0, 0xFF, 6

    PASS

    .section .bss
    .balign 4
recorded_masks:
    .space 24
