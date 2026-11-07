/*
 * t_illegal_vset8.S: Illegal instruction verification for VSET field >= 8.
 *
 * Tai_2 section 1 / approved decisions:
 * custom-1 (0x2B) VSET with funct7 >= 8 is illegal.
 * Core must latch ERR_PC = err_site, set ERR.ILLEGAL, and halt.
 */

    .include "sw/tests/test.inc"

    .globl main
    .section .text
main:
    SCALAR

    .globl err_site
err_site:
    .insn r 0x2B, 0, 8, x0, x0, x0      # VSET 8, x0 (funct7=8 >= 8: illegal)

    # Fail if execution reaches here (hardware did not halt on illegal instruction)
    FAIL 1
