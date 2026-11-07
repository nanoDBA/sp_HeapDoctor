#!/usr/bin/env bash
#
# Lease-gated access to the shared SQL Server test environments.
#
# THE ONLY sanctioned way for this repo to start, stop, or connect to one.
#
#   bash tools/rig-use.sh use <2019|2022|2025>          # acquire or exit 2, then start and wait for logins
#   bash tools/rig-use.sh use <2019|2022|2025> --wait   # acquire or poll (3h ceiling)
#   bash tools/rig-use.sh stop                          # acquire or exit 2, then stop all and release
#   bash tools/rig-use.sh release                       # release only; leaves the container running
#   bash tools/rig-use.sh status
#   bash tools/rig-use.sh sqlcmd <year> [sqlcmd args]   # run sqlcmd in that container, under our lease
#
# The sqlcmd verb is what the test scripts connect through.  From the repo root:
#
#   HEAPDOCTOR_SQLCMD='bash tools/rig-use.sh sqlcmd 2022' bash tests/run_suite.sh
#
# WHY THE GATE IS HERE (2026-08-02 incident): the harness had no lock
# integration.  Ad-hoc orchestrators piped the lease acquire to /dev/null and
# ignored its exit code, so when the other project held a live lease this harness
# stopped its containers mid-run.  The victim's remaining tests emit nothing,
# which reads as zero failures.  So a refused acquire touches nothing here, and
# the sqlcmd verb re-checks the lease on the rig in the same remote call as the
# connection: a script cannot reach a server while another harness holds it.
#
# WHY NO docker start/stop/run APPEARS BELOW: the environments are created and
# managed by a control script on the rig host, which runs one at a time, on a
# clone of the staged data, from a pinned image, and never deletes a container or
# data.  Calling docker directly would bypass all of that.  A harness that looked
# for containers by name and created any it did not find would start an empty
# instance.  The only docker verb used here is exec, on a container the control
# script already started, and exec cannot create or start one.
#
# CONFIGURATION: no hostname, path, or credential is committed.  Copy these into
# tools/rig.local.env (gitignored; environment variables of the same name win):
#
#   RIG_SSH_HOST           ssh alias of the rig host
#   RIG_CONTROL            path of the control script on that host, which provides
#                          ensure <year> | stop | status | password <year> |
#                          lock acquire|release|status [owner] [ttl-minutes]
#   RIG_CONTAINER_PATTERN  printf pattern naming the container for a year
#
# The SA password is read on the rig host at call time and handed to sqlcmd
# through the environment.  It never reaches this machine or a command line.
#
# The lease owner is "sp_HeapDoctor": the lock identifies the HARNESS, not the
# person, so the other project can tell whose run holds the rig.
#
# Exit status: 0 done; 2 lease refused (nothing was touched) or usage/config
# error; 3 sqlcmd refused because we do not hold the lease; 1 remote failure.
# The sqlcmd verb otherwise passes through sqlcmd's own status.

set -uo pipefail

OWNER="sp_HeapDoctor"
LEASE_MINUTES=180
READY_TIMEOUT_SECONDS=300
SQLCMD_PATH="/opt/mssql-tools18/bin/sqlcmd"

usage() {
    sed -n '7,12p' "${BASH_SOURCE[0]}" | sed 's/^# */usage: /' >&2
    exit 2
}

# Environment variables beat the file.  CR is stripped because this tree lives on
# cloud-synced storage that can rewrite line endings, and a stray CR would
# silently become part of a host name.
ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rig.local.env"
_host="${RIG_SSH_HOST:-}"; _control="${RIG_CONTROL:-}"; _pattern="${RIG_CONTAINER_PATTERN:-}"
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source <(tr -d '\r' < "$ENV_FILE")
fi
RIG_SSH_HOST="${_host:-${RIG_SSH_HOST:-}}"
RIG_CONTROL="${_control:-${RIG_CONTROL:-}}"
RIG_CONTAINER_PATTERN="${_pattern:-${RIG_CONTAINER_PATTERN:-}}"

