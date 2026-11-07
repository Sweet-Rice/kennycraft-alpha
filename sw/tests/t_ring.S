/*
 * sw/tests/t_ring.S
 *
 * Self-checking test for WIN_ORIGIN world-window ring buffer wrapping:
 * 1. Wait for DDR_STATUS calibration (offset 0x2C bit 0).
 * 2. Ensure initial WIN_ORIGIN is 0.
 * 3. Configure SLOT_VALID = 0x0002 (Slot 1 valid, Slots 0 and 2 invalid).
 * 4. Write a unique block value 0x0E to physical block (20, 8, 10) in slot 1
 *    via window-relative coordinates (x_rel=20, y=8, z_rel=10).
 * 5. Verify reads at WIN_ORIGIN=0:
 *    - rel(20, 8, 10) -> physical(20, 8, 10) in slot 1 (valid) -> returns 0x0E.
 *    - rel(36, 8, 10) -> physical(36, 8, 10) in slot 2 (invalid) -> returns air (0x00).
 *    - rel(4, 8, 10)  -> physical(4, 8, 10) in slot 0 (invalid) -> returns air (0x00).
 * 6. Change WIN_ORIGIN.x by 16 (WIN_ORIGIN = 0x0010):
 *    - Physical block (20, 8, 10) is now at adjusted relative index x_rel = 4 (since (4+16)%64 = 20).
 *    - Reading rel(4, 8, 10) must return the same stored value 0x0E.
 *    - Reading rel(20, 8, 10) now maps to physical 36 (slot 2, invalid) and returns air (0x00).
 *    - Reading rel(52, 8, 10) maps to physical 4 (slot 0, invalid) and returns air (0x00).
 * 7. Change WIN_ORIGIN in both x and z by 16 (WIN_ORIGIN = 0x1010):
 *    - Physical block (20, 8, 10) reached at adjusted relative indices x_rel=4, z_rel=58.
 *    - Reading rel(4, 8, 58) returns 0x0E.
 * 8. Restore WIN_ORIGIN to 0:
 *    - Verify register reads back 0.
 *    - Reading rel(20, 8, 10) again returns 0x0E.
 *    - Reading rel(4, 8, 10) again returns air (0x00).
 *
 * Error codes:
 *   FAIL 301: Initial read at rel(20, 8, 10) did not return 0x0E
 *   FAIL 302: Initial read at rel(36, 8, 10) (slot 2, invalid) did not return air
 *   FAIL 303: Initial read at rel(4, 8, 10) (slot 0, invalid) did not return air
 *   FAIL 304: After WIN_ORIGIN.x=16, adjusted read at rel(4, 8, 10) did not return 0x0E
 *   FAIL 305: After WIN_ORIGIN.x=16, read at rel(20, 8, 10) (maps to slot 2, invalid) did not return air
 *   FAIL 306: After WIN_ORIGIN.x=16, read at rel(52, 8, 10) (maps to slot 0, invalid) did not return air
 *   FAIL 307: After WIN_ORIGIN=(16, 16), read at rel(4, 8, 58) did not return 0x0E
 *   FAIL 308: WIN_ORIGIN register did not read back 0 after restore
 *   FAIL 309: After restoring origin, read at rel(20, 8, 10) did not return 0x0E
 *   FAIL 310: After restoring origin, read at rel(4, 8, 10) did not return air
 */

.include "sw/tests/test.inc"

    .section .text
    .globl main
main:
    li      s0, 0x50000000          # MMIO base
    li      s1, 0x20000000          # World window base

    # 1. Wait for DDR3 calibration
