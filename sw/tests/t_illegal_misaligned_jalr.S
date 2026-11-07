/*
 * t_illegal_misaligned_jalr.S: Illegal instruction verification for misaligned jump target.
 *
 * Tai_2 section 1 / approved decisions:
 *   - Misaligned taken instruction targets trap with ERR.ILLEGAL at the source PC.
 *   - Non-taken branch with misaligned target does not trap.
 *   - JALR clears bit 0 of the target address: odd address with bit 1 clear is legal.
 *   - Taken JALR with misaligned target (bit 1 set) traps before link register write.
 */

    .include "sw/tests/test.inc"

    .globl main
    .section .text
main:
    SCALAR

    # 1. Non-taken branch with misaligned target must NOT trap
    li   t0, 0
    bnez t0, .Lmisaligned_branch_target  # Condition false: branch not taken, no trap

    # 2. JALR with bit 0 set (addr % 4 == 1):
    # RISC-V clears bit 0: target = (t1 + 0) & ~1, which is 4-aligned. Must NOT trap.
    la   t1, .Llegal_jalr_target
    addi t1, t1, 1                       # bit 0 set, bit 1 clear
    jalr x0, 0(t1)                       # Must jump to .Llegal_jalr_target without trapping
    FAIL 1                               # Unreached

.Llegal_jalr_target:
    # 3. Taken JALR with misaligned target (addr % 4 == 2):
    # Target address has bit 1 set. Core must trap with ERR.ILLEGAL,
    # latch ERR_PC = err_site, and must NOT update link register ra.
    la   a0, .Lmisaligned_jalr_target
    addi a0, a0, 2                       # target[1:0] == 2'b10 (misaligned instruction PC)
    li   ra, 0x12345678                  # Sentinel in link register

    .globl err_site
err_site:
    jalr ra, 0(a0)                       # Taken misaligned jump: must trap with ERR.ILLEGAL

    # Fail if execution reaches here (hardware did not halt on misaligned jump)
    FAIL 2

.Lmisaligned_branch_target:
    .word 0                              # Non-taken target placeholder
.Lmisaligned_jalr_target:
    FAIL 3                               # Never reached if hardware trapped