ACTION="${1:-}"
[ -n "$ACTION" ] || usage
shift

# Strict host-key checking is deliberate.  Keepalives make a dead connection end
# with an error, because a suite that hangs silently is the failure this guards.
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=yes
          -o ServerAliveInterval=30 -o ServerAliveCountMax=4)

require_config() {
    if [ -z "$RIG_SSH_HOST" ] || [ -z "$RIG_CONTROL" ] || [ -z "$RIG_CONTAINER_PATTERN" ]; then
        echo "rig-use: RIG_SSH_HOST, RIG_CONTROL and RIG_CONTAINER_PATTERN must be set (see tools/rig.local.env)." >&2
        exit 2
    fi
}

# Container names are not accepted: an old-style "sqltest-2022" argument is a
# caller still written for the previous rig, and it must fail before any ssh.
require_year() {
    case "${1:-}" in
        2019|2022|2025) ;;
        *) echo "rig-use: expected 2019, 2022 or 2025, got '${1:-}'." >&2; exit 2 ;;
    esac
}

# Runs one control-script verb on the rig host.  Arguments are shell-quoted for
# the remote shell.  stdin is closed so a verb cannot eat a caller's piped script.
control() {
    local limit="$1" cmd arg
    shift
    cmd=$(printf '%q' "$RIG_CONTROL")
    for arg in "$@"; do cmd+=" $(printf '%q' "$arg")"; done
    timeout "$limit" ssh "${SSH_OPTS[@]}" "$RIG_SSH_HOST" "$cmd" </dev/null
}

# The gate.  The control script exits 1 when another owner holds the lock and
# only then; anything else (255 from ssh, 124 from timeout, 127 for a missing
# script) means we do not know who holds it, so it is an error, never a wait.
acquire_lease() {
    local wait="$1" rc
    control 120 lock acquire "$OWNER" "$LEASE_MINUTES"
    rc=$?
    [ "$rc" -eq 0 ] && return 0
    if [ "$rc" -ne 1 ]; then
        echo "rig-use: could not reach the lock (exit $rc).  Nothing was touched." >&2
        exit 1
    fi
    if [ "$wait" -eq 0 ]; then
        echo "rig-use: lease REFUSED -- the rig is held by another harness.  Nothing was touched." >&2
        echo "rig-use: wait for it, or re-run with --wait to poll." >&2
        exit 2
    fi
    echo "rig-use: lease held by another harness -- waiting, not stomping."
    # 60s polls: the acquire probe is cheap, and a coarser interval just wastes
    # rig time after the holder releases.  Measured 2026-08-02: a holder released
    # 27 min into a ~180-min TTL, so lease-remaining says nothing about
    # run-remaining.  Poll for the release; never release another owner's lease.
    for _ in $(seq 1 180); do         # 3h ceiling, 60s interval
        sleep 60
        control 120 lock acquire "$OWNER" "$LEASE_MINUTES" 2>/dev/null
        rc=$?
        [ "$rc" -eq 0 ] && return 0
        if [ "$rc" -ne 1 ]; then
            echo "rig-use: could not reach the lock (exit $rc) while waiting.  Nothing was touched." >&2
            exit 1
        fi
    done
    echo "rig-use: lease still held after 3h -- giving up.  Nothing was touched." >&2
    exit 2
}

# Runs sqlcmd inside the container, in one remote call that first confirms we
# hold an unexpired lease.  stdin passes through, so scripts can be piped in.
run_sqlcmd() {
    local year="$1" container ctl args="" arg
    shift
    # shellcheck disable=SC2059
    container=$(printf "$RIG_CONTAINER_PATTERN" "$year")
    ctl=$(printf '%q' "$RIG_CONTROL")
    for arg in "$@"; do args+=" $(printf '%q' "$arg")"; done

    ssh "${SSH_OPTS[@]}" "$RIG_SSH_HOST" "
lease=\$($ctl lock status </dev/null)
case \"\$lease\" in
    'held by $OWNER, -'*) echo \"rig-use: our lease has expired (\$lease).  Not connecting.\" >&2; exit 3 ;;
    'held by $OWNER, '*) ;;
    *) echo \"rig-use: we do not hold the lease (\$lease).  Not connecting; run 'tools/rig-use.sh use $year' first.\" >&2; exit 3 ;;
