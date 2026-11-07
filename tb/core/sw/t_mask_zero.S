/* t_mask_zero: the mask loop and M = 0 (Tai_2 section 2, Mask loops; Stage
   1 rung 5). Lane l walks l + 1 iterations of
       saved = MASKGET; while (BALLOT(n)) { iter++; n--; LMASK(n); } MASKSET(saved)
   When the last lane drops out M = 0, BALLOT still writes 0 into every
   lane, the loop branch reads lane 0 and exits. Then, with M = 0: a SW, an
   LW and a misaligned LW make no bus access and no error, a UART_TX store
   sends nothing, JAL jumps but writes no link. MASKSET(saved) from lane 0
   restores the mask. Results stay in registers and in dmem. */
#include "kc_test.h"
#include "kc_lanes.h"

#define W 0x10002000            /* watched by the testbench */

    .section .text.start
    .globl _start
_start:
    MASKALL
    LANEID(a0)
    addi  a1, a0, 1             /* n = lane + 1 */
    li    a2, 0                 /* iterations */
    li    a3, 0x33
    li    a4, 0x44
    li    ra, 0x77
    li    s4, W
    li    s5, W + 2
    li    s6, MMIO_BASE + MMIO_UART_TX
    li    s7, 0x5A
    MASKGET(s0)                 /* saved */

loop:
    BALLOT(t0, a1)
    beqz  t0, exit
    addi  a2, a2, 1
    addi  a1, a1, -1
    LMASK(a1)
    j     loop

exit:
    MASKGET(s1)                 /* 0 everywhere */
    sw    s7, 0(s4)             /* no access */
    lw    a3, 0(s4)             /* no access, a3 unchanged */
    lw    a4, 0(s5)             /* misaligned, no access, no error */
    sw    s7, 0(s6)             /* no UART byte */
    jal   ra, 1f                /* jumps, no link */
    j     .                     /* skipped */
1:  MASKSET(s0)                 /* lane 0's saved mask */
    MASKGET(s2)

    li    t6, 1
    MASKSET(t6)
    li    t6, 1
    li    t5, TB_DONE
    sw    t6, 0(t5)
2:  j     2b
