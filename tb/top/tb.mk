# Full top-level tests and lint (P3, P5 rung 8). Run from the repo root through
# `make check`.
#
# Game builds (Kennedy's game/Makefile, clang 18, Bennett's crt0.S):
#   kc_chip          1 lane, ray tracer          (Stage 0 core: LANES = 1)
#   kc_chip8         8 lanes, ray tracer         (Stage 1 core: LANES = 8 with
#   kc_chip_raster   1 lane, tile rasterizer      HAS_DIV_STACK = 1 for the
#   kc_chip8_raster  8 lanes, tile rasterizer     kc_chip8* builds, else Stage 0)
# The raster builds link with chip/stub_kc.ld (kc.ld + the D17 GPU memory).
#
#   top-hex          memory images for rtl/top.sv, one directory per game build:
#                    $(TOP_GEN)/<build>/kc_imem.hex, kc_dmem.hex (from the
#                    ELF), textures.hex, palette.hex (game/gen). Run it before
#                    a Vivado build: fpga/sources.tcl reads
#                    $(TOP_GEN)/kc_chip8 (KC_TARGET=top, Stage 1) and
#                    fpga/top_s0/sources.tcl $(TOP_GEN)/kc_chip (Stage 0).
#   tb-top-t_top_frame
#                    rtl/top.sv with ddr_model as the MIG runs TOP_ELF (default
#                    kc_chip, Stage 0) to its first FB_SWAP, captures the next
#                    frame from the VGA pins into $(TOP_OUT)/frame1.ppm
#                    (160x120) and frame1_vga.ppm (640x480), and prints the
#                    core cycle (CYCLES) of every FB_SWAP. TOP_FRAMES=N
#                    captures N frames, TOP_SWAPS=N runs until N swaps (frame
#                    rates), TOP_TIMEOUT=s the limit in board seconds,
#                    TOP_ARGS more plusargs (e.g. a retire trace window, see
#                    t_top_frame.sv);
#                    TOP_HEX=dir runs other images (e.g. ones patched in with
#                    fpga/patch_bit.sh), TOP_OUT=dir puts the frames elsewhere.
#   tb-top-golden-<build>
#                    the same run (GOLDEN_FRAMES frames, into $(OBJ)/top/<build>),
#                    then tb/top/kc_golden.c compares every frame pixel for pixel
#                    with the plain-C reference: Kennedy's game sources on his
#                    laptop HAL running the chip's kc_init + kc_frame sequence.
#                    make check runs it for kc_chip8 (P5 rung 8).
#   lint-top         verilator -Wall over the whole top at Stage 1 and Stage 0
#                    (sim models for the MMCM, BUFG, MIG and XPM, as in tb/ddr)

