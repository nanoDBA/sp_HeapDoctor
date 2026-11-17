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
#   bash tools/rig-use.sh run-create <year> [--wait]    # fresh environment for one version; versions may overlap
#   bash tools/rig-use.sh run-sqlcmd <year> [sqlcmd args]  # run sqlcmd in that fresh environment
#   bash tools/rig-use.sh run-destroy <year>            # remove that fresh environment and release its slot
#   bash tools/rig-use.sh run-list                      # the fresh environments this machine created
#
# TWO WAYS IN.  "use" takes the whole rig and reuses one long-lived environment
# per version, one version at a time.  "run-create" takes a slot for ONE version
# and builds a fresh environment from the staged data, so 2019, 2022 and 2025 can
# run side by side and nothing needs cleaning up by hand between runs.  The two
# exclude each other: a slot waits while the whole rig is held, and "use" is
# refused while any slot is live.  Each run has its own lease owner,
# "sp_HeapDoctor-<run id>", and the control script deletes only the container and
# volume that carry that run id.
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
    sed -n '7,16p' "${BASH_SOURCE[0]}" | sed 's/^# */usage: /' >&2
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

# ---- Fresh per-version environments ("run slots") ----------------------------
#
# The run id and container name of each run this machine created are kept
# outside the repo, one file per version, so a later call (or a later session)
# can find and destroy it.
RUN_STATE_DIR="${RIG_RUN_STATE_DIR:-$HOME/.cache/sp_HeapDoctor-rig}"
RUN_LEASE_MINUTES=180

run_state_file() { echo "$RUN_STATE_DIR/run-$1"; }

# Sets RUN_ID, RUN_OWNER and RUN_CONTAINER for a version, or exits 3.
load_run() {
    local year="$1" file
    file=$(run_state_file "$year")
    if [ ! -f "$file" ]; then
        echo "rig-use: no fresh environment recorded for $year.  Run 'tools/rig-use.sh run-create $year' first." >&2
        exit 3
    fi
    read -r RUN_ID RUN_CONTAINER < <(tr -d '\r' < "$file")
    case "$RUN_ID" in
        *[!0-9a-f]*|"") echo "rig-use: $file is not a run record." >&2; exit 3 ;;
    esac
    [ "${#RUN_ID}" -eq 32 ] || { echo "rig-use: $file is not a run record." >&2; exit 3; }
    RUN_OWNER="$OWNER-$RUN_ID"
}

# Same contract as run_sqlcmd, against a run's own container and its own lease.
run_sqlcmd_fresh() {
    local year="$1" ctl args="" arg
    shift
    load_run "$year"
    ctl=$(printf '%q' "$RIG_CONTROL")
    for arg in "$@"; do args+=" $(printf '%q' "$arg")"; done

    ssh "${SSH_OPTS[@]}" "$RIG_SSH_HOST" "
lease=\$($ctl lock status </dev/null | grep -F 'held by $RUN_OWNER, version=$year, ')
case \"\$lease\" in
    'held by $RUN_OWNER, version=$year, -'*) echo \"rig-use: the lease for this run has expired (\$lease).  Not connecting.\" >&2; exit 3 ;;
    'held by $RUN_OWNER, version=$year, '*) ;;
    *) echo 'rig-use: this run does not hold a lease for $year.  Not connecting.' >&2; exit 3 ;;
