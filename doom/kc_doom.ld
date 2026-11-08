/* Doom on KennyCraft (HAS_DDR_MEM=1, doom/README.md). Code is fetched from
   DDR3 through the I-cache: PC = DDR3 byte address, .text at 0x0010_0000
   (DDR3 0x0010_0000, below the WAD at 0x0040_0000). Fetch-only space reads 0
   as data, so .rodata, .data, .bss, heap and stack all live in DDR3 at
   0x8100_0000.. through the D-cache, up to the flush area at 0x8F00_0000. */
ENTRY(_start)
STACK_SIZE = 1M;
MEMORY {
  TEXT (rx) : ORIGIN = 0x00100000, LENGTH = 3M
  DATA (rw) : ORIGIN = 0x81000000, LENGTH = 0x0E000000
}
SECTIONS {
  .text : {
    KEEP(*(.text.start))
    *(.text .text.*)
  } > TEXT

  .rodata : {
    *(.rodata .rodata.*)
    *(.srodata .srodata.*)
  } > DATA
  .data : {
    . = ALIGN(4);
    *(.data .data.*)
    . = ALIGN(4);
    __global_pointer$ = . + 0x800;
    *(.sdata .sdata.*)
    . = ALIGN(16);
  } > DATA
  .bss (NOLOAD) : {
    . = ALIGN(4);
    __bss_start = .;
    *(.sbss .sbss.*)
    *(.bss .bss.*)
    *(COMMON)
    . = ALIGN(16);
    __bss_end = .;
  } > DATA
  _end = .;
  end = .;
  __stack_top = ORIGIN(DATA) + LENGTH(DATA);
  __stack_limit = __stack_top - STACK_SIZE;
  ASSERT(_end <= __stack_limit, "kc_doom.ld: data and bss overlap the stack")

  /DISCARD/ : {
    *(.note*) *(.comment) *(.eh_frame*) *(.riscv.attributes)
    *(.init_array*) *(.fini_array*) *(.ctors*) *(.dtors*)
  }
}