esac
SQLCMDPASSWORD=\$($ctl password $year </dev/null) || exit 3
[ -n \"\$SQLCMDPASSWORD\" ] || { echo 'rig-use: no SA password available for $year.' >&2; exit 3; }
export SQLCMDPASSWORD
exec docker exec -i -e SQLCMDPASSWORD $(printf '%q' "$container") $SQLCMD_PATH -S localhost -U sa -C$args
"
}

# Returns once startup recovery has finished AND every database is ONLINE, printing
# its build.  Logins are accepted, and a state check passes, before user databases
# have actually started.  A DROP DATABASE in that window removes the database from
# master but leaves its files, so every later CREATE DATABASE fails with error 5170
# (2026-11-06: the suite's setup did this to two instances, logging error 913 from
# the startup thread and no file deletes).  So the signal is SQL Server's own
# message.  The current error log starts at each restart, so an old message cannot
# satisfy this.  Asserting on a parsed build rather than on exit status alone: a
# sqlcmd error message is also output, and it must not read as ready.
wait_for_logins() {
    local year="$1" waited=0 build
    while [ "$waited" -lt "$READY_TIMEOUT_SECONDS" ]; do
        build=$(run_sqlcmd "$year" -h-1 -W -Q \
            "SET NOCOUNT ON; DECLARE @RecoveryLog table (LogDate datetime, ProcessInfo sysname, LogText nvarchar(max)); INSERT INTO @RecoveryLog EXEC sys.xp_readerrorlog 0, 1, N'Recovery is complete'; SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM @RecoveryLog) OR EXISTS (SELECT 1 FROM sys.databases WHERE state <> 0) THEN N'recovering' ELSE CONVERT(nvarchar(128), SERVERPROPERTY('ProductVersion')) END;" \
            </dev/null 2>/dev/null | tr -d '[:space:]')
        case "$build" in
            [0-9]*.[0-9]*.[0-9]*)
                echo "rig-use: READY: $year, build $build, recovery complete (after ${waited}s)."
                return 0
                ;;
        esac
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}

case "$ACTION" in
    status)
        require_config
        control 120 status
        ;;

    release)
        require_config
        control 120 lock release "$OWNER"
        ;;

    use)
        YEAR="${1:-}"
        WAIT=0
        [ "${2:-}" = "--wait" ] && WAIT=1
        require_year "$YEAR"
        require_config
        acquire_lease "$WAIT"

        # Only reachable with the lease held.  On failure the lease stays held so
        # the rig is not left unguarded in an unknown state.
        if ! control 600 ensure "$YEAR"; then
            echo "rig-use: ensure $YEAR failed AFTER acquiring the lease; the lease is still held.  Investigate, then 'release'." >&2
            exit 1
        fi
        if ! wait_for_logins "$YEAR"; then
            echo "rig-use: $YEAR did not accept a login within ${READY_TIMEOUT_SECONDS}s; the lease is still held.  Investigate, then 'release'." >&2
            exit 1
        fi
        ;;

    stop)
        require_config
        acquire_lease 0
        if ! control 300 stop; then
            echo "rig-use: stop failed AFTER acquiring the lease; the lease is still held.  Investigate, then 'release'." >&2
            exit 1
        fi
        control 120 lock release "$OWNER"
        ;;

    sqlcmd)
        YEAR="${1:-}"
        require_year "$YEAR"
        shift
        require_config
        run_sqlcmd "$YEAR" "$@"
        exit $?
        ;;

    *)
        usage
        ;;
esac
exit $?
