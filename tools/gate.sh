#!/usr/bin/env bash
#
# One command that answers "is this commit good?" on SQL Server 2019, 2022 and
# 2025 at once, and leaves a result file that names the commit it tested.
#
#   bash tools/gate.sh full                         # the whole suite
#   bash tools/gate.sh only <test> [<test> ...]     # just these test files
#   bash tools/gate.sh redgreen <base> <test> [...] # each test must FAIL against
#                                                   # the procedure at <base> and
#                                                   # PASS against the working tree
#
# <test> is a file name in tests/ without ".sql", for example 49_test_fgd0.
# <base> is any git revision, for example main or HEAD~1.
#
# Each version gets a fresh environment through tools/rig-use.sh run-create, the
# three run side by side, and every environment is destroyed again whatever
# happens.  Nothing here decides anything by reading output by eye: the verdict
# comes from the suite runner's exit status and its totals line.
#
# Output: one line per version, then "GATE PASSED" or "GATE FAILED".  The logs
# and result.json are written outside the repo, in a directory the last line
# names.  Limit the versions with GATE_VERSIONS="2022" for a quick check.
#
# Exit status: 0 passed; 1 failed; 2 usage or setup error.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RIG="$ROOT/tools/rig-use.sh"
SUITE="$ROOT/tests/run_suite.sh"
VERSIONS="${GATE_VERSIONS:-2019 2022 2025}"

