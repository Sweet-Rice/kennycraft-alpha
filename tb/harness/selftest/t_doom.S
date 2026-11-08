/*
 * tb/harness/selftest/t_doom.S: doom-selftest (mk/doom.mk), the HAS_DDR_MEM = 1
 * memory system on the doom kcvl (out/vl-doom):
 *   1xx  scratch (0x7000_0000) byte / half / word stores and loads
 *   2xx  D-cache (0x8000_0000) byte / half / word, then a conflicting line
 *        (same index, 32 KB away) evicts the dirty line and the re-read
 *        returns it from DDR3
 *   3xx  data preloaded by +ddr_manifest (pattern.bin at DDR3 0x0020_0000)
 *   4xx  a function copied into DDR3 0x0010_0000 through the D-cache, the
 *        D-cache cleaned through the flush area, then called at PC
 *        0x0010_0000 (I-cache fetch, a backward branch in DDR3 code)
 */
.include "sw/tests/test.inc"

    .section .text
    .globl main
main:
    /* ---- 1: scratch ---- */
    li      s0, 0x70000000
    li      t0, 0x12345678
    sw      t0, 0(s0)
    lw      t1, 0(s0)
    EXPECT_REG t1, t0, 101
    li      t0, 0xAB
    sb      t0, 1(s0)
    lw      t1, 0(s0)
    EXPECT_EQ t1, 0x1234AB78, 102
    li      t0, 0x8001
    sh      t0, 2(s0)
    lw      t1, 0(s0)
    EXPECT_EQ t1, 0x8001AB78, 103
    lh      t1, 2(s0)
    EXPECT_EQ t1, 0xFFFF8001, 104
    lhu     t1, 2(s0)
    EXPECT_EQ t1, 0x8001, 105
    lb      t1, 1(s0)
    EXPECT_EQ t1, 0xFFFFFFAB, 106
    lbu     t1, 1(s0)
    EXPECT_EQ t1, 0xAB, 107
    li      s1, 0x7000FFFC              /* last word */
    li      t0, 0xCAFEF00D
    sw      t0, 0(s1)
    lw      t1, 0(s0)
    EXPECT_EQ t1, 0x8001AB78, 108
    lw      t1, 0(s1)
    EXPECT_EQ t1, 0xCAFEF00D, 109

    /* ---- 2: D-cache ---- */
    li      s0, 0x80001000
    li      s1, 0x80009000              /* same index, other tag */
    li      t0, 0x11223344
    sw      t0, 0(s0)
    li      t0, 0x55667788
    sw      t0, 12(s0)
    lw      t1, 0(s0)
    EXPECT_EQ t1, 0x11223344, 201
    li      t0, 0xEE
    sb      t0, 2(s0)
    li      t0, 0x9ABC
    sh      t0, 14(s0)
    lw      t1, 0(s0)
    EXPECT_EQ t1, 0x11EE3344, 202
    lh      t1, 14(s0)
    EXPECT_EQ t1, 0xFFFF9ABC, 203
    lbu     t1, 2(s0)
    EXPECT_EQ t1, 0xEE, 204
    /* conflicting line: evicts (writes back) s0's line */
    li      t0, 0x0BADF00D
    sw      t0, 0(s1)
    lw      t1, 0(s1)
    EXPECT_EQ t1, 0x0BADF00D, 205
    lw      t1, 0(s0)                   /* evicts s1's line, refills s0's */
    EXPECT_EQ t1, 0x11EE3344, 206
    lw      t1, 12(s0)
    EXPECT_EQ t1, 0x9ABC7788, 207
    lw      t1, 0(s1)
    EXPECT_EQ t1, 0x0BADF00D, 208
    lw      t1, 4(s1)                   /* never written: DDR3 reads 0 */
    EXPECT_EQ t1, 0, 209

    /* ---- 3: preloaded data (pattern.bin: word k = 0xD0000000 + k) ---- */
    li      s0, 0x80200000
    li      t2, 0xD0000000
    li      t3, 0
    li      t4, 1024                    /* 4 KB */
1:  lw      t1, 0(s0)
    add     t5, t2, t3
    beq     t1, t5, 2f
    FAIL    301
2:  addi    s0, s0, 4
    addi    t3, t3, 1
    bltu    t3, t4, 1b
    li      s0, 0x80200000
    lbu     t1, 7(s0)                   /* word 1 = 0xD0000001, byte 3 */
    EXPECT_EQ t1, 0xD0, 302
    lhu     t1, 4(s0)
    EXPECT_EQ t1, 0x0001, 303

    /* ---- 4: code in DDR3 ---- */
    la      t0, far_code
    la      t1, far_code_end
    li      s0, 0x80100000
3:  lw      t2, 0(t0)
    sw      t2, 0(s0)
    addi    t0, t0, 4
    addi    s0, s0, 4
    bltu    t0, t1, 3b
    /* clean: one load per line of the 32 KB flush area */
    li      s0, 0x8F000000
    li      t1, 0x8F008000
4:  lw      t2, 0(s0)
    addi    s0, s0, 16
    bltu    s0, t1, 4b
    li      a0, 5
    li      t0, 0x00100000
    jalr    ra, 0(t0)
    EXPECT_EQ a0, 0x1000F, 401          /* 0x10000 + 5 + 4 + 3 + 2 + 1 */
    li      a0, 2
    li      t0, 0x00100000
    jalr    ra, 0(t0)                   /* second call: I-cache hits */
    EXPECT_EQ a0, 0x10003, 402
    PASS

/* Copied to DDR3 0x0010_0000: returns 0x10000 + a0 + (a0 - 1) + ... + 1.
   Position independent (one backward branch). */
    .section .rodata
    .balign 16
far_code:
    li      t0, 0
5:  add     t0, t0, a0
    addi    a0, a0, -1
    bnez    a0, 5b
    li      a0, 0x10000
    add     a0, a0, t0
    ret
far_code_end:
