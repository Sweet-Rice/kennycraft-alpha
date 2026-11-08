# Display testbenches and lint. Run from the repo root through `make check`.
# display_tb (FB_COUNT = 2) writes every captured frame and its expected image
# as PPMs into $(OBJ)/display; the rule then compares each pair byte for byte.
# display3_tb checks triple buffering (FB_COUNT = 3, D24) in the simulation
# itself: roles invariant, FB_SWAP read value, mailbox, promote, random swaps.

DISPLAY_RTL := rtl/display/sync2.sv rtl/display/vga_timing.sv rtl/display/framebuffer.sv \
               rtl/display/palette.sv rtl/display/display.sv
DISPLAY_TBS := display_tb
DISPLAY_PPM := mode0_frame1 mode0_frame2 mode1_frame1 mode1_frame2 swap_frame_before swap_frame_after

TB_TARGETS += $(addprefix tb-display-,$(DISPLAY_TBS)) tb-display-display3_tb lint-display

$(addprefix tb-display-,$(DISPLAY_TBS)): tb-display-%:
	@mkdir -p $(OBJ)/display
	$(VERILATOR) $(VL_TB) --timescale 1ns/1ps --top-module $* -Mdir $(OBJ)/display_$* $(DISPLAY_RTL) tb/display/$*.sv
	$(OBJ)/display_$*/V$* +outdir=$(OBJ)/display
	@for f in $(DISPLAY_PPM); do cmp $(OBJ)/display/$$f.ppm $(OBJ)/display/$${f}_expected.ppm || exit 1; done
	@echo "tb-display-$*: $(words $(DISPLAY_PPM)) PPM pairs identical"

tb-display-display3_tb:
	$(VERILATOR) $(VL_TB) --timescale 1ns/1ps --top-module display3_tb -Mdir $(OBJ)/display_display3_tb \
	  $(DISPLAY_RTL) tb/display/display3_tb.sv
	$(OBJ)/display_display3_tb/Vdisplay3_tb

lint-display:
	$(VERILATOR) $(VL_LINT) --top-module display $(DISPLAY_RTL)
	$(VERILATOR) $(VL_LINT) --top-module display -GFB_COUNT=3 $(DISPLAY_RTL)
	$(VERILATOR) $(VL_LINT) --top-module clk_gen rtl/display/clk_gen.sv
