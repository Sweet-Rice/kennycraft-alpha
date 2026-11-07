.DEFAULT_GOAL := check

# Same pinned GCC as tb/core and tb/isa. It must support Zmmul (D5).
RISCV_PREFIX ?= /home/tai/AMD/2026.1/gnu/riscv/lin/bin/riscv64-unknown-elf-
CROSS ?= $(RISCV_PREFIX)
CC := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump
MARCH := rv32i_zmmul
CFLAGS = -march=$(MARCH) -mabi=ilp32 -O2 -ffreestanding -nostdlib -fno-builtin -msmall-data-limit=0 -Wall -DKC_CHIP -Isw
LDFLAGS = -T sw/kc.ld -nostdlib -Wl,--build-id=none
LIBS = -lgcc
PROG ?= sw/demo/pattern.c
PYTHON ?= python3
HOST_CC ?= zig cc

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
	$(PYTHON) scripts/elf2hex.py $< $@ --offset-bytes 0 --words 8192 --nonempty

out/kc_dmem.hex: out/kc_dmem.bin scripts/elf2hex.py
	$(PYTHON) scripts/elf2hex.py $< $@ --offset-bytes 0x100 --words 8192

arena-host: | out
	$(HOST_CC) -std=c11 -Wall -Wextra -c sw/arena.c -o out/arena_host.o

.PHONY: clean-bench
clean: clean-bench
clean-bench:
	rm -rf out

