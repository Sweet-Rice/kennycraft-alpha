# UART helpers used only after returning to scalar mask 1.
    .macro SCALAR
    .insn r 0x0B, 7, 0, x0, x0, x0
    li t6, 1
    .insn r 0x0B, 6, 0, x0, t6, x0
    .endm

    .macro PASS
    SCALAR
    j .Lbench_pass
    .endm

    .macro FAIL number
    SCALAR
    li a0, \number
    j .Lbench_fail
    .endm

# Scalar-only assertion; t6 is scratch.
    .macro EXPECT_EQ reg, value, number
    li t6, \value
    beq \reg, t6, .Lbench_ok\@
    FAIL \number
.Lbench_ok\@:
    .endm

# Scalar-only register-to-register assertion.
    .macro EXPECT_REG reg, other, number
    beq \reg, \other, .Lbench_ok\@
    FAIL \number
.Lbench_ok\@:
    .endm

# Inline output preserves the supplied register; t4/t5 are scratch.
    .macro PUT reg
    li t4, 0x50000000
.Lbench_busy\@:
    lw t5, 0x14(t4)
    andi t5, t5, 2
    bnez t5, .Lbench_busy\@
    sw \reg, 0x18(t4)
    .endm

    .section .text
.Lbench_pass:
    la t2, .Lbench_pass_text
.Lbench_print:
    lbu a0, 0(t2)
    beqz a0, .Lbench_drain
    PUT a0
    addi t2, t2, 1
    j .Lbench_print

.Lbench_fail:
    mv s0, a0
    li a0, 'F'
    PUT a0
    li a0, 'A'
    PUT a0
    li a0, 'I'
    PUT a0
    li a0, 'L'
    PUT a0
    li a0, ' '
    PUT a0
    la t0, .Lbench_divisors
    li t1, 10
    li t3, 0
.Lbench_digit:
    lw t2, 0(t0)
    li a0, 0
.Lbench_subtract:
    bltu s0, t2, .Lbench_emit_digit
    sub s0, s0, t2
    addi a0, a0, 1
    j .Lbench_subtract
.Lbench_emit_digit:
    or t3, t3, a0
    bnez t3, .Lbench_output_digit
    li t6, 1
    bne t1, t6, .Lbench_next_digit
.Lbench_output_digit:
    addi a0, a0, '0'
    PUT a0
.Lbench_next_digit:
    addi t0, t0, 4
    addi t1, t1, -1
    bnez t1, .Lbench_digit
    li a0, 10
    PUT a0
.Lbench_drain:
    li t4, 0x50000000
    lw t5, 0x14(t4)
    andi t5, t5, 2
    bnez t5, .Lbench_drain
.Lbench_halt:
    j .Lbench_halt

    .section .rodata
.Lbench_pass_text:
    .asciz "PASS\n"
    .balign 4
.Lbench_divisors:
    .word 1000000000, 100000000, 10000000, 1000000, 100000
    .word 10000, 1000, 100, 10, 1
    .section .text
