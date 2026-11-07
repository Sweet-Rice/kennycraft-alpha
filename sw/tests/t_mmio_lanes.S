    .include "sw/tests/test.inc"

    .globl main
    .section .text
main:
    li   t4, 0x50000000                 # MMIO base address

    # 1. Wait until UART_STATUS (0x14) bit 0 indicates first RX byte is available
.Lwait_first_byte:
    lw   t5, 0x14(t4)
    andi t5, t5, 1
    beqz t5, .Lwait_first_byte

    # 2. First byte is available. Wait >= 1000 cycles for the second byte to finish
    # arriving into the FIFO (50 core clocks per bit * 10 bits = 500 clocks).
    lw   t0, 0x0C(t4)                   # sample CYCLES
.Lwait_second_byte:
    lw   t2, 0x0C(t4)
    sub  t2, t2, t0
    li   t3, 1500
    bltu t2, t3, .Lwait_second_byte

    # 3. Set mask to 0x03 (lanes 0 and 1 active)
    li   t0, 3
    .insn r 0x0B, 6, 0, x0, t0, x0      # MASKSET 3

    # 4. Perform a 2-lane MMIO load from UART_RX (0x50000010).
    # Lane 0 reads first and pops 0x6B; lane 1 reads next and pops 0x63.
    lw   a0, 0x10(t4)

    # 5. Wake all lanes to record each lane's received byte into dmem
    .insn r 0x0B, 7, 0, x0, x0, x0      # MASKALL
    .insn r 0x0B, 0, 0, a1, x0, x0      # LANEID a1
    slli a2, a1, 2
    la   a3, rx_bytes
    add  a3, a3, a2
    sw   a0, 0(a3)

    # 6. Return to scalar mask
    SCALAR

    # 7. Validate pop order: lane 0 got 0x6B, lane 1 got 0x63
    la   a3, rx_bytes

    lw   a0, 0(a3)
    EXPECT_EQ a0, 0x6B, 1

    lw   a0, 4(a3)
    EXPECT_EQ a0, 0x63, 2

    PASS

    .section .bss
    .balign 4
rx_bytes:
    .space 32
