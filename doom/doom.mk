# Doom (doomgeneric, shareware doom1.wad) software for the KennyCraft Doom
# configuration (HAS_DDR_MEM=1; included by mk/doom.mk; paths are relative to
# the repo root). `make doom` builds, in out/doom/:
#   kc_imem.hex   the bootloader (imem BRAM, 8192 words)
#   kc_dmem.hex   the bootloader's data (dmem 0x1000_0000..; 0x6000..0x7FFF zero)
#   header.bin, text.bin, data.bin, doom1.wad and ddr.manifest, the DDR3 image
#                 (`<hex DDR3 addr> <path>` per line, for +ddr_manifest and
#                 scripts/doom_load.py)
# See doom/README.md.
#
#   DOOM_ARGS   extra Doom command-line arguments baked into the image,
#               e.g. make doom DOOM_ARGS="-warp 1 1"
#   KC_PROF=1   per-frame cycle profile on the UART (doom/kc_prof.c)
#   KC_VCLOCK=1 virtual clock, one tic per frame: frames depend on the frame
#               number only, for frame-for-frame comparisons across builds

DOOM_CROSS   ?= /home/tai/AMD/2026.1/gnu/riscv/lin/bin/riscv64-unknown-elf-
DOOM_CC      := $(DOOM_CROSS)gcc
DOOM_OBJCOPY := $(DOOM_CROSS)objcopy
DOOM_OBJDUMP := $(DOOM_CROSS)objdump
DOOM_NM      := $(DOOM_CROSS)nm
DOOM_SIZE    := $(DOOM_CROSS)size
PYTHON       ?= python3
DOOM_ARGS    ?=
KC_PROF      ?= 0
KC_VCLOCK    ?= 0

DOOM_OUT    := out/doom
DOOM_OBJ    := $(DOOM_OUT)/obj
DOOM_DG     := doom/doomgeneric/doomgeneric

# doomgeneric's engine (its Makefile's SRC_DOOM) minus the X11 platform file and
# all sound and music code: i_sound.c, s_sound.c, sounds.c, memio.c, i_cdmus.c
# are replaced by the no-op doom/kc_nosound.c; mus2mid.c, gusconf.c and the
# SDL/Allegro sound and music backends are never built.
DOOM_ENGINE := dummy am_map doomdef doomstat dstrings d_event d_items d_iwad d_loop \
    d_main d_mode d_net f_finale f_wipe g_game hu_lib hu_stuff info i_endoom \
    i_joystick i_scale i_system i_timer m_argv m_bbox m_cheat m_config \
    m_controls m_fixed m_menu m_misc m_random p_ceilng p_doors p_enemy p_floor \
    p_inter p_lights p_map p_maputl p_mobj p_plats p_pspr p_saveg p_setup \
    p_sight p_spec p_switch p_telept p_tick p_user r_bsp r_data r_draw r_main \
    r_plane r_segs r_sky r_things sha1 statdump st_lib st_stuff tables v_video \
    wi_stuff w_checksum w_file w_main w_wad z_zone w_file_stdc i_input i_video \
    doomgeneric
DOOM_PLAT   := doomgeneric_kc kc_render kc_nosound syscalls $(if $(filter 1,$(KC_PROF)),kc_prof)

DOOM_ARCH   := -march=rv32i_zmmul -mabi=ilp32
DOOM_CFLAGS := $(DOOM_ARCH) -O2 -mstrict-align -ffunction-sections -fdata-sections \
    -fno-asynchronous-unwind-tables -fno-unwind-tables \
    -DCMAP256 -DDOOMGENERIC_RESX=320 -DDOOMGENERIC_RESY=200 -I$(DOOM_DG)
DOOM_ARGS_DEF := -D'KC_DOOM_ARGS=$(foreach a,$(DOOM_ARGS),"$(a)",)'
DOOM_OPTS   := -DKC_PROF=$(KC_PROF) -DKC_VCLOCK=$(KC_VCLOCK)
# The screen buffer goes to SCRATCH BRAM without editing doomgeneric
# (doom/doomgeneric_kc.c).
DOOM_WRAPS  := I_InitGraphics I_FinishUpdate R_ExecuteSetViewSize R_Init \
    $(if $(filter 1,$(KC_PROF)),R_RenderPlayerView R_RenderBSPNode R_DrawPlanes R_DrawMasked TryRunTics G_Ticker ST_Drawer HU_Drawer \
        V_DrawPatch V_DrawPatchDirect V_CopyRect V_DrawBlock)
DOOM_COMMA  := ,
DOOM_LDFLAGS := $(DOOM_ARCH) -nostartfiles -T doom/kc_doom.ld -Wl,--gc-sections \
    -Wl,--no-warn-rwx-segments -Wl,--build-id=none -Wl,-Map,$(DOOM_OUT)/doom.map \
    $(addprefix -Wl$(DOOM_COMMA)--wrap=,$(DOOM_WRAPS))

DOOM_OBJS := $(DOOM_OBJ)/crt0.o $(addprefix $(DOOM_OBJ)/dg_,$(addsuffix .o,$(DOOM_ENGINE))) \
    $(addprefix $(DOOM_OBJ)/,$(addsuffix .o,$(DOOM_PLAT)))

DOOM_WAD_URL  := https://raw.githubusercontent.com/Akbar30Bill/DOOM_wads/master/doom1.wad
DOOM_WAD_URL2 := https://cdn.jsdelivr.net/gh/Akbar30Bill/DOOM_wads@master/doom1.wad
DOOM_WAD_MD5  := f0cefca49926d00903cf57551d901abe

.PHONY: doom doom-check
doom: $(DOOM_OUT)/kc_imem.hex $(DOOM_OUT)/kc_dmem.hex $(DOOM_OUT)/ddr.manifest \
      $(DOOM_OUT)/doom.dis $(DOOM_OUT)/boot.dis doom-check

