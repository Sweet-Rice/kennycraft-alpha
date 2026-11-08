# VTRACE ray unit testbench and lint (P6). Run from the repo root through
# `make check`.
#
#   tb-vtrace-l2   vtrace_tb at WORLD_LATENCY = 2 (two world copies, D17), with
#                  a model of rtl/mem/world_mem.sv's two-phase reads
#   tb-vtrace-l1   vtrace_tb at WORLD_LATENCY = 1 (registered read)
#   lint-vtrace    verilator -Wall over rtl/vtrace at both latencies and LANES = 1
#
# Golden vectors come from tb/vtrace/golden.c, a host program linking
# Kennedy's game/src/trace.c and fixed.c unchanged (fixed.c needs the 1/x table
# that game/tools/gen_assets.py writes). VTRACE_SEED picks the random world
# and rays.

HOST_CC     ?= zig cc
VTRACE_SEED ?= 0x4B43
VT_OBJ      := $(OBJ)/vtrace
VT_DATA     := $(VT_OBJ)/data
VT_RTL      := rtl/vtrace/vtrace.sv
VT_GAME     := game/src/trace.c game/src/fixed.c

TB_TARGETS += tb-vtrace-l2 tb-vtrace-l1 lint-vtrace

$(VT_OBJ)/gen/kc_tables.h: game/tools/gen_assets.py
	@mkdir -p $(VT_OBJ)/gen
	python3 game/tools/gen_assets.py $(VT_OBJ)/gen > /dev/null

$(VT_OBJ)/golden: tb/vtrace/golden.c $(VT_GAME) $(wildcard game/src/*.h) $(VT_OBJ)/gen/kc_tables.h
	$(HOST_CC) -std=c11 -O2 -fwrapv -Wall -Wextra -DKC_HOST -DKC_LANES=1 \
	    -Igame/src -I$(VT_OBJ)/gen tb/vtrace/golden.c $(VT_GAME) -o $@

$(VT_DATA)/rand_groups.hex: $(VT_OBJ)/golden
	@mkdir -p $(VT_DATA)
	$(VT_OBJ)/golden $(VT_DATA) $(VTRACE_SEED)

tb-vtrace-l2 tb-vtrace-l1: tb-vtrace-l%: $(VT_DATA)/rand_groups.hex
	@mkdir -p $(OBJ)
	$(VERILATOR) $(VL_TB) --top-module vtrace_tb -GWORLD_LATENCY=$* -Mdir $(OBJ)/vtrace_l$* \
	    $(VT_RTL) tb/vtrace/vtrace_tb.sv
	$(OBJ)/vtrace_l$*/Vvtrace_tb +data=$(CURDIR)/$(VT_DATA)

lint-vtrace:
	$(VERILATOR) $(VL_LINT) --top-module vtrace $(VT_RTL)
	$(VERILATOR) $(VL_LINT) --top-module vtrace -GWORLD_LATENCY=1 $(VT_RTL)
	$(VERILATOR) $(VL_LINT) --top-module vtrace -GLANES=1 $(VT_RTL)
