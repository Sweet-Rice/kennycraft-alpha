#!/usr/bin/env bash
set -eu
if ! command -v updatemem >/dev/null 2>&1; then
    echo 'board: updatemem not found; run make board on the Vivado host' >&2
    exit 5
fi
if [ -z "${BIT:-}" ] || [ -z "${MMI:-}" ]; then
    echo 'board: set BIT= and MMI=' >&2
    exit 5
fi
if [ ! -f "$BIT" ]; then
    echo "board: bitstream file not found: $BIT" >&2
    exit 5
fi
if [ ! -f "$MMI" ]; then
    echo "board: meminfo file not found: $MMI" >&2
    exit 5
fi
for tool in gh openFPGALoader flock; do
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
paths=$("$PYTHON" scripts/mmi_paths.py "$MMI" --imem "${IMEM_PROC:-}" --dmem "${DMEM_PROC:-}")
imem_proc=${paths%%$'\n'*}
dmem_proc=${paths#*$'\n'}
mkdir -p out
"$PYTHON" scripts/elf2hex.py out/kc_imem.bin out/kc_imem.mem --offset-bytes 0 --words 8192 --mem
"$PYTHON" scripts/elf2hex.py out/kc_dmem.bin out/kc_dmem.mem --offset-bytes 0x100 --words 8192 --mem
updatemem -force -meminfo "$MMI" -bit "$BIT" \
    -data out/kc_imem.mem -proc "$imem_proc" \
    -data out/kc_dmem.mem -proc "$dmem_proc" -out out/kc_patched.bit

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
if ! gh api --paginate --slurp "repos/$REPO/issues/$ISSUE/comments" > "$scratch/thread.json"; then
    echo 'board: GitHub authorization required; run gh auth login' >&2
    exit 5
fi
"$PYTHON" - "$scratch/thread.json" <<'PY'
import json, re, sys
active = set()
data = json.load(open(sys.argv[1]))
pages = data if isinstance(data, list) else [data]
for page in pages:
    comments = page if isinstance(page, list) else [page]
    for comment in comments:
        body = comment.get('body', '') if isinstance(comment, dict) else ''
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
printf '**[%s]** taking-board\nProgramming %s (software %s) with openFPGALoader.\n' "$current_user" "$BIT" "$commit" > "$scratch/comment.md"
gh issue comment "$ISSUE" --repo "$REPO" --body-file "$scratch/comment.md"
taking=1
# The fpga-tools MCP's lock (FPGA_STATE/hardware.lock, flock(2)) in the workspace
# directory that holds the main checkout and wt/, from either of them.
if [ -z "${HARDWARE_LOCK:-}" ]; then
    common=$(git rev-parse --path-format=absolute --git-common-dir)
    HARDWARE_LOCK=$(dirname "$(dirname "$common")")/.fpga-state/hardware.lock
fi
mkdir -p "$(dirname "$HARDWARE_LOCK")"
flock -w 600 "$HARDWARE_LOCK" openFPGALoader -b arty_a7_100t out/kc_patched.bit
