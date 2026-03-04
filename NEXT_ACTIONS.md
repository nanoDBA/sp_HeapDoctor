# sp_HeapDoctor -- Next Actions

## Current State (2026-03-04)

**Version:** 1.0.2026.0302j
**Test suite:** 26 automated test scripts in `tests/` (01-26) + cleanup (99)
**All Batches 1-9 complete** — 0302a through 0302i shipped
**Batch 10 (session 0302j):** Security + correctness fixes (#93, #105, #122, #131, #132, #143)

## What Was Done (Batches 1-9, 0302a–0302i)

| Batch | Version | Key Items |
|-------|---------|-----------|
| 1-5   | 0302    | Region markers, @Force, LOB TOCTOU, CommandLog schema validation |
| 6     | 0302a-b | Critical bugs: compression, replication, FK detection, log space preflight |
| 7     | 0302c   | Safety guards: @AllowReplicationRebuild, AG failover, @CheckPermissionsOnly |
| 8     | 0302d-e | @Debug, @FillFactor, memory-optimized exclusion, @UpdateStatsAfterRebuild |
| 9     | 0302f-i | Observability (XE, CommandLog improvements), IO latch stats, @OutputTable, @GenerateScript, resumable CI swap, temporal history |

## v0302j — Security + Correctness (just shipped)

- **#131/#132**: @OutputTable PARSENAME+QUOTENAME validation prevents SQL injection
- **#143**: @UpdateStatsAfterRebuild fixed — uses `USE [db] + 2-part name` (UPDATE STATISTICS doesn't support 3-part names)
- **#122**: @GenerateScript RAISERROR uses `%s` format to handle `%` in object names
- **#93**: Stale stats note corrected — heap rebuild does not change modification counter; auto-update does NOT trigger
- **#105**: Discovery exclusion extended to XML indexes (type 3) and spatial indexes (type 4)

## Confirmed ALREADY_FIXED Issues (batch close ready)

These issues were fixed in earlier versions (0302a-0302i) and can be closed:

| Issue | Title | Fixed In |
|-------|-------|----------|
| #95  | AG secondary guard | 0302c |
| #98  | Columnstore guard for CI swap | 0302 (was already in discovery exclusion) |
| #101 | Key width 900→1700 | Code already uses `<= 1700` in HAVING clause |
| #108 | DATA_COMPRESSION in CI swap DDL | 0302b (compression preservation) |
| #109 | Concurrent runs guard (sp_getapplock) | 0302 (`@Force` + sp_getapplock) |
| #111 | @Databases parser spaces (LTRIM/RTRIM) | 0302 (DatabaseSplitter CTE) |
| #120 | @GenerateScript DATA_COMPRESSION | 0302h (command_text already includes it) |
| #123 | DB_ID() wrong database | 0302d+ (discovery SQL uses USE [db]) |
| #139 | @UseResumable RESUME wrong index | 0302i (deterministic naming `CX__Temp__[table]`) |
| #144 | @UseResumable=1 fails on SQL 2017 | 0302i (silent downgrade at validation) |

## Open Issues — Lars to Triage

See `memory/sp-heapdoctor-issue-analysis.md` for full triage. Summary:

### NEEDS_INVESTIGATION (24 issues)

These require deeper analysis, multi-session testing, or are complex enhancements:

| # | Title | Category |
|---|-------|----------|
| #94  | recommended_action column for automation | Enhancement |
| #97  | CI swap DROP failure — orphaned CI alert | Bug (complex) |
| #99  | Filtered NCI statistics after CI swap | Enhancement/edge case |
| #102 | CI swap mid-failure recovery guidance | Bug (complex, related to #97) |
| #103 | Resumable resume with multiple paused ops on same table | Edge case |
| #107 | CommandLog START missing filter params | Enhancement |
| #110 | Cross-database FK detection | Enhancement |
| #113 | Empty CATCH blocks for XE side-channel | Needs design decision |
| #115 | FK warning timing (pre-summary vs per-heap) | Enhancement |
| #119 | @GenerateScript temporal SYSTEM_VERSIONING | Enhancement |
| #129 | CI swap second-best candidate selection | Enhancement |
| #130 | Post CI swap child FK table statistics | Enhancement |
| #134 | @OutputTable schema evolution (new columns) | Enhancement |
| #135 | Discovery SAMPLED mode notification | Enhancement |
| #138 | Stats update timing vs CommandLog END | Enhancement (related to #143) |
| #141 | SYSTEM_VERSIONING recovery from KILL | Complex bug |
| #142 | @TopN CI swap preference | Enhancement |
| #145 | VLF fragmentation in rebuild priority | Enhancement |
| #146 | @PlanOnly SYSTEM_VERSIONING display | Enhancement |

### BY_DESIGN (15 issues)

These describe intended behavior — close with explanation:

| # | Title | Rationale |
|---|-------|-----------|
| #96  | Check constraints documentation | SQL Server preserves constraints through CI swap automatically |
| #100 | CI swap INCLUDE columns | Key-only CI is intentional (simpler, no INCLUDE bloat) |
| #104 | Sch-M lock duration | No way to avoid with ALTER TABLE REBUILD |
| #106 | Cold-start ETA fallback | Documented parameter, known limitation |
| #112 | INSTEAD OF trigger note per-table | Informational, per-table scope is intentional |
| #114 | @Execute 'DryRun' behavior | Documented alias for plan-only |
| #116 | @MinForwardedPct 2% default | Configurable, documented |
| #118 | avg_fragmentation_in_percent semantics | Documented SQL Server behavior |
| #121 | @GenerateScript idempotent | Re-running is user responsibility; documented |
| #124 | IO latch normalization by uptime | Not scoped; raw counts are useful for comparison |
| #125 | @LockTimeoutMs naming | Consistent with SQL Server parameter convention |
| #126 | @MaxDOP MAX_GRANT_PERCENT | Separate concern; use OPTION (MAX_GRANT_PERCENT) externally |
| #127 | Heap scan memory grant | MAXDOP parameter controls parallelism |
| #128 | @MinPages page_count vs alloc | Documented; page_count is correct metric for forwarded record cost |
| #133 | @OutputTable NULL est_seconds | NULL-able by design; documented |
| #136 | @MinPages page_count documentation | Documentation update only |
| #137 | Partitioned heap block rationale | Documentation update only |
| #140 | Temporal CI swap block rationale | Documentation update only |

## Test Suite Status (2026-03-04)

| Container | Real Failures (`*** FAIL`) | Notes |
|-----------|---------------------------|-------|
| sqltest-2019 (SQL 2019) | 0 | All 26 test files pass |
| sqltest-2017 (SQL 2017) | 0 | All 26 test files pass |

**Note:** The test runner's grep-based PASS/FAIL counter is unreliable — it counts "FAIL" in phrases like "Failed: 0" and "Review PASS/FAIL". The actual failure signal is `*** FAIL` in assertions. Both containers have zero real failures.

## Git Log Summary

```
fix: security+correctness: @OutputTable injection, stats fix, % escaping (#93, #105, #122, #131, #132, #143)
```

## What's Left for Batch 10+

- Address NEEDS_INVESTIGATION issues above (Lars approves priority order)
- Batch close of ALREADY_FIXED issues (Lars to review and close on GitHub)
- Potential Batch 11: commandLog improvements, @GenerateScript temporal, @OutputTable schema evolution
- Documentation updates for BY_DESIGN issues (can be done in one doc pass)

## Push to GitHub

Lars approves pushes. Current commits ready to push:
- v0302j commit (security + correctness)
- docs: updated NEXT_ACTIONS.md
