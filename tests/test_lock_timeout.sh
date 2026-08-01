#!/usr/bin/env bash
#
# Behavioural test for @LockTimeoutMs (#197).
#
# @LockTimeoutMs bounds how long a rebuild waits to ACQUIRE its lock. The whole
# point is the blocked case, and nothing in the .sql suite ever blocks a
# rebuild: every test runs on an idle database, so the timeout path never
# executed. What existed was parameter validation, which would still pass if the
# SET LOCK_TIMEOUT prefix stopped being emitted entirely.
#
# This cannot live in a .sql file. It needs a second session holding a
# conflicting lock while a first session tries to rebuild, and the suite is
# single-session sqlcmd. tests/29_test_parallel_concurrency.sh sets the
# precedent for driving concurrent sqlcmd processes.
#
# Shape:
#   Session A  BEGIN TRAN; SELECT ... WITH (TABLOCKX); WAITFOR; ROLLBACK
#   Session B  sp_HeapDoctor @PlanOnly = 0, @LockTimeoutMs = <short>
#
# Asserted on ELAPSED TIME and DISPOSITION, not on log text: B must give up near
# the timeout instead of waiting for A, and must report the target as not
# succeeded. Scraping messages would pass even if the rebuild silently hung.
#
# Usage (same conventions as run_suite.sh -- no credentials are stored here):
#   HEAPDOCTOR_SQLCMD='docker exec -i sqltest-2025 /opt/.../sqlcmd -S localhost -U sa -P <pw> -C' \
#     bash tests/test_lock_timeout.sh
#   bash tests/test_lock_timeout.sh -S <server> -U <user> -P <password>
#
# Exit status: 0 all assertions passed, 1 an assertion failed, 2 setup error.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER=""; USER_NAME=""; PASSWORD=""
# Overridable so the test can be shown to FAIL when the timeout is not short --
# an assertion that cannot fail proves nothing. With TIMEOUT_MS=60000 the rebuild
# waits out the blocker and 197B/197C go red, which is the control case.
BLOCK_SECONDS=${BLOCK_SECONDS:-40}      # A holds the lock this long
TIMEOUT_MS=${TIMEOUT_MS:-2000}          # what B is told to wait
GIVE_UP_CEILING=${GIVE_UP_CEILING:-25}  # B must return well inside BLOCK_SECONDS

while [ $# -gt 0 ]; do
    case "$1" in
        -S) SERVER="${2:-}"; shift 2 ;;
        -U) USER_NAME="${2:-}"; shift 2 ;;
        -P) PASSWORD="${2:-}"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ -n "${HEAPDOCTOR_SQLCMD:-}" ]; then
    SQLCMD="$HEAPDOCTOR_SQLCMD"
elif [ -n "$SERVER" ]; then
    SQLCMD="sqlcmd -S $SERVER -C"
    if [ -n "$USER_NAME" ]; then SQLCMD="$SQLCMD -U $USER_NAME -P $PASSWORD"; else SQLCMD="$SQLCMD -E"; fi
else
    echo "error: give -S <server>, or set HEAPDOCTOR_SQLCMD." >&2
    exit 2
fi

pass=0; fail=0
ok()  { echo "  PASS $1: $2"; pass=$((pass+1)); }
bad() { echo "  FAIL $1: $2"; fail=$((fail+1)); }

echo "=== @LockTimeoutMs behavioural test (#197) ==="

# Rebuild the database so HeapA has forwarded records to rebuild.
eval "$SQLCMD" -d master -b >/dev/null 2>&1 < "$TESTS_DIR/01_setup_test_data.sql" || {
    echo "FATAL: could not build HeapDoctorTest" >&2; exit 2; }

BLOCKER_LOG=$(mktemp)
cleanup() {
    # The blocking transaction must not outlive this script even on failure or
    # interrupt: a held TABLOCKX would wedge every later test on this rig.
    [ -n "${BLOCKER_PID:-}" ] && kill "$BLOCKER_PID" 2>/dev/null
    wait "${BLOCKER_PID:-}" 2>/dev/null
    eval "$SQLCMD" -d HeapDoctorTest -Q \
      "\"DECLARE @s int; SELECT TOP 1 @s = session_id FROM sys.dm_tran_locks WHERE resource_associated_entity_id = OBJECT_ID('dbo.HeapA') AND request_mode IN ('S','X') AND request_session_id <> @@SPID; IF @s IS NOT NULL EXEC('KILL ' + CAST(@s AS varchar(10)));\"" \
      >/dev/null 2>&1
    rm -f "$BLOCKER_LOG"
}
trap cleanup EXIT INT TERM

