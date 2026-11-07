/* t_mmio_lanes: MMIO under a multi-lane mask (Tai_2 section 2, MMIO row;
   Stage 1 rung 4). One bus access per active lane, in lane order: a UART_RX
   read under M = 0x03 pops two bytes (lane 0 the first), the next read with
   lane 0 alone pops the third; a LEDS write under M = 0x03 writes twice
   (lane 1's value last); a CYCLES read with every lane active returns
   consecutive counts. The testbench sends "ABC" and then writes TB_SELECT. */
#include "kc_test.h"

#define LANEID(rd)      .insn r 0x0B, 0, 0, rd, x0, x0
#define MASKSET(rs)     .insn r 0x0B, 6, 0, x0, rs, x0
#define MASKALL         .insn r 0x0B, 7, 0, x0, x0, x0

    .section .text.start
    .globl _start
_start:
    MASKALL
    LANEID(s1)
    li    s0, MMIO_BASE
    li    a0, 0x5A              /* preset in every lane */
    li    t2, 3
    li    t3, 1
    addi  t0, s1, 0x10          /* LEDS value 0x10 + lane */
    MASKSET(t3)

    li    t1, TB_SELECT
1:  lw    t4, 0(t1)
    beqz  t4, 1b                /* wait until the testbench has sent ABC */

    MASKSET(t2)
    lw    a0, MMIO_UART_RX(s0)  /* lane 0 'A', lane 1 'B' */
    MASKSET(t3)
    lw    a1, MMIO_UART_RX(s0)  /* 'C' */
    MASKSET(t2)
    sw    t0, MMIO_LEDS(s0)     /* 0x10, then 0x11 */
    MASKALL
    lw    a2, MMIO_CYCLES(s0)   /* lane n: c + n */
    MASKSET(t3)

    li    t1, TB_DONE
    sw    t3, 0(t1)
2:  j     2b
