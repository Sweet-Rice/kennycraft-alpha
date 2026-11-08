# KennyCraft top-level make.
#
# `make check` runs every target registered by a tb/<area>/tb.mk fragment.
# Each fragment appends its testbench and -Wall lint targets to TB_TARGETS,
# so areas never edit each other's rules. Bennett's sim, vl, board and keys
# targets (Bennett wiki page, Make targets) land here as they come up.
#
# `make check` runs the targets JOBS at a time (default: every hardware
# thread, or the -j given on the command line), with each target's output
# kept together, and builds each testbench's C++ with one job so the
# targets share the machine instead of each spawning nproc compilers.
# Verilation itself stays single-threaded (--verilate-jobs 1).
#
# Every VL_TB testbench links one copy of Verilator's runtime library
# (verilated.o, verilated_timing.o, verilated_threads.o), built once in
# $(VLRT) from a one-line module with the same flags, instead of
# recompiling it per testbench (most of each small test's build time).

VERILATOR     ?= verilator
VL_BUILD_JOBS ?= 0
OBJ           := obj_dir
VLRT          := $(OBJ)/vlrt
VLRT_OBJS     := $(addprefix $(abspath $(VLRT))/,verilated.o verilated_timing.o verilated_threads.o)
VL_TB_BASE    := --binary --timing --build-jobs $(VL_BUILD_JOBS) --verilate-jobs 1 -Wno-fatal
VL_TB         ?= $(VL_TB_BASE) -MAKEFLAGS VK_GLOBAL_OBJS= -LDFLAGS "$(VLRT_OBJS)"
# Testbenches with their own C++ main (clocks driven from C++, no --timing),
# long runs, so their C++ is built at -O3 (Verilator's default is -Os)
VL_EXE        ?= --cc --exe --build --build-jobs $(VL_BUILD_JOBS) --verilate-jobs 1 -Wno-fatal \
                 -MAKEFLAGS OPT_FAST=-O3 -MAKEFLAGS OPT_GLOBAL=-O3
VL_LINT       ?= --lint-only -Wall
JOBS          ?= $(shell nproc)

# Inside check-all, Verilator's own make (--build) must not inherit this
# make's jobserver: it cannot use it and only warns.
ifeq ($(MAKECMDGOALS),check-all)
unexport MAKEFLAGS
endif

TB_TARGETS :=
include $(wildcard tb/*/tb.mk)

.PHONY: check check-all clean $(TB_TARGETS)

# Built before any testbench (order-only: the runtime never goes stale
# within one Verilator install; `make clean` removes it).
$(TB_TARGETS): | $(VLRT_OBJS)

$(VLRT_OBJS) &:
	@mkdir -p $(VLRT)
	printf 'module vlrt;\n  initial #1 $$finish;\nendmodule\n' > $(VLRT)/vlrt.sv
	$(VERILATOR) $(VL_TB_BASE) --top-module vlrt -Mdir $(VLRT) $(VLRT)/vlrt.sv

check:
	@$(MAKE) --no-print-directory $(if $(filter -j%,$(MAKEFLAGS)),,-j$(JOBS)) \
	    --output-sync=target VL_BUILD_JOBS=1 check-all

check-all: $(TB_TARGETS)
	@echo "make check: $(words $(TB_TARGETS)) target(s) passed"

clean:
	rm -rf $(OBJ)
