/* The RISC-V GCC here links with --gc-sections and --build-id by default:
   ENTRY and KEEP hold the program, and the build-id note must not land
   ahead of .text at address 0. */
ENTRY(_start)
MEMORY {
  IMEM   (rx) : ORIGIN = 0x00000000, LENGTH = 32K
  DMEM   (rw) : ORIGIN = 0x10000100, LENGTH = 0x5F00
}
SECTIONS {
  .text   : { KEEP(*(.text.start)) *(.text*) } > IMEM
  .rodata : { *(.rodata*) *(.srodata*) } > DMEM
  .data   : { *(.data*) *(.sdata*) }   > DMEM
  .bss    : {
    . = ALIGN(4);
    __bss_start = .;
    *(.bss*)
    *(.sbss*)
    *(COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > DMEM
  /DISCARD/ : { *(.note*) }
}
