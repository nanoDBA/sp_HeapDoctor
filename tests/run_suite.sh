#!/usr/bin/env bash
#
# sp_HeapDoctor test suite runner (#193).
#
# A test run that produces no output must not look like a clean pass. This
# runner fails loudly when a run is incomplete, rather than reporting the
# silence as zero failures.
#
# It checks four things:
#
#   1. Every test file emits at least its expected number of assertions.
#   2. No test file emits zero assertions.
#   3. No unhandled "Msg NNNN" error appears in any file's output.
#   4. The SQL instance is still reachable when the suite ends.
#
# Expected counts are DERIVED FROM THE TEST SOURCES, not from a hand-kept
# manifest -- a manifest would go stale on every release, which is the same
# maintenance trap as the hardcoded version strings in #191.
#
# The derivation counts an assertion id only when the file contains BOTH a
# "PASS <id>:" and a "FAIL <id>:" literal. That deliberately excludes:
#
#   * guard-only ids such as 26-SETUP, which raise at severity 16 on failure
#     and emit nothing at all on the happy path; and
#   * environment-dependent ids such as 2L-2 and 2M-1, whose else-branch emits
#     "INFO", so whether they emit a countable assertion depends on the data
#     the engine happens to produce.
#
# Because of that second class, the derived figure is a MINIMUM, and the
# comparison is ">=", never "==". An equality check would fire spuriously on a
# perfectly good run -- the false alarm the issue explicitly rules out.
#
# Usage:
#   bash tests/run_suite.sh -S <server> [-U <user> -P <password>] [-t <file>]
#   bash tests/run_suite.sh --list
#
# Connection handling:
#   With -U/-P, SQL authentication is used. Without them, a trusted connection
#   is used. Set HEAPDOCTOR_SQLCMD to override the client invocation entirely,
#   e.g. to run against a container:
#
#     HEAPDOCTOR_SQLCMD='docker exec -i sqltest-2022 /opt/mssql-tools18/bin/sqlcmd
#         -S localhost -U sa -P "$PASSWORD" -C' bash tests/run_suite.sh
#
# No hostnames or credentials are stored in this file.
#
# The repository lives on cloud-synced storage where the executable bit does
# not survive, so invoke this as "bash tests/run_suite.sh", not "./run_suite.sh".
#
# Exit status: 0 all checks passed; 1 a check failed; 2 usage or setup error.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER=""; USER_NAME=""; PASSWORD=""; ONLY=""; LIST_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        -S) SERVER="${2:-}"; shift 2 ;;
        -U) USER_NAME="${2:-}"; shift 2 ;;
        -P) PASSWORD="${2:-}"; shift 2 ;;
        -t) ONLY="${2:-}"; shift 2 ;;
        --list) LIST_ONLY=1; shift ;;
        -h|--help) sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# The canonical assertion shape (#192): optional leading spaces, PASS or FAIL,
# a test id, then a colon. Anchored, so prose such as "should FAIL with ..."
# and section headers such as "Batch 11 PASS/FAIL Results" cannot match.
ID_RE='[0-9]+[A-Z]?[0-9]*(-[0-9]+)?(-SETUP)?'
PASS_RE="^[[:space:]]*PASS ${ID_RE}:"
FAIL_RE="^[[:space:]]*FAIL ${ID_RE}:"

# Minimum assertions a file must emit: ids carrying both a PASS and a FAIL
# literal. See the header for why this is a minimum and not an exact count.
expected_for() {
    local f="$1" p_ids f_ids
    p_ids=$(grep -oE "PASS ${ID_RE}:" "$f" 2>/dev/null | sed -E 's/^PASS //; s/:$//' | sort -u)
    f_ids=$(grep -oE "FAIL ${ID_RE}:" "$f" 2>/dev/null | sed -E 's/^FAIL //; s/:$//' | sort -u)
    comm -12 <(printf '%s\n' "$p_ids") <(printf '%s\n' "$f_ids") | grep -c '[^[:space:]]'
}

