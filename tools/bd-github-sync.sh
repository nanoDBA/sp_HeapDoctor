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

echo "=== 1/2  pulling issues from GitHub ==="
# --pull-only: GitHub is the source of truth for this repo. A bidirectional sync
# can push local beads up as real GitHub issues, which is not what a routine
# refresh should ever do.
if ! bd github sync --pull-only; then
    echo "error: bd github sync failed." >&2
    exit 1
fi

echo
echo "=== 2/2  reconciling priority from labels ==="
# shellcheck disable=SC2086
if ! bash "$HERE/bd-sync-priorities.sh" $RECONCILE_ARG; then
    echo "error: priority reconciliation failed." >&2
    exit 1
fi

exit 0