esac
SQLCMDPASSWORD=\$($ctl password $year </dev/null) || exit 3
[ -n \"\$SQLCMDPASSWORD\" ] || { echo 'rig-use: no SA password available for $year.' >&2; exit 3; }
export SQLCMDPASSWORD
exec docker exec -i -e SQLCMDPASSWORD $(printf '%q' "$RUN_CONTAINER") $SQLCMD_PATH -S localhost -U sa -C$args
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

    run-create)
        YEAR="${1:-}"
        WAIT=0
        [ "${2:-}" = "--wait" ] && WAIT=1
        require_year "$YEAR"
        require_config
        if [ -f "$(run_state_file "$YEAR")" ]; then
            echo "rig-use: a fresh environment for $YEAR is already recorded.  Destroy it first with 'run-destroy $YEAR'." >&2
            exit 2
        fi
        # A slot waits on the rig host while the whole rig is held, so say so up
        # front instead of blocking silently.  This is a courtesy check, not the
        # gate: the control script is the gate.
        LEASES=$(control 120 lock status) || { echo "rig-use: could not reach the lock.  Nothing was touched." >&2; exit 1; }
        if printf '%s\n' "$LEASES" | grep -q '^held by ' && ! printf '%s\n' "$LEASES" | grep -q 'version='; then
            if [ "$WAIT" -eq 0 ]; then
                echo "rig-use: slot REFUSED -- the whole rig is held ($LEASES).  Nothing was touched." >&2
                echo "rig-use: wait for it, or re-run with --wait." >&2
                exit 2
            fi
            echo "rig-use: the whole rig is held ($LEASES) -- waiting for it."
        fi
        if printf '%s\n' "$LEASES" | grep -q "version=$YEAR," && [ "$WAIT" -eq 0 ]; then
            echo "rig-use: slot REFUSED -- another run holds $YEAR.  Nothing was touched." >&2
            exit 2
        fi
        RUN_ID=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
        RUN_OWNER="$OWNER-$RUN_ID"
        mkdir -p "$RUN_STATE_DIR"
        # Recorded before anything is created, so a failure below still leaves a
        # record that run-destroy can act on.
        echo "$RUN_ID pending" > "$(run_state_file "$YEAR")"
        if ! control 7500 lock acquire "$RUN_OWNER" "$RUN_LEASE_MINUTES"; then
            rm -f "$(run_state_file "$YEAR")"
            echo "rig-use: could not take a slot lease.  Nothing was created." >&2
            exit 1
        fi
        CREATED=$(control 7500 run create "$YEAR" "$RUN_ID" "$RUN_OWNER")
        RC=$?
        printf '%s\n' "$CREATED"
        RUN_CONTAINER=$(printf '%s\n' "$CREATED" | sed -n 's/^run ready: .* container=\([^ ]*\) .*/\1/p' | tail -1)
        if [ "$RC" -ne 0 ] || [ -z "$RUN_CONTAINER" ]; then
            echo "rig-use: run create $YEAR failed; the record is kept.  Run 'tools/rig-use.sh run-destroy $YEAR' to clean up." >&2
            exit 1
        fi
        echo "$RUN_ID $RUN_CONTAINER" > "$(run_state_file "$YEAR")"
        BUILD=$(run_sqlcmd_fresh "$YEAR" -h-1 -W -Q "SET NOCOUNT ON; SELECT CONVERT(nvarchar(128), SERVERPROPERTY('ProductVersion'));" </dev/null 2>/dev/null | tr -d '[:space:]')
        case "$BUILD" in
            [0-9]*.[0-9]*.[0-9]*) echo "rig-use: READY: fresh $YEAR, build $BUILD." ;;
            *) echo "rig-use: fresh $YEAR was created but did not answer a query.  Run 'run-destroy $YEAR' to clean up." >&2; exit 1 ;;
        esac
        ;;

    run-sqlcmd)
        YEAR="${1:-}"
        require_year "$YEAR"
        shift
        require_config
        run_sqlcmd_fresh "$YEAR" "$@"
        exit $?
        ;;

    run-destroy)
        YEAR="${1:-}"
        require_year "$YEAR"
        require_config
        load_run "$YEAR"
        # Destroy needs a live lease, and ours may have expired during a long run.
        # Acquiring again only extends our own lease.
        if ! control 7500 lock acquire "$RUN_OWNER" "$RUN_LEASE_MINUTES"; then
            echo "rig-use: could not renew the lease for this run.  Nothing was removed." >&2
            exit 1
        fi
        if ! control 600 run destroy "$YEAR" "$RUN_ID" "$RUN_OWNER"; then
            echo "rig-use: run destroy $YEAR failed; the record and the lease are kept.  Investigate, then retry." >&2
            exit 1
        fi
        if ! control 120 lock release "$RUN_OWNER"; then
            echo "rig-use: the run is gone but its lease was not released.  Retry 'run-destroy $YEAR'." >&2
            exit 1
        fi
        rm -f "$(run_state_file "$YEAR")"
        ;;

    run-list)
        for YEAR in 2019 2022 2025; do
            if [ -f "$(run_state_file "$YEAR")" ]; then
                read -r RUN_ID RUN_CONTAINER < <(tr -d '\r' < "$(run_state_file "$YEAR")")
                echo "$YEAR run=$RUN_ID container=$RUN_CONTAINER"
            fi
        done
        ;;

    *)
        usage
        ;;
esac
exit $?
