#!/usr/bin/env bash
#
# THE way to sync GitHub issues into beads for this repo.
#
# Use this instead of calling `bd github sync` directly.
#
# Why a wrapper: `bd github sync` imports labels faithfully but does not map
# them to priority, so every issue lands as P2 no matter what it is labelled.
# After one full sync here, 116 beads carried a p1-p4 label and 73 had the wrong
# priority -- including 24 marked p1-critical sitting at P2, indistinguishable
# from ordinary work in any bd query that orders by priority.
#
# Reconciling afterwards works, but "remember to run the second command" is the
# same class of defect this project keeps fixing: something that silently
# degrades when a step is skipped, and looks fine until you look closely. So the
# reconcile is not a step you remember -- it is part of sync.
#
# Usage:
#   bash tools/bd-github-sync.sh                # pull from GitHub, then reconcile
#   bash tools/bd-github-sync.sh --pull-only    # same; explicit about direction
#   bash tools/bd-github-sync.sh --dry-run      # sync, then only REPORT drift
#
# Requires:
#   - beads credentials in the environment (~/.config/bd/dolt-agent.env, sourced
#     from .bashrc/.profile -- see docs/agents/issue-tracker.md)
#   - GITHUB_TOKEN, taken from `gh auth token` if not already set. It is
#     deliberately not persisted into .beads/config.yaml: that file sits on
#     cloud-synced storage and replicates to a server other projects share.
#
# The repo lives on cloud-synced storage where the exec bit does not survive, so
# invoke with `bash`, not `./`.
#
# Exit status: 0 success, 1 sync or reconcile failed, 2 setup error.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECONCILE_ARG="--apply"

case "${1:-}" in
    ""|--pull-only) ;;
    --dry-run) RECONCILE_ARG="" ;;
    *) echo "usage: bash tools/bd-github-sync.sh [--pull-only|--dry-run]" >&2; exit 2 ;;
esac

command -v bd >/dev/null || { echo "error: bd is not on PATH." >&2; exit 2; }

if [ -z "${GITHUB_TOKEN:-}" ]; then
    command -v gh >/dev/null || { echo "error: no GITHUB_TOKEN and gh is not on PATH." >&2; exit 2; }
    GITHUB_TOKEN="$(gh auth token 2>/dev/null)" || true
    export GITHUB_TOKEN
fi
[ -n "${GITHUB_TOKEN:-}" ] || { echo "error: could not obtain a GitHub token." >&2; exit 2; }

echo "=== 1/3  pulling issues from GitHub ==="
# --pull-only: GitHub is the source of truth for this repo. A bidirectional sync
# can push local beads up as real GitHub issues, which is not what a routine
# refresh should ever do.
#
# --prefer-github, not the default --prefer-newer: step 2 below bumps each
# bead's updated_at when it reconciles priority, so under prefer-newer the NEXT
# pull sees the local bead as "newer" than a GitHub close that happened in
# between and keeps it open forever. Observed 2026-08-02: three closed issues
# stayed open in beads through two consecutive pulls until this flag. GitHub
# being the source of truth is not just a policy statement -- the conflict
# resolution has to say it too.
if ! bd github sync --pull-only --prefer-github; then
    echo "error: bd github sync failed." >&2
    exit 1
fi

echo
echo "=== 2/3  reconciling priority from labels ==="
# shellcheck disable=SC2086
if ! bash "$HERE/bd-sync-priorities.sh" $RECONCILE_ARG; then
    echo "error: priority reconciliation failed." >&2
    exit 1
fi

echo
echo "=== 3/3  cross-checking open beads against GitHub ==="
# The incremental pull uses a high-water mark, and a close that lands just
# before the mark -- inside GitHub's search-index lag -- is skipped by every
# later incremental pull. Observed 2026-08-02: three closed issues stayed open
# in beads through THREE consecutive syncs (including one with
# --prefer-github). So the wrapper verifies the invariant it exists to
# maintain: no bead may be open whose GitHub issue is closed. Stragglers get a
# targeted `bd github pull`, which bypasses the watermark.
STALE=$(bd list --json 2>/dev/null | python3 -c '
import sys, json, subprocess
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
rows = data if isinstance(data, list) else data.get("issues", data.get("beads", []))
open_beads = {}
for r in rows:
    ref = r.get("external_ref") or ""
    if "/issues/" in ref and r.get("status") in ("open", "in_progress"):
        open_beads[ref.rsplit("/", 1)[-1]] = r["id"]
if not open_beads:
    sys.exit(0)
gh = subprocess.run(["gh", "issue", "list", "--state", "open", "--limit", "200",
                     "--json", "number"], capture_output=True, text=True)
gh_open = {str(x["number"]) for x in json.loads(gh.stdout or "[]")}
for num, bead in open_beads.items():
    if num not in gh_open:
        print(bead)
')

if [ -n "$STALE" ]; then
    COUNT=$(printf '%s\n' "$STALE" | grep -c '[^[:space:]]')
    echo "found $COUNT bead(s) open whose GitHub issue is not -- watermark stragglers. Re-pulling them:"
    # shellcheck disable=SC2086
    if ! bd github pull $STALE; then
        echo "error: targeted pull of stragglers failed." >&2
        exit 1
    fi
else
    echo "none: every open bead has an open GitHub issue."
fi

exit 0
