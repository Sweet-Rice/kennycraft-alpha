# Pipelined core (P8, rtl/core_pipe) testbenches and lint, registered with
# `make check` (run from the repo root). Built from tb/core/tb.mk's variables
# and rules (CORE_VL, CORE_HEX_*, CORE_S2Q, ...), so this file must be
# included after it: the top Makefile includes $(wildcard tb/*/tb.mk), which
# GNU make sorts, and tb/core/ sorts before tb/core_pipe/.
#
#   tb-core-pipe-<t>        every tb/core test tb-core-<t> (CORE_ALL, the -l8
#                           variants, t_illegal-ray, t_illegal-qrcp, t_qrcp,
#                           t_qrcp-l8) built with PIPELINED = 1 into
#                           $(OBJ)/core_<tb><suffix>_pipe
#   tb-core-pipe-t_cpi      tb/core_pipe/t_cpi_pipe_tb.sv: t_cpi.S checked
#                           against the pipelined stall model instead of the
#                           multi-cycle state machine
#   tb-core-pipe-t_qrcp(-l8)
#                           tb/core_pipe/t_qrcp_pipe_tb.sv: t_qrcp.S with
#                           core_pipe's QRCP latency (3 cycles after the
#                           previous retirement, 5 after a flush) instead
#                           of the multi-cycle 7
#   tb-core-pipe-t_mmio     tb/core_pipe/t_mmio_pipe_tb.sv: t_mmio.S with its
#                           two CYCLES checks at the pipelined MMIO LW and SW
#                           CPI (2 and 2: deltas 2 and 42 instead of 5 and 47)
#   tb-core-pipe-t_vtrace_async
#                           t_vtrace_async on core_pipe (the testbench takes
#                           PIPELINED for its VTRACE x0 retire spacing)
#   tracediff-core-pipe-<t> the multi-cycle (tb-core-<t>) and pipelined builds
#                           of the same test with +trace, retire traces
#                           compared without cycle numbers
#                           (tb/core_pipe/tracediff_pipe.py), every test
#   tb-core-pipe-t_pipe_stress(-ref), tracediff-core-pipe-t_pipe_stress
#                           tb/core_pipe/sw/t_pipe_stress.S: back-to-back
#                           hazards (forwarding, load-use, MUL, QRCP,
#                           VSET/VTRACE/VGET, mask writers, DIF/DELSE, JALR)
#                           on the Stage 2 core with QRCP, self-checking, on
#                           both cores, traces compared
#   tb-core-pipe-t_dwin(-ref), tracediff-core-pipe-t_dwin
#                           tb/core_pipe/sw/t_dwin.S: loads and stores in the
#                           dmem window that core_pipe keeps in distributed
#                           RAM (bank conflicts, coalescing, mixed window and
#                           BRAM lanes, aliases, edges, initial contents),
#                           memory checked, on both cores, traces compared
#   lint-core-pipe          verilator -Wall over kc_soc with PIPELINED = 1 at
#                           LANES = 1, 3 and 8 and every HAS_DIV_STACK,
#                           HAS_RAY_UNIT, HAS_QRCP combination, one target
#                           per run (lint-core-pipe-l<L>-d<D>r<R>q<Q>)
#
# Timing deltas. Some traces depend on the CPI: they read CYCLES or poll
# UART_STATUS, FB_SWAP or a flag the testbench writes, so loaded values and
# loop counts differ. CORE_PIPE_TD_<t> lists them per test for
# tracediff_pipe.py: --poll ADDR:NAME turns each loop around a load from
# ADDR into one line and prints its iteration counts on both cores; --mask
# ADDR:NAME masks the values loaded from ADDR and everything computed from
# them and prints both values. Nothing else may differ.
#
# CORE_PIPE=0 builds the same targets with PIPELINED = 0 (the multi-cycle
# core), which checks the rules and the comparator on identical cores.

ifeq ($(CORE_ALL),)
$(error tb/core_pipe/tb.mk needs tb/core/tb.mk included first)
endif

CORE_PIPE       ?= 1
CORE_PIPE_G     := -GPIPELINED="1'b$(CORE_PIPE)"
# Every pipelined tb build also binds core_pipe_halt_check into core_pipe
CORE_PIPE_TB    := $(CORE_PIPE_G) tb/core_pipe/core_pipe_halt_check.sv
# Lines at the end of the multi-cycle trace that the pipelined run may not
# have retired yet when the testbench calls $finish (tracediff_pipe.py
# --tail). None so far: every testbench waits long enough after TB_DONE.
CORE_PIPE_TAIL  ?= 0
CORE_PIPE_NAMES :=

