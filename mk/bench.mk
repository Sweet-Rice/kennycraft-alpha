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

VERILATOR ?= verilator
RUN_ARGS ?=
STAGE ?= 0
DDR ?= 1
LANES ?= $(if $(filter 1 2,$(STAGE)),8,1)
CHIP_TOP ?= bench_chip
PAL_HEX ?=
TEX_HEX ?=
PALETTE_ARGS = $(if $(PAL_HEX),--palette-hex "$(abspath $(PAL_HEX))")
TEXTURE_ARGS = $(if $(TEX_HEX),--texture-hex "$(abspath $(TEX_HEX))")
HARNESS_CPP = $(wildcard tb/harness/*.cpp)
SDL_CFLAGS := $(shell pkg-config --cflags sdl3 2>/dev/null)
SDL_LIBS := $(shell pkg-config --libs sdl3 2>/dev/null)
VL_FLAGS = --cc --exe --build -j 0 --verilate-jobs 1 -Wall --prefix Vkc --trace -o kcvl
HARNESS_CFLAGS = -std=c++17 -Wall -Wextra -I$(abspath tb/harness) $(SDL_CFLAGS)
RTL_FILES = rtl/kc_isa_pkg.sv $(filter-out rtl/kc_isa_pkg.sv rtl/isa_decode_check.sv rtl/top.sv rtl/display/clk_gen.sv rtl/ddr/ddr_clk.sv,$(wildcard rtl/*.sv rtl/core/*.sv rtl/soc/*.sv rtl/mem/*.sv rtl/display/*.sv rtl/ddr/*.sv rtl/vtrace/*.sv))
CHIP_FILE = $(if $(filter bench_chip,$(CHIP_TOP)),tb/harness/bench_chip.sv,rtl/top.sv)
VL_STUBS = $(wildcard tb/harness/stubs/*.sv) tb/ddr/xpm_sim.sv

.PHONY: vl-fixture vl-fixture-build check-fixture
vl-fixture-build: | out
	$(VERILATOR) $(VL_FLAGS) --Mdir out/vl-fixture --top-module fixture_top \
		-CFLAGS "$(HARNESS_CFLAGS) -DKC_FIXTURE" -LDFLAGS "$(SDL_LIBS)" \
		tb/harness/fixture/public.vlt tb/harness/fixture/fixture_top.sv \
		$(abspath $(HARNESS_CPP))

vl-fixture: vl-fixture-build
	out/vl-fixture/kcvl $(RUN_ARGS)

check-fixture: vl-fixture-build
	$(PYTHON) scripts/check_fixture.py
	$(PYTHON) scripts/check_harness.py

.PHONY: vl vl-build
vl-build: sw
	$(VERILATOR) $(VL_FLAGS) --Mdir out/vl --top-module $(CHIP_TOP) \
		-GLANES=$(LANES) -GIMEM_HEX='"out/kc_imem.hex"' -GDMEM_HEX='"out/kc_dmem.hex"' \
		-GPAL_HEX='"$(PAL_HEX)"' -GTEX_HEX='"$(TEX_HEX)"' \
		-CFLAGS "$(HARNESS_CFLAGS) -DKC_LANES=$(LANES) -DCHIP_TOP=$(CHIP_TOP)" -LDFLAGS "$(SDL_LIBS)" \
		tb/harness/public.vlt $(RTL_FILES) $(CHIP_FILE) $(VL_STUBS) $(abspath $(HARNESS_CPP))

vl: vl-build
	out/vl/kcvl $(PALETTE_ARGS) $(RUN_ARGS)

TESTS_0 = t_zmmul t_uart t_illegal_div t_illegal_ecall t_illegal_csr \
	t_illegal_misaligned t_illegal_vget2 t_illegal_vset8 t_illegal_unknown \
	t_illegal_misaligned_jalr t_fbswap
TESTS_1 = t_laneid t_mask t_ballot t_maskgetset t_lsu_order t_branch_uniform \
	t_divstack t_divskip t_mask_zero t_mmio_lanes t_jalr_uniform t_div_nested_lmask \
	t_divstack_overflow
TESTS_DDR = t_chunk_roundtrip t_slot_valid t_ring
TESTS = $(TESTS_0)
ifeq ($(DDR),1)
TESTS += $(TESTS_DDR)
endif
ifneq ($(filter 1 2,$(STAGE)),)
TESTS += $(TESTS_1)
endif
TEST_ARGS = --stage $(STAGE) --cc "$(CC)" --objcopy "$(OBJCOPY)" --nm "$(CROSS)nm" --cflags "$(CFLAGS)"

.PHONY: test-stage0 test-images
test-stage0: vl-build
	$(PYTHON) scripts/run_tests.py $(TEST_ARGS) $(TESTS_0)
.PHONY: test-ddr
test-ddr: vl-build
	$(PYTHON) scripts/run_tests.py $(TEST_ARGS) $(TESTS_DDR)
test-images:
	$(PYTHON) scripts/run_tests.py $(TEST_ARGS) --build-only $(TESTS)
.PHONY: test-stage1-build
test-stage1-build:
	$(PYTHON) scripts/run_tests.py $(TEST_ARGS) --build-only $(TESTS_1)
test-%: vl-build
	$(PYTHON) scripts/run_tests.py $(TEST_ARGS) $*
