/*
 * t_fbswap.S: Framebuffer swap and double-buffer verification test.
 *
 * Verifies:
 *   - Framebuffer back-buffer read and write semantics across boundaries
 *     (corners x=0,y=0; x=1,y=0; x=319,y=0; x=0,y=1; center; bottom-right).
 *   - FB_SWAP (MMIO 0x50000000) handshaking: writing 1 initiates swap,
 *     polls until hardware clears swap_pending at vsync.
 *   - Frame count progress: FRAME_COUNT (MMIO 0x50000004) increments after swap.
 *   - Double-buffering ping-pong semantics: back and front buffers toggle,
 *     preserving previously written contents across frame swaps.
 *   - FB_MODE (MMIO 0x50000028) read/write configuration.
 */

    .include "sw/tests/test.inc"

    .globl main
    .section .text
main:
    SCALAR

    li s0, 0x50000000          # MMIO base
    li s1, 0x40000000          # Framebuffer base (back buffer)

    # 1. Assert initial FB_SWAP is 0 (idle)
    lw t0, 0x00(s0)            # MMIO_FB_SWAP
    EXPECT_EQ t0, 0, 1

    # 2. Sample initial FRAME_COUNT
    lw s2, 0x04(s0)            # Initial frame count in s2

    # 3. Write distinct known test pattern to back buffer (Buffer A)
    li t0, 0x5A
    sb t0, 0(s1)               # offset 0 (top-left pixel)

    li t0, 0x3C
    sb t0, 1(s1)               # offset 1

    li t0, 0x69
    li t1, 319
    add t2, s1, t1
    sb t0, 0(t2)               # offset 319 (end of line 0)

    li t0, 0x96
    li t1, 320
    add t2, s1, t1
    sb t0, 0(t2)               # offset 320 (start of line 1)

    li t0, 0xA5
    li t1, 38400
    add t2, s1, t1
    sb t0, 0(t2)               # offset 38400 (screen center)

    li t0, 0xC3
    li t1, 76799
    add t2, s1, t1
    sb t0, 0(t2)               # offset 76799 (bottom-right pixel)

    # 4. Read back immediately to verify back buffer write/read integrity
    lbu a0, 0(s1)
    EXPECT_EQ a0, 0x5A, 10

    lbu a0, 1(s1)
    EXPECT_EQ a0, 0x3C, 11

    li t1, 319
    add t2, s1, t1
    lbu a0, 0(t2)
    EXPECT_EQ a0, 0x69, 12

    li t1, 320
    add t2, s1, t1
    lbu a0, 0(t2)
    EXPECT_EQ a0, 0x96, 13

    li t1, 38400
    add t2, s1, t1
    lbu a0, 0(t2)
    EXPECT_EQ a0, 0xA5, 14

    li t1, 76799
    add t2, s1, t1
    lbu a0, 0(t2)
    EXPECT_EQ a0, 0xC3, 15

    # 5. Request first swap
    li t0, 1
    sw t0, 0x00(s0)            # Set FB_SWAP = 1

    # 6. Poll FB_SWAP until cleared at vsync
.Lpoll_swap1:
    lw t0, 0x00(s0)
    bnez t0, .Lpoll_swap1

    # 7. Validate frame progress: FRAME_COUNT must have strictly advanced
    lw s3, 0x04(s0)
    bleu s3, s2, .Lfail_frame1
    j .Lok_frame1
.Lfail_frame1:
    FAIL 20
.Lok_frame1:

    # 8. Check double-buffer toggle: new back buffer (Buffer B) must be initial zero
    lbu a0, 0(s1)
    EXPECT_EQ a0, 0, 30

    lbu a0, 1(s1)
    EXPECT_EQ a0, 0, 31

    # 9. Draw new distinct pattern into Buffer B
    li t0, 0x11
    sb t0, 0(s1)
    li t0, 0x22
    sb t0, 1(s1)

    lbu a0, 0(s1)
    EXPECT_EQ a0, 0x11, 32
    lbu a0, 1(s1)
    EXPECT_EQ a0, 0x22, 33

    # 10. Request second swap
    li t0, 1
    sw t0, 0x00(s0)

.Lpoll_swap2:
    lw t0, 0x00(s0)
    bnez t0, .Lpoll_swap2

    # 11. Validate frame progress again: FRAME_COUNT must advance again
    lw s4, 0x04(s0)
    bleu s4, s3, .Lfail_frame2
    j .Lok_frame2
.Lfail_frame2:
    FAIL 40
.Lok_frame2:

    # 12. Check Buffer A is restored to back buffer with original contents intact
    lbu a0, 0(s1)
    EXPECT_EQ a0, 0x5A, 50

    lbu a0, 1(s1)
    EXPECT_EQ a0, 0x3C, 51

    li t1, 319
    add t2, s1, t1
    lbu a0, 0(t2)
    EXPECT_EQ a0, 0x69, 52

    li t1, 320
    add t2, s1, t1
    lbu a0, 0(t2)
    EXPECT_EQ a0, 0x96, 53

    li t1, 38400
    add t2, s1, t1
    lbu a0, 0(t2)
    EXPECT_EQ a0, 0xA5, 54

    li t1, 76799
    add t2, s1, t1
    lbu a0, 0(t2)
    EXPECT_EQ a0, 0xC3, 55

    # 13. Verify FB_MODE read/write
    li t0, 1
    sw t0, 0x28(s0)            # Set FB_MODE = 1 (160x120 mode)
    lw a0, 0x28(s0)
    EXPECT_EQ a0, 1, 60

    li t0, 0
    sw t0, 0x28(s0)            # Restore FB_MODE = 0 (320x240 mode)
    lw a0, 0x28(s0)
    EXPECT_EQ a0, 0, 61

    PASS