CORE_PIPE_CYCLES   := --mask 0x5000000c:CYCLES
CORE_PIPE_UART     := --poll 0x50000014:UART_STATUS
# TX-busy poll before every byte of "Hello, world!\r\n"
CORE_PIPE_TD_program_mem_tb := $(CORE_PIPE_UART)
# 15,000-cycle CYCLES wait, then RX-available and TX-busy polls per echo
CORE_PIPE_TD_t_uart := --poll 0x5000000c:CYCLES $(CORE_PIPE_UART)
# FB_SWAP pending poll; CYCLES around one LW and around CHUNK_CMD
CORE_PIPE_TD_t_mmio := --poll 0x50000000:FB_SWAP $(CORE_PIPE_CYCLES)
# wait for the testbench's TB_SELECT flag (after it has sent "ABC"); CYCLES
# read under every lane
CORE_PIPE_TD_t_mmio_lanes    := --poll 0x100000f0:TB_SELECT $(CORE_PIPE_CYCLES)
CORE_PIPE_TD_t_mmio_lanes-l8 := $(CORE_PIPE_TD_t_mmio_lanes)
# wait for the testbench's TB_SELECT flag (after it has sent eight UART bytes)
CORE_PIPE_TD_t_lsu_order    := --poll 0x100000f0:TB_SELECT
CORE_PIPE_TD_t_lsu_order-l8 := $(CORE_PIPE_TD_t_lsu_order)
# CYCLES before and after every class
CORE_PIPE_TD_t_cpi := $(CORE_PIPE_CYCLES)
# CYCLES around the async and sync overlap runs, read under every lane
CORE_PIPE_TD_t_vtrace_async := $(CORE_PIPE_CYCLES)

# $(call CORE_PIPE_RULES,name,tb module,obj suffix,flags,hex images[,variant])
# for the test tb/core/tb.mk builds as tb-core-<name>. With a variant, the
# pipelined build runs tb/core_pipe/<variant>.sv (same program and images,
# expectations for the pipelined core) instead of tb/core/<tb module>.sv;
# CORE_PIPE_VAR_G passes -G overrides to the variants.
CORE_PIPE_VAR_G ?=
CORE_PIPE_VL = $(VERILATOR) $(VL_TB) -Itb/core -Mdir $(OBJ)/core_$(1)$(2) --top-module $(1) \
               $(CORE_RTL) tb/core_pipe/$(1).sv $(CORE_HEX_$(3)) $(4) $(CORE_PIPE_VAR_G)
core_pipe_bin = $(if $(3),$(call core_bin,$(3),$(2)),$(call core_bin,$(1),$(2)_pipe))

define CORE_PIPE_RULES
CORE_PIPE_NAMES += $(1)

tb-core-pipe-$(1): $(5)
	@mkdir -p $(OBJ)
	$(if $(6),$$(call CORE_PIPE_VL,$(6),$(3),$(2),$(4) $$(CORE_PIPE_TB)), \
	    $$(call CORE_VL,$(2),$(3)_pipe,$(4) $$(CORE_PIPE_TB)))
	$(call core_pipe_bin,$(2),$(3),$(6)) $$(PLUSARGS)

tracediff-core-pipe-$(1): tb-core-$(1) tb-core-pipe-$(1)
	python3 tb/core_pipe/tracediff_pipe.py --tail $$(CORE_PIPE_TAIL) $$(CORE_PIPE_TD_$(1)) \
	    $(1)@pipe $$(call core_bin,$(2),$(3)) $(call core_pipe_bin,$(2),$(3),$(6))
endef

$(foreach t,$(filter-out t_cpi t_mmio,$(CORE_ALL)),$(eval $(call CORE_PIPE_RULES,$(t),$(call \
    core_tb,$(t)),,,$(call core_hex_deps,$(t)))))
$(foreach t,$(CORE_L8),$(eval $(call CORE_PIPE_RULES,$(t)-l8,$(call core_tb,$(t)),_l8, \
    -GLANES=8,$(call core_hex_deps,$(t)))))
$(eval $(call CORE_PIPE_RULES,t_illegal-ray,t_illegal_tb,_ray, \
    -GLANES=8 -GHAS_DIV_STACK="1'b1" -GHAS_RAY_UNIT="1'b1",$(call core_hex_deps,t_illegal)))
