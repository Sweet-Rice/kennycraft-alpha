#!/bin/sh
# stack_check.sh <elf> [limit] — worst-case stack depth of every call chain that runs on a lane.
# Each lane has exactly 1 KB of stack (crt0.S) and nothing detects an overflow: lane n spills
# into lane n+1's stack, lane 7 into the statics. This walks the static call graph from
#   main                               lane 0: game + kernel (sp starts at the lane 0 top)
#   kc_render_frame, kc_raster_kernel  lanes 1-7: they join at mask_all() with sp at their top
# Frame = a function's largest open stack adjustment (addi sp,sp,-N). Calls are auipc+jalr
# (-mno-relax) or jal, resolved by address, not by objdump's symbol label (which can name the
# wrong section). Tail calls (jr / j to another function) add no frame of their own.
# Fails on a chain deeper than the limit (default 1024 bytes), on recursion, on calls it cannot
# resolve (indirect, or not to a function start) and on unsized adjustments (sub sp,sp,reg).
ELF=$1
LIMIT=${2:-${STACK_LIMIT:-1024}}
[ -f "$ELF" ] || { echo "usage: stack_check.sh <elf> [limit]"; exit 2; }
llvm-objdump -d --no-show-raw-insn "$ELF" | awk -v limit="$LIMIT" -v elf="$ELF" '
function fail(msg) { print "FAIL: " msg; bad = 1 }
function hex(s,    v, i, c) {
    v = 0; sub(/^0x/, "", s)
    for (i = 1; i <= length(s); i++) { c = index("0123456789abcdef", substr(s, i, 1)); if (!c) break; v = v * 16 + c - 1 }
    return v
}
function num(s) {                                            # signed decimal or 0x hex
    if (substr(s, 1, 1) == "-") return -num(substr(s, 2))
    return (substr(s, 1, 2) == "0x") ? hex(s) : s + 0
}
function edge(kind, target) { ne++; efn[ne] = fn; ekind[ne] = kind; eaddr[ne] = target; eins[ne] = $0 }
/^[0-9a-f]+ <[^>]+>:$/ {
    fn = $2; gsub(/[<>:]/, "", fn); fns[fn] = 1; frame[fn] = 0; cur = 0
    at[hex($1)] = fn; split("", hi); next
}
fn == "" || $1 !~ /^[0-9a-f]+:$/ { next }
{
    pc = hex($1); op = $2
    if (op == "auipc") {                                     # rd = pc + (imm20 << 12)
        r = $3; sub(/,$/, "", r); imm = num($4); if (imm >= 524288) imm -= 1048576
        hi[r] = pc + imm * 4096; next
    }
    if (op == "addi" && $3 == "sp," && $4 == "sp,") {
        cur -= num($5); if (cur > frame[fn]) frame[fn] = cur; next
    }
    if ((op == "sub" || op == "add") && $3 == "sp," && $4 == "sp," && fn != "_start") {
        fail(fn ": unsized stack adjustment: " $0); next
    }
    if (op == "jalr" || op == "jr") {                        # jalr off(rs) / jr off(rs)
        a = $3; if (op == "jalr" && a ~ /,$/) a = $4         # (jalr rd, off(rs) form)
        if (op == "jr" && a == "ra") next                    # return
        if (match(a, /^-?(0x[0-9a-f]+|[0-9]+)\(/)) {
            off = num(substr(a, 1, RLENGTH - 1)); r = substr(a, RLENGTH + 1); sub(/\).*/, "", r)
        } else { off = 0; r = a }
        if (!(r in hi)) { fail(fn ": indirect call, cannot bound: " $0); next }
        edge(op == "jr" ? "tail" : "call", hi[r] + off); next
    }
    if (op == "jal" || op == "j") {                          # direct: absolute target printed
        a = (op == "jal" && $3 ~ /,$/) ? $4 : $3
        k = (op == "j" || $3 == "zero,") ? "jump" : "call"
        edge(k, hex(a)); next
    }
}
# depth(f) = max(frame(f) + depth(callee), depth(tail callee)); path in chain[f]
function depth(f,    i, d, best, bestc, g) {
    if (f in memo) return memo[f]
    if (f in onstack) { fail("recursion through " f); return 0 }
    onstack[f] = 1
    best = frame[f]; bestc = f " (" frame[f] ")"
    for (i = 1; i <= ne; i++) {
        if (efn[i] != f || !(i in etgt)) continue
        g = etgt[i]
        if (ekind[i] == "call") {
            d = frame[f] + depth(g)
            if (d > best) { best = d; bestc = f " (" frame[f] ") > " chain[g] }
        } else {
            d = depth(g)
            if (d > best) { best = d; bestc = f " (tail) > " chain[g] }
        }
    }
    delete onstack[f]
    memo[f] = best; chain[f] = bestc
    return best
}
END {
    for (i = 1; i <= ne; i++) {
        t = eaddr[i]
        if (t in at && (ekind[i] != "jump" || at[t] != efn[i])) etgt[i] = at[t]   # self call: recursion
        else if (ekind[i] != "jump") fail(efn[i] ": call not to a function start: " eins[i])
    }
    nent = split("main kc_render_frame kc_raster_kernel", ent, " ")
    for (i = 1; i <= nent; i++) {
        e = ent[i]
        if (!(e in fns)) continue
        d = depth(e)
        who = (e == "main") ? "lane 0  " : "lane 1-7"
        printf "  %s %-16s %4d / %d bytes: %s\n", who, e, d, limit, chain[e]
        if (d > limit) fail(e " chain needs " d " bytes of stack, lanes have " limit)
    }
    if (!("main" in fns)) fail("no main in " elf)
    if (!bad) print "stack check OK: " elf " (every lane chain fits in " limit " bytes)"
    exit bad
}'
