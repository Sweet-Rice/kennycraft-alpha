#!/bin/sh
# Patch the Bad Apple images into an existing top_s2p100 bitstream (no
# rebuild) and flash them (badapple/flash.sh).
#
#   FPGA_STATE=<fpga-mcp state dir> badapple/board.sh <build_dir> <img_dir> <out_dir> [<video.mkv> <seconds>]
#
# img_dir is badapple/build.py's output. out_dir gets bad_apple_pass_NN.bit
# and bad_apple_player.bit (fpga/patch_bit.sh, about 15 s each), the same
# layout as the "Bad Apple" release zip.
set -eu
[ $# -eq 3 ] || [ $# -eq 5 ] || { echo "usage: FPGA_STATE=... $0 <build_dir> <img_dir> <out_dir> [<video.mkv> <seconds>]" >&2; exit 2; }
build=$1 img=$2 out=$3
shift 3
root=$(cd "$(dirname "$0")/.." && pwd)

for d in "$img"/pass_* "$img/player"; do
    n=$(basename "$d")
    sh "$root/fpga/patch_bit.sh" "$build" "$d" "$out/patch_$n"
    cp "$out/patch_$n/patched.bit" "$out/bad_apple_$n.bit"
done
exec sh "$root/badapple/flash.sh" "$out" "$@"
