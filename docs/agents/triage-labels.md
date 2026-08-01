# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those roles to the
actual label strings in this repo, so the mapping stops being re-derived each session.

## State roles

| Canonical role    | Label in our tracker | Meaning                                          |
| ----------------- | -------------------- | ------------------------------------------------ |
| `needs-triage`    | `needs-triage`       | Maintainer needs to evaluate this issue          |
| `needs-info`      | `needs-info`         | Waiting on reporter for more information         |
| `ready-for-agent` | `ready-for-agent`    | Fully specified, ready for an AFK agent          |
| `ready-for-human` | `ready-for-human`    | Requires human implementation                    |
| `wontfix`         | `wontfix`            | Will not be actioned                             |

The label strings match the canonical names, so no translation is needed.

`needs-triage`, `needs-info` and `ready-for-human` were created on 2026-08-01 while writing
this file. Before that they did not exist, so `/triage` could not have applied them and its
"unlabeled / needs-triage / needs-info" discovery buckets could never populate.

## Category roles

| Canonical role | Label in our tracker |
| -------------- | -------------------- |
| `bug`          | `bug`                |
| `enhancement`  | `enhancement`        |

## Repo-specific labels

Not part of the canonical vocabulary. Documented so an audit can tell deliberate from
accidental.

| Label             | Meaning                                                                                                  |
| ----------------- | -------------------------------------------------------------------------------------------------------- |
| `triage-reviewed` | The issue has been evaluated against the code. In practice this repo's marker for "triaged and accepted"  |
| `stale-source`    | A `wontfix` variant: the claim was **verified false**, usually written against an outdated copy of the code |

`stale-source` earns its own label because it is a recurring failure mode here, not a
one-off. #180, #183 and #184 all asserted that `@UpdateStatsAfterRebuild` did not exist; it
had existed since `v0302e`. Distinguishing "we decline this" from "this was never true"
keeps the `wontfix` bucket meaningful.

## Priority labels

Orthogonal to state and category; apply at most one.

| Label              | Use for                                                            |
| ------------------ | ------------------------------------------------------------------ |
| `p1-critical`      | Data loss, corruption, or a wrong result presented as correct       |
| `p2-important`     | A documented feature does not work, or a safety check cannot fail   |
| `p3-nice-to-have`  | Real but tolerable; usually hygiene or an untested-but-correct path |
| `p4-deferred`      | Acknowledged, deliberately not scheduled                            |

**Note:** `bd github sync` does **not** read these. Every issue arrives in beads as `P2`
regardless of the label. If you order work by beads priority, it is not reflecting GitHub.

## Topical labels

Free-form, several may apply: `code-quality`, `locking`, `query-store`, `replication`,
`temporal`, `compatibility`, `containers`, `azure`, `performance`, `diagnostic`,
`documentation`.

## Applying them

Every triaged issue carries exactly **one category role** and **one state role**, plus
optionally one priority and any number of topical labels.

```bash
gh issue edit <n> --add-label "bug,p2-important,locking,triage-reviewed"
```

If two state roles are ever present at once, that is a conflict -- flag it to the
maintainer rather than guessing which one wins.
