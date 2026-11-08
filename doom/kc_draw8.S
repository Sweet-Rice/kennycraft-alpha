# 8-lane column and span inner loops (doom/kc_draw.c calls them from lane 0;
# ISA and masking rules: ref/wiki/Tai_2.md, sections 1 and 2).
#
# Lane 0 stores the arguments to a parameter block in dmem (KC_DMEM_DRAW,
# doom/kc_mem.h), MASKALL wakes lanes 1..7 and every lane loads the block
# (all lanes on one dmem word: one bus access per load). Lanes 1..7 never ran
# Doom code, so they use only registers written here, and no stack.
#
# Lane n draws pixels n, n + 8, n + 16, ...: its texture position starts n
# steps in and moves 8 steps per pixel, exactly the value Doom's scalar loop
# has at that pixel (32-bit wraparound). The full groups of 8 run with every
# lane on; then LMASK keeps the lanes n < count % 8 for the last pixels. The
# loop branches compare values every lane holds alike (uniform). Each pixel
# is stored before the LMASK (D20), and lane 0 always stays on, so MASKSET 1
# (the scalar lane is lane 0) ends the kernel before the return.

    .equ KC_DMEM_DRAW, 0x10005F00         # doom/kc_mem.h

    .macro LANEID rd
    .insn r 0x0B, 0, 0, \rd, x0, x0
    .endm
    .macro LMASK rs
    .insn r 0x0B, 1, 0, x0, \rs, x0
    .endm
    .macro MASKSET rs
    .insn r 0x0B, 6, 0, x0, \rs, x0
    .endm
    .macro MASKALL
    .insn r 0x0B, 7, 0, x0, x0, x0
    .endm

# Common entry: lane 0's a0..a5 to the block, then every lane loads them.
#   a0 texture position (frac), a1 step, a2 source, a3 colormap, a4 dest,
#   a5 pixel count (>= 1). Leaves t0 = lane number.
    .macro ENTER
    li    t6, KC_DMEM_DRAW
    sw    a0, 0(t6)
    sw    a1, 4(t6)
    sw    a2, 8(t6)
    sw    a3, 12(t6)
    sw    a4, 16(t6)
    sw    a5, 20(t6)
    MASKALL
    li    t6, KC_DMEM_DRAW
    lw    a0, 0(t6)
    lw    a1, 4(t6)
    lw    a2, 8(t6)
    lw    a3, 12(t6)
    lw    a4, 16(t6)
    lw    a5, 20(t6)
    LANEID t0
    .endm

    .macro LEAVE
    li    t1, 1
    MASKSET t1
    ret
    .endm

# void kc_col8(fixed_t frac, fixed_t step, const byte *source,
#              const lighttable_t *colormap, byte *dest, int count)
# R_DrawColumn: dest[k * 320] = colormap[source[((frac + k * step) >> 16) & 127]]
    .section .text.kc_col8, "ax"
    .globl kc_col8
    .p2align 2
kc_col8:
    ENTER
    mul   t1, t0, a1
    add   a0, a0, t1            # frac of this lane's first pixel
    li    t3, 320
    mul   t1, t0, t3
    add   a4, a4, t1            # its row
    slli  a1, a1, 3             # 8 steps
    li    t3, 320 * 8           # 8 rows
    srli  t4, a5, 3             # full groups
    beqz  t4, 2f
1:  srli  t1, a0, 16
    andi  t1, t1, 127
    add   t1, t1, a2
    lbu   t1, 0(t1)
    add   t1, t1, a3
    lbu   t1, 0(t1)
    sb    t1, 0(a4)
    add   a0, a0, a1
    add   a4, a4, t3
    addi  t4, t4, -1
    bnez  t4, 1b
2:  andi  t5, a5, 7
    beqz  t5, 3f
    sltu  t1, t0, t5
    LMASK t1
    srli  t1, a0, 16
    andi  t1, t1, 127
    add   t1, t1, a2
    lbu   t1, 0(t1)
    add   t1, t1, a3
    lbu   t1, 0(t1)
    sb    t1, 0(a4)
3:  LEAVE

# void kc_span8(uint32_t position, uint32_t step, const byte *source,
#               const lighttable_t *colormap, byte *dest, int count)
# R_DrawSpan: position packs x (bits 31:16) and y (15:0), 6.10 each;
# dest[k] = colormap[source[(p >> 26) | ((p >> 4) & 0xFC0)]], p = position + k * step
    .section .text.kc_span8, "ax"
    .globl kc_span8
    .p2align 2
kc_span8:
    ENTER
    mul   t1, t0, a1
    add   a0, a0, t1            # position of this lane's first pixel
    add   a4, a4, t0            # its column
    slli  a1, a1, 3             # 8 steps
    li    t3, 0xFC0
    srli  t4, a5, 3             # full groups
    beqz  t4, 2f
1:  srli  t1, a0, 4
    and   t1, t1, t3
    srli  t2, a0, 26
    or    t1, t1, t2
    add   t1, t1, a2
    lbu   t1, 0(t1)
    add   t1, t1, a3
    lbu   t1, 0(t1)
    sb    t1, 0(a4)
    add   a0, a0, a1
    addi  a4, a4, 8
    addi  t4, t4, -1
    bnez  t4, 1b
2:  andi  t5, a5, 7
    beqz  t5, 3f
    sltu  t1, t0, t5
    LMASK t1
    srli  t1, a0, 4
    and   t1, t1, t3
    srli  t2, a0, 26
    or    t1, t1, t2
    add   t1, t1, a2
    lbu   t1, 0(t1)
    add   t1, t1, a3
    lbu   t1, 0(t1)
    sb    t1, 0(a4)
3:  LEAVE
