#pragma once
#define KC_CLK(d) ((d).clk)
#define KC_RESET(d) ((d).ck_rst)
#define KC_RESET_ACTIVE 0
#define KC_UART_RX(d) ((d).uart_txd_in)
#define KC_UART_TX(d) ((d).uart_rxd_out)
#define KC_LEDS(d) (unsigned((d).led) | (unsigned((d).led_aux) << 1))
