# DDR3 chunk store testbenches and lint (P2b). Run from the repo root through
# `make check`.
#
# Verilator 5.020 cannot parse Vivado's XPM sources (SVA sequences, deassign),
# so simulation and lint compile tb/ddr/xpm_sim.sv (behavioral xpm_fifo_async
# and xpm_cdc_single) in their place; synthesis uses the real XPM library.
# tb/ddr/unisim_sim.sv models MMCME2_BASE, BUFG and the generated mig_ddr3
# (as ddr_model) for ddr_clk and the standalone board test top.
#
#   t_chunk_roundtrip, t_slot_valid, t_ring  chunk_engine + ddr_bridge + ddr_model
#                                            + world_remap (P2b Done checks)
#   t_ddr_test   fpga/ddr_test/ddr_test_top.sv end to end with ddr_model
#   lint-ddr     verilator -Wall over every rtl/ddr module and the test top

DDR_RTL  := rtl/ddr/chunk_engine.sv rtl/ddr/ddr_bridge.sv rtl/ddr/world_remap.sv rtl/ddr/ddr_model.sv
DDR_SIM  := tb/ddr/xpm_sim.sv
DDR_TOP  := rtl/ddr/ddr_clk.sv fpga/ddr_test/ddr_test_top.sv fpga/ddr_test/ddr_test_uart_tx.sv tb/ddr/unisim_sim.sv
DDR_TBS  := t_chunk_roundtrip t_slot_valid t_ring
DDR_LINT := chunk_engine ddr_bridge world_remap ddr_model ddr_clk ddr_test_top

TB_TARGETS += $(addprefix tb-ddr-,$(DDR_TBS)) $(addsuffix -rdbuf,$(addprefix tb-ddr-,$(DDR_TBS))) \
              tb-ddr-t_ddr_test lint-ddr

$(addprefix tb-ddr-,$(DDR_TBS)): tb-ddr-%:
	@mkdir -p $(OBJ)
	$(VERILATOR) $(VL_TB) -Itb/ddr --top-module $* -Mdir $(OBJ)/ddr_$* $(DDR_RTL) $(DDR_SIM) tb/ddr/$*.sv
	$(OBJ)/ddr_$*/V$*

# The same tests with the engine's LOAD beat buffer (chunk_engine RD_BUF = 1,
# the pipelined top's setting).
$(addsuffix -rdbuf,$(addprefix tb-ddr-,$(DDR_TBS))): tb-ddr-%-rdbuf:
	@mkdir -p $(OBJ)
	$(VERILATOR) $(VL_TB) -Itb/ddr +define+KC_RD_BUF --top-module $* -Mdir $(OBJ)/ddr_$*_rdbuf $(DDR_RTL) $(DDR_SIM) tb/ddr/$*.sv
	$(OBJ)/ddr_$*_rdbuf/V$*

tb-ddr-t_ddr_test:
	@mkdir -p $(OBJ)
	$(VERILATOR) $(VL_TB) --top-module t_ddr_test -Mdir $(OBJ)/ddr_t_ddr_test $(DDR_RTL) $(DDR_SIM) $(DDR_TOP) tb/ddr/t_ddr_test.sv
	$(OBJ)/ddr_t_ddr_test/Vt_ddr_test

lint-ddr:
	@for m in $(DDR_LINT); do \
	  echo "lint-ddr: $$m"; \
	  $(VERILATOR) $(VL_LINT) --timing --top-module $$m $(DDR_RTL) $(DDR_SIM) $(DDR_TOP) || exit 1; \
	done
