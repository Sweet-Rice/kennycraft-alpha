#!/bin/sh
# Flash Bad Apple onto the board: the 16 loader passes back to back, then the
# player, optionally recording the capture card from just before the player.
#
#   FPGA_STATE=<fpga-mcp state dir> badapple/flash.sh <bits_dir> [<video.mkv> <seconds>]
#
# bits_dir holds bad_apple_pass_NN.bit and bad_apple_player.bit (the "Bad
# Apple" release zip, or badapple/board.sh's output). Both programming steps
# hold the fpga-mcp hardware lock. The recording is the capture card's MJPEG
# stream copied as is (1280x720, 60 fps; CAPTURE_DEV, default /dev/video2).
set -eu
[ $# -eq 1 ] || [ $# -eq 3 ] || { echo "usage: FPGA_STATE=... $0 <bits_dir> [<video.mkv> <seconds>]" >&2; exit 2; }
bits=$1
here=$(cd "$(dirname "$0")" && pwd)
bin=${VIVADO_BIN:-/home/tai/AMD/2026.1/Vivado/bin}
: "${FPGA_STATE:?set FPGA_STATE to the fpga-tools MCP state directory}"
[ -f "$FPGA_STATE/hardware.lock" ] || { echo "flash.sh: no $FPGA_STATE/hardware.lock" >&2; exit 2; }

passes=$(ls "$bits"/bad_apple_pass_*.bit)
[ "$(echo "$passes" | wc -l)" -eq 16 ] || { echo "flash.sh: expected 16 pass bitstreams in $bits" >&2; exit 2; }
[ -f "$bits/bad_apple_player.bit" ] || { echo "flash.sh: no $bits/bad_apple_player.bit" >&2; exit 2; }

program() {
    flock -w 600 "$FPGA_STATE/hardware.lock" \
        "$bin/vivado" -mode batch -nojournal -nolog -notrace -source "$here/flash.tcl" -tclargs "$@"
}

# shellcheck disable=SC2086  # one argument per pass file (no spaces in these names)
program $passes

rec=
if [ $# -eq 3 ]; then
    ffmpeg -v error -y -f v4l2 -input_format mjpeg -video_size 1280x720 -framerate 60 \
        -t "$3" -i "${CAPTURE_DEV:-/dev/video2}" -c copy "$2" &
    rec=$!
    sleep 2
fi
program "$bits/bad_apple_player.bit"
if [ -n "$rec" ]; then
    wait "$rec"
    echo "recorded $2"
fi
