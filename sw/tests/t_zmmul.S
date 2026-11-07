/*
 * t_zmmul.S: Zmmul extension self-checking unit tests.
 *
 * Verifies standard RV32 Zmmul instructions:
 *   MUL    - rd = (rs1 * rs2)[31:0]
 *   MULH   - rd = (signed rs1 * signed rs2)[63:32]
 *   MULHSU - rd = (signed rs1 * unsigned rs2)[63:32]
 *   MULHU  - rd = (unsigned rs1 * unsigned rs2)[63:32]
 * Tests zero cases, identity, sign interactions, int32 min/max extremes,
 * asymmetric MULHSU behaviors, bit patterns, and register aliasing.
 */

    .include "sw/tests/test.inc"

    .globl main
    .section .text
main:
    SCALAR

    # Test 1: zero_zero (0x00000000 * 0x00000000)
    li a1, 0x00000000
    li a2, 0x00000000
    mul a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 10
    mulh a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 11
    mulhsu a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 12
    mulhu a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 13

    # Test 2: zero_pos (0x00000000 * 0x00003039)
    li a1, 0x00000000
    li a2, 0x00003039
    mul a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 20
    mulh a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 21
    mulhsu a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 22
    mulhu a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 23

    # Test 3: pos_zero (0x00003039 * 0x00000000)
    li a1, 0x00003039
    li a2, 0x00000000
    mul a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 30
    mulh a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 31
    mulhsu a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 32
    mulhu a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 33

    # Test 4: zero_neg (0x00000000 * 0xFFFFFFFF)
    li a1, 0x00000000
    li a2, 0xFFFFFFFF
    mul a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 40
    mulh a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 41
    mulhsu a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 42
    mulhu a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 43

    # Test 5: neg_zero (0xFFFFFFFF * 0x00000000)
    li a1, 0xFFFFFFFF
    li a2, 0x00000000
    mul a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 50
    mulh a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 51
    mulhsu a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 52
    mulhu a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 53

    # Test 6: one_one (0x00000001 * 0x00000001)
    li a1, 0x00000001
    li a2, 0x00000001
    mul a0, a1, a2
    EXPECT_EQ a0, 0x00000001, 60
    mulh a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 61
    mulhsu a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 62
    mulhu a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 63

    # Test 7: one_negone (0x00000001 * 0xFFFFFFFF)
    li a1, 0x00000001
    li a2, 0xFFFFFFFF
    mul a0, a1, a2
    EXPECT_EQ a0, 0xFFFFFFFF, 70
    mulh a0, a1, a2
    EXPECT_EQ a0, 0xFFFFFFFF, 71
    mulhsu a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 72
    mulhu a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 73

    # Test 8: negone_one (0xFFFFFFFF * 0x00000001)
    li a1, 0xFFFFFFFF
    li a2, 0x00000001
    mul a0, a1, a2
    EXPECT_EQ a0, 0xFFFFFFFF, 80
    mulh a0, a1, a2
    EXPECT_EQ a0, 0xFFFFFFFF, 81
    mulhsu a0, a1, a2
    EXPECT_EQ a0, 0xFFFFFFFF, 82
    mulhu a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 83

    # Test 9: negone_negone (0xFFFFFFFF * 0xFFFFFFFF)
    li a1, 0xFFFFFFFF
    li a2, 0xFFFFFFFF
    mul a0, a1, a2
    EXPECT_EQ a0, 0x00000001, 90
    mulh a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 91
    mulhsu a0, a1, a2
    EXPECT_EQ a0, 0xFFFFFFFF, 92
    mulhu a0, a1, a2
    EXPECT_EQ a0, 0xFFFFFFFE, 93

    # Test 10: intmin_intmin (0x80000000 * 0x80000000)
    li a1, 0x80000000
    li a2, 0x80000000
    mul a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 100
    mulh a0, a1, a2
    EXPECT_EQ a0, 0x40000000, 101
    mulhsu a0, a1, a2
    EXPECT_EQ a0, 0xC0000000, 102
    mulhu a0, a1, a2
    EXPECT_EQ a0, 0x40000000, 103

    # Test 11: intmin_negone (0x80000000 * 0xFFFFFFFF)
    li a1, 0x80000000
    li a2, 0xFFFFFFFF
    mul a0, a1, a2
    EXPECT_EQ a0, 0x80000000, 110
    mulh a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 111
    mulhsu a0, a1, a2
    EXPECT_EQ a0, 0x80000000, 112
    mulhu a0, a1, a2
    EXPECT_EQ a0, 0x7FFFFFFF, 113

    # Test 12: negone_intmin (0xFFFFFFFF * 0x80000000)
    li a1, 0xFFFFFFFF
    li a2, 0x80000000
    mul a0, a1, a2
    EXPECT_EQ a0, 0x80000000, 120
    mulh a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 121
    mulhsu a0, a1, a2
    EXPECT_EQ a0, 0xFFFFFFFF, 122
    mulhu a0, a1, a2
    EXPECT_EQ a0, 0x7FFFFFFF, 123

    # Test 13: intmin_two (0x80000000 * 0x00000002)
    li a1, 0x80000000
    li a2, 0x00000002
    mul a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 130
    mulh a0, a1, a2
    EXPECT_EQ a0, 0xFFFFFFFF, 131
    mulhsu a0, a1, a2
    EXPECT_EQ a0, 0xFFFFFFFF, 132
    mulhu a0, a1, a2
    EXPECT_EQ a0, 0x00000001, 133

    # Test 14: intmax_intmax (0x7FFFFFFF * 0x7FFFFFFF)
    li a1, 0x7FFFFFFF
    li a2, 0x7FFFFFFF
    mul a0, a1, a2
    EXPECT_EQ a0, 0x00000001, 140
    mulh a0, a1, a2
    EXPECT_EQ a0, 0x3FFFFFFF, 141
    mulhsu a0, a1, a2
    EXPECT_EQ a0, 0x3FFFFFFF, 142
    mulhu a0, a1, a2
    EXPECT_EQ a0, 0x3FFFFFFF, 143

    # Test 15: intmax_intmin (0x7FFFFFFF * 0x80000000)
    li a1, 0x7FFFFFFF
    li a2, 0x80000000
    mul a0, a1, a2
    EXPECT_EQ a0, 0x80000000, 150
    mulh a0, a1, a2
    EXPECT_EQ a0, 0xC0000000, 151
    mulhsu a0, a1, a2
    EXPECT_EQ a0, 0x3FFFFFFF, 152
    mulhu a0, a1, a2
    EXPECT_EQ a0, 0x3FFFFFFF, 153

    # Test 16: intmin_intmax (0x80000000 * 0x7FFFFFFF)
    li a1, 0x80000000
    li a2, 0x7FFFFFFF
    mul a0, a1, a2
    EXPECT_EQ a0, 0x80000000, 160
    mulh a0, a1, a2
    EXPECT_EQ a0, 0xC0000000, 161
    mulhsu a0, a1, a2
    EXPECT_EQ a0, 0xC0000000, 162
    mulhu a0, a1, a2
    EXPECT_EQ a0, 0x3FFFFFFF, 163

    # Test 17: mixed1 (0x12345678 * 0x9ABCDEF0)
    li a1, 0x12345678
    li a2, 0x9ABCDEF0
    mul a0, a1, a2
    EXPECT_EQ a0, 0x242D2080, 170
    mulh a0, a1, a2
    EXPECT_EQ a0, 0xF8CC93D6, 171
    mulhsu a0, a1, a2
    EXPECT_EQ a0, 0x0B00EA4E, 172
    mulhu a0, a1, a2
    EXPECT_EQ a0, 0x0B00EA4E, 173

    # Test 18: mixed2 (0x9ABCDEF0 * 0x12345678)
    li a1, 0x9ABCDEF0
    li a2, 0x12345678
    mul a0, a1, a2
    EXPECT_EQ a0, 0x242D2080, 180
    mulh a0, a1, a2
    EXPECT_EQ a0, 0xF8CC93D6, 181
    mulhsu a0, a1, a2
    EXPECT_EQ a0, 0xF8CC93D6, 182
    mulhu a0, a1, a2
    EXPECT_EQ a0, 0x0B00EA4E, 183

    # Test 19: checkerboard (0x5A5A5A5A * 0xA5A5A5A5)
    li a1, 0x5A5A5A5A
    li a2, 0xA5A5A5A5
    mul a0, a1, a2
    EXPECT_EQ a0, 0xB67A3E02, 190
    mulh a0, a1, a2
    EXPECT_EQ a0, 0xE01C5894, 191
    mulhsu a0, a1, a2
    EXPECT_EQ a0, 0x3A76B2EE, 192
    mulhu a0, a1, a2
    EXPECT_EQ a0, 0x3A76B2EE, 193

    # Test 20: power2 (0x10000000 * 0x10000000)
    li a1, 0x10000000
    li a2, 0x10000000
    mul a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 200
    mulh a0, a1, a2
    EXPECT_EQ a0, 0x01000000, 201
    mulhsu a0, a1, a2
    EXPECT_EQ a0, 0x01000000, 202
    mulhu a0, a1, a2
    EXPECT_EQ a0, 0x01000000, 203

    # Test 21: near_negone (0xFFFFFFFE * 0xFFFFFFFD)
    li a1, 0xFFFFFFFE
    li a2, 0xFFFFFFFD
    mul a0, a1, a2
    EXPECT_EQ a0, 0x00000006, 210
    mulh a0, a1, a2
    EXPECT_EQ a0, 0x00000000, 211
    mulhsu a0, a1, a2
    EXPECT_EQ a0, 0xFFFFFFFE, 212
    mulhu a0, a1, a2
    EXPECT_EQ a0, 0xFFFFFFFB, 213

    # Test 22: Register aliasing (rd == rs1 == rs2)
    li a0, 7
    mul a0, a0, a0
    EXPECT_EQ a0, 49, 220

    li a0, 0x80000000
    mulh a0, a0, a0
    EXPECT_EQ a0, 0x40000000, 221

    li a0, 0x80000000
    mulhsu a0, a0, a0
    EXPECT_EQ a0, 0xC0000000, 222

    li a0, 0xFFFFFFFF
    mulhu a0, a0, a0
    EXPECT_EQ a0, 0xFFFFFFFE, 223

    # Test 23: Register aliasing (rd == rs1, different rs2)
    li a0, 15
    li a1, 3
    mul a0, a0, a1
    EXPECT_EQ a0, 45, 230

    # Test 24: Register aliasing (rd == rs2, different rs1)
    li a1, 15
    li a0, 3
    mul a0, a1, a0
    EXPECT_EQ a0, 45, 240

    PASS