$(eval $(call CORE_PIPE_RULES,t_illegal-qrcp,t_illegal_tb,_qrcp,$(CORE_S2Q), \
    $(call core_hex_deps,t_illegal)))
# t_qrcp with core_pipe's QRCP latency (t_qrcp_pipe_tb.sv)
$(eval $(call CORE_PIPE_RULES,t_qrcp,t_qrcp_tb,,-GHAS_QRCP="1'b1",$(CORE_QRCP_HEX),t_qrcp_pipe_tb))
$(eval $(call CORE_PIPE_RULES,t_qrcp-l8,t_qrcp_tb,_l8,$(CORE_S2Q),$(CORE_QRCP_HEX),t_qrcp_pipe_tb))
# asynchronous VTRACE (tb/core/t_vtrace_async_tb.sv) on the Stage 2 core with QRCP
$(eval $(call CORE_PIPE_RULES,t_vtrace_async,t_vtrace_async_tb,,$(CORE_S2Q),$(CORE_VTA_HEX)))
# t_cpi with the pipelined stall model (t_cpi_pipe_tb.sv)
$(eval $(call CORE_PIPE_RULES,t_cpi,t_cpi_tb,,,$(call core_hex_deps,t_cpi),t_cpi_pipe_tb))
# t_mmio with its two CYCLES checks at the pipelined LW/SW CPI (t_mmio_pipe_tb.sv)
$(eval $(call CORE_PIPE_RULES,t_mmio,t_mmio_tb,,,$(call core_hex_deps,t_mmio),t_mmio_pipe_tb))

# Hazard stress on the Stage 2 core with QRCP (tb/core_pipe/sw/t_pipe_stress.S,
# t_pipe_stress_tb.sv): tb-core-pipe-t_pipe_stress-ref runs it on the
# multi-cycle core, tb-core-pipe-t_pipe_stress on core_pipe, and
# tracediff-core-pipe-t_pipe_stress compares the two traces.
CORE_PIPE_SW_OBJ := $(OBJ)/core_pipe_sw
CORE_PIPE_STRESS_HEX := $(CORE_PIPE_SW_OBJ)/t_pipe_stress_imem.hex \
                        $(CORE_PIPE_SW_OBJ)/t_pipe_stress_dmem.hex
CORE_HEX_t_pipe_stress_tb := -GIMEM_HEX='"$(CURDIR)/$(CORE_PIPE_SW_OBJ)/t_pipe_stress_imem.hex"' \
                             -GDMEM_HEX='"$(CURDIR)/$(CORE_PIPE_SW_OBJ)/t_pipe_stress_dmem.hex"'

$(CORE_PIPE_SW_OBJ)/%.elf: tb/core_pipe/sw/%.S tb/core/sw/kc_test.h tb/core/sw/kc_lanes.h \
                           tb/core/sw/test.ld
	@mkdir -p $(CORE_PIPE_SW_OBJ)
	$(RISCV_PREFIX)gcc $(CORE_SW_FLAGS) -Itb/core/sw $< -o $@

$(CORE_PIPE_SW_OBJ)/%_imem.hex $(CORE_PIPE_SW_OBJ)/%_dmem.hex: $(CORE_PIPE_SW_OBJ)/%.elf \
                                                               tb/core/sw/bin2hex.py
	$(RISCV_PREFIX)objcopy -O binary -j .text $< $(CORE_PIPE_SW_OBJ)/$*_imem.bin
	$(RISCV_PREFIX)objcopy -O binary -j .data $< $(CORE_PIPE_SW_OBJ)/$*_dmem.bin
	python3 tb/core/sw/bin2hex.py $(CORE_PIPE_SW_OBJ)/$*_imem.bin $(CORE_PIPE_SW_OBJ)/$*_imem.hex 8192
	python3 tb/core/sw/bin2hex.py $(CORE_PIPE_SW_OBJ)/$*_dmem.bin $(CORE_PIPE_SW_OBJ)/$*_dmem.hex \
	    8192 0x100

.PRECIOUS: $(CORE_PIPE_SW_OBJ)/%.elf $(CORE_PIPE_SW_OBJ)/%_imem.hex $(CORE_PIPE_SW_OBJ)/%_dmem.hex

tb-core-pipe-t_pipe_stress-ref: $(CORE_PIPE_STRESS_HEX)
	@mkdir -p $(OBJ)
	$(call CORE_PIPE_VL,t_pipe_stress_tb,,t_pipe_stress_tb,$(CORE_S2Q))
	$(call core_bin,t_pipe_stress_tb) $(PLUSARGS)

