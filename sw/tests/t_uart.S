/*
 * t_uart.S: UART echo verification test.
 *
 * Checks that the core receives "kc!\n" (bytes 0x6B, 0x63, 0x21, 0x0A)
 * from UART_RX (MMIO 0x50000010) as queued at reset frame 0, and echoes
 * each byte back to UART_TX (MMIO 0x50000018) before emitting PASS.
 */

    .include "sw/tests/test.inc"

    .globl main
    .section .text
main:
    SCALAR

    li s0, 0x50000000          # MMIO base address

    # Byte 1: 'k' (0x6B)
.Lwait_rx1:
    lw t0, 0x14(s0)            # UART_STATUS
    andi t0, t0, 1             # bit 0 = RX byte available
    beqz t0, .Lwait_rx1
    lw a0, 0x10(s0)            # UART_RX pop byte
    andi a0, a0, 0xFF
    EXPECT_EQ a0, 0x6B, 1      # Must equal 'k'
    PUT a0                     # Echo 'k' to UART_TX

    # Byte 2: 'c' (0x63)
.Lwait_rx2:
    lw t0, 0x14(s0)
    andi t0, t0, 1
    beqz t0, .Lwait_rx2
    lw a0, 0x10(s0)
    andi a0, a0, 0xFF
    EXPECT_EQ a0, 0x63, 2      # Must equal 'c'
    PUT a0                     # Echo 'c' to UART_TX

    # Byte 3: '!' (0x21)
.Lwait_rx3:
    lw t0, 0x14(s0)
    andi t0, t0, 1
    beqz t0, .Lwait_rx3
    lw a0, 0x10(s0)
    andi a0, a0, 0xFF
    EXPECT_EQ a0, 0x21, 3      # Must equal '!'
    PUT a0                     # Echo '!' to UART_TX

    # Byte 4: '\n' (0x0A)
.Lwait_rx4:
    lw t0, 0x14(s0)
    andi t0, t0, 1
    beqz t0, .Lwait_rx4
    lw a0, 0x10(s0)
    andi a0, a0, 0xFF
    EXPECT_EQ a0, 0x0A, 4      # Must equal '\n'
    PUT a0                     # Echo '\n' to UART_TX

    PASS
