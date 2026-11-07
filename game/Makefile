# KennyCraft — Kenny's engine, game and assets.
#   make            assets + laptop build
#   make shots      golden camera shots into out/shots (PNG + raw .fb)
#   make play       scripted play-through with checks
#   make vectors    VTRACE test vectors from the C reference (out/vectors)
#   make contract   vtrace_ref against the wiki VTRACE rules (ties, saturation, cap 0)
#   make chip       rv32i_zmmul build with stand-in crt0/linker; checks no div/float/libcalls
#   make chip8      same with KC_LANES=8 (Stage 1 kernel)
#   make chip-raster  tile rasterizer builds (1 and 8 lanes) + lane lint
#   make compare    ray tracer vs rasterizer on the golden poses (out/cmp)
SRC      := src/kc_libc.c src/arena.c src/fixed.c src/trace.c src/render.c src/terrain.c src/chunks.c src/game.c src/kc_main.c
RASTER   := src/mesh.c src/raster.c
HOST_SRC := host/hal_host.c host/png.c host/main_host.c
GEN      := gen/kc_tables.h gen/kc_assets.h gen/textures.hex gen/palette.hex

CC       ?= cc
CFLAGS   := -std=c11 -O2 -Wall -Wextra -Wno-unused-parameter -Isrc -Igen -Ihost
CHIP_CC  ?= clang
CHIP_FLAGS := --target=riscv32-unknown-elf -march=rv32i_zmmul -mabi=ilp32 -O2 -ffreestanding \
              -nostdlib -fno-builtin -fno-jump-tables -Wall -Isrc -Igen -mno-relax \
              -DKC_CHIP -msmall-data-limit=0   # no .sdata/.sbss: Bennett's kc.ld only collects .bss*

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
build/kc_chip.elf: $(SRC) $(GEN) src/*.h chip/bench/crt0.S chip/bench/kc.ld | build
	$(CHIP_CC) $(CHIP_FLAGS) -DKC_LANES=1 -T chip/bench/kc.ld chip/bench/crt0.S $(SRC) -o $@
build/kc_chip8.elf: $(SRC) $(GEN) src/*.h chip/bench/crt0.S chip/bench/kc.ld | build
	$(CHIP_CC) $(CHIP_FLAGS) -DKC_LANES=8 -T chip/bench/kc.ld chip/bench/crt0.S $(SRC) -o $@

build/kc_chip_raster.elf: $(SRC) $(RASTER) $(GEN) src/*.h chip/bench/crt0.S chip/stub_kc.ld | build
	$(CHIP_CC) $(CHIP_FLAGS) -DKC_LANES=1 -DKC_RASTER=1 -T chip/stub_kc.ld chip/bench/crt0.S $(SRC) $(RASTER) -o $@
build/kc_chip8_raster.elf: $(SRC) $(RASTER) $(GEN) src/*.h chip/bench/crt0.S chip/stub_kc.ld | build
	$(CHIP_CC) $(CHIP_FLAGS) -DKC_LANES=8 -DKC_RASTER=1 -T chip/stub_kc.ld chip/bench/crt0.S $(SRC) $(RASTER) -o $@

chip-raster: build/kc_chip_raster.elf build/kc_chip8_raster.elf
	@sh tools/chip_check.sh build/kc_chip_raster.elf
	@sh tools/chip_check.sh build/kc_chip8_raster.elf
	@sh tools/lane_lint.sh build/kc_chip8_raster.elf

chip: build/kc_chip.elf
	@sh tools/chip_check.sh $<
chip8: build/kc_chip8.elf
	@sh tools/chip_check.sh $<
	@sh tools/lane_lint.sh $<

build:
	mkdir -p build
clean:
	rm -rf build out gen
