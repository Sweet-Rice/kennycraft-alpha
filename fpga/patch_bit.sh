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
#            hardware lock: FPGA_STATE must name the MCP's state directory
#            (the one holding hardware.lock); there is no default
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

if [ -f "$hex/palette.hex" ] && ! cmp -s "$hex/palette.hex" "$build/palette.hex"; then
    echo "patch_bit.sh: $hex/palette.hex differs from the one built into $build;" >&2
    echo "  the palette (RAMB18) cannot be patched with updatemem 2026.1, rebuild instead" >&2
    exit 1
fi

mkdir -p "$out"
python3 "$root/fpga/hex2mem.py" "$hex/kc_imem.hex"  "$out/kc_imem.mem"  32
python3 "$root/fpga/hex2mem.py" "$hex/kc_dmem.hex"  "$out/kc_dmem.mem"  32
python3 "$root/fpga/hex2mem.py" "$hex/textures.hex" "$out/textures.mem" 4

"$bin/updatemem" -force -meminfo "$build/kc.mmi" -bit "$build/top.bit" \
    -data "$out/kc_imem.mem"  -proc imem    -data "$out/kc_dmem.mem"  -proc dmem \
    -data "$out/textures.mem" -proc tex \
    -out "$out/patched.bit"

if [ "${4:-}" = program ]; then
    : "${FPGA_STATE:?set FPGA_STATE to the fpga-tools MCP state directory}"
    if [ ! -f "$FPGA_STATE/hardware.lock" ]; then
        echo "patch_bit.sh: $FPGA_STATE/hardware.lock not found; FPGA_STATE must be the MCP's state directory" >&2
        exit 2
    fi
    flock -w 600 "$FPGA_STATE/hardware.lock" \
        "$bin/vivado" -mode batch -nojournal -nolog -notrace \
        -source "$root/fpga/program.tcl" -tclargs "$out/patched.bit"
fi
