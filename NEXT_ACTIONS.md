# sp_HeapDoctor -- Next Actions

## Current State (2026-03-13)

**Version:** 2026.03.11.1
**Test suite:** 26 automated test scripts in `tests/` (01-26) + cleanup (99)
**All Batches 1-9 complete** -- 0302a through 0302i shipped
**Batch 10 (v0302j):** Security + correctness fixes (#93, #105, #122, #131, #132, #143)
**Issue triage (2026-03-13):** All 44 open issues reviewed and resolved

## What Was Done (Batches 1-9, 0302a-0302i)

| Batch | Version | Key Items |
|-------|---------|-----------|
| 1-5   | 0302    | Region markers, @Force, LOB TOCTOU, CommandLog schema validation |
| 6     | 0302a-b | Critical bugs: compression, replication, FK detection, log space preflight |
| 7     | 0302c   | Safety guards: @AllowReplicationRebuild, AG failover, @CheckPermissionsOnly |
| 8     | 0302d-e | @Debug, @FillFactor, memory-optimized exclusion, @UpdateStatsAfterRebuild |
| 9     | 0302f-i | Observability (XE, CommandLog), IO latch stats, @OutputTable, @GenerateScript, resumable CI swap, temporal history |

## Issue Triage Complete (2026-03-13)

All 44 open issues have been reviewed against the codebase. Result:

### Fixed This Session (1 issue)

| # | Title | Fix |
|---|-------|-----|
| #119 | @GenerateScript temporal SYSTEM_VERSIONING | @Help text was stale -- said "manual" but code generates wrappers automatically since v0302i |

### Already Fixed in Prior Versions (29 issues -- close on GitHub)

| # | Title | Fixed In |
|---|-------|----------|
| #94  | recommended_action column | v0226+ (column exists: CI_SWAP/REBUILD/MONITOR) |
| #95  | AG secondary guard | 0302c |
| #97  | CI swap DROP failure orphan alert | v0302+ (orphan scan + per-rebuild CATCH) |
| #98  | Columnstore guard for CI swap | 0302 (discovery exclusion) |
| #99  | Filtered NCI stats after CI swap | v0311 #163 (warning fires for all rebuild paths) |
| #101 | Key width 900-1700 | Code uses `<= 1700` in HAVING |
| #102 | CI swap recovery guidance | v0302+ (paste-ready DROP in orphan scan) |
| #103 | Resumable multiple paused ops | v0302i (exact index name filter) |
| #107 | CommandLog START missing params | v0302j (comment + @invocation_command has all) |
| #108 | DATA_COMPRESSION in CI swap DDL | 0302b |
| #109 | Concurrent runs guard | 0302 (@Force + sp_getapplock) |
| #111 | @Databases parser spaces | 0302 (DatabaseSplitter CTE) |
| #113 | Empty CATCH for XE trace | v0302d+ (@Debug surfacing at all 4 sites) |
| #115 | FK warning timing | v0302b (pre-execution, by design) |
| #120 | @GenerateScript DATA_COMPRESSION | 0302h |
| #123 | DB_ID() wrong database | 0302d+ |
| #130 | Post CI swap child FK stats | v0311 #164 (unconditional after CI swap) |
| #134 | @OutputTable schema evolution | v0302h (drift detection + ALTER TABLE ADD) |
| #135 | Discovery SAMPLED mode notification | v0302+ (output message + verify_command) |
| #138 | Stats timing vs CommandLog END | No bug (correct order: stats before CommandLog END) |
| #139 | @UseResumable RESUME wrong index | 0302i |
| #141 | SYSTEM_VERSIONING recovery from KILL | v0302i (startup orphan check + breadcrumbs) |
| #144 | @UseResumable=1 fails on SQL 2017 | 0302i |
| #145 | VLF fragmentation | v0311.1 #168 (advisory warning when > 1000) |
| #146 | @PlanOnly SYSTEM_VERSIONING display | v0302i (is_temporal_history in result set) |

### By Design / Documented (18 issues -- close on GitHub with explanation)

| # | Title | Rationale |
|---|-------|-----------|
| #96  | Check constraints documentation | SQL Server preserves constraints through CI swap |
| #100 | CI swap INCLUDE columns | Key-only CI intentional (simpler, no INCLUDE bloat) |
| #104 | Sch-M lock duration | Unavoidable with ALTER TABLE REBUILD |
| #106 | Cold-start ETA fallback | Documented parameter, known limitation |
| #110 | Cross-database FK detection | SQL Server doesn't support cross-DB FKs natively |
| #112 | INSTEAD OF trigger note per-table | Informational, per-table scope intentional |
| #114 | @Execute 'DryRun' behavior | Documented alias for plan-only |
| #116 | @MinForwardedPct 2% default | Configurable, documented |
| #118 | avg_fragmentation_in_percent semantics | Documented SQL Server behavior |
| #121 | @GenerateScript idempotent | Re-running is user responsibility |
| #124 | IO latch normalization by uptime | Raw counts useful for comparison |
| #125 | @LockTimeoutMs naming | Consistent with SQL Server convention |
| #126 | @MaxDOP MAX_GRANT_PERCENT | Separate concern |
| #127 | Heap scan memory grant | MAXDOP controls parallelism |
| #128 | @MinPages page_count vs alloc | page_count is correct metric |
| #129 | CI swap second-best candidate | Only best key used; falls back to REBUILD if blocked |
| #133 | @OutputTable NULL est_seconds | NULL-able by design |
| #142 | @TopN CI swap preference | Documented in @Help with workaround |

### Documentation-Only (3 issues -- can be closed or done in one doc pass)

| # | Title |
|---|-------|
| #136 | @MinPages page_count documentation |
| #137 | Partitioned heap block rationale |
| #140 | Temporal CI swap block rationale |

## Test Suite Status (2026-03-04)

| Container | Real Failures | Notes |
|-----------|---------------|-------|
| sqltest-2019 (SQL 2019) | 0 | All 26 test files pass |
| sqltest-2017 (SQL 2017) | 0 | All 26 test files pass |

## What's Left

- **Batch close on GitHub**: 29 ALREADY_FIXED + 18 BY_DESIGN + 3 docs-only = 50 issues to close
- **No open bugs remain** -- all NEEDS_INVESTIGATION items resolved
- Future work: new feature requests only (no backlog)
