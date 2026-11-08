# QRCP unit checks (D22). Run from the repo root through `make check`.
#
#   tb-qrcp-model    host C: tb/qrcp/qrcp_model.h (rtl/core/qrcp.sv step by
#                    step, register widths included) against the normative
#                    qrcp() of game/src/fixed.c, linked unchanged, on every
#                    QRCP_STRIDE-th input plus the edge classes
#   tb-qrcp-unit     rtl/core/qrcp.sv alone (qrcp_unit_tb) against golden
#                    vectors from the same program: the edge classes and
#                    2 x QRCP_RANDOM random inputs (QRCP_SEED)
#
# Not in `make check`: `make qrcp-exhaustive` runs the model check on all
# 2^32 inputs (about a minute on one thread).
#
# fixed.c needs the RCP constants that game/tools/gen_assets.py writes into
# kc_tables.h. The core tests with QRCP are in tb/core/tb.mk (t_qrcp).

HOST_CC     ?= zig cc
QRCP_STRIDE ?= 251
QRCP_RANDOM ?= 20000
QRCP_SEED   ?= 0x4B43
QR_OBJ      := $(OBJ)/qrcp

TB_TARGETS += tb-qrcp-model tb-qrcp-unit

$(QR_OBJ)/gen/kc_tables.h: game/tools/gen_assets.py
	@mkdir -p $(QR_OBJ)/gen
	python3 game/tools/gen_assets.py $(QR_OBJ)/gen > /dev/null

$(QR_OBJ)/qrcp_check: tb/qrcp/qrcp_check.c tb/qrcp/qrcp_model.h game/src/fixed.c \
                      game/src/fixed.h $(QR_OBJ)/gen/kc_tables.h
	$(HOST_CC) -std=c11 -O2 -fwrapv -Wall -Wextra -Igame/src -I$(QR_OBJ)/gen -Itb/qrcp \
	    tb/qrcp/qrcp_check.c game/src/fixed.c -o $@

tb-qrcp-model: $(QR_OBJ)/qrcp_check
	$(QR_OBJ)/qrcp_check stride $(QRCP_STRIDE)

qrcp-exhaustive: $(QR_OBJ)/qrcp_check
	$(QR_OBJ)/qrcp_check all

$(QR_OBJ)/vectors.txt: $(QR_OBJ)/qrcp_check
	$(QR_OBJ)/qrcp_check vectors $@ $(QRCP_RANDOM) $(QRCP_SEED)

tb-qrcp-unit: $(QR_OBJ)/vectors.txt
	$(VERILATOR) $(VL_TB) --top-module qrcp_unit_tb -Mdir $(QR_OBJ)/unit \
	    rtl/core/qrcp.sv tb/qrcp/qrcp_unit_tb.sv
	$(QR_OBJ)/unit/Vqrcp_unit_tb +vectors=$(CURDIR)/$(QR_OBJ)/vectors.txt

.PHONY: qrcp-exhaustive
