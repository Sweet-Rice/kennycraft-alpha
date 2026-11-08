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
#   tracediff-core-pipe-<t> the multi-cycle (tb-core-<t>) and pipelined builds
#                           of the same test with +trace, retire traces
#                           compared without cycle numbers
#                           (tb/core_pipe/tracediff_pipe.py)
#   lint-core-pipe          verilator -Wall over kc_soc with PIPELINED = 1 at
#                           LANES = 1, 3 and 8 and every HAS_DIV_STACK,
#                           HAS_RAY_UNIT, HAS_QRCP combination, one target
#                           per run (lint-core-pipe-l<L>-d<D>r<R>q<Q>)
#
# Not in `make check`: tracediff-core-pipe-<t> for the tests whose trace
# depends on timing (CORE_PIPE_TIMED). They read CYCLES or poll UART_STATUS,
# FB_SWAP or a byte the testbench sends, so loaded values and loop counts
# change with the CPI. Run them by hand to see the first difference. t_cpi
# has no tracediff: its CYCLES values are its output.
#
# CORE_PIPE=0 builds the same targets with PIPELINED = 0 (the multi-cycle
# core), which checks the rules and the comparator on identical cores.

ifeq ($(CORE_ALL),)
$(error tb/core_pipe/tb.mk needs tb/core/tb.mk included first)
endif

CORE_PIPE       ?= 1
CORE_PIPE_G     := -GPIPELINED="1'b$(CORE_PIPE)"
# Lines at the end of the multi-cycle trace that the pipelined run may not
# have retired yet when the testbench calls $finish (tracediff_pipe.py --tail)
CORE_PIPE_TAIL  ?= 2
CORE_PIPE_TIMED := t_mmio t_mmio_lanes t_mmio_lanes-l8 t_uart program_mem_tb
CORE_PIPE_NAMES :=

# $(call CORE_PIPE_RULES,name,tb module,obj suffix,flags,hex images)
# for the test tb/core/tb.mk builds as tb-core-<name>
define CORE_PIPE_RULES
CORE_PIPE_NAMES += $(1)

tb-core-pipe-$(1): $(5)
	@mkdir -p $(OBJ)
	$$(call CORE_VL,$(2),$(3)_pipe,$(4) $$(CORE_PIPE_G))
	$$(call core_bin,$(2),$(3)_pipe) $$(PLUSARGS)

tracediff-core-pipe-$(1): tb-core-$(1) tb-core-pipe-$(1)
	python3 tb/core_pipe/tracediff_pipe.py --tail $$(CORE_PIPE_TAIL) $(1)@pipe \
	    $$(call core_bin,$(2),$(3)) $$(call core_bin,$(2),$(3)_pipe)
endef

$(foreach t,$(filter-out t_cpi,$(CORE_ALL)),$(eval $(call CORE_PIPE_RULES,$(t),$(call \
    core_tb,$(t)),,,$(call core_hex_deps,$(t)))))
$(foreach t,$(CORE_L8),$(eval $(call CORE_PIPE_RULES,$(t)-l8,$(call core_tb,$(t)),_l8, \
    -GLANES=8,$(call core_hex_deps,$(t)))))
$(eval $(call CORE_PIPE_RULES,t_illegal-ray,t_illegal_tb,_ray, \
    -GLANES=8 -GHAS_DIV_STACK="1'b1" -GHAS_RAY_UNIT="1'b1",$(call core_hex_deps,t_illegal)))
$(eval $(call CORE_PIPE_RULES,t_illegal-qrcp,t_illegal_tb,_qrcp,$(CORE_S2Q), \
    $(call core_hex_deps,t_illegal)))
$(eval $(call CORE_PIPE_RULES,t_qrcp,t_qrcp_tb,,-GHAS_QRCP="1'b1",$(CORE_QRCP_HEX)))
$(eval $(call CORE_PIPE_RULES,t_qrcp-l8,t_qrcp_tb,_l8,$(CORE_S2Q),$(CORE_QRCP_HEX)))

# t_cpi with the pipelined expectations. CORE_PIPE_CPI_G: -G overrides of
# t_cpi_pipe_tb's CPI parameters.
CORE_PIPE_CPI_G ?=
tb-core-pipe-t_cpi: $(call core_hex_deps,t_cpi)
	@mkdir -p $(OBJ)
	$(VERILATOR) $(VL_TB) -Itb/core -Mdir $(OBJ)/core_t_cpi_pipe_tb --top-module t_cpi_pipe_tb \
	    $(CORE_RTL) tb/core_pipe/t_cpi_pipe_tb.sv $(CORE_HEX_t_cpi_tb) $(CORE_PIPE_G) \
	    $(CORE_PIPE_CPI_G)
	$(OBJ)/core_t_cpi_pipe_tb/Vt_cpi_pipe_tb $(PLUSARGS)

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

TB_TARGETS += $(addprefix tb-core-pipe-,$(CORE_PIPE_NAMES) t_cpi) lint-core-pipe \
              $(addprefix tracediff-core-pipe-,$(filter-out $(CORE_PIPE_TIMED),$(CORE_PIPE_NAMES)))

.PHONY: $(addprefix tracediff-core-pipe-,$(filter $(CORE_PIPE_TIMED),$(CORE_PIPE_NAMES))) \
        $(CORE_PIPE_LINT)
