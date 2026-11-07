#include <stdint.h>

#define REG(addr) (*(volatile uint32_t *)(addr))
#define UART_STATUS REG(0x50000014)
#define UART_RX REG(0x50000010)
#define UART_TX REG(0x50000018)
#define FB_SWAP REG(0x50000000)
#define FB_MODE REG(0x50000028)

int main(void) {
    volatile uint32_t *palette = (volatile uint32_t *)0x60000000;
    volatile uint8_t *fb = (volatile uint8_t *)0x40000000;
    int sx = 76, sy = 56;
    uint32_t frame = 0;
    FB_MODE = 1;
    for (unsigned i = 0; i < 256; ++i)
        palette[i] = ((i >> 4) << 8) | ((i & 15) << 4) | 8;
    const char *p = "pattern up\n";
    while (*p) {
        while (UART_STATUS & 2) { }
        UART_TX = (uint8_t)*p++;
    }
    for (;;) {
        while (UART_STATUS & 1) {
            uint32_t key = UART_RX;
            if (key == 0xF7 && sy > 0) --sy;
            if (key == 0xE1 && sx > 0) --sx;
            if (key == 0xF3 && sy < 111) ++sy;
            if (key == 0xE4 && sx < 151) ++sx;
        }
        for (unsigned y = 0; y < 120; ++y)
            for (unsigned x = 0; x < 160; ++x)
                fb[y * 320 + x] = (uint8_t)(x + y + frame);
        for (int y = sy; y < sy + 8; ++y)
            for (int x = sx; x < sx + 8; ++x)
                fb[y * 320 + x] = 0xFF;
        FB_SWAP = 1;
        while (FB_SWAP) { }
        ++frame;
    }
}
