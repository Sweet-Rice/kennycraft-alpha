#!/bin/sh
# Load Bad Apple into DDR3 on the board and start the player, on an existing
# top_s2p100 bitstream (no rebuild).
#
#   FPGA_STATE=<fpga-mcp state dir> badapple/board.sh <build_dir> <img_dir> <out_dir>
#
# img_dir is badapple/build.py's output. Every image is patched first
# (fpga/patch_bit.sh, about 15 s each), then the passes are programmed back
# to back and the player last, so DDR3 goes unrefreshed only while the FPGA
# is being configured. Each pass shows a green border when its chunks read
# back intact; the player's first screen shows every chunk (green intact,
# red damaged) and plays only when all are intact.
set -eu
[ $# -eq 3 ] || { echo "usage: FPGA_STATE=... $0 <build_dir> <img_dir> <out_dir>" >&2; exit 2; }
build=$1 img=$2 out=$3
root=$(cd "$(dirname "$0")/.." && pwd)
bin=${VIVADO_BIN:-/home/tai/AMD/2026.1/Vivado/bin}
: "${FPGA_STATE:?set FPGA_STATE to the fpga-tools MCP state directory}"

for d in "$img"/pass_* "$img/player"; do
    sh "$root/fpga/patch_bit.sh" "$build" "$d" "$out/$(basename "$d")"
done

for d in "$img"/pass_* "$img/player"; do
    echo "programming $(basename "$d")"
    flock -w 600 "$FPGA_STATE/hardware.lock" \
        "$bin/vivado" -mode batch -nojournal -nolog -notrace \
        -source "$root/fpga/program.tcl" -tclargs "$out/$(basename "$d")/patched.bit"
    sleep 2   # a pass finishes in well under a second at 100 MHz
done
