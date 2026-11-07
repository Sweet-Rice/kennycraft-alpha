/*
 * t_illegal_misaligned.S: Illegal instruction verification for misaligned LW.
 *
 * Tai_2 section 1: Misaligned load or store (LW/SW not 4-aligned, LH/LHU/SH
 * not 2-aligned) is illegal in KennyCraft.
 * Core must latch ERR_PC = err_site, set ERR.ILLEGAL, and halt.
 */

    .include "sw/tests/test.inc"

    .globl main
    .section .text
main:
    SCALAR

    la a0, test_buf
    addi a0, a0, 1                      # a0 is misaligned: addr % 4 == 1

    .globl err_site
err_site:
    lw a1, 0(a0)                        # Misaligned LW: must trap with ERR.ILLEGAL

    # Fail if execution reaches here (hardware did not halt on illegal instruction)
    FAIL 1

    .section .data
    .balign 4
test_buf:
    .word 0x12345678
    .word 0x9ABCDEF0
