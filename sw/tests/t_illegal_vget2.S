/*
 * t_illegal_vget2.S: Illegal instruction verification for a reserved VGET field.
 *
 * custom-1 (0x2B) VGET with funct7 >= 3 is reserved / illegal (field 2 is the
 * VTRACE result for the asynchronous VTRACE; field 3 is the first reserved one).
 * Core must latch ERR_PC = err_site, set ERR.ILLEGAL, and halt.
 */

    .include "sw/tests/test.inc"

    .globl main
    .section .text
main:
    SCALAR

    .globl err_site
err_site:
    .insn r 0x2B, 2, 3, a0, x0, x0      # VGET a0, 3 (word 0x0600252B)

    # Fail if execution reaches here (hardware did not halt on illegal instruction)
    FAIL 1