$(DOOM_OBJ):
	mkdir -p $@

# The baked-in arguments and the KC_ options are part of the build: rebuild the
# platform objects and relink when they change.
$(DOOM_OBJ)/args: FORCE | $(DOOM_OBJ)
	@echo '$(DOOM_ARGS) $(DOOM_OPTS)' | cmp -s - $@ || echo '$(DOOM_ARGS) $(DOOM_OPTS)' > $@

$(DOOM_OBJ)/crt0.o: doom/crt0.S | $(DOOM_OBJ)
	$(DOOM_CC) $(DOOM_ARCH) -c $< -o $@

$(DOOM_OBJ)/dg_%.o: $(DOOM_DG)/%.c | $(DOOM_OBJ)
	$(DOOM_CC) $(DOOM_CFLAGS) -w -MMD -c $< -o $@

$(DOOM_OBJ)/doomgeneric_kc.o: doom/doomgeneric_kc.c $(DOOM_OBJ)/args | $(DOOM_OBJ)
	$(DOOM_CC) $(DOOM_CFLAGS) -Wall -Wextra $(DOOM_ARGS_DEF) $(DOOM_OPTS) -MMD -c $< -o $@

$(DOOM_OBJ)/%.o: doom/%.c $(DOOM_OBJ)/args | $(DOOM_OBJ)
	$(DOOM_CC) $(DOOM_CFLAGS) -Wall -Wextra $(DOOM_OPTS) -MMD -c $< -o $@

-include $(wildcard $(DOOM_OBJ)/*.d)

$(DOOM_OUT)/doom.elf: $(DOOM_OBJS) doom/kc_doom.ld $(DOOM_OBJ)/args
	$(DOOM_CC) $(DOOM_LDFLAGS) $(DOOM_OBJS) -lc -lm -lgcc -o $@
	$(DOOM_SIZE) -A $@

$(DOOM_OUT)/%.dis: $(DOOM_OUT)/%.elf
	$(DOOM_OBJDUMP) -d $< > $@

# ---- bootloader (imem BRAM + dmem) ----
$(DOOM_OUT)/boot.elf: doom/boot/crt0.S doom/boot/boot.c doom/boot/boot.ld | $(DOOM_OBJ)
	$(DOOM_CC) $(DOOM_ARCH) -Os -Wall -Wextra -nostartfiles -nostdlib -T doom/boot/boot.ld \
	    -Wl,--gc-sections -Wl,--build-id=none -ffunction-sections -fdata-sections -fno-asynchronous-unwind-tables \
	    doom/boot/crt0.S doom/boot/boot.c -lgcc -o $@

$(DOOM_OUT)/boot_imem.bin: $(DOOM_OUT)/boot.elf
	$(DOOM_OBJCOPY) -O binary -j .text $< $@

$(DOOM_OUT)/boot_dmem.bin: $(DOOM_OUT)/boot.elf
	$(DOOM_OBJCOPY) -O binary -j .rodata -j .data $< $@

$(DOOM_OUT)/kc_imem.hex: $(DOOM_OUT)/boot_imem.bin scripts/elf2hex.py
	$(PYTHON) scripts/elf2hex.py $< $@ --offset-bytes 0 --words 8192 --nonempty

$(DOOM_OUT)/kc_dmem.hex: $(DOOM_OUT)/boot_dmem.bin scripts/elf2hex.py
	$(PYTHON) scripts/elf2hex.py $< $@ --offset-bytes 0 --words 8192

doom-check: $(DOOM_OUT)/doom.elf $(DOOM_OUT)/boot.elf doom/check_elf.py
	$(PYTHON) doom/check_elf.py $(DOOM_OUT)/doom.elf --objdump $(DOOM_OBJDUMP) --nm $(DOOM_NM) \
	    --code 0x00100000:0x300000 --data 0x81000000:0x0E000000 --min-heap 0x2000000
	$(PYTHON) doom/check_elf.py $(DOOM_OUT)/boot.elf --objdump $(DOOM_OBJDUMP) --nm $(DOOM_NM) \
	    --code 0:0x8000 --data 0x10000000:0x5000

# ---- DDR3 image ----
$(DOOM_OUT)/text.bin: $(DOOM_OUT)/doom.elf
	$(DOOM_OBJCOPY) -O binary -j .text $< $@

# .rodata starts the data area at 0x8100_0000; .bss is cleared by doom/crt0.S.
$(DOOM_OUT)/data.bin: $(DOOM_OUT)/doom.elf
	$(DOOM_OBJCOPY) -O binary -j .rodata -j .data $< $@

$(DOOM_OUT)/ddr.manifest: $(DOOM_OUT)/text.bin $(DOOM_OUT)/data.bin $(DOOM_OUT)/doom1.wad doom/mkimage.py
	$(PYTHON) doom/mkimage.py --text $(DOOM_OUT)/text.bin --data $(DOOM_OUT)/data.bin \
	    --wad $(DOOM_OUT)/doom1.wad --entry 0x$$($(DOOM_NM) $(DOOM_OUT)/doom.elf | awk '$$3 == "_start" { print $$1 }') \
	    --header $(DOOM_OUT)/header.bin --manifest $@

# Shareware DOOM1.WAD v1.9, checked against its published MD5; never committed.
$(DOOM_OUT)/doom1.wad: | $(DOOM_OBJ)
	curl -fsSL --retry 3 -o $@.tmp $(DOOM_WAD_URL) || curl -fsSL --retry 3 -o $@.tmp $(DOOM_WAD_URL2)
	echo '$(DOOM_WAD_MD5)  $@.tmp' | md5sum -c --quiet
	mv $@.tmp $@

FORCE:
