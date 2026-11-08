    .section .text.start
    .globl _start
_start:
    .insn r 0x0B, 7, 0, x0, x0, x0      # MASKALL
    .insn r 0x0B, 0, 0, t0, x0, x0      # t0 = LANEID
    slli  t0, t0, 10                    # lane * 1024
    li    sp, 0x10008000
    sub   sp, sp, t0                    # each lane gets its own 1 KB stack
    li    t1, 1
    .insn r 0x0B, 6, 0, x0, t1, x0      # MASKSET 1, lane 0 only
    la    a0, __data_start              # .data from its load copy: BRAM keeps the last
    la    a1, __data_end                # run's values over a warm reset (kc.ld)
    la    a2, __data_load
4:  bgeu  a0, a1, 5f
    lw    t2, 0(a2)
    sw    t2, 0(a0)
    addi  a0, a0, 4
    addi  a2, a2, 4
    j     4b
5:
    la    a0, __bss_start
    la    a1, __bss_end
1:  bgeu  a0, a1, 2f
    sw    zero, 0(a0)
    addi  a0, a0, 4
    j     1b
2:  call  main
3:  j     3b
