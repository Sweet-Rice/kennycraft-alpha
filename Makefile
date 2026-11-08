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

VERILATOR     ?= verilator
VL_BUILD_JOBS ?= 0
VL_TB         ?= --binary --timing --build-jobs $(VL_BUILD_JOBS) --verilate-jobs 1 -Wno-fatal
# Testbenches with their own C++ main (clocks driven from C++, no --timing)
VL_EXE        ?= --cc --exe --build --build-jobs $(VL_BUILD_JOBS) --verilate-jobs 1 -Wno-fatal
VL_LINT       ?= --lint-only -Wall
OBJ           := obj_dir
JOBS          ?= $(shell nproc)

# Inside check-all, Verilator's own make (--build) must not inherit this
# make's jobserver: it cannot use it and only warns.
ifeq ($(MAKECMDGOALS),check-all)
unexport MAKEFLAGS
endif

TB_TARGETS :=
include $(wildcard tb/*/tb.mk)

.PHONY: check check-all clean $(TB_TARGETS)

check:
	@$(MAKE) --no-print-directory $(if $(filter -j%,$(MAKEFLAGS)),,-j$(JOBS)) \
	    --output-sync=target VL_BUILD_JOBS=1 check-all

check-all: $(TB_TARGETS)
	@echo "make check: $(words $(TB_TARGETS)) target(s) passed"

clean:
	rm -rf $(OBJ)
