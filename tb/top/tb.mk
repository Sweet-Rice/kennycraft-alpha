# Full top-level test and lint (P3). Run from the repo root through `make check`.
#
#   top-hex          memory images for rtl/top.sv in $(TOP_GEN): kc_imem.hex and
#                    kc_dmem.hex from Kennedy's chip build (game/, `make chip`,
#                    clang 18, Bennett's kc.ld + crt0.S), textures.hex and
#                    palette.hex from game/gen. Run it before a Vivado build:
#                    fpga/sources.tcl reads these images and does not build them.
#   tb-top-t_top_frame
#                    rtl/top.sv with ddr_model as the MIG runs the program to
#                    its first FB_SWAP, captures the next frame from the VGA
#                    pins into $(TOP_OUT)/frame1.ppm (160x120) and
#                    frame1_vga.ppm (640x480). TOP_FRAMES=N captures N frames;
#                    TOP_HEX=dir runs other images (e.g. ones patched in with
#                    fpga/patch_bit.sh), TOP_OUT=dir puts the frames elsewhere.
#   lint-top         verilator -Wall over the whole top (sim models for the
#                    MMCM, BUFG, MIG and XPM, as in tb/ddr)

TOP_GEN    := $(OBJ)/top_hex
TOP_HEX    ?= $(TOP_GEN)
TOP_OUT    ?= $(OBJ)/top
TOP_FRAMES ?= 1
TOP_RTL    := rtl/kc_isa_pkg.sv $(wildcard rtl/core/*.sv) $(wildcard rtl/mem/*.sv) \
              $(wildcard rtl/soc/*.sv) $(wildcard rtl/display/*.sv) \
              rtl/ddr/chunk_engine.sv rtl/ddr/ddr_bridge.sv rtl/ddr/world_remap.sv \
              rtl/ddr/ddr_model.sv rtl/ddr/ddr_clk.sv tb/ddr/xpm_sim.sv tb/ddr/unisim_sim.sv \
              rtl/top.sv
TOP_IMAGES := kc_imem.hex kc_dmem.hex textures.hex palette.hex

TB_TARGETS += tb-top-t_top_frame lint-top

.PHONY: top-hex
top-hex: $(addprefix $(TOP_GEN)/,$(TOP_IMAGES))

# game/ owns its build; its outputs (game/build, game/gen) are gitignored there.
game/build/kc_chip.elf: $(wildcard game/src/*) $(wildcard game/chip/bench/*) game/tools/gen_assets.py
	$(MAKE) -C game chip

game/gen/textures.hex game/gen/palette.hex: game/build/kc_chip.elf

$(TOP_GEN)/kc_imem.hex $(TOP_GEN)/kc_dmem.hex &: game/build/kc_chip.elf tb/core/sw/bin2hex.py
	@mkdir -p $(TOP_GEN)
	$(RISCV_PREFIX)objcopy -O binary -j .text $< $(TOP_GEN)/kc_imem.bin
	$(RISCV_PREFIX)objcopy -O binary -j .rodata -j .data $< $(TOP_GEN)/kc_dmem.bin
	python3 tb/core/sw/bin2hex.py $(TOP_GEN)/kc_imem.bin $(TOP_GEN)/kc_imem.hex 8192
	python3 tb/core/sw/bin2hex.py $(TOP_GEN)/kc_dmem.bin $(TOP_GEN)/kc_dmem.hex 8192 0x100

$(TOP_GEN)/textures.hex $(TOP_GEN)/palette.hex: $(TOP_GEN)/%.hex: game/gen/%.hex
	@mkdir -p $(TOP_GEN)
	cp $< $@

tb-top-t_top_frame: $(addprefix $(TOP_HEX)/,$(TOP_IMAGES))
	@mkdir -p $(TOP_OUT)
	$(VERILATOR) $(VL_TB) -O3 --timescale 1ns/1ps --top-module t_top_frame -Mdir $(OBJ)/top_t_top_frame \
	  -GIMEM_HEX='"$(TOP_HEX)/kc_imem.hex"' -GDMEM_HEX='"$(TOP_HEX)/kc_dmem.hex"' \
	  -GTEX_HEX='"$(TOP_HEX)/textures.hex"' -GPAL_HEX='"$(TOP_HEX)/palette.hex"' \
	  $(TOP_RTL) tb/top/t_top_frame.sv
	$(OBJ)/top_t_top_frame/Vt_top_frame +outdir=$(TOP_OUT) +frames=$(TOP_FRAMES)

lint-top:
	$(VERILATOR) $(VL_LINT) --timing --top-module top $(TOP_RTL)
	$(VERILATOR) $(VL_LINT) --top-module world_mem rtl/mem/world_mem.sv
