# ISA package checks (P0). Run from the repo root through `make check`.
#   tb-isa-encoding  Verilator C++ harness: every Tai_2 table row through
#                    rtl/isa_decode_check.sv, plus every illegal case.
#   tb-isa-asm       scripts/check_encoding.py: assembles sw/tests/encoding.S
#                    and compares the objdump words with the Tai_2 example hex.
#                    Set KC_WIKI=<wiki checkout> to also cross-check the table
#                    parsed from the wiki's Tai_2.md.
#   lint-isa         -Wall lint of the package and the decode module.

ISA_RTL      := rtl/kc_isa_pkg.sv rtl/isa_decode_check.sv
RISCV_PREFIX ?= /home/tai/AMD/2026.1/gnu/riscv/lin/bin/riscv64-unknown-elf-
KC_WIKI      ?=
PYTHON       ?= python3

TB_TARGETS += tb-isa-encoding tb-isa-asm lint-isa

tb-isa-encoding:
	@mkdir -p $(OBJ)
	$(VERILATOR) --cc --exe --build --build-jobs $(VL_BUILD_JOBS) --verilate-jobs 1 -Wall --top-module isa_decode_check \
		-Mdir $(OBJ)/isa_encoding -o Vtest_encoding \
		$(ISA_RTL) $(CURDIR)/tb/isa/test_encoding.cpp
	$(OBJ)/isa_encoding/Vtest_encoding

tb-isa-asm:
	RISCV_PREFIX=$(RISCV_PREFIX) $(PYTHON) scripts/check_encoding.py \
		$(if $(KC_WIKI),--wiki $(KC_WIKI)/Tai_2.md)

lint-isa:
	$(VERILATOR) $(VL_LINT) --top-module isa_decode_check $(ISA_RTL)
