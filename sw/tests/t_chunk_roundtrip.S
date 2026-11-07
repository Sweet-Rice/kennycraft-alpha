/*
 * sw/tests/t_chunk_roundtrip.S
 *
 * Self-checking test for DDR3 chunk store roundtrip:
 * 1. Wait for DDR_STATUS calibration (offset 0x2C bit 0).
 * 2. Ensure WIN_ORIGIN is 0 and SLOT_VALID enables slot 0 (0xFFFF).
 * 3. Sample initial CHUNK_DONE count.
 * 4. Fill all 8,192 blocks of slot 0 (16x32x16) with a varying non-zero
 *    low-nibble pattern: ((x + (z << 1) + (y << 2)) & 0x0E) + 1.
 * 5. Issue CHUNK_CMD STORE (bit 31 = 1, cz = 0, cx = 0).
 * 6. Poll CHUNK_DONE until it advances by 1.
 * 7. Clear all 8,192 blocks of slot 0 to 0 (air) and verify clearing.
 * 8. Issue CHUNK_CMD LOAD (bit 31 = 0, cz = 0, cx = 0).
 * 9. Poll CHUNK_DONE until it advances by 2 total.
 * 10. Verify completion count equals initial + 2.
 * 11. Compare all 8,192 block low-nibbles against the original pattern.
 *
 * Error codes:
 *   FAIL 101: CHUNK_DONE did not advance after STORE
 *   FAIL 102: Slot not zeroed after clearing
 *   FAIL 103: CHUNK_DONE did not advance after LOAD
 *   FAIL 104: Block data mismatch after reload
 */

.include "sw/tests/test.inc"

    .section .text
    .globl main
main:
    li      s0, 0x50000000          # MMIO base
    li      s2, 0x20000000          # World window base

    # 1. Wait for DDR3 calibration (DDR_STATUS offset 0x2C, bit 0)
.Lwait_ddr_cal:
    lw      t0, 0x2C(s0)
    andi    t0, t0, 1
    beqz    t0, .Lwait_ddr_cal

    # 2. Reset WIN_ORIGIN and validate all slots
    sw      zero, 0x3C(s0)          # WIN_ORIGIN = 0
    li      t0, 0xFFFF
    sw      t0, 0x38(s0)            # SLOT_VALID = 0xFFFF

    # 3. Read initial CHUNK_DONE count
    lw      s1, 0x34(s0)            # s1 = initial CHUNK_DONE

    # 4. Fill slot 0 (16 x 32 x 16 = 8,192 blocks) with varying low-nibble pattern
    #    x in [0..15], z in [0..15], y in [0..31]
    #    val = ((x + (z << 1) + (y << 2)) & 0x0E) + 1  (values in 1..15)
    #    addr = 0x20000000 | (y << 12) | (z << 6) | x
    li      t1, 0                   # y = 0
.Lfill_y:
    li      t2, 0                   # z = 0
.Lfill_z:
    li      t3, 0                   # x = 0
.Lfill_x:
    slli    t4, t2, 1               # z << 1
    add     t4, t4, t3              # x + (z << 1)
    slli    t5, t1, 2               # y << 2
    add     t4, t4, t5              # x + (z << 1) + (y << 2)
    andi    t4, t4, 0x0E
    addi    t4, t4, 1               # pattern nibble (1..15)

    slli    t5, t1, 12              # y << 12
    slli    t6, t2, 6               # z << 6
    or      t5, t5, t6
    or      t5, t5, t3              # offset = (y << 12) | (z << 6) | x
    add     t5, s2, t5              # addr = 0x20000000 + offset
    sb      t4, 0(t5)

    addi    t3, t3, 1
    li      t4, 16
    bltu    t3, t4, .Lfill_x

    addi    t2, t2, 1
    bltu    t2, t4, .Lfill_z

    addi    t1, t1, 1
    li      t4, 32
    bltu    t1, t4, .Lfill_y

    # 5. Issue CHUNK_CMD STORE: op=1 (bit 31), cz=0, cx=0 -> 0x80000000
    lui     t0, 0x80000
    sw      t0, 0x30(s0)

    # 6. Wait for CHUNK_DONE to advance by 1
    addi    s3, s1, 1               # s3 = initial + 1
.Lwait_store:
    lw      t0, 0x34(s0)
    bne     t0, s3, .Lwait_store

    # 7. Clear all 8,192 blocks of slot 0 to 0 (air)
    li      t1, 0                   # y = 0
.Lclear_y:
    li      t2, 0                   # z = 0
.Lclear_z:
    li      t3, 0                   # x = 0
.Lclear_x:
    slli    t5, t1, 12
    slli    t6, t2, 6
    or      t5, t5, t6
    or      t5, t5, t3
    add     t5, s2, t5
    sb      zero, 0(t5)

    addi    t3, t3, 1
    li      t4, 16
    bltu    t3, t4, .Lclear_x

    addi    t2, t2, 1
    bltu    t2, t4, .Lclear_z

    addi    t1, t1, 1
    li      t4, 32
    bltu    t1, t4, .Lclear_y

    # Verify sample block cleared
    lbu     t0, 0(s2)
    bnez    t0, .Lfail_clear

    # 8. Issue CHUNK_CMD LOAD: op=0 (bit 31), cz=0, cx=0 -> 0x00000000
    sw      zero, 0x30(s0)

    # 9. Wait for CHUNK_DONE to advance by 2 total
    addi    s3, s1, 2               # s3 = initial + 2
.Lwait_load:
    lw      t0, 0x34(s0)
    bne     t0, s3, .Lwait_load

    # 10. Check completion count equals initial + 2
    lw      t0, 0x34(s0)
    beq     t0, s3, .Ldone_count_ok
    FAIL    103

.Ldone_count_ok:
    # 11. Compare all 8,192 reloaded block nibbles
    li      t1, 0                   # y = 0
.Lcheck_y:
    li      t2, 0                   # z = 0
.Lcheck_z:
    li      t3, 0                   # x = 0
.Lcheck_x:
    slli    t4, t2, 1               # z << 1
    add     t4, t4, t3              # x + (z << 1)
    slli    t5, t1, 2               # y << 2
    add     t4, t4, t5              # x + (z << 1) + (y << 2)
    andi    t4, t4, 0x0E
    addi    t4, t4, 1               # expected nibble (1..15)

    slli    t5, t1, 12
    slli    t6, t2, 6
    or      t5, t5, t6
    or      t5, t5, t3
    add     t5, s2, t5
    lbu     t0, 0(t5)
    andi    t0, t0, 0x0F

    beq     t0, t4, .Lblock_ok
    FAIL    104                     # Block data mismatch after reload

.Lblock_ok:
    addi    t3, t3, 1
    li      t4, 16
    bltu    t3, t4, .Lcheck_x

    addi    t2, t2, 1
    bltu    t2, t4, .Lcheck_z

    addi    t1, t1, 1
    li      t4, 32
    bltu    t1, t4, .Lcheck_y

    PASS

.Lfail_clear:
    FAIL    102
