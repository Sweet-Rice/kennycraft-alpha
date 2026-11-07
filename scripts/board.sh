#!/usr/bin/env bash
# Board access for make board / make keys, run from the repo root:
#
#   board.sh program          patch out/kc_*.bin (and TEX_HEX=/PAL_HEX=) into BIT=
#                             with updatemem and program it with fpga/program.tcl
#   board.sh keys [args]      run scripts/kc.py [args] on the board UART
#
# Both refuse while another agent holds the board on issue #1, post
# `taking-board` / `releasing-board` as BOARD_AGENT (default kc-bench), and
# hold the fpga-tools MCP hardware lock (HARDWARE_LOCK=) while on the board.
set -eu
mode=${1:-}
case $mode in
    program|keys) shift ;;
    *) echo 'usage: board.sh program | board.sh keys [kc.py args]' >&2; exit 2 ;;
esac
PYTHON=${PYTHON:-python3}
for tool in gh flock git; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "board: $tool not found" >&2
        exit 5
    fi
done

# The fpga-tools MCP's lock (FPGA_STATE/hardware.lock, flock(2)) in the workspace
# directory that holds the main checkout and wt/, from either of them.
if [ -z "${HARDWARE_LOCK:-}" ]; then
    common=$(git rev-parse --path-format=absolute --git-common-dir)
    HARDWARE_LOCK=$(dirname "$(dirname "$common")")/.fpga-state/hardware.lock
fi

patch_bitstream() {
    VIVADO_BIN=${VIVADO_BIN:-/home/tai/AMD/2026.1/Vivado/bin}
    for tool in "$VIVADO_BIN/updatemem" "$VIVADO_BIN/vivado"; do
        if [ ! -x "$tool" ]; then
            echo "board: $tool not found; set VIVADO_BIN= to the Vivado bin directory" >&2
            exit 5
        fi
    done
    if [ ! -f fpga/program.tcl ]; then
        echo 'board: fpga/program.tcl missing from this checkout (fpga/ scripts on main)' >&2
        exit 5
    fi
    if [ -z "${BIT:-}" ] || [ -z "${MMI:-}" ]; then
        echo 'board: set BIT= and MMI= (top.bit and kc.mmi from an fpga/build.tcl build)' >&2
        exit 5
    fi
    if [ ! -f "$BIT" ]; then
        echo "board: bitstream file not found: $BIT" >&2
        exit 5
    fi
    if [ ! -f "$MMI" ]; then
        echo "board: meminfo file not found: $MMI (kc.mmi is written by fpga/build.tcl)" >&2
        exit 5
    fi
    if [ ! -f out/kc_imem.bin ] || [ ! -f out/kc_dmem.bin ]; then
        echo 'board: missing out/kc_imem.bin or out/kc_dmem.bin; run make sw first' >&2
        exit 5
    fi
    # imem and dmem always; the texture and palette BRAMs when TEX_HEX= / PAL_HEX=
    # give $readmemh images (as for the Verilator build).
    local names images procs data i proc width name offset
    names=("imem${IMEM_PROC:+=$IMEM_PROC}" "dmem${DMEM_PROC:+=$DMEM_PROC}")
    images=(out/kc_imem.bin out/kc_dmem.bin)
    if [ -n "${TEX_HEX:-}" ]; then names+=("tex${TEX_PROC:+=$TEX_PROC}"); images+=("$TEX_HEX"); fi
    if [ -n "${PAL_HEX:-}" ]; then names+=("palette${PALETTE_PROC:+=$PALETTE_PROC}"); images+=("$PAL_HEX"); fi
    if [ "${#names[@]}" -gt 2 ] && [ ! -f fpga/hex2mem.py ]; then
        echo 'board: fpga/hex2mem.py missing from this checkout; TEX_HEX=/PAL_HEX= need it (fpga/ scripts on main)' >&2
        exit 5
    fi
    if ! procs=$("$PYTHON" scripts/mmi_paths.py "$MMI" "${names[@]}"); then
        if [ -n "${PAL_HEX:-}" ]; then
            echo 'board: note: kc.mmi leaves out the RAMB18 palette (fpga/build.tcl), so palette changes need a Vivado rebuild' >&2
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
}

if [ "$mode" = program ]; then
    patch_bitstream
    taking_note="programming $BIT patched with software $(git rev-parse --short HEAD) via fpga/program.tcl (about 1 min)"
    release_note='programming exited with status %s. Board is free.'
else
    taking_note="UART key session: scripts/kc.py $*"
    release_note='key session ended with status %s. Board is free.'
fi

REPO=${BOARD_REPO:-Sweet-Rice/kennycraft-alpha}
ISSUE=${BOARD_ISSUE:-1}

# Claims on issue #1 are `**[agent-name]** `taking-board` · ...`; the shared gh
# login (Sweet-Rice) would not say which agent holds the board.
agent=${BOARD_AGENT-kc-bench}
if [ -z "$agent" ]; then
    agent=$(gh api user -q .login 2>/dev/null || true)
fi
if [ -z "$agent" ]; then
    echo 'board: set BOARD_AGENT= or run gh auth login' >&2
    exit 5
fi

scratch=$(mktemp -d)
taking=0
cleanup() {
    status=$?
    trap - EXIT INT TERM
    if [ "$taking" = 1 ]; then
        flock -u 9 2>/dev/null || true
        # shellcheck disable=SC2059
        printf "**[%s]** \`releasing-board\` · $release_note\n" "$agent" "$status" > "$scratch/comment.md"
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
printf '**[%s]** `taking-board` · %s\n' "$agent" "$taking_note" > "$scratch/comment.md"
gh issue comment "$ISSUE" --repo "$REPO" --body-file "$scratch/comment.md"
taking=1

# fd 9 holds the lock until cleanup; children that must not keep it get 9>&-.
mkdir -p "$(dirname "$HARDWARE_LOCK")"
exec 9>>"$HARDWARE_LOCK"
if ! flock -w 600 9; then
    echo "board: $HARDWARE_LOCK still held after 600 s (pid $(cat "$HARDWARE_LOCK" 2>/dev/null || echo unknown))" >&2
    exit 5
fi
echo "$$" > "$HARDWARE_LOCK"
if [ "$mode" = program ]; then
    # program.tcl may start a hw_server daemon, which must not inherit the lock.
    "$VIVADO_BIN/vivado" -mode batch -nojournal -nolog -notrace \
        -source fpga/program.tcl -tclargs out/kc_patched.bit 9>&-
else
    KC_HARDWARE_LOCK_FD=9 "$PYTHON" scripts/kc.py "$@"
fi
