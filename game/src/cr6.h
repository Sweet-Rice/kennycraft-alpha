// cr6.h — CR6 UART command link with the laptop (wiki Shared.md, CR6 / D8). Lane 0 only.
// Nothing changes until the laptop sends HELLO: key replays never do, so golden frames and
// UART output in tests stay byte-identical.
#ifndef KC_CR6_H
#define KC_CR6_H
#include <stdint.h>

int32_t cr6_byte(uint8_t b);       // one UART RX byte; 1 if it belongs to a frame (not a key)
void    cr6_end_drain(void);       // after each drain: STATUS (ack/nack, credit) when linked
void    cr6_key(uint8_t code);     // E / Y / N key-down: INTERACT or CONFIRM events
void    cr6_draw_hud(int32_t W);   // balance, quote and contract bars (when linked)

#endif
