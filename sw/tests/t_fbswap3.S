/*
 * t_fbswap3.S: FB_SWAP with three framebuffers (FB_COUNT = 3, D24), the
 * Stage 2 counterpart of t_fbswap.S.
 *
 * Buffers are told apart by a tag byte at offset 0 (the CPU only ever sees
 * its draw buffer at 0x4000_0000); every buffer starts zeroed. The test
 * first waits for a FRAME_COUNT edge (the start of a vblank), so the next
 * vblank is a whole frame (~840 k core cycles) away and each step below has
 * one outcome:
 *   - FB_SWAP reads 0 at reset; after a store of 1 it reads 0 again within
 *     SWAP_MAX core cycles (no vblank wait), and FRAME_COUNT does not move.
 *   - Swap 1: the new draw buffer is a fresh one (tag 0), not the one just
 *     made ready, and keeps what is written to it.
 *   - Swap 2 before the vblank replaces the ready frame (mailbox): its
 *     buffer comes straight back as the draw buffer with its pixels intact.
 *   - After a vblank (the ready frame became front) swap 3 hands out the
 *     buffer that was front before (tag 0): neither the new front nor the
 *     frame just made ready.
 *   - Swap 4 before the next vblank again replaces the ready frame and hands
 *     its buffer back.
 */

    .include "sw/tests/test.inc"

    .equ SWAP_MAX, 200          # core cycles FB_SWAP may read 1 after a store

    # Store 1 to FB_SWAP and poll until it reads 0; fail if that takes more
    # than SWAP_MAX cycles or FRAME_COUNT moved (s2 = FRAME_COUNT expected).
    .macro SWAP number
    lw t3, 0x0C(s0)            # CYCLES
    li t0, 1
    sw t0, 0x00(s0)            # FB_SWAP = 1
.Lswap_poll\@:
    lw t0, 0x0C(s0)
    sub t0, t0, t3
    li t1, SWAP_MAX
    bgeu t0, t1, .Lswap_slow\@
    lw t0, 0x00(s0)
    bnez t0, .Lswap_poll\@
    lw t0, 0x04(s0)            # FRAME_COUNT
    beq t0, s2, .Lswap_ok\@
    FAIL \number + 1
.Lswap_slow\@:
    FAIL \number
.Lswap_ok\@:
    .endm

    # Write tag and a check byte to the draw buffer and read both back.
    .macro DRAW tag, number
    li t0, \tag
    sb t0, 0(s1)
    sb t0, 0(s4)
    lbu a0, 0(s1)
    EXPECT_EQ a0, \tag, \number
    lbu a0, 0(s4)
    EXPECT_EQ a0, \tag, \number + 1
    .endm

    # Draw buffer tag (offset 0 and 76799) must be value.
    .macro EXPECT_TAG value, number
    lbu a0, 0(s1)
    EXPECT_EQ a0, \value, \number
    lbu a0, 0(s4)
    EXPECT_EQ a0, \value, \number + 1
    .endm

    # Wait for the next FRAME_COUNT edge; s2 = the new FRAME_COUNT.
    .macro WAIT_FRAME
    lw t0, 0x04(s0)
.Lframe_wait\@:
    lw s2, 0x04(s0)
    beq s2, t0, .Lframe_wait\@
    .endm

    .globl main
    .section .text
main:
    SCALAR

    li s0, 0x50000000          # MMIO base
    li s1, 0x40000000          # draw buffer, offset 0
    li s4, 0x40000000 + 76799  # draw buffer, last byte

    # 1. FB_SWAP idle, then line up just after the start of a vblank.
    lw t0, 0x00(s0)
    EXPECT_EQ t0, 0, 1
    WAIT_FRAME

    # 2. Buffer A: tag 0xA1, swap 1 makes it ready.
    EXPECT_TAG 0, 10
    DRAW 0xA1, 12
    SWAP 14

    # 3. A fresh buffer B (not A), keeps its pixels.
    EXPECT_TAG 0, 20
    DRAW 0xB2, 22

    # 4. Swap 2 before the vblank replaces A with B; A comes back intact.
    SWAP 24
    EXPECT_TAG 0xA1, 30
    DRAW 0xC3, 32

    # 5. Vblank: B becomes front. Swap 3 makes A (0xC3) ready and hands out
    #    the old front buffer (tag 0), neither B nor A.
    WAIT_FRAME
    SWAP 40
    EXPECT_TAG 0, 42
    DRAW 0xD4, 44

    # 6. Swap 4 before the next vblank replaces A; A comes back intact.
    SWAP 50
    EXPECT_TAG 0xC3, 52

    # 7. Swaps never moved FRAME_COUNT by themselves.
    lw t0, 0x04(s0)
    EXPECT_REG t0, s2, 60

    PASS
