/*
 * t_illegal_misaligned_branch.S: a taken branch whose target is not
 * 4-aligned halts with ERR.ILLEGAL, ERR_PC = the branch's own PC (D16).
 */

    .include "sw/tests/test.inc"

    .globl main
    .section .text
main:
    SCALAR

    # A taken branch to an aligned target must not trap
    li   t0, 1
    bnez t0, .Laligned_target
    FAIL 1

.Laligned_target:
    .globl err_site
err_site:
    bnez t0, .Lmisaligned_target+2       # Taken, target[1:0] == 2'b10

    # Fail if execution reaches here (hardware did not halt on the branch)
    FAIL 2

.Lmisaligned_target:
    FAIL 3                               # Never reached if hardware trapped
