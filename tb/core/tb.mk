# Core testbenches and lint, registered with `make check` (run from the repo
# root).
#
#   tb-core-datapath_tb     directed tests poked into imem
#   tb-core-program_mem_tb  tb/core/program.mem (mkprog.py) through $readmemh
#   tb-core-t_zmmul, tb-core-t_uart, tb-core-t_illegal, tb-core-t_mmio,
#   tb-core-t_lanectl, tb-core-t_cpi
#                           programs in tb/core/sw/*.S, assembled with the
#                           RISC-V GCC, loaded as kc_imem/kc_dmem images
#   tb-core-t_laneid        Stage 1 rung 3, LANEID / MASKALL / scalar lane
#   tb-core-t_lsu_order, tb-core-t_mmio_lanes
#                           Stage 1 rung 4, lane-serial LSU and MMIO
#   tb-core-<t>-l8          the Stage 1 tests (CORE_L8) at LANES = 8
#   tracediff-core-<tb>     Stage 1 rung 2: the same test at LANES = 8 with
#                           only lane 0 able to activate (LANE0_ONLY), whose
#                           retirement trace must equal the LANES = 1 trace
#                           (tb/core/tracediff.py)
#   lint-core               verilator -Wall over rtl/core, rtl/mem, rtl/soc
#                           at LANES = 1 and LANES = 8
#
# Not in `make check`: `make tracediff-base-core` (Stage 1 rung 1) builds
# every test above against the Stage 0 core of git ref CORE_BASE_REF and
# compares its LANES = 1 trace with the current core's.
#
# `make tb-core-t_cpi` prints the measured CPI of every instruction class.
# Add PLUSARGS=+trace for a per-instruction retirement trace.

RISCV_PREFIX ?= /home/tai/AMD/2026.1/gnu/riscv/lin/bin/riscv64-unknown-elf-
CORE_SW_FLAGS := -march=rv32i_zmmul -mabi=ilp32 -nostdlib -nostartfiles \
                 -Wl,--build-id=none -Ttb/core/sw/test.ld
CORE_SW_OBJ   := $(OBJ)/core_sw

