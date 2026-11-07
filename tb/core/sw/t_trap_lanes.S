/* t_trap_lanes: illegal cases raised by lanes other than lane 0 (Tai_2
   section 1; P4 review gaps). The testbench writes the case number to
   TB_SELECT and resets the core once per case; case k sits at 0x100 +
   0x40*k as MASKSET, then the instruction under test at +4. a2 (preset
   0x55) is the rd of every load, ra (preset 0x77) the link of the JAL.
   0  control: M = 0xDF, LW whose address is misaligned only in inactive
      lane 5: no error, the seven active lanes load.
   1  full mask, LW misaligned in lane 5 only: ERR.ILLEGAL before any lane
      reaches the bus.
   2  M = 0xFE, LH misaligned in lane 3 only: the same.
   3  full mask, JAL ra, +6: ERR.ILLEGAL at the JAL, no lane links (D16). */
#include "kc_test.h"
#include "kc_lanes.h"

#define W 0x10004000            /* watched by the testbench */

.macro NOT_REACHED
    li    t2, 1
    sw    t2, (TB_MARK - DMEM_BASE)(t0)
99: j     99b
.endm

    .section .text.start
    .globl _start
_start:
    MASKALL
    LANEID(s0)
    li    a2, 0x55
    li    ra, 0x77
    slli  s1, s0, 2
    li    t1, W
    add   s3, t1, s1            /* W + 4 * lane */
    addi  t3, s0, -5
    seqz  t3, t3
    slli  t3, t3, 1
    add   s3, s3, t3            /* + 2 in lane 5 */
    addi  s4, t1, 0x20
    add   s4, s4, s1
    addi  t3, s0, -3
    seqz  t3, t3
    add   s4, s4, t3            /* W + 0x20 + 4 * lane, + 1 in lane 3 */
    li    s5, 0xDF
    li    s6, 0xFF
    li    s7, 0xFE
    li    t0, DMEM_BASE
    lw    t1, (TB_SELECT - DMEM_BASE)(t0)
    slli  t1, t1, 6
    addi  t1, t1, 0x100
    jr    t1

    .org 0x100                  /* 0: control */
    MASKSET(s5)
    lw    a2, 0(s3)
    li    t6, 1
    MASKSET(t6)
    li    t6, 1
    sw    t6, (TB_DONE - DMEM_BASE)(t0)
1:  j     1b
    .org 0x140                  /* 1: LW misaligned in lane 5 */
    MASKSET(s6)
    lw    a2, 0(s3)
    NOT_REACHED
    .org 0x180                  /* 2: LH misaligned in lane 3, M = 0xFE */
    MASKSET(s7)
    lh    a2, 0(s4)
    NOT_REACHED
    .org 0x1c0                  /* 3: JAL ra, +6 under the full mask */
    MASKSET(s6)
    .word 0x006000EF
    NOT_REACHED