# --- Session A: hold a SHARED table lock -------------------------------------
#
# Deliberately S, not X. An exclusive lock also blocks discovery, because
# dm_db_index_physical_stats needs a shared lock -- the run then stalls in the
# scan for the blocker's full duration and never reaches the rebuild, so
# @LockTimeoutMs (which wraps only the rebuild command) never applies. Measured:
# 41s elapsed against a 40s blocker with the timeout set to 2s.
#
# A shared lock is compatible with the scan but still conflicts with the Sch-M
# the rebuild needs, which is precisely the wait @LockTimeoutMs bounds.
eval "$SQLCMD" -d HeapDoctorTest -Q \
  "\"BEGIN TRAN; SELECT TOP 1 * FROM dbo.HeapA WITH (TABLOCK, HOLDLOCK); WAITFOR DELAY '00:00:${BLOCK_SECONDS}'; ROLLBACK;\"" \
  > "$BLOCKER_LOG" 2>&1 &
BLOCKER_PID=$!

# Wait until the lock is genuinely held; polling beats a fixed sleep.
held=0
for _ in $(seq 1 20); do
    n=$(eval "$SQLCMD" -d HeapDoctorTest -h-1 -W -Q \
        "\"SET NOCOUNT ON; SELECT COUNT(*) FROM sys.dm_tran_locks WHERE resource_associated_entity_id = OBJECT_ID('dbo.HeapA') AND request_mode IN ('S','X');\"" \
        2>/dev/null | tr -d '[:space:]')
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    if [ "$n" -ge 1 ]; then held=1; break; fi
    sleep 1
done

if [ "$held" -eq 1 ]; then
    ok "197A" "blocking session holds a conflicting table lock on dbo.HeapA"
else
    bad "197A" "could not establish the blocking lock; the rest of this test would be vacuous"
    echo "results: $pass passed, $fail failed"
    exit 1
fi

# --- Session B: try to rebuild with a short acquisition timeout --------------
start=$(date +%s)
OUT=$(eval "$SQLCMD" -d HeapDoctorTest -Q \
  "\"DECLARE @f int, @s int, @t int; EXEC dbo.sp_HeapDoctor @Databases = N'HeapDoctorTest', @Tables = N'dbo.HeapA', @CpuSource = N'NONE', @PlanOnly = 0, @LockTimeoutMs = ${TIMEOUT_MS}, @TargetsFound = @t OUTPUT, @Failed = @f OUTPUT, @Skipped = @s OUTPUT; SELECT 'RESULT targets=' + ISNULL(CAST(@t AS varchar(10)),'?') + ' failed=' + ISNULL(CAST(@f AS varchar(10)),'?') + ' skipped=' + ISNULL(CAST(@s AS varchar(10)),'?');\"" \
  2>&1)
end=$(date +%s)
elapsed=$((end - start))

echo "  (elapsed ${elapsed}s, blocker holds ${BLOCK_SECONDS}s)"

# 197B: it must give up rather than wait out the blocker.
if [ "$elapsed" -lt "$GIVE_UP_CEILING" ]; then
    ok "197B" "rebuild gave up after ${elapsed}s instead of waiting ${BLOCK_SECONDS}s for the lock"
else
    bad "197B" "rebuild took ${elapsed}s: it waited for the blocker rather than honouring @LockTimeoutMs"
fi

# 197C: the blocked target must be reported as not succeeded.
RESULT_LINE=$(printf '%s\n' "$OUT" | grep -aoE "RESULT targets=[0-9?]+ failed=[0-9?]+ skipped=[0-9?]+" | head -1)
if [ -z "$RESULT_LINE" ]; then
    bad "197C" "no OUTPUT-parameter summary came back; cannot confirm disposition"
