# Bootloader start-up: lane 0 only, stack at the top of dmem 0x1000_0000..0x1000_5FFF
# (0x6000..0x7FFF stays untouched), .bss cleared, then main.
    .section .text.start
    .globl _start
_start:
    li    t1, 1
    .insn r 0x0B, 6, 0, x0, t1, x0      # MASKSET 1: lane 0 only
    li    sp, 0x10006000
    la    a0, __bss_start
    la    a1, __bss_end
1:  bgeu  a0, a1, 2f
    sw    zero, 0(a0)
    addi  a0, a0, 4
    j     1b
2:  call  main
3:  j     3b
