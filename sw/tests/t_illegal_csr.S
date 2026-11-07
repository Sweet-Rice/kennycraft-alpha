/*
 * t_illegal_csr.S: Illegal instruction verification for CSR instructions.
 *
 * Tai_2 section 1: Base ISA CSR instructions (OPC_SYSTEM = 0x73) are illegal.
 * Emitted as .word 0xC0002573 (csrr a0, cycle) to avoid requiring the Zicsr
 * compiler feature when compiling under -march=rv32i_zmmul.
 * Core must latch ERR_PC = err_site, set ERR.ILLEGAL, and halt.
 */

    .include "sw/tests/test.inc"

    .globl main
    .section .text
main:
    SCALAR

    .globl err_site
err_site:
    .word 0xC0002573                    # csrr a0, cycle (csrrs a0, 0xC00, x0)

    # Fail if execution reaches here (hardware did not halt on illegal instruction)
    FAIL 1
