/*
 * t_illegal_misaligned_jal.S: a JAL whose target is not 4-aligned halts
 * with ERR.ILLEGAL, ERR_PC = the JAL's own PC (D16).
 */

    .include "sw/tests/test.inc"

    .globl main
    .section .text
main:
    SCALAR

    .globl err_site
err_site:
    jal  ra, .Lmisaligned_target+2       # target[1:0] == 2'b10

    # Fail if execution reaches here (hardware did not halt on the JAL)
    FAIL 1

.Lmisaligned_target:
    FAIL 2                               # Never reached if hardware trapped
