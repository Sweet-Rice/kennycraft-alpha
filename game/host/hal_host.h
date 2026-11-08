// hal_host.h — laptop-only hooks into the emulated chip.
#ifndef KC_HAL_HOST_H
#define KC_HAL_HOST_H
#include <stdint.h>
#include <stdio.h>

typedef struct {
    uint64_t world_reads, world_writes, frames, chunk_loads, chunk_stores;
    uint64_t stores_from_valid;              // CHUNK_CMD stores issued while the slot's SLOT_VALID bit was set
} host_stats;
extern host_stats hstats;

void host_init(int realtime_clock);          // 1: CYCLES follows the wall clock; 0: host_advance_cycles
void host_push_key(uint8_t key_byte);
void host_advance_cycles(uint32_t cycles);
void host_uart_out(FILE *f, int quiet);      // UART_TX to f (NULL: stderr); quiet: capture only
void host_tx_clear(void);
extern uint8_t  host_tx[4096];               // UART_TX bytes since host_tx_clear()
extern uint32_t host_tx_n;
const uint8_t  *host_front_buffer(void);     // what VGA shows (after the last swap)
const uint8_t  *host_back_buffer(void);
const uint16_t *host_palette(void);          // RGB444
int  host_fb_mode(void);                     // 1 = 160x120
void host_on_swap(void);                     // implemented by the front-end

const char *host_ddr_fill_name(void);       // KC_DDR_FILL: power-on DDR3 contents (default random)
void host_ddr_copy(uint32_t src_id, uint32_t dst_id);   // DDR3 chunk dst := chunk src
void host_reset(uint32_t cycles0);           // reset button: registers cleared, CYCLES = cycles0, memories kept
uint32_t host_slot_valid(void);              // SLOT_VALID as the hardware holds it
uint8_t  host_bram_phys(uint32_t px, uint32_t y, uint32_t pz);   // raw BRAM, ignores SLOT_VALID

int  png_write_fb(const char *path, const uint8_t *fb, const uint16_t *pal, int w, int h, int scale);

#endif
