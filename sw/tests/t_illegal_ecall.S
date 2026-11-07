/*
 * t_illegal_ecall.S: Illegal instruction verification for ECALL.
 *
 * Tai_2 section 1: Base ISA SYSTEM opcode (0x73) instructions
 * including ECALL (word 0x00000073) are illegal in KennyCraft.
 * Core must latch ERR_PC = err_site, set ERR.ILLEGAL, and halt.
 */

    .include "sw/tests/test.inc"

    .globl main
    .section .text
main:
    SCALAR

    .globl err_site
err_site:
    ecall                               # opcode 0x73, word 0x00000073

    # Fail if execution reaches here (hardware did not halt on illegal instruction)
    FAIL 1
