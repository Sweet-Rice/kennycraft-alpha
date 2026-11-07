/*
 * sw/tests/t_slot_valid.S
 *
 * Self-checking test for SLOT_VALID semantics:
 * 1. Wait for DDR_STATUS calibration (offset 0x2C bit 0).
 * 2. Ensure WIN_ORIGIN is 0.
 * 3. Verify CPU loads:
 *    - Valid slot reads return the stored block values.
 *    - Invalidation (clearing valid bit) forces CPU loads to return air (0x00).
 *    - Writes to an invalid slot persist in underlying memory but read as air.
 *    - Restoring the valid bit reveals the stored data.
 * 4. At KC_STAGE >= 2:
 *    - Test that VTRACE ray stepping into an invalid slot treats it as air
 *      and does not register a hit (ray passes through).
 *    - Restoring the slot valid bit causes the exact same ray step to hit
 *      the solid block and return correct hit metadata.
 *
 * Error codes:
 *   FAIL 201: Slot 0 read mismatch when valid
 *   FAIL 202: Slot 1 read mismatch when valid
 *   FAIL 203: Slot 0 read mismatch when slot 1 is invalidated
 *   FAIL 204: Slot 1 load did not return air (0) when invalid
 *   FAIL 205: Slot 0 load did not return air (0) when both invalid
 *   FAIL 206: Slot 1 load did not return air (0) when both invalid
 *   FAIL 207: Slot 1 load did not return air (0) after write while invalid
 *   FAIL 208: Slot 0 did not reveal stored value after restoring validity
 *   FAIL 209: Slot 1 did not reveal stored value after restoring validity
 *   FAIL 210: Stage 2: VTRACE did not pass invalid slot (hit was not 0)
 *   FAIL 211: Stage 2: VTRACE step count wrong on invalid slot miss
 *   FAIL 212: Stage 2: VTRACE did not hit solid block when valid
 *   FAIL 213: Stage 2: VTRACE block type mismatch
 *   FAIL 214: Stage 2: VTRACE face axis mismatch
 *   FAIL 215: Stage 2: VTRACE face sign mismatch
 *   FAIL 216: Stage 2: VTRACE step count mismatch
 *   FAIL 217: Stage 2: VGET field 0 (hit cell) mismatch
 *   FAIL 218: Stage 2: VGET field 1 (t at hit) mismatch
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

    # Slot 0 block: (x=5, y=10, z=5), sx=0, sz=0 -> slot 0
    # addr0 = 0x20000000 | (10 << 12) | (5 << 6) | 5 = 0x2000A145
    li      s2, 0x2000A145

    # Slot 1 block: (x=20, y=10, z=5), sx=1, sz=0 -> slot 1
    # addr1 = 0x20000000 | (10 << 12) | (5 << 6) | 20 = 0x2000A154
    li      s3, 0x2000A154

    # 3. Enable slots 0 and 1 (SLOT_VALID = 0x0003)
    li      t0, 0x0003
    sw      t0, 0x38(s0)

    # Store distinct non-zero values into each slot
    li      t1, 0x0A                # Type 10
    sb      t1, 0(s2)
    li      t1, 0x0B                # Type 11
    sb      t1, 0(s3)

    # Verify reads when valid
    lbu     t0, 0(s2)
    EXPECT_EQ t0, 0x0A, 201

    lbu     t0, 0(s3)
    EXPECT_EQ t0, 0x0B, 202

    # Invalidate slot 1 (SLOT_VALID = 0x0001: slot 0 valid, slot 1 invalid)
    li      t0, 0x0001
    sw      t0, 0x38(s0)

    # Slot 0 remains valid and returns stored value
    lbu     t0, 0(s2)
    EXPECT_EQ t0, 0x0A, 203

    # Slot 1 is invalid: load MUST return air (0x00)
    lbu     t0, 0(s3)
    EXPECT_EQ t0, 0x00, 204

    # Invalidate both slots (SLOT_VALID = 0x0000)
    sw      zero, 0x38(s0)

    # Both loads return air
    lbu     t0, 0(s2)
    EXPECT_EQ t0, 0x00, 205

    lbu     t0, 0(s3)
    EXPECT_EQ t0, 0x00, 206

    # Write a new value into slot 1 while invalid
    li      t1, 0x07
    sb      t1, 0(s3)

    # Reading slot 1 while still invalid must still return air
    lbu     t0, 0(s3)
    EXPECT_EQ t0, 0x00, 207

    # Restore validity for both slots (SLOT_VALID = 0x0003)
    li      t0, 0x0003
    sw      t0, 0x38(s0)

    # Slot 0 reveals original stored value 0x0A
    lbu     t0, 0(s2)
    EXPECT_EQ t0, 0x0A, 208

    # Slot 1 reveals updated stored value 0x07
    lbu     t0, 0(s3)
    EXPECT_EQ t0, 0x07, 209

#if defined(KC_STAGE) && (KC_STAGE >= 2)
    # 4. Stage 2 VTRACE coverage: verify rays pass through invalid slots.
    # Target solid block in Slot 1 at (x=16, y=5, z=5):
    # addr = 0x20000000 | (5 << 12) | (5 << 6) | 16 = 0x20005150
    li      s4, 0x20005150
    li      t1, 5                   # Solid block type 5
    sb      t1, 0(s4)

    # Ray configuration:
    # Start cell at (x=15, y=5, z=5) in slot 0 boundary.
    # Packed start cell:
    #   bits 5:0  = x = 15 = 0x0F
    #   bits 10:6 = y = 5  = 0x0140
    #   bits 16:11 = z = 5 = 0x2800
    #   packed = 0x294F
    #
    # Single-step geometry stepping +x:
    #   tMax.x = 1.0 (0x00010000), tMax.y/z large (0x7FFF0000)
    #   tDelta.x = 1.0 (0x00010000), tDelta.y/z large (0x7FFF0000)
    #   signs = 0 (+x, +y, +z)

    # Part A: Slot 1 INVALID (SLOT_VALID = 0x0001)
    li      t0, 0x0001
    sw      t0, 0x38(s0)

    # Load ray state into lane 0 via VSET
    li      t0, 0x294F
    .insn r 0x2B, 0, 0, x0, t0, x0     # VSET 0, start cell (15, 5, 5)
    li      t0, 0x00010000
    .insn r 0x2B, 0, 1, x0, t0, x0     # VSET 1, tMax.x = 1.0
    lui     t1, 0x7FFF
    .insn r 0x2B, 0, 2, x0, t1, x0     # VSET 2, tMax.y = large
    .insn r 0x2B, 0, 3, x0, t1, x0     # VSET 3, tMax.z = large
    .insn r 0x2B, 0, 4, x0, t0, x0     # VSET 4, tDelta.x = 1.0
    .insn r 0x2B, 0, 5, x0, t1, x0     # VSET 5, tDelta.y = large
    .insn r 0x2B, 0, 6, x0, t1, x0     # VSET 6, tDelta.z = large
    .insn r 0x2B, 0, 7, x0, zero, x0   # VSET 7, signs = 0

    # VTRACE with max_steps = 1
    li      a1, 1
    .insn r 0x2B, 1, 0, a0, a1, x0     # VTRACE a0, a1

    # In invalid slot, read returns air; ray must not hit
    andi    t0, a0, 1
    EXPECT_EQ t0, 0, 210

    # Step count must be 1
    srli    t0, a0, 8
    andi    t0, t0, 0xFF
    EXPECT_EQ t0, 1, 211

    # Part B: Slot 1 VALID (SLOT_VALID = 0x0003)
    li      t0, 0x0003
    sw      t0, 0x38(s0)

    # Re-issue exact same ray
    li      t0, 0x294F
    .insn r 0x2B, 0, 0, x0, t0, x0     # VSET 0
    li      t0, 0x00010000
    .insn r 0x2B, 0, 1, x0, t0, x0     # VSET 1
    lui     t1, 0x7FFF
    .insn r 0x2B, 0, 2, x0, t1, x0     # VSET 2
    .insn r 0x2B, 0, 3, x0, t1, x0     # VSET 3
    .insn r 0x2B, 0, 4, x0, t0, x0     # VSET 4
    .insn r 0x2B, 0, 5, x0, t1, x0     # VSET 5
    .insn r 0x2B, 0, 6, x0, t1, x0     # VSET 6
    .insn r 0x2B, 0, 7, x0, zero, x0   # VSET 7

    li      a1, 1
    .insn r 0x2B, 1, 0, a0, a1, x0     # VTRACE a0, a1

    # In valid slot, ray must hit solid block
    andi    t0, a0, 1
    EXPECT_EQ t0, 1, 212

    # Block type must be 5 (bits 7:4)
    srli    t0, a0, 4
    andi    t0, t0, 0x0F
    EXPECT_EQ t0, 5, 213

    # Face axis must be 0 for x-axis (bits 2:1)
    srli    t0, a0, 1
    andi    t0, t0, 3
    EXPECT_EQ t0, 0, 214

    # Face sign must be 0 for positive step (bit 3)
    srli    t0, a0, 3
    andi    t0, t0, 1
    EXPECT_EQ t0, 0, 215

    # Steps taken must be 1 (bits 15:8)
    srli    t0, a0, 8
    andi    t0, t0, 0xFF
    EXPECT_EQ t0, 1, 216

    # VGET field 0: hit cell packed (16, 5, 5) -> 0x2950
    .insn r 0x2B, 2, 0, a2, x0, x0     # VGET a2, field 0
    EXPECT_EQ a2, 0x2950, 217

    # VGET field 1: t at hit (1.0 in Q16.16 -> 0x00010000)
    .insn r 0x2B, 2, 1, a3, x0, x0     # VGET a3, field 1
    EXPECT_EQ a3, 0x00010000, 218
#endif

    PASS