TOP_ELFS      := kc_chip kc_chip8 kc_chip_raster kc_chip8_raster
TOP_ELF       ?= kc_chip
TOP_GEN       := $(OBJ)/top_hex
TOP_HEX       ?= $(TOP_GEN)/$(TOP_ELF)
TOP_OUT       ?= $(OBJ)/top
TOP_FRAMES    ?= 1
TOP_SWAPS     ?= 0
TOP_TIMEOUT   ?= 20
TOP_ARGS      ?=
GOLDEN_FRAMES ?= 2
HOST_CC       ?= zig cc
TOP_RTL    := rtl/kc_isa_pkg.sv $(wildcard rtl/core/*.sv) $(wildcard rtl/mem/*.sv) \
              $(wildcard rtl/soc/*.sv) $(wildcard rtl/display/*.sv) \
              rtl/ddr/chunk_engine.sv rtl/ddr/ddr_bridge.sv rtl/ddr/world_remap.sv \
              rtl/ddr/ddr_model.sv rtl/ddr/ddr_clk.sv tb/ddr/xpm_sim.sv tb/ddr/unisim_sim.sv \
              rtl/top.sv
TOP_IMAGES := kc_imem.hex kc_dmem.hex textures.hex palette.hex

# Core configuration for a game build: 8 lanes + divergence stack for kc_chip8*.
top_lanes = $(if $(filter kc_chip8%,$(1)),8,1)
top_div   = $(if $(filter kc_chip8%,$(1)),1,0)

TB_TARGETS += tb-top-t_top_frame tb-top-golden-kc_chip8 lint-top

.PHONY: top-hex $(addprefix tb-top-golden-,$(TOP_ELFS))
top-hex: $(foreach e,$(TOP_ELFS),$(addprefix $(TOP_GEN)/$(e)/,$(TOP_IMAGES)))

# game/ owns its build; its outputs (game/build, game/gen) are gitignored there.
GAME_DEPS := $(wildcard game/src/*) $(wildcard game/chip/bench/*) game/chip/stub_kc.ld \
             game/tools/gen_assets.py
game/build/kc_chip.elf: $(GAME_DEPS)
	$(MAKE) -C game chip
game/build/kc_chip8.elf: $(GAME_DEPS)
	$(MAKE) -C game chip8
game/build/kc_chip_raster.elf game/build/kc_chip8_raster.elf &: $(GAME_DEPS)
	$(MAKE) -C game chip-raster

game/gen/textures.hex game/gen/palette.hex game/gen/kc_assets.h game/gen/kc_tables.h: game/build/kc_chip.elf

define TOP_IMAGE_RULES
$(TOP_GEN)/$(1)/kc_imem.hex $(TOP_GEN)/$(1)/kc_dmem.hex &: game/build/$(1).elf tb/core/sw/bin2hex.py
	@mkdir -p $(TOP_GEN)/$(1)
	$(RISCV_PREFIX)objcopy -O binary -j .text $$< $(TOP_GEN)/$(1)/kc_imem.bin
	$(RISCV_PREFIX)objcopy -O binary -j .rodata -j .data $$< $(TOP_GEN)/$(1)/kc_dmem.bin
	python3 tb/core/sw/bin2hex.py $(TOP_GEN)/$(1)/kc_imem.bin $(TOP_GEN)/$(1)/kc_imem.hex 8192
	python3 tb/core/sw/bin2hex.py $(TOP_GEN)/$(1)/kc_dmem.bin $(TOP_GEN)/$(1)/kc_dmem.hex 8192 0x100

$(TOP_GEN)/$(1)/textures.hex $(TOP_GEN)/$(1)/palette.hex: $(TOP_GEN)/$(1)/%.hex: game/gen/%.hex
	@mkdir -p $(TOP_GEN)/$(1)
	cp $$< $$@
endef
$(foreach e,$(TOP_ELFS),$(eval $(call TOP_IMAGE_RULES,$(e))))

# $(call top_run,<build>,<hex dir>,<out dir>,<frames>): Verilate t_top_frame for
# the build's core configuration (one model directory per build) and run it.
define top_run
	@mkdir -p $(3)
	$(VERILATOR) $(VL_TB) -O3 --timescale 1ns/1ps --top-module t_top_frame -Mdir $(OBJ)/top_t_top_frame_$(1) \
	  -GLANES=$(call top_lanes,$(1)) -GHAS_DIV_STACK=$(call top_div,$(1)) \
	  -GIMEM_HEX='"$(2)/kc_imem.hex"' -GDMEM_HEX='"$(2)/kc_dmem.hex"' \
	  -GTEX_HEX='"$(2)/textures.hex"' -GPAL_HEX='"$(2)/palette.hex"' \
	  $(TOP_RTL) tb/top/t_top_frame.sv
	$(OBJ)/top_t_top_frame_$(1)/Vt_top_frame +outdir=$(3) +frames=$(4) +swaps=$(TOP_SWAPS) +timeout_s=$(TOP_TIMEOUT) $(TOP_ARGS)
endef

tb-top-t_top_frame: $(addprefix $(TOP_HEX)/,$(TOP_IMAGES))
	$(call top_run,$(TOP_ELF),$(TOP_HEX),$(TOP_OUT),$(TOP_FRAMES))

# Plain-C reference: the game's sources + game/host/hal_host.c, KC_LANES = 1,
# with or without the rasterizer to match the chip build.
GOLDEN_SRC := $(addprefix game/src/,kc_libc.c arena.c fixed.c trace.c render.c terrain.c \
                chunks.c game.c kc_main.c) game/host/hal_host.c tb/top/kc_golden.c
GOLDEN_CFLAGS := -std=c11 -O2 -Wall -Wextra -Wno-unused-parameter -Igame/src -Igame/gen -Igame/host -DKC_HOST

$(OBJ)/kc_golden_ray: $(GOLDEN_SRC) $(wildcard game/src/*.h) game/gen/kc_assets.h game/gen/kc_tables.h
	@mkdir -p $(OBJ)
	$(HOST_CC) $(GOLDEN_CFLAGS) $(GOLDEN_SRC) -o $@
$(OBJ)/kc_golden_raster: $(GOLDEN_SRC) $(wildcard game/src/*.h) game/gen/kc_assets.h game/gen/kc_tables.h
	@mkdir -p $(OBJ)
	$(HOST_CC) $(GOLDEN_CFLAGS) -DKC_RASTER=1 $(GOLDEN_SRC) game/src/mesh.c game/src/raster.c -o $@

top_golden = $(OBJ)/kc_golden_$(if $(filter %_raster,$(1)),raster,ray)

define TOP_GOLDEN_RULE
tb-top-golden-$(1): $(addprefix $(TOP_GEN)/$(1)/,$(TOP_IMAGES)) $(call top_golden,$(1))
	$(call top_run,$(1),$(TOP_GEN)/$(1),$(OBJ)/top/$(1),$(GOLDEN_FRAMES))
	$(call top_golden,$(1)) $(GOLDEN_FRAMES) $(OBJ)/top/$(1) $(OBJ)/top/$(1)
endef
$(foreach e,$(TOP_ELFS),$(eval $(call TOP_GOLDEN_RULE,$(e))))

lint-top:
	$(VERILATOR) $(VL_LINT) --timing --top-module top $(TOP_RTL)
	$(VERILATOR) $(VL_LINT) --timing --top-module top -GLANES=1 -GHAS_DIV_STACK=0 $(TOP_RTL)
	$(VERILATOR) $(VL_LINT) --top-module world_mem rtl/mem/world_mem.sv
