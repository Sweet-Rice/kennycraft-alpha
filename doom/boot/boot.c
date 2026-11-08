// Doom bootloader (imem BRAM at 0x0, HAS_DDR_MEM=1; doom/README.md).
//
// Waits for DDR3 calibration, then checks the boot header at DDR3 0
// (CPU 0x8000_0000): magic 'KCDM', entry PC, image end, checksum = sum of the
// u32 words at DDR3 0x0010_0000..end except the WAD area 0x0040_0000..0x00FF_FFFF.
// A valid image (preloaded in simulation,
// or still in DDR3 after a reset) boots at once. Otherwise the image comes over
// the UART from scripts/doom_load.py, little-endian frames:
//   'W' addr len data[len] sum   write len bytes at DDR3 addr, sum = byte sum
//   'Z' addr len                 zero len bytes at DDR3 addr
//   'G'                          check the header and boot
// Each frame is answered 'A' (done) or 'N' (bad sum, range or header).
// Before jumping, the D-cache is cleaned through the flush area so the I-cache
// fetches the code just written.
#include <stdint.h>

#define MMIO ((volatile uint32_t *)0x50000000u)
#define MMIO_CYCLES      0x0C
#define MMIO_UART_RX     0x10
#define MMIO_UART_STATUS 0x14
#define MMIO_UART_TX     0x18
#define MMIO_DDR_STATUS  0x2C

#define DDR        ((volatile uint8_t *)0x80000000u)
#define DDR_W      ((volatile uint32_t *)0x80000000u)
#define FLUSH_BASE 0x8F000000u
#define FLUSH_LINES 2048u
#define MAGIC      0x4D44434Bu           // 'KCDM'
#define IMG_START  0x00100000u
#define WAD_START  0x00400000u           // WAD area, left out of the checksum
#define WAD_END    0x01000000u
#define IMG_LIMIT  0x0F000000u           // flush area

static void putc_(char c) {
    while (MMIO[MMIO_UART_STATUS >> 2] & 2u) {}
    MMIO[MMIO_UART_TX >> 2] = (uint8_t)c;
}

static void puts_(const char *s) {
    while (*s) putc_(*s++);
}

static void puthex(uint32_t v) {
    for (int i = 28; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 15u]);
}

static uint8_t getc_(void) {
    while (!(MMIO[MMIO_UART_STATUS >> 2] & 1u)) {}
    return (uint8_t)MMIO[MMIO_UART_RX >> 2];
}

static uint32_t get32(void) {
    uint32_t v = getc_();
    v |= (uint32_t)getc_() << 8;
    v |= (uint32_t)getc_() << 16;
    v |= (uint32_t)getc_() << 24;
    return v;
}

// Entry PC, or 0 if the header or checksum is bad.
static uint32_t check_image(void) {
    uint32_t magic = DDR_W[0], entry = DDR_W[1], end = DDR_W[2], sum = DDR_W[3];
    if (magic != MAGIC) { puts_("kcboot: no image header\n"); return 0; }
    if (end <= IMG_START || end > IMG_LIMIT || (end & 3u) || entry < IMG_START || entry >= end || (entry & 3u)) {
        puts_("kcboot: bad header\n");
        return 0;
    }
    puts_("kcboot: checking ");
    puthex(IMG_START); putc_('-'); puthex(end); putc_('\n');
    uint32_t s = 0;
    for (uint32_t a = IMG_START; a < end; a += 4) {
        if (a == WAD_START) a = WAD_END;      // the WAD area is not summed (boot time)
        s += DDR_W[a >> 2];
    }
    if (s != sum) {
        puts_("kcboot: checksum "); puthex(s); puts_(" != "); puthex(sum); putc_('\n');
        return 0;
    }
    return entry;
}

static void boot(uint32_t entry) {
    for (uint32_t k = 0; k < FLUSH_LINES; k++) (void)*(volatile uint32_t *)(FLUSH_BASE + k * 16u);
    puts_("kcboot: jump "); puthex(entry); putc_('\n');
    ((void (*)(void))entry)();
}

static int range_ok(uint32_t addr, uint32_t len) {
    return addr < IMG_LIMIT && len <= IMG_LIMIT - addr;
}

int main(void) {
    puts_("kcboot: waiting for DDR3\n");
    while (!(MMIO[MMIO_DDR_STATUS >> 2] & 1u)) {}
    uint32_t entry = check_image();
    if (entry) boot(entry);
    puts_("kcboot: waiting for image (scripts/doom_load.py)\n");
    for (;;) {
        uint8_t op = getc_();
        if (op == 'W') {
            uint32_t addr = get32(), len = get32(), s = 0;
            int ok = range_ok(addr, len);
            for (uint32_t i = 0; i < len; i++) {
                uint8_t b = getc_();
                s += b;
                if (ok) DDR[addr + i] = b;
            }
            putc_(ok && get32() == s ? 'A' : 'N');
        } else if (op == 'Z') {
            uint32_t addr = get32(), len = get32();
            int ok = range_ok(addr, len) && !((addr | len) & 3u);
            if (ok) for (uint32_t i = 0; i < len; i += 4) DDR_W[(addr + i) >> 2] = 0;
            putc_(ok ? 'A' : 'N');
        } else if (op == 'G') {
            entry = check_image();
            putc_(entry ? 'A' : 'N');
            if (entry) boot(entry);
        }
    }
}
