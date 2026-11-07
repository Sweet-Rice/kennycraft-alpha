/*
 * t_illegal_unknown.S: Illegal instruction verification for unsupported base encoding.
 *
 * Tai_2 section 1 / approved decisions:
 * Every encoding not explicitly defined in Tai_2 section 1 is illegal.
 * Emits an all-zero word (0x00000000, unallocated opcode 0x00).
 * Core must latch ERR_PC = err_site, set ERR.ILLEGAL, and halt.
 */

    .include "sw/tests/test.inc"

    .globl main
    .section .text
main:
    SCALAR

    .globl err_site
err_site:
    .word 0x00000000                    # All-zero word: unallocated opcode, illegal

    # Fail if execution reaches here (hardware did not halt on illegal instruction)
    FAIL 1
