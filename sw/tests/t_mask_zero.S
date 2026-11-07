    .include "sw/tests/test.inc"

    .globl main
    .section .text
main:
    # 1. Wake all 8 lanes
    .insn r 0x0B, 7, 0, x0, x0, x0      # MASKALL

    # Save original mask in s2 (0xFF in all lanes)
    .insn r 0x0B, 5, 0, s2, x0, x0      # MASKGET s2

    # Initialize per-lane remaining steps: lane 0 has 1, lane 7 has 8
    .insn r 0x0B, 0, 0, a0, x0, x0      # LANEID a0
    addi a1, a0, 1                      # remaining steps = lane + 1
    li   s3, 0                          # steps completed counter
    li   a3, 0x123                      # sentinel in a3 before loop

    # 2. Mask loop (pattern used in DDA voxel traversal):
    # while (ballot(remaining_steps != 0)) {
    #     step();
    #     lmask(remaining_steps != 0);
    # }
.Lloop:
    snez a2, a1
    .insn r 0x0B, 3, 0, a3, a2, x0      # BALLOT a3, a2 (writes all lanes)
    beqz a3, .Lloop_exit                # uniform branch: exits when a3 == 0

    # Body executed only by active lanes
    addi s3, s3, 1                      # count step
    addi a1, a1, -1                     # decrement remaining steps
    snez a4, a1
    .insn r 0x0B, 1, 0, x0, a4, x0      # LMASK a4 (finished lanes drop out)
    j    .Lloop

.Lloop_exit:
    # When the last lane dropped out, M became 0.
    # The final BALLOT produced 0 and wrote 0 into a3 across ALL lanes.
    # With M = 0, MASKSET reads rs1 (s2) from lane 0 to restore M = 0xFF.
    .insn r 0x0B, 6, 0, x0, s2, x0      # MASKSET s2 (restores M = 0xFF)

    # All lanes are active again. Each lane records its a3 and step count s3.
    .insn r 0x0B, 0, 0, a0, x0, x0      # LANEID a0
    slli t0, a0, 2

    la   t1, ballot_zero_results
    add  t1, t1, t0
    sw   a3, 0(t1)

    la   t2, step_counts
    add  t2, t2, t0
    sw   s3, 0(t2)

    # Return to scalar mask
    SCALAR

    # Validate that BALLOT wrote 0 to every lane on the exit iteration
    la   t1, ballot_zero_results
    lw   a0, 0(t1)
    EXPECT_EQ a0, 0, 1
    lw   a0, 4(t1)
    EXPECT_EQ a0, 0, 2
    lw   a0, 8(t1)
    EXPECT_EQ a0, 0, 3
    lw   a0, 12(t1)
    EXPECT_EQ a0, 0, 4
    lw   a0, 16(t1)
    EXPECT_EQ a0, 0, 5
    lw   a0, 20(t1)
    EXPECT_EQ a0, 0, 6
    lw   a0, 24(t1)
    EXPECT_EQ a0, 0, 7
    lw   a0, 28(t1)
    EXPECT_EQ a0, 0, 8

    # Validate that each lane completed exactly lane + 1 steps before dropping out
    la   t2, step_counts
    lw   a0, 0(t2)
    EXPECT_EQ a0, 1, 9
    lw   a0, 4(t2)
    EXPECT_EQ a0, 2, 10
    lw   a0, 8(t2)
    EXPECT_EQ a0, 3, 11
    lw   a0, 12(t2)
    EXPECT_EQ a0, 4, 12
    lw   a0, 16(t2)
    EXPECT_EQ a0, 5, 13
    lw   a0, 20(t2)
    EXPECT_EQ a0, 6, 14
    lw   a0, 24(t2)
    EXPECT_EQ a0, 7, 15
    lw   a0, 28(t2)
    EXPECT_EQ a0, 8, 16

    PASS

    .section .bss
    .balign 4
ballot_zero_results:
    .space 32
step_counts:
    .space 32
