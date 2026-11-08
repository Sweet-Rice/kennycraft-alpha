# KennyCraft — Kenny's engine, game and assets.
#   make            assets + laptop build
#   make shots      golden camera shots into out/shots (PNG + raw .fb)
#   make play       scripted play-through with checks
#   make vectors    VTRACE test vectors from the C reference (out/vectors)
#   make contract   vtrace_ref against the wiki VTRACE rules (ties, saturation, cap 0)
#   make chip       rv32i_zmmul build with stand-in crt0/linker; checks no div/float/libcalls
#                   and that every lane's call chain fits its 1 KB stack
#   make chip8      same with KC_LANES=8 (Stage 1 kernel)
#   make chip-raster  tile rasterizer builds (1 and 8 lanes) + lane lint + stack check
#   make compare    ray tracer vs rasterizer on the golden poses (out/cmp)
SRC      := src/kc_libc.c src/arena.c src/fixed.c src/trace.c src/render.c src/entity.c src/terrain.c src/chunks.c src/game.c src/kc_main.c
RASTER   := src/mesh.c src/raster.c
HOST_SRC := host/hal_host.c host/png.c host/main_host.c
GEN      := gen/kc_tables.h gen/kc_assets.h gen/textures.hex gen/palette.hex

CC       ?= cc
CFLAGS   := -std=c11 -O2 -Wall -Wextra -Wno-unused-parameter -Isrc -Igen -Ihost
CHIP_CC  ?= clang
CHIP_FLAGS := --target=riscv32-unknown-elf -march=rv32i_zmmul -mabi=ilp32 -ffreestanding \
              -nostdlib -fno-builtin -fno-jump-tables -Wall -Isrc -Igen -mno-relax \
              -DKC_CHIP -msmall-data-limit=0 -ffunction-sections -fdata-sections
CHIP_LDFLAGS := -Wl,--gc-sections,--entry=_start
# -msmall-data-limit=0: no .sdata/.sbss, Bennett's kc.ld only collects .bss*.
# --gc-sections drops functions a build never calls (kc.ld has no ENTRY, so name _start).
# Per-file optimization. The kernel files (everything the lanes run per pixel / per
# triangle) stay at -O2; lane-0 game code is built for size: IMEM is 32 KB.
KERNEL_OPT := -O2
GAME_OPT   := -Os
GAME_FILES := arena.c terrain.c chunks.c game.c kc_main.c mesh.c
chip_opt    = $(if $(filter $(GAME_FILES),$(notdir $(1))),$(GAME_OPT),$(KERNEL_OPT))

.PHONY: all shots play vectors contract compare bench chip chip8 chip-raster clean
all: build/kc_host

$(GEN): tools/gen_assets.py $(wildcard assets/textures.png)
	python3 tools/gen_assets.py gen

# Start editing textures: copy the generated atlas to assets/textures.png, edit it, run make.
atlas-edit:
	mkdir -p assets && cp gen/textures_atlas.png assets/textures.png && echo "edit assets/textures.png, then make"

build/kc_host: $(SRC) $(RASTER) $(HOST_SRC) $(GEN) src/*.h host/*.h | build
	$(CC) $(CFLAGS) -DKC_HOST -DKC_RASTER=1 $(SRC) $(RASTER) $(HOST_SRC) -o $@

shots: build/kc_host
	mkdir -p out/shots && ./build/kc_host shots out/shots
play: build/kc_host
	mkdir -p out/play && ./build/kc_host play out/play
vectors: build/kc_host
	mkdir -p out/vectors && ./build/kc_host vectors out/vectors
contract: build/kc_host
	./build/kc_host contract
compare: build/kc_host
	mkdir -p out/cmp && ./build/kc_host compare out/cmp
bench: build/kc_host
	./build/kc_host bench

# Ray tracer: Bennett's real kc.ld + crt0 (bench/kc-bench). crt0 runs MASKALL/LANEID/MASKSET,
# which Stage 0 executes at LANES = 1 (issue #1, option A).
# Each variant compiles its objects into build/<variant>/ with that variant's defines.
# $(1) variant, $(2) defines, $(3) sources, $(4) linker script
define CHIP_ELF
build/$(1)/%.o: src/%.c $$(GEN) $$(wildcard src/*.h) Makefile | build
	@mkdir -p $$(@D)
	$$(CHIP_CC) $$(CHIP_FLAGS) $$(call chip_opt,$$<) $(2) -c $$< -o $$@
build/kc_$(1).elf: $$(patsubst src/%.c,build/$(1)/%.o,$(3)) chip/bench/crt0.S $(4) Makefile | build
	$$(CHIP_CC) $$(CHIP_FLAGS) $$(CHIP_LDFLAGS) $(2) -T $(4) chip/bench/crt0.S $$(filter %.o,$$^) -o $$@
endef
$(eval $(call CHIP_ELF,chip,-DKC_LANES=1,$(SRC),chip/bench/kc.ld))
$(eval $(call CHIP_ELF,chip8,-DKC_LANES=8,$(SRC),chip/bench/kc.ld))
$(eval $(call CHIP_ELF,chip_raster,-DKC_LANES=1 -DKC_RASTER=1,$(SRC) $(RASTER),chip/stub_kc.ld))
$(eval $(call CHIP_ELF,chip8_raster,-DKC_LANES=8 -DKC_RASTER=1,$(SRC) $(RASTER),chip/stub_kc.ld))

chip-raster: build/kc_chip_raster.elf build/kc_chip8_raster.elf
	@sh tools/chip_check.sh build/kc_chip_raster.elf
	@sh tools/chip_check.sh build/kc_chip8_raster.elf
	@sh tools/lane_lint.sh build/kc_chip8_raster.elf
	@sh tools/stack_check.sh build/kc_chip_raster.elf
	@sh tools/stack_check.sh build/kc_chip8_raster.elf

chip: build/kc_chip.elf
	@sh tools/chip_check.sh $<
	@sh tools/stack_check.sh $<
chip8: build/kc_chip8.elf
	@sh tools/chip_check.sh $<
	@sh tools/lane_lint.sh $<
	@sh tools/stack_check.sh $<

build:
	mkdir -p build
clean:
	rm -rf build out gen
