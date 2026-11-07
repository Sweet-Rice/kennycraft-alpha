/* t_divstack_overflow: divergence stack errors (Tai_2 section 2, Errors;
   Stage 1 rung 7). The testbench writes the case number to TB_SELECT and
   resets the core once per case; case k sits at 0x100 + 0x80*k.
   0  control: eight nested DIFs (true everywhere) and eight DENDIFs, plus a
      DIF that falls through although its label is misaligned; no halt.
   1  nine nested DIFs: the ninth halts with ERR.DIVSTACK (slot + 0x20).
   2  DELSE on an empty stack: ERR.DIVSTACK.
   3  DENDIF on an empty stack: ERR.DIVSTACK.
   4  DIF false everywhere jumping to a label with bit 1 set: ERR.ILLEGAL at
      the DIF, nothing pushed (D16 applied to custom-2, question on #15).
   5  DIF true everywhere, then a DELSE whose else mask is 0 jumping to a
      label with bit 1 set: ERR.ILLEGAL at the DELSE (slot + 4). */
#include "kc_test.h"
#include "kc_lanes.h"

.macro NOT_REACHED
    li    t2, 1
    sw    t2, (TB_MARK - DMEM_BASE)(t0)
99: j     99b
.endm

    .section .text.start
    .globl _start
_start:
    MASKALL
    li    s1, 1                 /* true */
    li    s2, 0                 /* false */
    li    t0, DMEM_BASE
    lw    t1, (TB_SELECT - DMEM_BASE)(t0)
    slli  t1, t1, 7
    addi  t1, t1, 0x100
    jr    t1

    .org 0x100                  /* 0: control */
    .rept 8
    DIF(s1, 1f)
    .endr
    .rept 8
    DENDIF
    .endr
1:  .word 0x0004835B            /* DIF s1, +6: falls through */
    DENDIF
    MASKGET(a0)
    li    t6, 1
    MASKSET(t6)
    li    t6, 1
    sw    t6, (TB_DONE - DMEM_BASE)(t0)
2:  j     2b

    .org 0x180                  /* 1: nine nested DIFs */
    .rept 9
    DIF(s1, 1f)
    .endr
1:  NOT_REACHED

    .org 0x200                  /* 2: DELSE, empty stack */
    DELSE(1f)
1:  NOT_REACHED

    .org 0x280                  /* 3: DENDIF, empty stack */
    DENDIF
    NOT_REACHED

    .org 0x300                  /* 4: DIF s2, +6 (jumps, misaligned) */
    .word 0x0009035B
    NOT_REACHED

    .org 0x380                  /* 5: DIF true, DELSE +6 (jumps, misaligned) */
    DIF(s1, 1f)
1:  .word 0x0000135B
    NOT_REACHED