tb-core-pipe-t_pipe_stress: $(CORE_PIPE_STRESS_HEX)
	@mkdir -p $(OBJ)
	$(call CORE_PIPE_VL,t_pipe_stress_tb,_pipe,t_pipe_stress_tb,$(CORE_S2Q) $(CORE_PIPE_TB))
	$(call core_bin,t_pipe_stress_tb,_pipe) $(PLUSARGS)

tracediff-core-pipe-t_pipe_stress: tb-core-pipe-t_pipe_stress-ref tb-core-pipe-t_pipe_stress
	python3 tb/core_pipe/tracediff_pipe.py --tail $(CORE_PIPE_TAIL) t_pipe_stress@pipe \
	    $(call core_bin,t_pipe_stress_tb) $(call core_bin,t_pipe_stress_tb,_pipe)

# dmem window (tb/core_pipe/sw/t_dwin.S, t_dwin_tb.sv): loads and stores in
# dmem 0x6000..0x7FFF, which core_pipe serves from distributed RAM, on both
# cores, with the memory checked through dmem_rd and the traces compared.
CORE_PIPE_DWIN_HEX := $(CORE_PIPE_SW_OBJ)/t_dwin_imem.hex $(CORE_PIPE_SW_OBJ)/t_dwin_dmem.hex
CORE_HEX_t_dwin_tb := -GIMEM_HEX='"$(CURDIR)/$(CORE_PIPE_SW_OBJ)/t_dwin_imem.hex"' \
                      -GDMEM_HEX='"$(CURDIR)/$(CORE_PIPE_SW_OBJ)/t_dwin_dmem.hex"'

tb-core-pipe-t_dwin-ref: $(CORE_PIPE_DWIN_HEX)
	@mkdir -p $(OBJ)
	$(call CORE_PIPE_VL,t_dwin_tb,,t_dwin_tb,$(CORE_S2Q))
	$(call core_bin,t_dwin_tb) $(PLUSARGS)

tb-core-pipe-t_dwin: $(CORE_PIPE_DWIN_HEX)
	@mkdir -p $(OBJ)
	$(call CORE_PIPE_VL,t_dwin_tb,_pipe,t_dwin_tb,$(CORE_S2Q) $(CORE_PIPE_TB))
	$(call core_bin,t_dwin_tb,_pipe) $(PLUSARGS)

tracediff-core-pipe-t_dwin: tb-core-pipe-t_dwin-ref tb-core-pipe-t_dwin
	python3 tb/core_pipe/tracediff_pipe.py --tail $(CORE_PIPE_TAIL) t_dwin@pipe \
	    $(call core_bin,t_dwin_tb) $(call core_bin,t_dwin_tb,_pipe)

# Lint matrix: LANES x HAS_DIV_STACK x HAS_RAY_UNIT x HAS_QRCP
define CORE_PIPE_LINT_RULE
CORE_PIPE_LINT += lint-core-pipe-l$(1)-d$(2)r$(3)q$(4)
lint-core-pipe-l$(1)-d$(2)r$(3)q$(4):
	$$(VERILATOR) $$(VL_LINT) --top-module kc_soc -GPIPELINED="1'b1" -GLANES=$(1) \
	    -GHAS_DIV_STACK="1'b$(2)" -GHAS_RAY_UNIT="1'b$(3)" -GHAS_QRCP="1'b$(4)" $$(CORE_RTL)
endef
CORE_PIPE_LINT :=
$(foreach l,1 3 8,$(foreach d,0 1,$(foreach r,0 1,$(foreach q,0 1, \
    $(eval $(call CORE_PIPE_LINT_RULE,$(l),$(d),$(r),$(q)))))))

lint-core-pipe: $(CORE_PIPE_LINT)

TB_TARGETS += $(addprefix tb-core-pipe-,$(CORE_PIPE_NAMES)) lint-core-pipe \
              $(addprefix tracediff-core-pipe-,$(CORE_PIPE_NAMES)) \
              tb-core-pipe-t_pipe_stress-ref tb-core-pipe-t_pipe_stress \
              tracediff-core-pipe-t_pipe_stress \
              tb-core-pipe-t_dwin-ref tb-core-pipe-t_dwin tracediff-core-pipe-t_dwin

.PHONY: $(CORE_PIPE_LINT)