.Lwait_cal:
    lw      t0, 0x2C(s0)
    andi    t0, t0, 1
    beqz    t0, .Lwait_cal

    # 2. Reset WIN_ORIGIN to 0
    sw      zero, 0x3C(s0)

    # 3. Set SLOT_VALID: only slot 1 is valid (SLOT_VALID = 0x0002)
    #    Slot 0 (bits 3:0 of x_phys, sz=0) is invalid
    #    Slot 1 (bits 5:4 of x_phys = 1, sz=0) is valid
    #    Slot 2 (bits 5:4 of x_phys = 2, sz=0) is invalid
    li      t0, 0x0002
    sw      t0, 0x38(s0)

    # Precompute addresses for relative coordinates with y=8, z=10:
    #   offset = (y << 12) | (z << 6) | x = (8 << 12) | (10 << 6) | x = 0x8280 | x
    #
    # rel(x=20, y=8, z=10): offset = 0x8294, addr = 0x20008294
    li      s2, 0x20008294

    # rel(x=36, y=8, z=10): offset = 0x82A4, addr = 0x200082A4
    li      s3, 0x200082A4

    # rel(x=4,  y=8, z=10): offset = 0x8284, addr = 0x20008284
    li      s4, 0x20008284

    # rel(x=52, y=8, z=10): offset = 0x82B4, addr = 0x200082B4
    li      s5, 0x200082B4

    # rel(x=4, y=8, z=58): offset = (8 << 12) | (58 << 6) | 4 = 0x8000 | 0x0E80 | 4 = 0x8E84
    li      s6, 0x20008E84

    # 4. Write distinctive block type 0x0E into physical block (20, 8, 10)
    #    At WIN_ORIGIN=0, rel(20, 8, 10) directly addresses physical(20, 8, 10).
    li      t1, 0x0E
    sb      t1, 0(s2)

    # 5. Verify reads at WIN_ORIGIN=0
    # rel(20, 8, 10) -> physical(20, 8, 10) in slot 1 (valid) -> 0x0E
    lbu     t0, 0(s2)
    EXPECT_EQ t0, 0x0E, 301

    # rel(36, 8, 10) -> physical(36, 8, 10) in slot 2 (invalid) -> air (0x00)
    lbu     t0, 0(s3)
    EXPECT_EQ t0, 0x00, 302

    # rel(4, 8, 10) -> physical(4, 8, 10) in slot 0 (invalid) -> air (0x00)
    lbu     t0, 0(s4)
    EXPECT_EQ t0, 0x00, 303

    # 6. Change WIN_ORIGIN.x by 16: WIN_ORIGIN = 0x0010
    li      t0, 16
    sw      t0, 0x3C(s0)

    # Adjusted relative index for physical(20, 8, 10):
    #   (x_rel + 16) mod 64 = 20 => x_rel = 4.
    # Reading rel(4, 8, 10) addresses physical(20, 8, 10) in slot 1 -> returns 0x0E
    lbu     t0, 0(s4)
    EXPECT_EQ t0, 0x0E, 304

    # Under WIN_ORIGIN.x=16:
    # rel(20, 8, 10) -> physical x = (20 + 16) mod 64 = 36 (slot 2, invalid) -> air
    lbu     t0, 0(s2)
    EXPECT_EQ t0, 0x00, 305

    # rel(52, 8, 10) -> physical x = (52 + 16) mod 64 = 4 (slot 0, invalid) -> air
    lbu     t0, 0(s5)
    EXPECT_EQ t0, 0x00, 306

    # 7. Change WIN_ORIGIN in both x and z by 16: WIN_ORIGIN = (16 << 8) | 16 = 0x1010
    li      t0, 0x1010
    sw      t0, 0x3C(s0)

    # Adjusted relative indices for physical(20, 8, 10):
    #   (x_rel + 16) mod 64 = 20 => x_rel = 4
    #   (z_rel + 16) mod 64 = 10 => z_rel = 58  (since (58 + 16) mod 64 = 74 mod 64 = 10)
    # Reading rel(4, 8, 58) addresses physical(20, 8, 10) in slot 1 -> returns 0x0E
    lbu     t0, 0(s6)
    EXPECT_EQ t0, 0x0E, 307

    # 8. Restore WIN_ORIGIN to 0
    sw      zero, 0x3C(s0)

    # Verify WIN_ORIGIN register is 0
    lw      t0, 0x3C(s0)
    EXPECT_EQ t0, 0, 308

    # Verify address mappings after restoring origin
    # rel(20, 8, 10) again maps to physical(20, 8, 10) -> returns 0x0E
    lbu     t0, 0(s2)
    EXPECT_EQ t0, 0x0E, 309

    # rel(4, 8, 10) again maps to physical(4, 8, 10) -> returns air (0x00)
    lbu     t0, 0(s4)
    EXPECT_EQ t0, 0x00, 310

    PASS
