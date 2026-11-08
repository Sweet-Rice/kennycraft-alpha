/* Doom bootloader: code in the 32 KB imem BRAM, data and stack in dmem
   0x1000_0000..0x1000_5FFF (crt0 puts the stack top at 0x1000_6000). */
ENTRY(_start)
MEMORY {
  IMEM (rx) : ORIGIN = 0x00000000, LENGTH = 32K
  DMEM (rw) : ORIGIN = 0x10000000, LENGTH = 0x5000
}
SECTIONS {
  .text   : { KEEP(*(.text.start)) *(.text .text.*) } > IMEM
  .rodata : { *(.rodata .rodata.*) *(.srodata .srodata.*) } > DMEM
  .data   : { *(.data .data.*) *(.sdata .sdata.*) } > DMEM
  .bss (NOLOAD) : {
    . = ALIGN(4);
    __bss_start = .;
    *(.sbss .sbss.*) *(.bss .bss.*) *(COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > DMEM
  /DISCARD/ : { *(.note*) *(.comment) *(.eh_frame*) *(.riscv.attributes) }
}
