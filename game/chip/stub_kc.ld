/* stub_kc.ld — Bennett's kc.ld + the GPUMEM region from D17 / CR2 (wiki, Bennett page):
   68 KB at 0x7000_0000 for the rasterizer's mesh pages and command lists. */
ENTRY(_start)
MEMORY {
    IMEM (rx)  : ORIGIN = 0x00000000, LENGTH = 32K
    DMEM (rw)  : ORIGIN = 0x10000100, LENGTH = 0x5F00   /* up to the lane stacks at 0x1000_6000 */
    GPUMEM (rw): ORIGIN = 0x70000000, LENGTH = 0x11000  /* D17: exactly what the hardware has */
}
SECTIONS {
    .text : { *(.text.start) *(.text*) } > IMEM
    .rodata : { *(.rodata*) *(.srodata*) } > DMEM
    .data : { *(.data*) *(.sdata*) } > DMEM
    .gpumem (NOLOAD) : { *(.gpumem*) } > GPUMEM
    .bss : { __bss_start = .; *(.bss*) *(.sbss*) *(COMMON) . = ALIGN(4); __bss_end = .; } > DMEM
}
