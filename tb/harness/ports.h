#pragma once
// Board pins shared by bench_chip and rtl/top.sv (P3): clk, ck_rst,
// uart_rxd_out, uart_txd_in and led (error LED). The MMIO LEDS register is
// read from kc_soc, since a top need not route it to pins.
#define KC_CLK(d) ((d).clk)
#define KC_RESET(d) ((d).ck_rst)
#define KC_RESET_ACTIVE 0
#define KC_UART_RX(d) ((d).uart_txd_in)
#define KC_UART_TX(d) ((d).uart_rxd_out)
// Bits 7:0 MMIO LEDS, bit 8 the error LED pin.
#define KC_LEDS(d) (unsigned((d).rootp->KC_TOP_DOT(u_soc__DOT__leds)) | (unsigned((d).led) << 8))
