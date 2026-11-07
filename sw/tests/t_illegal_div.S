/*
 * t_illegal_div.S: Illegal instruction verification for DIV.
 *
 * Tai_2 section 1: Under RV32I+Zmmul, DIV/DIVU/REM/REMU
 * (funct3 100 to 111 with funct7 0000001, opcode 0x33) are illegal.
 * Core must latch ERR_PC = err_site, set ERR.ILLEGAL, and halt.
 */

    .include "sw/tests/test.inc"

    .globl main
    .section .text
main:
    SCALAR

    li a0, 20
    li a1, 4

    .globl err_site
err_site:
    .insn r 0x33, 4, 1, a0, a0, a1      # div a0, a0, a1 (word 0x02B54533)

    # Fail if execution reaches here (hardware did not halt on illegal instruction)
    FAIL 1