else
    f=$(printf '%s' "$RESULT_LINE" | sed -E 's/.*failed=([0-9?]+).*/\1/')
    s=$(printf '%s' "$RESULT_LINE" | sed -E 's/.*skipped=([0-9?]+).*/\1/')
    case "$f" in ''|*[!0-9]*) f=0 ;; esac
    case "$s" in ''|*[!0-9]*) s=0 ;; esac
    if [ "$((f + s))" -ge 1 ]; then
        ok "197C" "blocked target reported as not succeeded ($RESULT_LINE)"
    else
        bad "197C" "blocked target was not recorded as failed or skipped ($RESULT_LINE)"
    fi
fi

# 197D: the run must surface the actual timeout ERROR, not merely the advisory.
#
# The earlier pattern also matched the informational "Lock acquisition timeout:
# N ms" banner, which is printed whenever @LockTimeoutMs is set at all -- so it
# passed even in the control run where the rebuild waited out the blocker. Match
# error 1222 specifically.
if printf '%s\n' "$OUT" | grep -aqiE "Lock request time out period exceeded|Msg 1222"; then
    ok "197D" "lock timeout surfaced in the run output"
else
    bad "197D" "no lock-timeout diagnostic in the output; a blocked rebuild should say why it failed"
fi

# --- Phase 2 (#199): an EXCLUSIVE lock must not stall discovery ---------------
#
# Before #199, @LockTimeoutMs wrapped only the rebuild. dm_db_index_physical_stats
# needs a shared lock, so an exclusive lock stalled the SCAN and the run never
# reached the phase the timeout governed: a 40s blocker against a 2s cap produced
# a 41-second run that reported TOTAL SUCCESS. That is why phase 1 uses a shared
# lock. This phase asserts the exclusive case is now bounded and reported.

# Let phase 1's blocker finish before taking a new lock.
wait "${BLOCKER_PID:-}" 2>/dev/null
BLOCKER_PID=""

eval "$SQLCMD" -d HeapDoctorTest -Q \
  "\"BEGIN TRAN; SELECT TOP 1 * FROM dbo.HeapA WITH (TABLOCKX, HOLDLOCK); WAITFOR DELAY '00:00:${BLOCK_SECONDS}'; ROLLBACK;\"" \
  > "$BLOCKER_LOG" 2>&1 &
BLOCKER_PID=$!

xheld=0
for _ in $(seq 1 20); do
    n=$(eval "$SQLCMD" -d HeapDoctorTest -h-1 -W -Q \
        "\"SET NOCOUNT ON; SELECT COUNT(*) FROM sys.dm_tran_locks WHERE resource_associated_entity_id = OBJECT_ID('dbo.HeapA') AND request_mode = 'X';\"" \
        2>/dev/null | tr -d '[:space:]')
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    if [ "$n" -ge 1 ]; then xheld=1; break; fi
    sleep 1
done

if [ "$xheld" -eq 1 ]; then
    ok "199A" "blocking session holds an EXCLUSIVE lock on dbo.HeapA"
else
    bad "199A" "could not establish the exclusive lock; the #199 assertions would be vacuous"
fi

if [ "$xheld" -eq 1 ]; then
    xstart=$(date +%s)
    XOUT=$(eval "$SQLCMD" -d HeapDoctorTest -Q \
      "\"EXEC dbo.sp_HeapDoctor @Databases = N'HeapDoctorTest', @Tables = N'dbo.HeapA', @CpuSource = N'NONE', @PlanOnly = 1, @LockTimeoutMs = ${TIMEOUT_MS};\"" \
      2>&1)
    xend=$(date +%s)
    xelapsed=$((xend - xstart))
    echo "  (discovery elapsed ${xelapsed}s against a ${BLOCK_SECONDS}s exclusive blocker)"

    # 199B: the SCAN must give up, not wait out the blocker.
    if [ "$xelapsed" -lt "$GIVE_UP_CEILING" ]; then
        ok "199B" "discovery gave up after ${xelapsed}s instead of stalling for ${BLOCK_SECONDS}s"
    else
        bad "199B" "discovery took ${xelapsed}s: @LockTimeoutMs still does not cover the scan"
    fi

    # 199C: and it must SAY the results are incomplete, not return a short list quietly.
    if printf '%s\n' "$XOUT" | grep -aqiE "DISCOVERY WAS PARTIAL|BLOCKED scanning"; then
        ok "199C" "blocked scan reported as partial rather than returning a quietly short list"
    else
        bad "199C" "no partial-discovery warning; a blocked scan is indistinguishable from a clean one"
    fi
fi

echo "results: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
