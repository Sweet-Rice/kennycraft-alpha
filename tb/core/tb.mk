# Core testbenches and lint, registered with `make check` (run from the repo
# root).
#
#   tb-core-datapath_tb     directed tests poked into imem
#   tb-core-program_mem_tb  tb/core/program.mem (mkprog.py) through $readmemh
#   tb-core-t_zmmul, tb-core-t_uart, tb-core-t_illegal, tb-core-t_mmio,
#   tb-core-t_lanectl, tb-core-t_cpi
#                           programs in tb/core/sw/*.S, assembled with the
#                           RISC-V GCC, loaded as kc_imem/kc_dmem images
#   lint-core               verilator -Wall over rtl/core, rtl/mem, rtl/soc
#                           at LANES = 1 and LANES = 8
#
# `make tb-core-t_cpi` prints the measured CPI of every instruction class.
# Add PLUSARGS=+trace for a per-instruction retirement trace.

RISCV_PREFIX ?= /home/tai/AMD/2026.1/gnu/riscv/lin/bin/riscv64-unknown-elf-
CORE_SW_FLAGS := -march=rv32i_zmmul -mabi=ilp32 -nostdlib -nostartfiles \
                 -Wl,--build-id=none -Ttb/core/sw/test.ld
CORE_SW_OBJ   := $(OBJ)/core_sw

CORE_RTL  := rtl/kc_isa_pkg.sv $(wildcard rtl/core/*.sv) $(wildcard rtl/mem/*.sv) \
             $(wildcard rtl/soc/*.sv)
CORE_TBS  := datapath_tb program_mem_tb
CORE_PROG := t_zmmul t_uart t_illegal t_mmio t_lanectl t_cpi
PLUSARGS  ?=

TB_TARGETS += $(addprefix tb-core-,$(CORE_TBS) $(CORE_PROG)) lint-core

# Test programs -> imem/dmem images
$(CORE_SW_OBJ)/%.elf: tb/core/sw/%.S tb/core/sw/kc_test.h tb/core/sw/test.ld
	@mkdir -p $(CORE_SW_OBJ)
	$(RISCV_PREFIX)gcc $(CORE_SW_FLAGS) -Itb/core/sw $< -o $@

$(CORE_SW_OBJ)/%_imem.hex $(CORE_SW_OBJ)/%_dmem.hex: $(CORE_SW_OBJ)/%.elf tb/core/sw/bin2hex.py
	$(RISCV_PREFIX)objcopy -O binary -j .text $< $(CORE_SW_OBJ)/$*_imem.bin
	$(RISCV_PREFIX)objcopy -O binary -j .data $< $(CORE_SW_OBJ)/$*_dmem.bin
	python3 tb/core/sw/bin2hex.py $(CORE_SW_OBJ)/$*_imem.bin $(CORE_SW_OBJ)/$*_imem.hex 8192
	python3 tb/core/sw/bin2hex.py $(CORE_SW_OBJ)/$*_dmem.bin $(CORE_SW_OBJ)/$*_dmem.hex 8192 0x100

.PRECIOUS: $(CORE_SW_OBJ)/%.elf $(CORE_SW_OBJ)/%_imem.hex $(CORE_SW_OBJ)/%_dmem.hex

CORE_VL = $(VERILATOR) $(VL_TB) -Itb/core -Mdir $(OBJ)/core_$(1) --top-module $(1) \
          $(CORE_RTL) tb/core/$(1).sv

tb-core-datapath_tb:
	@mkdir -p $(OBJ)
	$(call CORE_VL,datapath_tb)
	$(OBJ)/core_datapath_tb/Vdatapath_tb $(PLUSARGS)

tb-core-program_mem_tb:
	@mkdir -p $(OBJ)
	$(call CORE_VL,program_mem_tb) -GIMEM_HEX='"$(CURDIR)/tb/core/program.mem"'
	$(OBJ)/core_program_mem_tb/Vprogram_mem_tb $(PLUSARGS)

$(addprefix tb-core-,$(CORE_PROG)): tb-core-%: $(CORE_SW_OBJ)/%_imem.hex $(CORE_SW_OBJ)/%_dmem.hex
	$(call CORE_VL,$*_tb) -GIMEM_HEX='"$(CURDIR)/$(CORE_SW_OBJ)/$*_imem.hex"' \
	    -GDMEM_HEX='"$(CURDIR)/$(CORE_SW_OBJ)/$*_dmem.hex"'
	$(OBJ)/core_$*_tb/V$*_tb $(PLUSARGS)

lint-core:
	$(VERILATOR) $(VL_LINT) --top-module kc_soc $(CORE_RTL)
	$(VERILATOR) $(VL_LINT) --top-module kc_soc -GLANES=8 $(CORE_RTL)
