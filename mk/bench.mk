.DEFAULT_GOAL := check

CROSS ?= riscv-none-elf-
ifeq ($(shell command -v $(CROSS)gcc 2>/dev/null),)
CROSS := riscv64-unknown-elf-
endif
ifneq ($(shell command -v $(CROSS)gcc 2>/dev/null),)
RISCV_PREFIX ?= $(CROSS)
endif
CC := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump
MARCH := $(shell $(CC) -march=rv32i_zmmul -mabi=ilp32 -E -x c /dev/null >/dev/null 2>&1 && echo rv32i_zmmul || echo rv32im)
CFLAGS = -march=$(MARCH) -mabi=ilp32 -O2 -ffreestanding -nostdlib -fno-builtin -msmall-data-limit=0 -Wall -DKC_CHIP -Isw
LDFLAGS = -T sw/kc.ld -nostdlib
LIBS = -lgcc
PROG ?= sw/demo/pattern.c
PYTHON ?= python3

.PHONY: sw arena-host FORCE
sw: out/kc.elf out/kc.dis out/kc.map out/kc_imem.hex out/kc_dmem.hex

out:
	mkdir -p $@

# Rebuild when PROG changes, even if the new sources have older timestamps.
out/kc.elf: FORCE sw/crt0.S sw/kc.ld sw/arena.c sw/arena.h sw/gpu.h $(PROG) | out
	$(CC) $(CFLAGS) $(LDFLAGS) -Wl,-Map,out/kc.map sw/crt0.S $(PROG) sw/arena.c $(LIBS) -o $@

out/kc.map: out/kc.elf
	@test -f $@

out/kc.dis: out/kc.elf
	$(OBJDUMP) -d $< > $@

out/kc_imem.bin: out/kc.elf
	$(OBJCOPY) -O binary -j .text $< $@

out/kc_dmem.bin: out/kc.elf
	$(OBJCOPY) -O binary -j .rodata -j .data $< $@

out/kc_imem.hex: out/kc_imem.bin scripts/elf2hex.py
	$(PYTHON) scripts/elf2hex.py $< $@ --offset-bytes 0 --words 8192

out/kc_dmem.hex: out/kc_dmem.bin scripts/elf2hex.py
	$(PYTHON) scripts/elf2hex.py $< $@ --offset-bytes 0x100 --words 8192

arena-host: | out
	cc -std=c11 -Wall -Wextra -c sw/arena.c -o out/arena_host.o
