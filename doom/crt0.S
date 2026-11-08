# Doom start-up: lane 0 only, stack at the top of XMEM, .bss cleared, then main.
    .section .text.start
    .globl _start
_start:
    li    t1, 1
    .insn r 0x0B, 6, 0, x0, t1, x0      # MASKSET 1: lane 0 only
    la    sp, __stack_top
.option push
.option norelax
    la    gp, __global_pointer$
.option pop
    la    a0, __bss_start
    la    a1, __bss_end
1:  bgeu  a0, a1, 2f
    sw    zero, 0(a0)
    addi  a0, a0, 4
    j     1b
2:  call  main
    call  exit
3:  j     3b
