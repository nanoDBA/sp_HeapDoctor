# sp_HeapDoctor - Internal Contracts

> `STYLE_GUIDE.md` covers how the code should **look**. This covers what must stay
> **true**. A reviewer following the style guide to the letter would have passed every
> defect listed below.
>
> Structure adopted from sp_StatUpdate's `CONSISTENCY_GUIDELINES.md`, which separates the
> two concerns. Every entry here has an issue number attached because every one of them
> was learned the expensive way.

## 1. Partial results announce themselves

**The rule:** any run that returns a subset of what was asked for must say so. Silence is
reserved for "complete and nothing to report".

This is the single most repeated defect in the project's history:

| Issue | What was silent |
| --- | --- |
| #193 | A test run whose container died produced no output and reported **zero failures** |
| #198 | `@MinForwardedPct` dropped heaps inside the discovery `WHERE`, so "nothing qualified" and "everything was filtered" looked identical |
| #199 | A blocked scan stalled discovery; the run reported total success after 41 seconds against a 2-second cap |
| #195 | `QUICKIESTORE` ranked one database and left the rest at `cpu_ms = 0`, visible only as a warning naming no rows |
| #187 | A CI swap whose `DROP` failed left the table clustered and **advanced the success counter** |

**How to apply it:** when adding a filter, an early exit, or an error branch, ask what the
caller sees when it fires. If the answer is "fewer rows and no explanation", it is wrong.
Count what you dropped and say so; the rows are usually already materialised, so counting
them is free.

## 2. Output parameters are set on every non-error exit

**The rule:** `@TargetsFound`, `@Succeeded`, `@Failed`, `@Skipped`, `@Status` and
`@StatusMessage` are assigned on every path that returns without raising at severity 16.
Zero where nothing happened -- never NULL.

**Why:** `IF @TargetsFound = 0` never matches NULL, so a caller cannot distinguish "did
nothing" from "never ran". Before #204 they were assigned only on normal completion, so
`@Help`, `@CheckPermissionsOnly`, reveal mode, plan-only runs and the zero-target exit all
returned NULL -- and the zero-target exit is the path a nightly job against a healthy
server takes **every time**.

Error paths that `RAISERROR(..., 16, 1)` may leave them unset: the caller gets an
exception, not a return.

## 3. The verdict is `Status`, not `@Failed`

**The rule:** `ERROR > WARNING > SUCCESS`, decided in that order, with the message naming
the most severe condition.

- `ERROR` -- a rebuild failed, or a target needs manual recovery
- `WARNING` -- the run is incomplete: discovery blocked, databases errored, targets
  skipped, or heaps filtered out
- `SUCCESS` -- complete, with nothing outstanding

**Why:** `@Failed = 0` is not a clean bill of health. Every row in the table under
contract 1 leaves it at zero.

`StopReason` is the finer-grained companion, written to the `HEAP_REBUILD_END`
`ExtendedInfo` XML. It is an enum, evaluated in this order:

| Value | Meaning |
| --- | --- |
| `COMPLETED_WITH_ERRORS` | at least one rebuild failed |
| `DISCOVERY_BLOCKED` | a database could not be scanned; the target list is a **subset** |
| `COMPLETED_WITH_SCAN_ERRORS` | a database errored during discovery |
| `COMPLETED_WITH_FILTERED_HEAPS` | heaps were dropped by `@MinForwardedPct` |
| `COMPLETED_WITH_SKIPS` | targets were skipped at execution |
| `SUCCESS` | complete, nothing outstanding |

Order matters: `DISCOVERY_BLOCKED` outranks the generic scan-error value because
"the list is incomplete" is a different claim from "something errored".

## 4. The result-set shape is defined once

**The rule:** `dbo.ResultsTemplate` in `01_setup_test_data.sql` is the only definition of
the result-set column list. Tests do:

```sql
SELECT * INTO #Whatever FROM dbo.ResultsTemplate WHERE 1 = 0;
```

**Why (#190):** the 58-column DDL was duplicated across 25 test files. Three copies were
missed because they were named `#Est` / `#VerCheck` / `#EstResults` rather than `#Results`,
and **two of them reported PASS while capturing nothing** -- the `INSERT ... EXEC` failed
with `Msg 213` and the assertions ran against an empty table.

**When auditing, grep for a column name, never a temp-table name.**

## 5. The version has one source

**The rule:** `dbo.ExpectedVersion`, derived from the deployed procedure's
`sys.sql_modules` definition. No test file contains a version literal.

**Why (#191):** 19 files hardcoded it, the release sweep lapsed twice, and a stale value in
`14_test_resume` made test `14E` fail the *version* check and never reach the obfuscation
guard it is named for -- passing for the wrong reason.

A release edits **zero** test files.

## 6. An assertion must be able to fail

**The rule:** every assertion id emits a countable outcome on every path -- `PASS`, `FAIL`
or `SKIP`. `INFO` is narration and the counter cannot see it.

**Why (#202):** four ids had no failure path at all. `2F-2` was a *manual eyeball check*
wearing an assertion id ("Verify MAXDOP = 2 in the output above"), so `@Maxdop` emission
was never verified by anything. Its premise was also false -- `command_text` is a
result-set column and was capturable all along.

`SKIP` exists for assertions that genuinely may not apply on a given engine or data shape.
It records that the assertion was reached and deliberately not made, which `INFO` could
not.

**Corollary:** prove an assertion can fail. `tests/test_lock_timeout.sh` is run with a long
timeout specifically to show it goes red; that control run caught a check of mine that
matched an informational banner and could never have failed.

## 7. Dynamic SQL is parameterised

**The rule:** all values pass through `sys.sp_executesql` parameters. The only
concatenated values are identifiers via `QUOTENAME()`, and integers that SQL Server will
not accept as variables (`SET LOCK_TIMEOUT`, `MAXDOP`).

Each such exception carries a comment saying why it is safe.

## Known Debt

Accepted deviations. Listed so an audit can tell deliberate from accidental instead of
re-litigating them.

| Item | Impact | Notes |
| --- | --- | --- |
| `QUICKIESTORE` is single-database | Medium | TODO carried in region 14; cross-database targets are marked `QUICKIE_OTHER_DB` (#195) so the gap is visible rather than silent |
| `@MaxRunSeconds` granularity | Medium | Checked between databases and between targets, never inside either. A running `ALTER TABLE REBUILD` cannot be cancelled from the same session (#200) |
| Parallel dead-worker recovery | Medium | Phase B deferred; a killed worker strands its queue row (#201) |
| `SAMPLED` estimates drive filtering | Low | Disclosed in the banner, `DETAILED` available, excluded counts now reported (#198) |
| Structural assertions in tests | Low | Some paths need a second session or an installed sp_QuickieStore; those are asserted against `sys.sql_modules` and the test header says so |
| `--` comments in test files | Low | The procedure body uses `/* */` exclusively; test scripts use `--` for readability |

---
*Created 2026-08-01 while closing #205. Add to this file when a defect turns out to have*
*been an undocumented invariant rather than a coding-style slip.*
