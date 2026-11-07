#!/bin/sh
# Patch new memory images into a built top bitstream with updatemem, no
# Vivado rebuild, and optionally program the board.
#
#   fpga/patch_bit.sh <build_dir> <hex_dir> <out_dir> [program]
#
# build_dir  a KC_TARGET=top build output (top.bit, kc.mmi from fpga/build.tcl)
# hex_dir    kc_imem.hex, kc_dmem.hex, textures.hex in the formats
#            rtl/top.sv reads with $readmemh (`make top-hex` writes them to
#            obj_dir/top_hex). The palette is not patchable (see
#            fpga/build.tcl); palette.hex changes need a rebuild.
# out_dir    gets the MEM files and patched.bit
# program    program patched.bit (fpga/program.tcl) under the fpga-tools MCP
#            hardware lock, FPGA_STATE (default ../.fpga-state)
#
# The updatemem command it runs, per fpga/build.tcl:
#   updatemem -force -meminfo kc.mmi -bit top.bit \
#     -data kc_imem.mem -proc imem -data kc_dmem.mem -proc dmem \
#     -data textures.mem -proc tex \
#     -out patched.bit
set -eu
[ $# -ge 3 ] || { echo "usage: $0 <build_dir> <hex_dir> <out_dir> [program]" >&2; exit 2; }
build=$1 hex=$2 out=$3
root=$(cd "$(dirname "$0")/.." && pwd)
bin=${VIVADO_BIN:-/home/tai/AMD/2026.1/Vivado/bin}
state=${FPGA_STATE:-$root/../../.fpga-state}

mkdir -p "$out"
python3 "$root/fpga/hex2mem.py" "$hex/kc_imem.hex"  "$out/kc_imem.mem"  32
python3 "$root/fpga/hex2mem.py" "$hex/kc_dmem.hex"  "$out/kc_dmem.mem"  32
python3 "$root/fpga/hex2mem.py" "$hex/textures.hex" "$out/textures.mem" 4

"$bin/updatemem" -force -meminfo "$build/kc.mmi" -bit "$build/top.bit" \
    -data "$out/kc_imem.mem"  -proc imem    -data "$out/kc_dmem.mem"  -proc dmem \
    -data "$out/textures.mem" -proc tex \
    -out "$out/patched.bit"

if [ "${4:-}" = program ]; then
    flock -w 600 "$state/hardware.lock" \
        "$bin/vivado" -mode batch -nojournal -nolog -notrace \
        -source "$root/fpga/program.tcl" -tclargs "$out/patched.bit"
fi
