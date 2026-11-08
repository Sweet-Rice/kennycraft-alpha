/* Shared constants for the tb/core test programs (addresses from the Shared
   page, Memory map and MMIO; offsets match rtl/kc_isa_pkg.sv). */
#define DMEM_BASE         0x10000000
#define MMIO_BASE         0x50000000
#define UNMAPPED_BASE     0x70000000
#define MMIO_FB_SWAP      0x00
#define MMIO_FRAME_COUNT  0x04
#define MMIO_VSYNC        0x08
#define MMIO_CYCLES       0x0C
#define MMIO_UART_RX      0x10
#define MMIO_UART_STATUS  0x14
#define MMIO_UART_TX      0x18
#define MMIO_ERR          0x1C
#define MMIO_ERR_PC       0x20
#define MMIO_LEDS         0x24
#define MMIO_FB_MODE      0x28

/* Test mailbox in the reserved shared state (0x1000_0030..0x1000_00FF).
   The testbench writes SELECT before reset; programs write DONE = 1 at the end. */
#define TB_SELECT         0x100000F0
#define TB_MARK           0x100000F4
#define TB_DONE           0x100000FC
