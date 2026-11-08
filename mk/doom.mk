# Doom on the KennyCraft chip (HAS_DDR_MEM = 1: code and data in DDR3 behind
# the I-cache and D-cache, rtl/soc/kc_soc.sv). Included from the top Makefile.
#
#   make doom            software images in out/doom (doom/doom.mk)
#   make doom-vl-build   kcvl for the doom configuration in out/vl-doom: rtl/top.sv
#                        with LANES = 8, the divergence stack, QRCP, no ray unit,
#                        two framebuffers, the pipelined core and HAS_DDR_MEM = 1,
#                        images out/doom/kc_imem.hex, kc_dmem.hex. CORE_MHZ stays
#                        50 here (the board build uses 100): it only sets the UART
#                        divider and the CYCLES prescaler, and the harness models
#                        the UART at 50 cycles per bit (tb/harness/io.cpp)
#   make doom-vl         run it (RUN_ARGS=...) with +ddr_manifest=out/doom/ddr.manifest
#   make doom-selftest   tb/harness/selftest/t_doom.S on that kcvl: scratch,
#                        D-cache (eviction / write-back), manifest preload and a
#                        call into code in DDR3 through the I-cache
#
# kcvl loads out/doom/*.hex relative to its working directory, so the
# self-test runs it inside out/doom-selftest with its own out/doom images.

DOOM_VL_MDIR   := out/vl-doom
DOOM_VL_CONFIG := STAGE=2 LANES=8 HAS_DIV_STACK=1 HAS_RAY_UNIT=0 HAS_QRCP=1 FB_COUNT=2 \
                  CHIP_TOP=top PIPELINED=1 VL_MDIR=$(DOOM_VL_MDIR)

.PHONY: doom-vl-build doom-vl-model doom-vl doom-selftest
doom-vl-build:
	$(MAKE) --no-print-directory doom-vl-model $(DOOM_VL_CONFIG)

doom-vl-model: VL_EXTRA = -GHAS_DDR_MEM="1'b1"
doom-vl-model: VL_IMEM_HEX = out/doom/kc_imem.hex
doom-vl-model: VL_DMEM_HEX = out/doom/kc_dmem.hex
doom-vl-model:
	$(VL_MODEL_RECIPE)

doom-vl: doom-vl-build
	$(DOOM_VL_MDIR)/kcvl +ddr_manifest=out/doom/ddr.manifest $(RUN_ARGS)

DOOM_ST := out/doom-selftest
doom-selftest: doom-vl-build
	@mkdir -p $(DOOM_ST)/out/doom
	$(CC) $(CFLAGS) $(LDFLAGS) -Wl,-Map,$(DOOM_ST)/kc.map sw/crt0.S tb/harness/selftest/t_doom.S $(LIBS) \
		-o $(DOOM_ST)/kc.elf
	$(OBJCOPY) -O binary -j .text $(DOOM_ST)/kc.elf $(DOOM_ST)/kc_imem.bin
	$(OBJCOPY) -O binary -j .rodata -j .data $(DOOM_ST)/kc.elf $(DOOM_ST)/kc_dmem.bin
	$(PYTHON) scripts/elf2hex.py $(DOOM_ST)/kc_imem.bin $(DOOM_ST)/out/doom/kc_imem.hex \
		--offset-bytes 0 --words 8192 --nonempty
	$(PYTHON) scripts/elf2hex.py $(DOOM_ST)/kc_dmem.bin $(DOOM_ST)/out/doom/kc_dmem.hex \
		--offset-bytes 0x100 --words 8192
	$(PYTHON) -c "import struct; open('$(DOOM_ST)/pattern.bin', 'wb').write(b''.join(struct.pack('<I', 0xD0000000 + k) for k in range(1024)))"
	echo "200000 pattern.bin" > $(DOOM_ST)/ddr.manifest
	cd $(DOOM_ST) && $(abspath $(DOOM_VL_MDIR))/kcvl --headless --expect-pass --max-cycles 5000000 \
		--png-dir frames +ddr_manifest=ddr.manifest

-include doom/doom.mk