# Test files are every tests/*.sql except the shared setup (01_) and the
# teardown / demo helpers (99_). Discovered, not listed, so a new test file is
# picked up without editing this runner.
TEST_FILES=()
for _f in "$TESTS_DIR"/*.sql; do
    [ -e "$_f" ] || continue
    _b=$(basename "$_f" .sql)
    case "$_b" in 01_*|99_*) continue ;; esac
    TEST_FILES+=("$_b")
done

if [ "${#TEST_FILES[@]}" -eq 0 ]; then
    echo "error: no test files found in $TESTS_DIR" >&2
    exit 2
fi

if [ -n "$ONLY" ]; then
    TEST_FILES=("${ONLY%.sql}")
fi

if [ "$LIST_ONLY" -eq 1 ]; then
    total=0
    for t in "${TEST_FILES[@]}"; do
        e=$(expected_for "$TESTS_DIR/$t.sql"); total=$((total + e))
        printf '%-40s %3d\n' "$t" "$e"
    done
    printf '%-40s %3d\n' "TOTAL (minimum)" "$total"
    exit 0
fi

# Build the sqlcmd invocation. HEAPDOCTOR_SQLCMD wins outright so the suite can
# be pointed at a container, a remote host, or any other client wrapper. This is
# deliberately after --list, which is pure static analysis and needs no server.
if [ -n "${HEAPDOCTOR_SQLCMD:-}" ]; then
    SQLCMD="$HEAPDOCTOR_SQLCMD"
elif [ -n "$SERVER" ]; then
    SQLCMD="sqlcmd -S $SERVER -C"
    if [ -n "$USER_NAME" ]; then
        SQLCMD="$SQLCMD -U $USER_NAME -P $PASSWORD"
    else
        SQLCMD="$SQLCMD -E"
    fi
else
    echo "error: give -S <server>, or set HEAPDOCTOR_SQLCMD." >&2
    exit 2
fi

SETUP="$TESTS_DIR/01_setup_test_data.sql"
[ -f "$SETUP" ] || { echo "error: missing $SETUP" >&2; exit 2; }

reachable() { eval "$SQLCMD" -Q "\"SET NOCOUNT ON; SELECT 1\"" >/dev/null 2>&1; }

# Emit a script for piping into sqlcmd, stripping a leading UTF-8 BOM.
# sqlcmd strips the BOM itself when it opens a file with -i, but not when the
# script arrives on stdin -- there the BOM reaches the parser and the batch dies
# with "Msg 102 ... Incorrect syntax near '<BOM>'". sp_HeapDoctor.sql is stored
# with a BOM, so without this the procedure silently fails to deploy.
feed() {
    if [ "$(head -c 3 "$1" | od -An -tx1 | tr -d ' \n')" = "efbbbf" ]; then
        tail -c +4 "$1"
    else
        cat "$1"
    fi
}

# Check 4a: the instance must be reachable before we start, so an unreachable
# server is reported as such rather than as 33 empty test files.
if ! reachable; then
    echo "FATAL: SQL instance is not reachable. Nothing was run." >&2
    exit 2
fi

# Deploy the procedure under test. Without this the suite would run against
# whatever build happens to be installed, and a green result would say nothing
# about the working tree.
PROC="$(dirname "$TESTS_DIR")/sp_HeapDoctor.sql"
if [ -f "$PROC" ]; then
    if feed "$PROC" | eval "$SQLCMD" -d master -b >/dev/null 2>&1; then
        echo "deployed: $PROC"
    else
        echo "FATAL: sp_HeapDoctor.sql failed to deploy. Nothing was run." >&2
        exit 2
    fi
else
    echo "warning: $PROC not found; testing whatever build is already installed" >&2
fi

echo "=== sp_HeapDoctor test suite: ${#TEST_FILES[@]} file(s) ==="

fail_total=0; pass_total=0; msg_total=0; expected_total=0
problems=()

for t in "${TEST_FILES[@]}"; do
    src="$TESTS_DIR/$t.sql"
    [ -f "$src" ] || { problems+=("$t: file not found"); continue; }

    expected=$(expected_for "$src")

    # A .sql file that defines no assertions at all is not a test file -- it is
    # a stray script sharing the directory. Skip it rather than report it as a
    # file that emitted nothing, which would be a false alarm.
    if [ "$expected" -eq 0 ]; then
        printf '%-40s %s\n' "$t" "skipped (defines no assertions)"
        continue
    fi

    expected_total=$((expected_total + expected))

    # Scripts are fed on stdin rather than with -i, so the client never needs to
    # resolve a path. That is what lets HEAPDOCTOR_SQLCMD be a "docker exec -i"
    # wrapper: the files stay on the host, and only their contents cross over.
    #
    # Every file starts from a freshly built database, so files stay independent.
    feed "$SETUP" | eval "$SQLCMD" -d master -b >/dev/null 2>&1

    out=$(feed "$src" | eval "$SQLCMD" -d HeapDoctorTest 2>&1)

    # Exclude the "Review PASS/FAIL results above" style summary lines before counting.
    body=$(printf '%s\n' "$out" | grep -av 'PASS/FAIL')
    p=$(printf '%s\n' "$body" | grep -acE "$PASS_RE")
    f=$(printf '%s\n' "$body" | grep -acE "$FAIL_RE")
    m=$(printf '%s\n' "$body" | grep -acE '^Msg [0-9]+')

    pass_total=$((pass_total + p)); fail_total=$((fail_total + f)); msg_total=$((msg_total + m))

    status="ok"
    # Check 2: silence is not success.
    if [ "$((p + f))" -eq 0 ]; then
        status="NO ASSERTIONS"; problems+=("$t: emitted no assertions at all (expected >= $expected)")
    # Check 1: a short run is an incomplete run.
    elif [ "$((p + f))" -lt "$expected" ]; then
        status="SHORT"; problems+=("$t: emitted $((p + f)) assertions, expected >= $expected")
    fi
    [ "$f" -gt 0 ] && problems+=("$t: $f assertion(s) FAILED")
    # Check 3: an unhandled engine error means the file did not run as written.
    [ "$m" -gt 0 ] && problems+=("$t: $m unhandled Msg error(s)")

    printf '%-40s PASS=%-4d FAIL=%-3d Msg=%-3d expected>=%-4d %s\n' \
        "$t" "$p" "$f" "$m" "$expected" "$status"

    if [ "$f" -gt 0 ] || [ "$m" -gt 0 ]; then
        printf '%s\n' "$body" | grep -aE "$FAIL_RE|^Msg [0-9]+" | sed 's/^/    /' | head -20
    fi
done

echo
echo "=== totals: PASS=$pass_total FAIL=$fail_total Msg=$msg_total (expected >= $expected_total) ==="

# Check 4b: the instance must have survived the run. A suite whose target
# vanished mid-run otherwise reports zero failures, which is indistinguishable
# from success -- the exact defect this runner exists to prevent.
if reachable; then
    echo "LIVENESS: SQL instance still reachable"
else
    echo "LIVENESS: SQL INSTANCE BECAME UNREACHABLE MID-RUN"
    problems+=("the SQL instance became unreachable during the run; results are incomplete")
fi

if [ "$pass_total" -lt "$expected_total" ]; then
    problems+=("suite total $pass_total is below the expected minimum $expected_total")
fi

if [ "${#problems[@]}" -gt 0 ]; then
    echo
    echo "SUITE FAILED:"
    printf '  - %s\n' "${problems[@]}"
    exit 1
fi

echo "SUITE PASSED"
exit 0
