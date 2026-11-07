#!/usr/bin/env bash
set -eu
VIVADO_BIN=${VIVADO_BIN:-/home/tai/AMD/2026.1/Vivado/bin}
for tool in "$VIVADO_BIN/updatemem" "$VIVADO_BIN/vivado"; do
    if [ ! -x "$tool" ]; then
        echo "board: $tool not found; set VIVADO_BIN= to the Vivado bin directory" >&2
        exit 5
    fi
done
if [ ! -f fpga/program.tcl ]; then
    echo 'board: fpga/program.tcl missing; make board needs the P3 fpga/ scripts (stage0/p3)' >&2
    exit 5
fi
if [ -z "${BIT:-}" ] || [ -z "${MMI:-}" ]; then
    echo 'board: set BIT= and MMI= (top.bit and kc.mmi from a P3 fpga/build.tcl build)' >&2
    exit 5
fi
if [ ! -f "$BIT" ]; then
    echo "board: bitstream file not found: $BIT" >&2
    exit 5
fi
if [ ! -f "$MMI" ]; then
    echo "board: meminfo file not found: $MMI (kc.mmi is written by the P3 fpga/build.tcl)" >&2
    exit 5
fi
for tool in gh flock; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "board: $tool not found" >&2
        exit 5
    fi
done
PYTHON=${PYTHON:-python3}
if [ ! -f out/kc_imem.bin ] || [ ! -f out/kc_dmem.bin ]; then
    echo 'board: missing out/kc_imem.bin or out/kc_dmem.bin; run make sw first' >&2
    exit 5
fi
# imem and dmem always; the texture and palette BRAMs when TEX_HEX= / PAL_HEX=
# give $readmemh images (as for the Verilator build).
names=("imem${IMEM_PROC:+=$IMEM_PROC}" "dmem${DMEM_PROC:+=$DMEM_PROC}")
images=(out/kc_imem.bin out/kc_dmem.bin)
if [ -n "${TEX_HEX:-}" ]; then names+=("tex${TEX_PROC:+=$TEX_PROC}"); images+=("$TEX_HEX"); fi
if [ -n "${PAL_HEX:-}" ]; then names+=("palette${PALETTE_PROC:+=$PALETTE_PROC}"); images+=("$PAL_HEX"); fi
if [ "${#names[@]}" -gt 2 ] && [ ! -f fpga/hex2mem.py ]; then
    echo 'board: fpga/hex2mem.py missing; TEX_HEX=/PAL_HEX= need the P3 fpga/ scripts (stage0/p3)' >&2
    exit 5
fi
if ! procs=$("$PYTHON" scripts/mmi_paths.py "$MMI" "${names[@]}"); then
    if [ -n "${PAL_HEX:-}" ]; then
        echo 'board: note: P3 kc.mmi leaves out the RAMB18 palette (fpga/build.tcl), so palette changes need a Vivado rebuild' >&2
    fi
    exit 5
fi
mapfile -t procs <<< "$procs"
mkdir -p out
data=()
for i in "${!procs[@]}"; do
    proc=${procs[$i]% *}
    width=${procs[$i]##* }
    name=${names[$i]%%=*}
    case $name in
        imem|dmem)
            if [ "$width" != 32 ]; then
                echo "board: MMI $name processor $proc is $width bits wide, expected 32" >&2
                exit 5
            fi
            offset=0
            if [ "$name" = dmem ]; then offset=0x100; fi
            "$PYTHON" scripts/elf2hex.py "${images[$i]}" "out/kc_$name.mem" --offset-bytes "$offset" --words 8192 --mem
            ;;
        *)
            "$PYTHON" fpga/hex2mem.py "${images[$i]}" "out/kc_$name.mem" "$width"
            ;;
    esac
    data+=(-data "out/kc_$name.mem" -proc "$proc")
done
"$VIVADO_BIN/updatemem" -force -meminfo "$MMI" -bit "$BIT" "${data[@]}" -out out/kc_patched.bit

REPO=${BOARD_REPO:-Sweet-Rice/kennycraft-alpha}
ISSUE=${BOARD_ISSUE:-1}

current_user=$(gh api user -q .login 2>/dev/null || true)
if [ -z "$current_user" ]; then
    echo 'board: GitHub authorization required; run gh auth login' >&2
    exit 5
fi

scratch=$(mktemp -d)
taking=0
cleanup() {
    status=$?
    trap - EXIT INT TERM
    if [ "$taking" = 1 ]; then
        printf '**[%s]** releasing-board\nProgramming exited with status %s; board released.\n' "$current_user" "$status" > "$scratch/comment.md"
        if ! gh issue comment "$ISSUE" --repo "$REPO" --body-file "$scratch/comment.md"; then
            echo "board: failed to post releasing-board; notify $REPO issue #$ISSUE manually" >&2
            if [ "$status" = 0 ]; then status=5; fi
        fi
    fi
    if [ -n "${scratch:-}" ] && [ -d "$scratch" ]; then
        rm -rf "$scratch"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Read every page and refuse to interrupt another user's outstanding board lease.
# gh 2.45 has no --slurp: --jq runs per page, giving one JSON string per comment.
if ! gh api --paginate "repos/$REPO/issues/$ISSUE/comments" --jq '.[] | .body | tojson' > "$scratch/thread.jsonl"; then
    echo "board: cannot read $REPO issue #$ISSUE comments; run gh auth login" >&2
    exit 5
fi
"$PYTHON" - "$scratch/thread.jsonl" <<'PY'
import json, re, sys
active = set()
with open(sys.argv[1]) as thread:
    for line in thread:
        body = json.loads(line) or ''
        match = re.search(r'\*\*\[([^]]+)\]\*\*\s*`?(taking-board|releasing-board)\b', body)
        if match:
            agent, status = match.groups()
            if status == 'taking-board':
                active.add(agent)
            else:
                active.discard(agent)
if active:
    print('board: held by ' + ', '.join(sorted(active)), file=sys.stderr)
    sys.exit(5)
PY
commit=$(git rev-parse --short HEAD)
printf '**[%s]** taking-board\nProgramming %s (software %s) with fpga/program.tcl.\n' "$current_user" "$BIT" "$commit" > "$scratch/comment.md"
gh issue comment "$ISSUE" --repo "$REPO" --body-file "$scratch/comment.md"
taking=1
# The fpga-tools MCP's lock (FPGA_STATE/hardware.lock, flock(2)) in the workspace
# directory that holds the main checkout and wt/, from either of them.
if [ -z "${HARDWARE_LOCK:-}" ]; then
    common=$(git rev-parse --path-format=absolute --git-common-dir)
    HARDWARE_LOCK=$(dirname "$(dirname "$common")")/.fpga-state/hardware.lock
fi
mkdir -p "$(dirname "$HARDWARE_LOCK")"
flock -w 600 "$HARDWARE_LOCK" \
    "$VIVADO_BIN/vivado" -mode batch -nojournal -nolog -notrace \
    -source fpga/program.tcl -tclargs out/kc_patched.bit
