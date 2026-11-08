/* t_mmio: every MMIO register and the display / chunk-engine / byte-region
   ports of kc_soc, against the harness models in soc_harness.svh, plus the
   unmapped 0x7 region (the removed GPU memory). Results go to res[] in dmem;
   the testbench checks them and the models. */
#include "kc_test.h"
#define DDR_STATUS  0x2C
#define CHUNK_CMD   0x30
#define SLOT_VALID  0x38
#define WIN_ORIGIN  0x3C

    .section .text.start
    .globl _start
_start:
    li    s0, MMIO_BASE
    la    s1, res

    li    t0, 0xA5
    sw    t0, MMIO_LEDS(s0)         /* LEDS = 0xA5 */
    lw    t1, MMIO_LEDS(s0)
    sw    t1, 0(s1)                 /* write-only: reads 0 */

    li    t0, 1
    sw    t0, MMIO_FB_MODE(s0)
    lw    t1, MMIO_FB_MODE(s0)
    sw    t1, 4(s1)                 /* 1 */

    sw    t0, MMIO_FB_SWAP(s0)      /* one swap_req pulse */
    lw    t1, MMIO_FB_SWAP(s0)
    sw    t1, 8(s1)                 /* pending: 1 */
    li    t2, 0
1:  addi  t2, t2, 1
    lw    t1, MMIO_FB_SWAP(s0)
    bnez  t1, 1b
    sw    t2, 12(s1)                /* polls until the model's vblank flip */
    lw    t1, MMIO_FRAME_COUNT(s0)
    sw    t1, 16(s1)
    lw    t1, MMIO_VSYNC(s0)
    sw    t1, 20(s1)

    lw    t1, MMIO_CYCLES(s0)
    lw    t2, MMIO_CYCLES(s0)
    sub   t2, t2, t1
    sw    t2, 24(s1)                /* 5: one LW apart */

    lw    t1, MMIO_UART_STATUS(s0)
    sw    t1, 28(s1)                /* 0: RX empty, TX idle */
    lw    t1, MMIO_UART_RX(s0)
    sw    t1, 32(s1)                /* empty FIFO reads 0 */
    li    t0, 0x55
    sb    t0, MMIO_UART_TX(s0)
    lw    t1, MMIO_UART_STATUS(s0)
    sw    t1, 36(s1)                /* 2: TX busy */

    li    t0, 0xBEEF
    sw    t0, SLOT_VALID(s0)
    lw    t1, SLOT_VALID(s0)
    sw    t1, 40(s1)                /* 0xBEEF through the register port */
    lw    t1, DDR_STATUS(s0)
    sw    t1, 44(s1)                /* model value 1 */
    li    t0, 0x00000302            /* LOAD chunk x = 2, z = 3 */
    lw    t1, MMIO_CYCLES(s0)
    sw    t0, CHUNK_CMD(s0)         /* stalls in the model */
    lw    t2, MMIO_CYCLES(s0)
    sub   t2, t2, t1
    sw    t2, 48(s1)
    li    t0, 0x1020
    sw    t0, WIN_ORIGIN(s0)

    li    s2, 0x40000000            /* framebuffer */
    li    t0, 0x44332211
    sw    t0, 16(s2)
    li    t0, 0x77
    sb    t0, 19(s2)
    lw    t1, 16(s2)
    sw    t1, 52(s1)                /* 0x77332211 */
    lhu   t1, 18(s2)
    sw    t1, 56(s1)                /* 0x7733 */
    li    t3, 76799
    add   t3, t3, s2
    li    t0, 0x9C
    sb    t0, 0(t3)                 /* last pixel */
    lbu   t1, 0(t3)
    sw    t1, 60(s1)
    li    t0, 0xBEEF
    sh    t0, 18(s2)
    lw    t1, 16(s2)
    sw    t1, 96(s1)                /* 0xBEEF2211 */
    lb    t1, 19(s2)
    sw    t1, 100(s1)               /* 0xFFFFFFBE */
    lh    t1, 18(s2)
    sw    t1, 104(s1)               /* 0xFFFFBEEF */
    li    t3, 0x40020011            /* addr[27:17] not decoded: byte 17 */
    li    t0, 0x5A
    sb    t0, 0(t3)
    lw    t1, 16(s2)
    sw    t1, 108(s1)               /* 0xBEEF5A11 */

    li    s3, 0x60000000            /* palette */
    li    t0, 0x7ABC
    sw    t0, 20(s3)                /* entry 5 = 0xABC */
    lw    t1, 20(s3)
    sw    t1, 64(s1)                /* write only: 0 */

    li    s4, 0x20000000            /* world stub: 4 bits per block */
    li    t0, 0x0F0E0D0C
    sw    t0, 0x100(s4)
    li    t0, 0xFF
    sb    t0, 0x101(s4)
    lw    t1, 0x100(s4)
    sw    t1, 68(s1)                /* 0x0F0E0F0C */
    li    s5, 0x30002800            /* texture stub: 4 bits per texel */
    li    t0, 0x5A
    sb    t0, 0x7FF(s5)       /* texel 0x2FFF */
    lbu   t1, 0x7FF(s5)       /* texel 0x2FFF */
    sw    t1, 72(s1)                /* 0x0A */
    lh    t1, 0x100(s4)
    sw    t1, 76(s1)                /* 0x0F0C */

    li    s6, UNMAPPED_BASE         /* 0x7000_0000: unmapped */
    li    t0, 0x12345678
    sw    t0, 0(s6)
    sb    t0, 5(s6)
    sh    t0, 6(s6)
    li    t3, UNMAPPED_BASE + 0x10FFC   /* the old GPU memory's last word */
    sw    t0, 0(t3)
    lw    t1, 0(s6)
    sw    t1, 80(s1)                /* 0 */
    lw    t1, 0(t3)
    sw    t1, 84(s1)                /* 0 */
    lbu   t1, 5(s6)
    sw    t1, 88(s1)                /* 0 */
    lh    t1, 6(s6)
    sw    t1, 92(s1)                /* 0 */

    li    t0, 1
    li    t1, TB_DONE
    sw    t0, 0(t1)
2:  j     2b

    .data
res:
    .space 4 * 30
