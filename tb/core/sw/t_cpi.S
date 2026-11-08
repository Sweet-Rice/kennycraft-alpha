/* t_cpi: cycles per instruction for every class, measured with CYCLES.
   Each slot reads CYCLES, runs N copies of one instruction, reads CYCLES
   again and stores the difference to results[slot]. Slot 0 has an empty
   body, so CPI = (results[k] - results[0]) / N. Slot 9 times AUIPC + JALR
   pairs; the testbench subtracts the AUIPC CPI. Slots 25 and 26 time a
   loop instead (LI, then N passes of ADDI, the body and a BNEZ back edge
   taken N - 1 times), so the same branch and JAL run again and again. */
#include "kc_test.h"
#define N 32

.macro MEASURE slot, body:vararg
    lw    t0, MMIO_CYCLES(s0)
    .rept N
    \body
    .endr
    lw    t1, MMIO_CYCLES(s0)
    sub   t1, t1, t0
    sw    t1, (\slot * 4)(s1)
.endm

.macro MEASURE2 slot, first, second
    lw    t0, MMIO_CYCLES(s0)
    .rept N
    \first
    \second
    .endr
    lw    t1, MMIO_CYCLES(s0)
    sub   t1, t1, t0
    sw    t1, (\slot * 4)(s1)
.endm

.macro MEASURE_LOOP slot, body:vararg
    lw    t0, MMIO_CYCLES(s0)
    li    t2, N
77: addi  t2, t2, -1
    \body
    bnez  t2, 77b
    lw    t1, MMIO_CYCLES(s0)
    sub   t1, t1, t0
    sw    t1, (\slot * 4)(s1)
.endm

    .section .text.start
    .globl _start
_start:
    li    s0, MMIO_BASE
    la    s1, results
    la    s2, scratch
    li    s3, 0x20000000        /* world */
    li    s4, 0x30000000        /* textures */
    li    s5, 0x40000000        /* framebuffer */

    MEASURE 0
    MEASURE 1,  add a0, a1, a2
    MEASURE 2,  addi a0, a1, 3
    MEASURE 3,  lui a0, 0x12345
    MEASURE 4,  auipc a0, 0
    MEASURE 5,  mul a0, a1, a2
    MEASURE 6,  mulhu a0, a1, a2
    MEASURE 7,  bne zero, zero, .+4
    MEASURE 8,  beq zero, zero, .+4
    MEASURE2 9, "auipc a5, 0", "jalr zero, 8(a5)"
    MEASURE 10, jal zero, .+4
    MEASURE 11, lw a0, 0(s2)
    MEASURE 12, lbu a0, 1(s2)
    MEASURE 13, sw a0, 4(s2)
    MEASURE 14, sb a0, 5(s2)
    MEASURE 15, lw a0, MMIO_CYCLES(s0)
    MEASURE 16, lbu a0, 3(s3)
    MEASURE 17, lw a0, 4(s3)
    MEASURE 18, sb a0, 3(s3)
    MEASURE 19, sw a0, 4(s3)
    MEASURE 20, lw a0, 0(s4)
    MEASURE 21, sb a0, 7(s5)
    MEASURE 22, fence
    MEASURE 23, .insn r 0x0B, 5, 0, a0, x0, x0   /* MASKGET */
    MEASURE 24, .insn r 0x0B, 7, 0, x0, x0, x0   /* MASKALL */
    MEASURE_LOOP 25
    MEASURE_LOOP 26, jal zero, .+4

    li    t0, 1
    li    t1, TB_DONE
    sw    t0, 0(t1)
1:  j     1b

    .data
results:
    .space 4 * 27
scratch:
    .space 16