usage() { sed -n '3,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

MODE="${1:-}"
[ $# -gt 0 ] && shift
BASE=""
case "$MODE" in
    full) [ $# -eq 0 ] || usage ;;
    only) [ $# -ge 1 ] || usage ;;
    redgreen) [ $# -ge 2 ] || usage; BASE="$1"; shift ;;
    *) usage ;;
esac
TESTS=("$@")

for t in "${TESTS[@]}"; do
    [ -f "$ROOT/tests/$t.sql" ] || { echo "gate: no such test file: tests/$t.sql" >&2; exit 2; }
done

COMMIT=$(git -C "$ROOT" rev-parse HEAD) || exit 2
DIRTY=false
[ -n "$(git -C "$ROOT" status --porcelain)" ] && DIRTY=true

OUT="${GATE_OUT_DIR:-$HOME/.cache/sp_HeapDoctor-rig/gate}/$(date +%Y%m%d-%H%M%S)-${COMMIT:0:7}"
mkdir -p "$OUT" || exit 2

BASE_PROC=""
if [ "$MODE" = redgreen ]; then
    BASE_COMMIT=$(git -C "$ROOT" rev-parse --verify "$BASE^{commit}" 2>/dev/null) \
        || { echo "gate: not a git revision: $BASE" >&2; exit 2; }
    BASE_PROC="$OUT/sp_HeapDoctor.base.sql"
    git -C "$ROOT" show "$BASE_COMMIT:sp_HeapDoctor.sql" > "$BASE_PROC" \
        || { echo "gate: $BASE has no sp_HeapDoctor.sql" >&2; exit 2; }
fi

# Prints the value of one counter from the runner's totals line, or -1.
total() { # <log> <PASS|FAIL|SKIP|Msg>
    local v
    v=$(grep -E '^=== totals: ' "$1" 2>/dev/null | tail -1 | sed -n "s/.* $2=\([0-9][0-9]*\).*/\1/p")
    echo "${v:--1}"
}

# Runs the suite runner once.  Prints nothing; the log is the record.
suite() { # <year> <log> <proc or ""> [runner args]
    local year="$1" log="$2" proc="$3"
    shift 3
    if [ -n "$proc" ]; then
        HEAPDOCTOR_PROC="$proc" HEAPDOCTOR_SQLCMD="bash '$RIG' run-sqlcmd $year" bash "$SUITE" "$@" > "$log" 2>&1
    else
        HEAPDOCTOR_SQLCMD="bash '$RIG' run-sqlcmd $year" bash "$SUITE" "$@" > "$log" 2>&1
    fi
}

# Everything for one version.  Writes "$OUT/verdict_<year>" as "<ok|bad> <detail>".
one_version() {
    local year="$1" ok=1 detail="" t rc log
    if ! bash "$RIG" run-create "$year" --wait > "$OUT/create_$year.log" 2>&1; then
        bash "$RIG" run-destroy "$year" > "$OUT/destroy_$year.log" 2>&1
        echo "bad could not create the environment (see create_$year.log)" > "$OUT/verdict_$year"
        return
    fi

    case "$MODE" in
        full)
            log="$OUT/full_$year.log"
            suite "$year" "$log" ""; rc=$?
            detail="PASS=$(total "$log" PASS) FAIL=$(total "$log" FAIL) SKIP=$(total "$log" SKIP) Msg=$(total "$log" Msg) rc=$rc"
            [ "$rc" -eq 0 ] || ok=0
            ;;
        only)
            for t in "${TESTS[@]}"; do
                log="$OUT/only_${t}_$year.log"
                suite "$year" "$log" "" -t "$t"; rc=$?
                detail+="$t: PASS=$(total "$log" PASS) FAIL=$(total "$log" FAIL) Msg=$(total "$log" Msg) rc=$rc; "
                [ "$rc" -eq 0 ] || ok=0
            done
            ;;
        redgreen)
            for t in "${TESTS[@]}"; do
                # Red: the old procedure must produce at least one FAIL line.  A
                # setup error (rc 2) or a run with no FAIL is not a red test.
                log="$OUT/red_${t}_$year.log"
                suite "$year" "$log" "$BASE_PROC" -t "$t"; rc=$?
                local red_fail; red_fail=$(total "$log" FAIL)
                if [ "$rc" -eq 1 ] && [ "$red_fail" -ge 1 ]; then
                    detail+="$t: red FAIL=$red_fail Msg=$(total "$log" Msg)"
                else
                    detail+="$t: NOT RED (FAIL=$red_fail rc=$rc)"; ok=0
                fi
                log="$OUT/green_${t}_$year.log"
                suite "$year" "$log" "" -t "$t"; rc=$?
                detail+=", green PASS=$(total "$log" PASS) FAIL=$(total "$log" FAIL) Msg=$(total "$log" Msg) rc=$rc; "
                [ "$rc" -eq 0 ] || ok=0
            done
            ;;
    esac

    if ! bash "$RIG" run-destroy "$year" > "$OUT/destroy_$year.log" 2>&1; then
        ok=0; detail+=" ENVIRONMENT NOT DESTROYED (see destroy_$year.log)"
    fi
    if [ "$ok" -eq 1 ]; then echo "ok $detail" > "$OUT/verdict_$year"; else echo "bad $detail" > "$OUT/verdict_$year"; fi
}

for year in $VERSIONS; do one_version "$year" & done
wait

PASSED=true
JSON="{\"commit\":\"$COMMIT\",\"dirty\":$DIRTY,\"mode\":\"$MODE\",\"base\":\"${BASE_COMMIT:-}\",\"tests\":\"${TESTS[*]:-}\",\"versions\":{"
SEP=""
for year in $VERSIONS; do
    read -r state detail < "$OUT/verdict_$year" 2>/dev/null || { state=bad; detail="no verdict was written"; }
    [ "$state" = ok ] || PASSED=false
    printf '%s %-4s %s\n' "$year" "$state" "$detail"
    JSON+="$SEP\"$year\":{\"ok\":$([ "$state" = ok ] && echo true || echo false),\"detail\":\"${detail//\"/\'}\"}"
    SEP=","
done
JSON+="},\"passed\":$PASSED}"
printf '%s\n' "$JSON" > "$OUT/result.json"

if [ "$PASSED" = true ]; then
    echo "GATE PASSED  mode=$MODE commit=${COMMIT:0:7} dirty=$DIRTY  $OUT"
    exit 0
fi
echo "GATE FAILED  mode=$MODE commit=${COMMIT:0:7} dirty=$DIRTY  $OUT"
exit 1
