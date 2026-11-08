MEMORY {
  IMEM (rx) : ORIGIN = 0x00000000, LENGTH = 32K
  DMEM (rw) : ORIGIN = 0x10000100, LENGTH = 0x5F00
}
SECTIONS {
  .text   : { *(.text.start) *(.text*) } > IMEM
  .rodata : { *(.rodata*) } > DMEM
  /* .data runs at its DMEM address but loads after .bss: crt0.S copies it in on every
     reset, so a warm reset (ck_rst) starts from the initial values like a JTAG load. */
  .data   : AT(ALIGN(__bss_end, 4)) { __data_start = .; *(.data*) . = ALIGN(4); __data_end = .; } > DMEM
  .bss    : { __bss_start = .; *(.bss*) *(COMMON) __bss_end = .; } > DMEM
  __data_load = LOADADDR(.data);
  ASSERT(__data_load + SIZEOF(.data) <= ORIGIN(DMEM) + LENGTH(DMEM), "DMEM overflow: .data load copy")
}
