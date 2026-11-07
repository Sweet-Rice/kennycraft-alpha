/*
 * t_illegal_vget2.S: Illegal instruction verification for VGET field 2.
 *
 * Tai_2 section 1: custom-1 (0x2B) VGET with funct7 >= 2 is reserved / illegal.
 * Core must latch ERR_PC = err_site, set ERR.ILLEGAL, and halt.
 */

    .include "sw/tests/test.inc"

    .globl main
    .section .text
main:
    SCALAR

    .globl err_site
err_site:
    .insn r 0x2B, 2, 2, a0, x0, x0      # VGET a0, 2 (word 0x0400252B)

    # Fail if execution reaches here (hardware did not halt on illegal instruction)
    FAIL 1
