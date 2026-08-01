#!/bin/bash
#
# sqltest-lock -- mutual exclusion for the shared sqltest-20xx container rig.
#
# WHY THIS EXISTS
#   This 7.6 GB host can only run ONE SQL Server container at a time, so every
#   harness that wants a container stops whichever one is currently running.
#   sp_HeapDoctor and sp_StatUpdate both do that, independently, and when they
#   overlap one silently stops the other's container mid-suite. The victim sees
#   tests that emit no output at all -- which reads as "0 failures", not as an
#   error. That is how a truncated run masquerades as a green one.
#
# WHY A LEASE AND NOT flock
#   A test suite is dozens of separate ssh invocations, not one long-lived
#   process, so there is no process to hang a flock on. This takes a lease
#   instead: a directory created atomically via mkdir, holding an owner label
#   and an expiry. A crashed or disconnected run cannot wedge the rig forever
#   because the lease expires on its own.
#
# USAGE
#   sqltest-lock acquire <owner> [ttl_minutes]   # default 120
#   sqltest-lock release <owner>
#   sqltest-lock status
#   sqltest-lock run <owner> <ttl_minutes> <cmd...>   # acquire, run, always release
#
#   Re-acquiring a lease you already hold refreshes its expiry, so it is safe
#   to call before each phase of a long run.
#
# EXIT CODES
#   0 ok   1 usage error   2 held by someone else   3 not held / not owner
#
set -uo pipefail

LOCKDIR=/tmp/sqltest-rig.lock.d
OWNERFILE=$LOCKDIR/owner
EXPIRYFILE=$LOCKDIR/expires_at

now() { date +%s; }

read_lease() {
    LEASE_OWNER=""; LEASE_EXPIRY=0
    [ -d "$LOCKDIR" ] || return 1
    LEASE_OWNER=$(cat "$OWNERFILE" 2>/dev/null || echo "unknown")
    LEASE_EXPIRY=$(cat "$EXPIRYFILE" 2>/dev/null || echo 0)
    return 0
}

expired() { [ "$(now)" -ge "${LEASE_EXPIRY:-0}" ]; }

reap_if_expired() {
    if read_lease && expired; then
        echo "sqltest-lock: reaping expired lease from '$LEASE_OWNER'" >&2
        rm -rf "$LOCKDIR"
    fi
}

cmd_acquire() {
    local owner="$1" ttl="${2:-120}"
    [ -n "$owner" ] || { echo "sqltest-lock: owner required" >&2; return 1; }
    reap_if_expired
    if mkdir "$LOCKDIR" 2>/dev/null; then
        printf '%s\n' "$owner" > "$OWNERFILE"
        printf '%s\n' "$(( $(now) + ttl * 60 ))" > "$EXPIRYFILE"
        echo "sqltest-lock: acquired by '$owner' for ${ttl}m"
        return 0
    fi
    read_lease
    if [ "$LEASE_OWNER" = "$owner" ]; then
        printf '%s\n' "$(( $(now) + ttl * 60 ))" > "$EXPIRYFILE"
        echo "sqltest-lock: refreshed by '$owner' for ${ttl}m"
        return 0
    fi
    local left=$(( (LEASE_EXPIRY - $(now)) / 60 ))
    echo "sqltest-lock: HELD by '$LEASE_OWNER' (~${left}m left). Not touching the rig." >&2
    echo "sqltest-lock: wait, or if that run is definitely dead: sqltest-lock release '$LEASE_OWNER'" >&2
    return 2
}

cmd_release() {
    local owner="$1"
    read_lease || { echo "sqltest-lock: not held"; return 0; }
    if [ "$LEASE_OWNER" != "$owner" ]; then
        echo "sqltest-lock: held by '$LEASE_OWNER', not '$owner' -- refusing to release" >&2
        return 3
    fi
    rm -rf "$LOCKDIR"
    echo "sqltest-lock: released by '$owner'"
}

cmd_status() {
    if ! read_lease; then echo "sqltest-lock: free"; return 0; fi
    local left=$(( (LEASE_EXPIRY - $(now)) / 60 ))
    if expired; then
        echo "sqltest-lock: EXPIRED lease from '$LEASE_OWNER' (reaped on next acquire)"
    else
        echo "sqltest-lock: held by '$LEASE_OWNER', ~${left}m remaining"
    fi
}

cmd_run() {
    local owner="$1" ttl="$2"; shift 2
    cmd_acquire "$owner" "$ttl" || return $?
    trap 'cmd_release "$owner" >/dev/null 2>&1' EXIT INT TERM
    "$@"
    local rc=$?
    trap - EXIT INT TERM
    cmd_release "$owner" >/dev/null
    return $rc
}

case "${1:-}" in
    acquire) shift; cmd_acquire "${1:-}" "${2:-120}" ;;
    release) shift; cmd_release "${1:-}" ;;
    status)  cmd_status ;;
    run)     shift; cmd_run "$@" ;;
    *) echo "usage: sqltest-lock {acquire <owner> [ttl_min] | release <owner> | status | run <owner> <ttl_min> <cmd...>}" >&2; exit 1 ;;
esac
