# QRCP unit checks (D22). Run from the repo root through `make check`.
#
#   tb-qrcp-model    host C: tb/qrcp/qrcp_model.h (rtl/core/qrcp.sv step by
#                    step, register widths included) against the normative
#                    qrcp() of game/src/fixed.c, linked unchanged, on every
#                    QRCP_STRIDE-th input plus the edge classes; also checks
#                    that sw/tests/t_qrcp_buckets.inc matches fixed.c
#   tb-qrcp-unit     rtl/core/qrcp.sv alone (qrcp_unit_tb) against golden
#                    vectors from the same program: the edge classes and
#                    2 x QRCP_RANDOM random inputs (QRCP_SEED)
#   tb-qrcp-pipe-eq  rtl/core_pipe/qrcp_pipe.sv (core_pipe's pipelined unit)
#                    against rtl/core/qrcp.sv (qrcp_pipe_eq_tb): the edge
#                    classes and QRCP_PIPE_RANDOM random inputs (QRCP_SEED),
#                    identical y required
#
# Not in `make check`: `make qrcp-exhaustive` runs the model check on all
# 2^32 inputs (about a minute on one thread), and `make qrcp-bench-inc`
# regenerates sw/tests/t_qrcp_buckets.inc (the expected table of the bench
# self-test's seed ROM pass, one input per bucket) from fixed.c.
#
# fixed.c needs the RCP constants that game/tools/gen_assets.py writes into
# kc_tables.h. The core tests with QRCP are in tb/core/tb.mk (t_qrcp).

HOST_CC     ?= zig cc
QRCP_STRIDE ?= 251
QRCP_RANDOM ?= 20000
QRCP_SEED   ?= 0x4B43
QRCP_PIPE_RANDOM ?= 1000000
QR_OBJ      := $(OBJ)/qrcp

TB_TARGETS += tb-qrcp-model tb-qrcp-unit tb-qrcp-pipe-eq

$(QR_OBJ)/gen/kc_tables.h: game/tools/gen_assets.py
	@mkdir -p $(QR_OBJ)/gen
	python3 game/tools/gen_assets.py $(QR_OBJ)/gen > /dev/null

$(QR_OBJ)/qrcp_check: tb/qrcp/qrcp_check.c tb/qrcp/qrcp_model.h game/src/fixed.c \
                      game/src/fixed.h $(QR_OBJ)/gen/kc_tables.h
	$(HOST_CC) -std=c11 -O2 -fwrapv -Wall -Wextra -Igame/src -I$(QR_OBJ)/gen -Itb/qrcp \
	    tb/qrcp/qrcp_check.c game/src/fixed.c -o $@

tb-qrcp-model: $(QR_OBJ)/qrcp_check
	$(QR_OBJ)/qrcp_check stride $(QRCP_STRIDE)
	$(QR_OBJ)/qrcp_check buckets $(QR_OBJ)/t_qrcp_buckets.inc
	cmp $(QR_OBJ)/t_qrcp_buckets.inc sw/tests/t_qrcp_buckets.inc

qrcp-bench-inc: $(QR_OBJ)/qrcp_check
	$(QR_OBJ)/qrcp_check buckets sw/tests/t_qrcp_buckets.inc

qrcp-exhaustive: $(QR_OBJ)/qrcp_check
	$(QR_OBJ)/qrcp_check all

$(QR_OBJ)/vectors.txt: $(QR_OBJ)/qrcp_check
	$(QR_OBJ)/qrcp_check vectors $@ $(QRCP_RANDOM) $(QRCP_SEED)

tb-qrcp-unit: $(QR_OBJ)/vectors.txt
	$(VERILATOR) $(VL_TB) --top-module qrcp_unit_tb -Mdir $(QR_OBJ)/unit \
	    rtl/core/qrcp.sv tb/qrcp/qrcp_unit_tb.sv
	$(QR_OBJ)/unit/Vqrcp_unit_tb +vectors=$(CURDIR)/$(QR_OBJ)/vectors.txt

.PHONY: qrcp-exhaustive qrcp-bench-inc

tb-qrcp-pipe-eq:
	$(VERILATOR) $(VL_TB) --top-module qrcp_pipe_eq_tb -Mdir $(QR_OBJ)/pipe_eq \
	    rtl/core/qrcp.sv rtl/core_pipe/qrcp_pipe.sv tb/qrcp/qrcp_pipe_eq_tb.sv
	$(QR_OBJ)/pipe_eq/Vqrcp_pipe_eq_tb +random=$(QRCP_PIPE_RANDOM) \
	    +seed=$(patsubst 0x%,%,$(QRCP_SEED))
