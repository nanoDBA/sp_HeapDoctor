#!/usr/bin/env bash
#
# Lease-gated container activation for the shared sqltest rig.
#
# THE ONLY sanctioned way for this repo to start or stop a sqltest container.
#
# Why this exists (2026-08-02 incident): the harness had no lock integration --
# tests/run_suite.sh drives sqlcmd through whatever HEAPDOCTOR_SQLCMD points at
# and never consults the lease, and container switching was raw caller-side
# `docker stop`/`docker start`. The acquire/release was a README instruction,
# i.e. advisory. Ad-hoc orchestrators then piped `sqltest-lock acquire` to
# /dev/null and ignored its exit code, so when sp_StatUpdate held a live lease
# this harness stomped its containers mid-run. A refused acquire refused
# nothing.
#
# This tool makes refusal mean refusal:
#
#   bash tools/rig-use.sh <ssh-host> use <container>          # acquire or exit 2
#   bash tools/rig-use.sh <ssh-host> use <container> --wait   # acquire or poll (3h ceiling)
#   bash tools/rig-use.sh <ssh-host> release
#   bash tools/rig-use.sh <ssh-host> status
#
# On `use`: the lease is acquired FIRST, and only a successful acquire is
# followed by stopping other sqltest containers and starting the requested one.
# The default on refusal is exit 2 with a message -- the polite one-liner:
#
#   bash tools/rig-use.sh <host> use sqltest-2022 || { echo "rig held -- not starting"; exit 2; }
#
# `--wait` opts an orchestrator into polling until the lease frees.
#
# No hostname, credential, or rig-specific value is committed here: the host is
# an argument, the remote lock tool defaults to ~/bin/sqltest-lock and can be
# overridden with SQLTEST_LOCK_CMD, and this script never touches SQL logins --
# readiness and credentials remain the caller's concern (HEAPDOCTOR_SQLCMD).
#
# The lease owner string is "sp_HeapDoctor": the lock identifies the HARNESS,
# not the person, so the other project can tell whose run holds the rig.
#
# Exit status: 0 done; 2 lease refused (nothing was touched) or usage error;
# 1 remote/docker failure after the lease was held.

set -uo pipefail

HOST="${1:-}"
ACTION="${2:-}"
LOCK_CMD="${SQLTEST_LOCK_CMD:-~/bin/sqltest-lock}"
OWNER="sp_HeapDoctor"
LEASE_MINUTES=180

usage() {
    echo "usage: bash tools/rig-use.sh <ssh-host> use <container> [--wait] | release | status" >&2
    exit 2
}

[ -n "$HOST" ] && [ -n "$ACTION" ] || usage

rssh() { timeout 120 ssh -o BatchMode=yes -o ConnectTimeout=40 "$HOST" "$@"; }

case "$ACTION" in
    status)
        rssh "$LOCK_CMD status"
        ;;

    release)
        rssh "$LOCK_CMD release $OWNER"
        ;;

    use)
        CONTAINER="${3:-}"
        [ -n "$CONTAINER" ] || usage
        WAIT=0
        [ "${4:-}" = "--wait" ] && WAIT=1

        # The gate. Exit code checked; a refusal touches nothing.
        if ! rssh "$LOCK_CMD acquire $OWNER $LEASE_MINUTES"; then
            if [ "$WAIT" -eq 0 ]; then
                echo "rig-use: lease REFUSED -- the rig is held by another harness. Nothing was touched." >&2
                echo "rig-use: wait for it, or re-run with --wait to poll." >&2
                exit 2
            fi
            echo "rig-use: lease held by another harness -- waiting, not stomping."
            acquired=0
            for _ in $(seq 1 60); do          # 3h ceiling, 3-min interval
                sleep 180
                if rssh "$LOCK_CMD acquire $OWNER $LEASE_MINUTES"; then
                    acquired=1
                    break
                fi
            done
            if [ "$acquired" -ne 1 ]; then
                echo "rig-use: lease still held after 3h -- giving up. Nothing was touched." >&2
                exit 2
            fi
        fi

        # Only reachable with the lease held.
        if rssh "docker stop \$(docker ps -q --filter name=sqltest) >/dev/null 2>&1; sleep 3; docker start $CONTAINER >/dev/null"; then
            echo "rig-use: lease held; $CONTAINER started. Allow ~30s for SQL Server to accept connections."
        else
            echo "rig-use: docker activation failed AFTER acquiring the lease; the lease is still held so the rig is not left unguarded. Investigate, then 'release'." >&2
            exit 1
        fi
        ;;

    *)
        usage
        ;;
esac
exit 0
