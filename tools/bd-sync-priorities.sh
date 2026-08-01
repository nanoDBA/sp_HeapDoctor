#!/usr/bin/env bash
#
# Reconcile beads priority from GitHub priority labels.
#
# `bd github sync` imports labels faithfully but does not map them to priority:
# every issue arrives as P2 regardless of whether it is labelled p1-critical or
# p4-deferred. Measured on this repo after a full sync: 116 beads carried a
# p1-p4 label and 73 had the wrong priority, including 24 marked p1-critical
# sitting at P2 -- indistinguishable from ordinary work in any bd query that
# orders by priority.
#
# This runs AFTER `bd github sync` and fixes that. GitHub remains the source of
# truth; the label is authoritative and beads is reconciled to it.
#
# Usage:
#   bash tools/bd-sync-priorities.sh              # dry run, shows what would change
#   bash tools/bd-sync-priorities.sh --apply      # actually update
#
# Requires bd credentials in the environment (see docs/agents/issue-tracker.md).
# The repo lives on cloud-synced storage where the exec bit does not survive, so
# invoke with `bash`, not `./`.
#
# Exit status: 0 success (including "nothing to do"), 1 an update failed,
# 2 setup error.

set -uo pipefail

APPLY=0
case "${1:-}" in
    --apply) APPLY=1 ;;
    ""|--dry-run) APPLY=0 ;;
    *) echo "usage: bash tools/bd-sync-priorities.sh [--apply]" >&2; exit 2 ;;
esac

command -v bd >/dev/null || { echo "error: bd is not on PATH." >&2; exit 2; }

SNAPSHOT=$(mktemp) || exit 2
trap 'rm -f "$SNAPSHOT"' EXIT

if ! bd list --status all --limit 5000 --json > "$SNAPSHOT" 2>/dev/null; then
    echo "error: could not read beads. Are the credentials loaded and the server reachable?" >&2
    exit 2
fi

# Emit "id<TAB>current<TAB>wanted" for every bead whose label disagrees with its
# stored priority. Parsing in python because the payload is JSON and the label
# list is nested -- grep/sed on that is how silent mismatches get introduced.
MISMATCHES=$(python3 - "$SNAPSHOT" <<'PY'
import json, sys

LABEL_TO_PRIORITY = {
    'p1-critical':     1,
    'p2-important':    2,
    'p3-nice-to-have': 3,
    'p4-deferred':     4,
}

data = json.load(open(sys.argv[1]))
rows = data if isinstance(data, list) else data.get('issues', data.get('beads', []))

for row in rows:
    wanted = [LABEL_TO_PRIORITY[l] for l in (row.get('labels') or []) if l in LABEL_TO_PRIORITY]
    if len(wanted) != 1:
        # No priority label, or more than one -- not something to guess at.
        continue
    if row.get('priority') != wanted[0]:
        print(f"{row['id']}\t{row.get('priority')}\t{wanted[0]}")
PY
) || { echo "error: failed to parse the beads snapshot." >&2; exit 2; }

if [ -z "$MISMATCHES" ]; then
    echo "All beads already match their GitHub priority label. Nothing to do."
    exit 0
fi

COUNT=$(printf '%s\n' "$MISMATCHES" | grep -c '[^[:space:]]')

if [ "$APPLY" -eq 0 ]; then
    echo "$COUNT bead(s) disagree with their priority label (dry run):"
    printf '%s\n' "$MISMATCHES" | awk -F'\t' '{printf "  %-46s P%s -> P%s\n", $1, $2, $3}' | head -20
    [ "$COUNT" -gt 20 ] && echo "  ... and $((COUNT - 20)) more"
    echo
    echo "Re-run with --apply to update them."
    exit 0
fi

echo "Updating $COUNT bead(s)..."
failed=0
while IFS=$'\t' read -r id current wanted; do
    [ -n "$id" ] || continue
    if bd update "$id" -p "$wanted" >/dev/null 2>&1; then
        printf '  %-46s P%s -> P%s\n' "$id" "$current" "$wanted"
    else
        printf '  FAILED %-40s P%s -> P%s\n' "$id" "$current" "$wanted" >&2
        failed=$((failed + 1))
    fi
done <<< "$MISMATCHES"

if [ "$failed" -gt 0 ]; then
    echo "$failed update(s) failed." >&2
    exit 1
fi

echo "Done. $COUNT bead(s) reconciled."
exit 0