CORE_RTL_CORE := $(wildcard rtl/core/*.sv)
CORE_RTL_REST := $(wildcard rtl/mem/*.sv) $(wildcard rtl/soc/*.sv)
CORE_RTL      := rtl/kc_isa_pkg.sv $(CORE_RTL_CORE) $(CORE_RTL_REST)
CORE_TBS  := datapath_tb program_mem_tb
CORE_RUNG5 := t_mask t_ballot t_maskgetset t_mask_zero
CORE_RUNG6 := t_branch_uniform t_jalr_uniform
CORE_PROG := t_zmmul t_uart t_illegal t_mmio t_lanectl t_cpi t_laneid t_lsu_order t_mmio_lanes \
             $(CORE_RUNG5) $(CORE_RUNG6)
CORE_L8   := t_laneid t_lsu_order t_mmio_lanes $(CORE_RUNG5) $(CORE_RUNG6)
CORE_ALL  := $(CORE_TBS) $(CORE_PROG)
PLUSARGS  ?=

TB_TARGETS += $(addprefix tb-core-,$(CORE_ALL)) $(addprefix tracediff-core-,$(CORE_ALL)) \
              $(addsuffix -l8,$(addprefix tb-core-,$(CORE_L8))) lint-core

# Test programs -> imem/dmem images
$(CORE_SW_OBJ)/%.elf: tb/core/sw/%.S tb/core/sw/kc_test.h tb/core/sw/kc_lanes.h tb/core/sw/test.ld
	@mkdir -p $(CORE_SW_OBJ)
	$(RISCV_PREFIX)gcc $(CORE_SW_FLAGS) -Itb/core/sw $< -o $@

$(CORE_SW_OBJ)/%_imem.hex $(CORE_SW_OBJ)/%_dmem.hex: $(CORE_SW_OBJ)/%.elf tb/core/sw/bin2hex.py
	$(RISCV_PREFIX)objcopy -O binary -j .text $< $(CORE_SW_OBJ)/$*_imem.bin
	$(RISCV_PREFIX)objcopy -O binary -j .data $< $(CORE_SW_OBJ)/$*_dmem.bin
	python3 tb/core/sw/bin2hex.py $(CORE_SW_OBJ)/$*_imem.bin $(CORE_SW_OBJ)/$*_imem.hex 8192
	python3 tb/core/sw/bin2hex.py $(CORE_SW_OBJ)/$*_dmem.bin $(CORE_SW_OBJ)/$*_dmem.hex 8192 0x100

.PRECIOUS: $(CORE_SW_OBJ)/%.elf $(CORE_SW_OBJ)/%_imem.hex $(CORE_SW_OBJ)/%_dmem.hex

# Memory images per testbench
CORE_HEX_datapath_tb    :=
CORE_HEX_program_mem_tb := -GIMEM_HEX='"$(CURDIR)/tb/core/program.mem"'
$(foreach t,$(CORE_PROG),$(eval CORE_HEX_$(t)_tb := \
    -GIMEM_HEX='"$(CURDIR)/$(CORE_SW_OBJ)/$(t)_imem.hex"' \
    -GDMEM_HEX='"$(CURDIR)/$(CORE_SW_OBJ)/$(t)_dmem.hex"'))

# Testbench module of a test name (t_zmmul -> t_zmmul_tb, datapath_tb as is)
core_tb = $(if $(filter %_tb,$(1)),$(1),$(1)_tb)
core_hex_deps = $(if $(filter $(1),$(CORE_PROG)),$(CORE_SW_OBJ)/$(1)_imem.hex $(CORE_SW_OBJ)/$(1)_dmem.hex)

# $(call CORE_VL,tb module,obj suffix,extra flags[,rtl])
CORE_VL = $(VERILATOR) $(VL_TB) -Itb/core -Mdir $(OBJ)/core_$(1)$(2) --top-module $(1) \
          $(if $(4),$(4),$(CORE_RTL)) tb/core/$(1).sv $(CORE_HEX_$(1)) $(3)
core_bin = $(OBJ)/core_$(1)$(2)/V$(1)

define CORE_TB_RULES
tb-core-$(1): $(call core_hex_deps,$(1))
	@mkdir -p $(OBJ)
	$(call CORE_VL,$(call core_tb,$(1)))
	$(call core_bin,$(call core_tb,$(1))) $(PLUSARGS)

# Rung 2: LANES = 8, mask bits 7..1 pinned to 0, against LANES = 1
tracediff-core-$(1): tb-core-$(1)
	$(call CORE_VL,$(call core_tb,$(1)),_l8z,-GLANES=8 -GLANE0_ONLY=1)
	python3 tb/core/tracediff.py --lane0 $(1)@L8z $(call core_bin,$(call core_tb,$(1))) \
	    $(call core_bin,$(call core_tb,$(1)),_l8z)
endef
$(foreach t,$(CORE_ALL),$(eval $(call CORE_TB_RULES,$(t))))

# Stage 1 tests at LANES = 8, every lane free
define CORE_L8_RULES
tb-core-$(1)-l8: $(call core_hex_deps,$(1))
	@mkdir -p $(OBJ)
	$(call CORE_VL,$(call core_tb,$(1)),_l8,-GLANES=8)
	$(call core_bin,$(call core_tb,$(1)),_l8) $(PLUSARGS)
endef
$(foreach t,$(CORE_L8),$(eval $(call CORE_L8_RULES,$(t))))

# Rung 1: the Stage 0 core (git ref CORE_BASE_REF) against the current core,
# both at LANES = 1, same harness, same test images
CORE_BASE_REF ?= 16bccea
CORE_BASE_DIR := $(OBJ)/core_base_rtl

tracediff-base-core: $(addprefix tracediff-base-core-,$(CORE_ALL))

$(addprefix tracediff-base-core-,$(CORE_ALL)): tracediff-base-core-%: tb-core-%
	@rm -rf $(CORE_BASE_DIR)_$* && mkdir -p $(CORE_BASE_DIR)_$*
	git archive $(CORE_BASE_REF) rtl/core | tar -x -C $(CORE_BASE_DIR)_$*
	$(call CORE_VL,$(call core_tb,$*),_base,+define+KC_BASE_CORE, \
	    rtl/kc_isa_pkg.sv $$(ls $(CORE_BASE_DIR)_$*/rtl/core/*.sv) $(CORE_RTL_REST))
	python3 tb/core/tracediff.py $*@base $(call core_bin,$(call core_tb,$*),_base) \
	    $(call core_bin,$(call core_tb,$*))

.PHONY: tracediff-base-core $(addprefix tracediff-base-core-,$(CORE_ALL))

lint-core:
	$(VERILATOR) $(VL_LINT) --top-module kc_soc $(CORE_RTL)
	$(VERILATOR) $(VL_LINT) --top-module kc_soc -GLANES=8 $(CORE_RTL)