VERILATOR ?= verilator
RUN_ARGS ?=
STAGE ?= 0
DDR ?= 1
# CHIP_TOP=top is rtl/top.sv (P3). LANES and HAS_DIV_STACK are bench_chip
# parameters only; the harness reads the lane count from the built core.
LANES ?= $(if $(filter 1 2,$(STAGE)),8,1)
HAS_DIV_STACK ?= $(if $(filter 1 2,$(STAGE)),1,0)
CHIP_TOP ?= bench_chip
CHIP_PARAMS = $(if $(filter bench_chip,$(CHIP_TOP)),-GLANES=$(LANES) -GHAS_DIV_STACK="1'b$(HAS_DIV_STACK)")
VL_MDIR ?= out/vl
PAL_HEX ?=
TEX_HEX ?=
PALETTE_ARGS = $(if $(PAL_HEX),--palette-hex "$(abspath $(PAL_HEX))")
TEXTURE_ARGS = $(if $(TEX_HEX),--texture-hex "$(abspath $(TEX_HEX))")
HARNESS_CPP = $(wildcard tb/harness/*.cpp)
SDL_CFLAGS := $(shell pkg-config --cflags sdl3 2>/dev/null)
SDL_LIBS := $(shell pkg-config --libs sdl3 2>/dev/null)
KC_SDL := $(if $(SDL_LIBS),1,0)
# Verilator's wrapper drops an empty argument, so never pass -LDFLAGS "".
SDL_LDFLAGS = $(if $(SDL_LIBS),-LDFLAGS "$(SDL_LIBS)")
VL_FLAGS = --cc --exe --build -j 0 --verilate-jobs 1 -Wall --prefix Vkc --trace -o kcvl
HARNESS_CFLAGS = -std=c++17 -Wall -Wextra -I$(abspath tb/harness) -DKC_SDL=$(KC_SDL) $(SDL_CFLAGS)
RTL_FILES = rtl/kc_isa_pkg.sv $(filter-out rtl/kc_isa_pkg.sv rtl/isa_decode_check.sv rtl/top.sv rtl/display/clk_gen.sv rtl/ddr/ddr_clk.sv,$(wildcard rtl/*.sv rtl/core/*.sv rtl/soc/*.sv rtl/mem/*.sv rtl/display/*.sv rtl/ddr/*.sv rtl/vtrace/*.sv))
CHIP_FILE = $(if $(filter bench_chip,$(CHIP_TOP)),tb/harness/bench_chip.sv,rtl/top.sv)
VL_STUBS = $(wildcard tb/harness/stubs/*.sv) tb/ddr/xpm_sim.sv

.PHONY: vl-fixture vl-fixture-build check-fixture
vl-fixture-build: | out
	$(VERILATOR) $(VL_FLAGS) --Mdir out/vl-fixture --top-module fixture_top \
		-CFLAGS "$(HARNESS_CFLAGS) -DKC_FIXTURE" $(SDL_LDFLAGS) \
		tb/harness/fixture/public.vlt tb/harness/fixture/fixture_top.sv \
		$(abspath $(HARNESS_CPP))

vl-fixture: vl-fixture-build
	out/vl-fixture/kcvl $(RUN_ARGS)

check-fixture: vl-fixture-build
	$(PYTHON) scripts/check_fixture.py
	$(PYTHON) scripts/check_harness.py

.PHONY: vl vl-build
vl-build: sw
	@mkdir -p $(VL_MDIR)
	$(VERILATOR) $(VL_FLAGS) --Mdir $(VL_MDIR) --top-module $(CHIP_TOP) $(CHIP_PARAMS) \
		-GIMEM_HEX='"out/kc_imem.hex"' -GDMEM_HEX='"out/kc_dmem.hex"' \
		-GPAL_HEX='"$(if $(PAL_HEX),$(abspath $(PAL_HEX)))"' -GTEX_HEX='"$(if $(TEX_HEX),$(abspath $(TEX_HEX)))"' \
		-CFLAGS "$(HARNESS_CFLAGS) -DCHIP_TOP=$(CHIP_TOP)" $(SDL_LDFLAGS) \
		tb/harness/public.vlt $(RTL_FILES) $(CHIP_FILE) $(VL_STUBS) $(abspath $(HARNESS_CPP))

vl: vl-build
	$(VL_MDIR)/kcvl $(RUN_ARGS)

TESTS_0 = t_zmmul t_uart t_illegal_div t_illegal_ecall t_illegal_csr \
	t_illegal_misaligned t_illegal_vget2 t_illegal_vset8 t_illegal_unknown \
	t_illegal_misaligned_jalr t_illegal_misaligned_branch t_illegal_misaligned_jal \
	t_fbswap
TESTS_1 = t_laneid t_mask t_ballot t_maskgetset t_lsu_order t_branch_uniform \
	t_divstack t_divskip t_mask_zero t_mmio_lanes t_jalr_uniform t_div_nested_lmask \
	t_divstack_overflow
TESTS_DDR = t_chunk_roundtrip t_slot_valid t_ring
TESTS_2 = t_vtrace
TESTS = $(TESTS_0)
ifeq ($(DDR),1)
TESTS += $(TESTS_DDR)
endif
ifneq ($(filter 1 2,$(STAGE)),)
TESTS += $(TESTS_1)
endif
ifeq ($(STAGE),2)
TESTS += $(TESTS_2)
endif
TEST_ARGS = --stage $(STAGE) --cc "$(CC)" --objcopy "$(OBJCOPY)" --nm "$(CROSS)nm" --cflags "$(CFLAGS)"

# Stage 2 joins once P7 puts the ray unit in the core.
.PHONY: check-bench check-stage
check-bench:
	$(MAKE) check-fixture
	$(MAKE) check-stage STAGE=0
	$(MAKE) check-stage STAGE=1
	$(MAKE) golden-check
check-stage: vl-build
	$(PYTHON) scripts/run_tests.py $(TEST_ARGS) $(TESTS)

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

# Golden camera shots (Bennett.md, Shared.md Verification): Kennedy's plain C
# reference (make -C game shots) against kcvl running the same pose, kcvl
# built with the game's palette and textures in its own directory.
.PHONY: golden-check tracediff
GOLDEN_VL = out/golden/vl
GAME_CHIP_CC ?= clang
golden-check:
	$(MAKE) -C game CC="$(HOST_CC)" shots
	$(MAKE) vl-build VL_MDIR=$(GOLDEN_VL) PAL_HEX=game/gen/palette.hex TEX_HEX=game/gen/textures.hex
	$(PYTHON) scripts/golden.py --binary $(GOLDEN_VL)/kcvl --cc "$(GAME_CHIP_CC)" --objcopy "$(OBJCOPY)" \
		--lanes $(if $(filter bench_chip,$(CHIP_TOP)),$(LANES),1)
tracediff: vl-build
	@test -n "$(REF)" || { echo "tracediff: set REF=" >&2; exit 5; }
	$(PYTHON) scripts/compare_ref.py --ref "$(REF)" --frames $(if $(FRAMES),$(FRAMES),5) $(if $(KEYS),--keys "$(KEYS)") $(PALETTE_ARGS) $(TEXTURE_ARGS)

.PHONY: board keys
board: check
	BIT="$(BIT)" MMI="$(MMI)" IMEM_PROC="$(IMEM_PROC)" DMEM_PROC="$(DMEM_PROC)" \
		TEX_HEX="$(TEX_HEX)" PAL_HEX="$(PAL_HEX)" TEX_PROC="$(TEX_PROC)" PALETTE_PROC="$(PALETTE_PROC)" \
		PYTHON="$(PYTHON)" bash scripts/board.sh program
keys:
	$(PYTHON) scripts/kc.py $(if $(PORT),--port "$(PORT)")
