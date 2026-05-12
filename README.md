# sp_HeapDoctor

**Heap Forwarded Record Mitigation for SQL Server** | v2026.05.11.7

Your heaps have forwarded records.  You know they do.  You've been meaning to deal with them for months.  sp_HeapDoctor finds them, ranks them by how much CPU they're actually costing you, and rebuilds them so you can stop pretending that heap is fine.

## The Problem

When a variable-length row on a heap grows beyond its original page, SQL Server doesn't move it cleanly.  It leaves a forwarding pointer on the old page and puts the row on a new page.  Every single read that follows that pointer does **double the I/O**.  At scale, forwarded records silently degrade scan and seek performance on heaps, and "silently" is the operative word because nothing in your monitoring is going to flag this until you go looking.

Most DBAs fix this manually: run `dm_db_index_physical_stats`, squint at the results, decide which tables matter, write ALTER TABLE REBUILD, hope they picked the right ones.  sp_HeapDoctor does all of that, except it uses Query Store CPU data instead of squinting.

## Philosophy

sp_HeapDoctor is built around three ideas:

1. **Rank by impact, not by size.**  A 10 GB heap with zero Query Store activity is less important than a 500 MB heap driving 200K CPU ms of table scans.  The proc uses Query Store showplan XML to attribute CPU to heap objects via `Table Scan` operators, then supplements with `forwarded_fetch_count` (runtime pointer traversals) and structural severity (`forwarded_pct * page_count`).  All three signals feed a mixed ranking formula so that heaps are rebuilt in order of actual pain.

2. **Measure before you fix.**  Every rebuild captures a before-snapshot of Query Store runtime stats (logical reads, physical reads, duration, executions) and a list of `query_hash` values per heap.  These are persisted in CommandLog `ExtendedInfo` XML.  Because `query_hash` is stable across plan recompilation and CI_SWAP DDL changes, you can query current QS data by the same hashes to measure whether the rebuild actually helped.

3. **Safe defaults, escape hatches.**  Plan-only mode is the default.  Lock timeouts, time limits, online preference, and CI swap are all opt-in.  The proc warns about write-heavy heaps (forwarded records will recur), pre-flight lock contention, and online-to-offline fallback rather than making silent decisions.

## Key Features

- **CPU-prioritized rebuilds** - ranks heaps by Query Store CPU cost, not just forwarded record count.  Rebuilds the heaps that actually hurt, not the ones that are just large.
- **Query Store showplan XML mapping** - parses showplan `//RelOp[@PhysicalOp="Table Scan"]` nodes to attribute CPU to heap objects.  Only counts Table Scan operators; index seeks on your NCIs don't count.
- **sp_QuickieStore integration** - alternative CPU source via Erik Darling's [sp_QuickieStore](https://github.com/erikdarlingdata/DarlingData), useful when Query Store isn't available or you want a second opinion on query performance.
- **CI swap technique** - creates a temp clustered index using a safe unique NC key, then drops it.  Auto-detects keys, guards against LOB columns, and shows the NCI rebuild cost before you commit to it.
- **Online rebuild support** - auto-detects Enterprise/Developer/Azure SQL DB.  Falls back to offline on Standard, because Microsoft would like you to upgrade.
- **Multi-database targeting** - Ola Hallengren `@Databases` parameter (`USER_DATABASES`, wildcards, exclusions, comma-separated).  If you already know how Ola's tools work, you already know how this works.
- **Table-level filtering** - `@Tables` parameter narrows discovery to specific tables: `@Tables = 'dbo.Orders, -dbo.Staging%'`.  Same syntax as `@Databases` (wildcards, exclusions, comma-separated).  Schema is optional: `'Orders'` matches any schema.
- **Plan-then-execute workflow** - `@ResumeRunID` skips the expensive discovery and Query Store analysis by loading targets from a previous plan-only scan.  Run `@PlanOnly=1` to review, note the RunID, then `@ResumeRunID=<guid>, @PlanOnly=0` to execute the same targets without re-scanning.
- **CommandLog logging** - `HEAP_REBUILD_START`/`END` bracketing with per-rebuild `ExtendedInfo` XML.  Post-rebuild verification confirms the forwarded records are actually gone, because trust but verify.
- **Per-rebuild lock timeout** - `SET LOCK_TIMEOUT` prefix/suffix with session restore.  Your blocking chain will thank you.
- **Time limit** - `@MaxRunSeconds` with graceful stop (remaining targets logged as `SKIPPED`).  Maintenance windows end whether you're done or not.
- **Plan-only mode** - `@PlanOnly = 1` (default) shows targets and commands without executing.  Look before you leap.  This is the default for a reason.
- **Query Store performance snapshot** - captures before-rebuild QS runtime stats (logical reads, physical reads, duration, executions) and `query_hash` list per heap.  Persisted in CommandLog `ExtendedInfo` XML for before/after trending.  `query_hash` is stable across plan recompilation and CI_SWAP DDL changes, so you can find the same queries in current QS data regardless of what happened to plan_id.
- **Forwarded fetch counters** - `forwarded_fetch_count` from `dm_db_index_operational_stats` shows how many times forwarded record pointers were actually traversed at runtime, not just how many exist.  A heap with 50% forwarded records but zero fetches isn't hurting anyone.
- **Heap-only discovery** - materializes heap `object_id`s first via `sys.indexes WHERE type = 0`, then scans only those with `dm_db_index_physical_stats`.  On databases with thousands of tables, this skips all non-heap objects instead of asking the DMF to evaluate every table.
- **Write-heavy heap detection** - `usage_hint` column flags heaps with more writes than reads via `dm_db_index_usage_stats`.  `WRITE_ONLY` means zero reads (staging table), `WRITE_HEAVY` means more updates than scans+seeks.  Forwarded records will come right back on these tables; consider adding a clustered index instead of rebuilding.
- **Scan phase time limit** - when `@MaxRunSeconds` is set, the discovery loop checks elapsed time between databases.  If time is exhausted during scanning, remaining databases are skipped so the execution phase can still process whatever targets were found.
- **Pre-flight lock check** - before each rebuild, checks `dm_tran_locks` for other sessions holding locks on the target table.  If found, emits a warning that Sch-M acquisition may block or be blocked.  Does not prevent the rebuild.
- **Obfuscation for external sharing** - `@ObfuscateKey` replaces database/schema/table names with deterministic hex pseudonyms in result sets and CommandLog.  `@RevealKey` decrypts the mapping from a previous run.  `@ObfuscateSeed` enables consistent pseudonyms across environments for side-by-side comparison.
- **Resumable CI swap** - `@UseResumable = 1` (default) adds `RESUMABLE = ON` to CI swap CREATE INDEX.  If the operation is interrupted, the next run detects the paused index and issues ALTER INDEX ... RESUME instead of starting over.
- **Temporal history support** - `@IncludeTemporalHistory = 1` discovers forwarded-record history tables that are normally excluded.  Auto-disables SYSTEM_VERSIONING on the parent before rebuild and re-enables after (both success and failure paths).
- **Permission pre-check** - `@CheckPermissionsOnly = 1` validates ALTER TRACE, VIEW DATABASE STATE, ALTER, and CommandLog INSERT permissions without executing.  Respects `@Databases` for scoping.
- **Script generation** - `@GenerateScript = 1` outputs an executable T-SQL rebuild script instead of running rebuilds.  Copy, paste, review, run.
- **Result persistence** - `@OutputTable` writes the result set to a user-specified table for automation and trending.  Creates the table if it doesn't exist.
- **Pre-flight safety checks** - log space (skips when insufficient), tempdb space (advisory), FK references (informational), AG failover detection, INSTEAD OF trigger detection, LOB TOCTOU re-check at execution time.
- **Impact projections** - `size_mb`, `est_space_savings_mb`, `est_ci_swap_overhead_mb`, `est_log_mb`, and `days_since_last_rebuild` help operators size maintenance windows and anticipate log growth.
- **IO latch wait stats** - `page_io_latch_wait_count` and `page_io_latch_wait_ms` per heap from `dm_db_index_operational_stats`.  High values indicate disk pressure independent of forwarded records.

## Requirements

- **SQL Server 2017+** - uses `STRING_AGG`, which means 2016 is out.  Yes, really.  It's 2026.
- **Enterprise or Developer edition** for online rebuilds.  Standard edition gets offline rebuilds, which work fine but block readers.  You get what you pay for.
- **Azure SQL Database and Managed Instance** are supported.  Edition detection uses `EngineEdition`, not the edition string.
- **Ola Hallengren's `dbo.CommandLog` table** for logging (set `@LogToTable = 'N'` if you don't have it)
  - Create it from: https://ola.hallengren.com/scripts/CommandLog.sql
  - `dbo.CommandExecute` is **not** required.  sp_HeapDoctor handles its own execution.

## Installation

```sql
-- Run the script to create the procedure in any database
-- (typically master or a DBA utility database)
sqlcmd -S YourServer -d master -i sp_HeapDoctor.sql
```

## Quick Start

```sql
-- 1) Plan-only for the current database (recommended starting point)
EXEC dbo.sp_HeapDoctor @PlanOnly = 1;

-- 2) Scan all user databases
EXEC dbo.sp_HeapDoctor
    @Databases = 'USER_DATABASES',
    @PlanOnly  = 1;

-- 3) Execute online rebuilds with lock timeout
EXEC dbo.sp_HeapDoctor
    @PlanOnly         = 0,
    @OnlinePreference = 'AUTO',
    @LockTimeoutMs    = 5000;

-- 4) Execute with time limit and parallelism control
EXEC dbo.sp_HeapDoctor
    @PlanOnly      = 0,
    @MaxRunSeconds = 3600,
    @Maxdop        = 2;

-- 5) Plan-only with time estimates (uses CommandLog history)
EXEC dbo.sp_HeapDoctor
    @Databases     = 'USER_DATABASES',
    @EstimateTime  = 1,
    @PlanOnly      = 1;

-- 6) Target specific tables (wildcards + exclusions)
EXEC dbo.sp_HeapDoctor
    @Databases = 'USER_DATABASES',
    @Tables    = 'dbo.Orders%, -dbo.Orders_Archive',
    @PlanOnly  = 1;

-- 7) Plan-then-execute: review first, execute same targets without re-scanning
EXEC dbo.sp_HeapDoctor @PlanOnly = 1;
-- Note the RunID from output, then:
EXEC dbo.sp_HeapDoctor
    @ResumeRunID = '<RunID-from-plan-only>',
    @PlanOnly    = 0;

-- 8) Obfuscated output (safe to share externally)
EXEC dbo.sp_HeapDoctor
    @Databases    = 'USER_DATABASES',
    @ObfuscateKey = 'my secret passphrase',
    @PlanOnly     = 1;

-- 9) Reveal real names from an obfuscated run
EXEC dbo.sp_HeapDoctor
    @RevealKey   = 'my secret passphrase',
    @RevealRunID = '153ACF40-D520-4472-ABE1-8A9BC99203A7';

-- 10) Check permissions before running
EXEC dbo.sp_HeapDoctor
    @Databases          = 'USER_DATABASES',
    @CheckPermissionsOnly = 1;

-- 11) Generate copy-paste rebuild script
EXEC dbo.sp_HeapDoctor
    @Databases      = 'USER_DATABASES',
    @GenerateScript = 1;

-- 12) Include temporal history table heaps
EXEC dbo.sp_HeapDoctor
    @IncludeTemporalHistory = 1,
    @PlanOnly               = 1;

-- 13) Resumable CI swap with fill factor
EXEC dbo.sp_HeapDoctor
    @AllowCiSwap  = 1,
    @PreferCiSwap = 1,
    @UseResumable = 1,
    @FillFactor   = 90,
    @PlanOnly     = 0;
```

## Real-World Scenarios

### Saturday night maintenance window: rebuild the worst heaps across all databases

You have a 2-hour window starting at midnight.  You want online rebuilds where possible, a 10-second lock timeout so nothing blocks for long, MAXDOP 2 to leave CPU for overnight ETL, and only the top 10 worst heaps per database so the job finishes within the window.

```sql
EXEC dbo.sp_HeapDoctor
    @Databases        = 'USER_DATABASES',
    @PlanOnly         = 0,
    @OnlinePreference = 'AUTO',
    @LockTimeoutMs    = 10000,
    @MaxRunSeconds    = 7200,
    @Maxdop           = 2,
    @TopN             = 10,
    @EstimateTime     = 1;
```

### Investigating a slow report that scans a known heap

The `SalesHistory` table in the `Reporting` database is a heap.  Users complain that a weekly report takes 40 minutes.  You want to see how bad the forwarded records are, what Query Store says about CPU, and whether a rebuild would help -- without touching anything yet.

```sql
EXEC dbo.sp_HeapDoctor
    @Databases = 'Reporting',
    @Tables    = 'dbo.SalesHistory',
    @PlanOnly  = 1;
```

Check `forwarded_pct`, `total_cpu_ms`, and `forwarded_fetch_count` in the output.  If `forwarded_pct` is high but `forwarded_fetch_count` is near zero, the report may not be hitting forwarded records (it might use an NCI seek path).  If both are high, a rebuild will likely help.

### Vendor database you cannot add indexes to

The vendor says "no schema changes."  CI swap is off the table, but you can still do `ALTER TABLE REBUILD` because it doesn't change the schema.  The vendor's `AppData` database has 200+ heaps; you only care about ones larger than 50 MB with at least 5% forwarded records, and you want to skip write-heavy staging tables that will just re-fragment.

```sql
EXEC dbo.sp_HeapDoctor
    @Databases       = 'AppData',
    @MinPages        = 6400,
    @MinForwardedPct = 5.00,
    @SkipWriteHeavy  = 1,
    @AllowCiSwap     = 0,
    @PlanOnly        = 1;
```

### Standard Edition: careful offline rebuilds during off-hours

Every rebuild is offline and holds Sch-M for the full duration.  You want large heaps only (80 MB+), limit to the top 3 worst, cap at 30 minutes total, and skip anything rebuilt in the last 30 days.

```sql
EXEC dbo.sp_HeapDoctor
    @Databases           = 'USER_DATABASES',
    @MinPages            = 10000,
    @TopN                = 3,
    @MaxRunSeconds       = 1800,
    @MinDaysSinceRebuild = 30,
    @PlanOnly            = 0,
    @LockTimeoutMs       = 5000;
```

### Handing off a report to a consultant without exposing table names

A performance consultant needs your forwarded record data but you cannot share real object names.  Generate an obfuscated plan-only report with a consistent seed so you can compare their recommendations back to real tables later.

```sql
/* Step 1: Generate the obfuscated report */
EXEC dbo.sp_HeapDoctor
    @Databases     = 'USER_DATABASES',
    @ObfuscateKey  = 'acme-q1-review',
    @ObfuscateSeed = 'consultant-handoff',
    @EstimateTime  = 1,
    @PlanOnly      = 1;
/* Copy the result set (all metrics are real, only names are pseudonyms) */

/* Step 2: When the consultant says "T_43306ED0 needs a rebuild", reveal it */
EXEC dbo.sp_HeapDoctor
    @RevealKey   = 'acme-q1-review',
    @RevealRunID = '<RunID-from-step-1>';
```

### Post-deployment check: did the new release create forwarded records?

After deploying a release that changed column widths on several tables, you want to scan just those tables across dev and prod to see if forwarded records appeared.  No execution, just a diagnostic.

```sql
EXEC dbo.sp_HeapDoctor
    @Databases       = 'MyApp',
    @Tables          = 'dbo.Customers, dbo.Invoices, dbo.LineItems',
    @MinPages        = 100,
    @MinForwardedPct = 0.01,
    @PlanOnly        = 1;
```

### SQL Agent job with failure alerting

Set up a recurring SQL Agent job that rebuilds heaps and raises an error if any rebuild fails, so the operator gets notified.

```sql
DECLARE @found int, @ok int, @bad int, @skip int;

EXEC dbo.sp_HeapDoctor
    @Databases        = 'USER_DATABASES',
    @PlanOnly         = 0,
    @OnlinePreference = 'AUTO',
    @LockTimeoutMs    = 15000,
    @MaxRunSeconds    = 3600,
    @TopN             = 15,
    @TargetsFound     = @found OUTPUT,
    @Succeeded        = @ok OUTPUT,
    @Failed           = @bad OUTPUT,
    @Skipped          = @skip OUTPUT;

IF @bad > 0
    RAISERROR(N'sp_HeapDoctor: %d of %d rebuilds failed (%d skipped).', 16, 1, @bad, @found, @skip);
```

### Busy OLTP server: throttled scan with minimal latch contention

Discovery itself can add load on a server with hundreds of databases.  Throttle the scan with a 500ms pause between databases, limit to 2 databases worth of targets, and use `@CpuSource = 'NONE'` to skip Query Store XML parsing entirely.

```sql
EXEC dbo.sp_HeapDoctor
    @Databases      = 'USER_DATABASES',
    @ScanThrottleMs = 500,
    @CpuSource      = 'NONE',
    @TopN           = 5,
    @PlanOnly       = 1;
```

### Generate a script for change-control review before execution

Your change advisory board requires pre-approved SQL before any production maintenance.  Generate the rebuild script, paste it into the change ticket, and execute it manually after approval.

```sql
EXEC dbo.sp_HeapDoctor
    @Databases      = 'USER_DATABASES',
    @GenerateScript = 1,
    @TopN           = 10;
```

### CI swap for a heap with many forwarded records but no LOB columns

The `OrderDetails` table is a 4 GB heap with 35% forwarded records and a unique nonclustered index on `(OrderID, LineNumber)`.  A regular `ALTER TABLE REBUILD` would hold Sch-M for the full duration.  CI swap creates a temp clustered index using that existing key, which eliminates forwarded records as a side effect of the B-tree reorg, then drops it to return the table to a heap -- all online.

```sql
EXEC dbo.sp_HeapDoctor
    @Databases    = 'Sales',
    @Tables       = 'dbo.OrderDetails',
    @AllowCiSwap  = 1,
    @PreferCiSwap = 1,
    @PlanOnly     = 1;
/* Check nci_count and key_source_index in the output before committing */
```

## Before You Run @PlanOnly = 0

Plan-only mode is the default for a reason.  Before switching to execution, walk through this checklist:

- [ ] **Run @PlanOnly = 1 first** and validate the target list against your knowledge of which heaps are actually hot.  The proc ranks by CPU and forwarded fetch rate, but you know your workload better than any formula.
- [ ] **Set @LockTimeoutMs explicitly.**  The default is NULL (wait forever).  A rebuild that can't acquire Sch-M will block indefinitely, and anything waiting behind it blocks too.  Start with 5000-30000 ms for production.
- [ ] **Set @MaxRunSeconds explicitly.**  The default is NULL (no time limit).  The proc will run until it finishes or is killed, ignoring your maintenance window entirely.  Size this to your available window minus a safety margin.
- [ ] **On Standard Edition, raise @MinPages** beyond the default (1000 pages / 8 MB).  Every rebuild is offline on Standard, holding Sch-M for the full duration.  See the [Standard Edition note](#standard-edition) below.
- [ ] **Check open [GitHub issues](https://github.com/nanoDBA/sp_HeapDoctor/issues)** for known limitations before your first production run.

The quick-start examples above already show `@LockTimeoutMs = 5000` and `@MaxRunSeconds = 3600`.  The checklist just makes the *why* explicit.

## Standard Edition

On Standard Edition (and when `@OnlinePreference = 'OFF'` on any edition), all rebuilds are **offline**.  The Sch-M lock is held for the entire rebuild duration, blocking all readers and writers on the target table.  For a large heap, that can be minutes.

This changes the meaning of `@MinPages`.  On Enterprise with online rebuilds, the default of 1000 (8 MB) is a reasonable floor because the lock is brief.  On Standard Edition, 8 MB heaps that take seconds to rebuild still block queries for those seconds, and you may have dozens of them in the target list.  Small heaps with forwarded records are usually not worth an offline rebuild.

**Before running @PlanOnly = 0 on Standard Edition:**

- **Raise @MinPages** to 5000-10000 (40-80 MB) as a starting point.  Tune based on your tolerance for blocking.
- **Run @PlanOnly = 1 first** and sort by `page_count` to confirm you're comfortable with the size of every heap in the target list.
- **Use @MaxRunSeconds** and schedule for off-hours.  Offline rebuilds during business hours cause user-visible blocking even on "small" tables.
- **Consider @TopN** to limit the batch size.  Rebuilding 3 large heaps in a maintenance window is better than queuing 25 and timing out partway through.

The proc detects Standard Edition automatically and falls back to offline with a warning.  It does not adjust `@MinPages` for you.

## Parameters

### Target Selection

| Parameter | Default | Description |
|-----------|---------|-------------|
| `@Databases` | `NULL` | `NULL` = current DB.  Supports `USER_DATABASES`, `ALL_DATABASES`, `SYSTEM_DATABASES`, `AVAILABILITY_GROUP_DATABASES`, wildcards (`%`), exclusions (`-`), comma-separated |
| `@Tables` | `NULL` | `NULL` = all tables.  Filter by table name: `'dbo.Orders'`, `'Orders'` (any schema), `'dbo.%'` (wildcard), `'-dbo.Staging%'` (exclude).  Same syntax as `@Databases` |
| `@LookbackDays` | `7` | Query Store lookback window in days |
| `@TopN` | `25` | Max targets per database |
| `@MinPages` | `1000` | Skip heaps smaller than this (page count) |
| `@MaxPages` | `NULL` | Skip heaps larger than this (`NULL` = no cap) |
| `@MinForwardedPct` | `2.00` | Minimum forwarded record % to qualify |
| `@SkipWriteHeavy` | `0` | `1` = completely exclude `WRITE_HEAVY` and `WRITE_ONLY` heaps.  Default ranking penalties still apply when `0` |
| `@MinDaysSinceRebuild` | `NULL` | Skip heaps rebuilt fewer than N days ago (requires CommandLog for rebuild history).  `NULL` = no filtering |

### CPU Source

| Parameter | Default | Description |
|-----------|---------|-------------|
| `@CpuSource` | `'QUERY_STORE'` | `QUERY_STORE`, `QUICKIESTORE`, or `NONE` |
| `@QuickieExecSql` | `NULL` | EXEC statement for sp_QuickieStore |
| `@QuickiePlanIdColumn` | `'plan_id'` | Plan ID column name in Quickie output |
| `@QuickieCpuUsColumn` | `'avg_cpu_time'` | CPU column name in Quickie output |
| `@QuickieCpuUnit` | `'us'` | Unit of CPU column: `us` or `ms` |

### Actions

| Parameter | Default | Description |
|-----------|---------|-------------|
| `@OnlinePreference` | `'AUTO'` | `AUTO` (edition-based), `ON` (prefer; falls back to offline with warning), `OFF` (force offline) |
| `@AllowCiSwap` | `0` | Enable CI swap path |
| `@PreferCiSwap` | `0` | Prefer CI swap when safe key exists + online allowed |
| `@FillFactor` | `0` | Fill factor for CI swap CREATE INDEX (0 = server default, 1-100) |
| `@UpdateStatsAfterRebuild` | `0` | Run `UPDATE STATISTICS WITH FULLSCAN` after each successful rebuild |
| `@UseResumable` | `1` | `RESUMABLE = ON` for CI swap CREATE INDEX (SQL 2017+).  Detects and resumes paused operations |
| `@IncludeTemporalHistory` | `0` | Include temporal history table heaps.  Auto-manages SYSTEM_VERSIONING during rebuilds |

### Execution

| Parameter | Default | Description |
|-----------|---------|-------------|
| `@PlanOnly` | `1` | `1` = print commands only, `0` = execute |
| `@Execute` | `NULL` | Ola Hallengren convention: `Y` = execute (`@PlanOnly=0`), `N` = plan only (`@PlanOnly=1`).  Overrides `@PlanOnly` when set |
| `@Maxdop` | `NULL` | MAXDOP on index operations (`NULL` = omit) |
| `@LockTimeoutMs` | `NULL` | Per-rebuild lock timeout in ms |
| `@MaxRunSeconds` | `NULL` | Stop after N seconds (`NULL` = no limit) |
| `@ScanThrottleMs` | `NULL` | Milliseconds to pause between database scans (0-60000).  Reduces latch contention on busy servers |
| `@ResumeRunID` | `NULL` | Load targets from a prior `@PlanOnly=1` HEAP_SCAN_SUMMARY.  Skips discovery and QS analysis.  Requires `@LogToTable='Y'` on the original run |
| `@Force` | `0` | Bypass orphaned applock from KILLed sessions.  Use when prior run was killed and the re-entrancy guard blocks new runs |
| `@AllowReplicationRebuild` | `0` | Allow published heap rebuilds (shows estimated replication events).  Heaps with `replication_hint` are skipped by default |
| `@CheckPermissionsOnly` | `0` | Check permissions (ALTER TRACE, VIEW DATABASE STATE, ALTER, CommandLog INSERT) and return without executing |

### Estimation

| Parameter | Default | Description |
|-----------|---------|-------------|
| `@EstimateTime` | `0` | Show estimated rebuild time per target based on CommandLog history and live calibration |
| `@EstimateLookbackDays` | `90` | CommandLog history window for throughput rates (days) |
| `@BaselineRebuildMBPerMin` | `NULL` | Cold-start MB/min when no CommandLog history.  Provides ETA on first run without waiting for calibration data |

### Logging

| Parameter | Default | Description |
|-----------|---------|-------------|
| `@LogToTable` | `'Y'` | `Y` = log to `dbo.CommandLog`, `N` = no logging |
| `@Debug` | `0` | Extra diagnostic output (database list, target details, environment info) |
| `@Help` | `0` | Print parameter documentation and return.  `1` = common parameters, `2` = advanced + environmental details |

### Obfuscation

| Parameter | Default | Description |
|-----------|---------|-------------|
| `@ObfuscateKey` | `NULL` | Passphrase for pseudonymizing database/schema/table names in output.  When set, all object names in result sets, CommandLog entries, and execution logs are replaced with deterministic hex pseudonyms |
| `@ObfuscateSeed` | `NULL` | Optional seed for cross-environment consistency.  Same key + same seed on different servers produces identical pseudonyms.  When NULL, auto-seeded with RunID (unique per run) |
| `@RevealKey` | `NULL` | Passphrase to decrypt a previous obfuscated run.  Must match the `@ObfuscateKey` used in the original run.  Requires `@RevealRunID` |
| `@RevealRunID` | `NULL` | RunID (uniqueidentifier) of the obfuscated run to decrypt.  The RunID is displayed in the RAISERROR output when obfuscation is applied |

### Script & Output

| Parameter | Default | Description |
|-----------|---------|-------------|
| `@OutputTable` | `NULL` | Persist result set to a user-specified table (3-part name).  Creates the table if it doesn't exist |
| `@GenerateScript` | `0` | Output executable T-SQL rebuild script instead of running rebuilds |

### Output Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `@TargetsFound` | int OUTPUT | Number of targets discovered.  Populated in both plan-only and execute modes |
| `@Succeeded` | int OUTPUT | Rebuilds completed successfully.  NULL in plan-only mode |
| `@Failed` | int OUTPUT | Rebuilds that errored.  NULL in plan-only mode |
| `@Skipped` | int OUTPUT | Targets skipped (time limit, TOCTOU, etc.).  NULL in plan-only mode |

Useful for SQL Agent integration:

```sql
DECLARE @found int, @succeeded int, @failed int, @skipped int;

EXEC dbo.sp_HeapDoctor
    @Databases     = 'USER_DATABASES',
    @PlanOnly      = 0,
    @MaxRunSeconds = 3600,
    @TargetsFound  = @found OUTPUT,
    @Succeeded     = @succeeded OUTPUT,
    @Failed        = @failed OUTPUT,
    @Skipped       = @skipped OUTPUT;

IF @failed > 0
    RAISERROR(N'sp_HeapDoctor: %d rebuild(s) failed.', 16, 1, @failed);
```

## Result Set Columns

The target list result set (returned in both plan-only and execute modes) contains the following columns:

### Identity and Location

| Column | Type | Description |
|--------|------|-------------|
| `version` | nvarchar | Procedure version string |
| `target_id` | int | Row identity (stable within a run) |
| `sort_order` | int | Execution priority (1 = first to rebuild) |
| `database_name` | sysname | Target database |
| `schema_name` | sysname | Schema |
| `table_name` | sysname | Table name |

### Physical Stats (from dm_db_index_physical_stats, SAMPLED mode)

| Column | Type | Description |
|--------|------|-------------|
| `page_count` | bigint | Total pages in the heap |
| `record_count` | bigint | Row count estimate |
| `forwarded_record_count` | bigint | Forwarded records found (SAMPLED estimate) |
| `forwarded_pct` | decimal(6,2) | `forwarded_record_count / record_count * 100` |
| `avg_page_space_pct` | decimal(5,2) | Average page space used (%).  Low values suggest compaction opportunity |
| `avg_frag_pct` | decimal(5,2) | Logical fragmentation %.  Less meaningful for heaps than B-trees |
| `ghost_record_count` | bigint | Ghost records awaiting cleanup.  Rebuild reclaims these |

### Operational Stats (from dm_db_index_operational_stats)

| Column | Type | Description |
|--------|------|-------------|
| `forwarded_fetch_count` | bigint | Cumulative count of forwarded pointer traversals since server restart.  The runtime impact metric: how often forwarded records are actually being followed |

### CPU and Ranking

| Column | Type | Description |
|--------|------|-------------|
| `total_cpu_ms` | bigint | Query Store CPU attributed to this heap (Table Scan operators only).  NULL when `@CpuSource = 'NONE'` |
| `ranking_basis` | varchar(20) | How this target was ranked: `QS_CPU` (Query Store data available), `QS_NO_DATA` (QS active but no matching plans), `FWD_PCT` (CPU source is NONE) |

### CI Swap Info

| Column | Type | Description |
|--------|------|-------------|
| `nci_count` | int | Nonclustered index count.  Each NCI is rebuilt twice during CI swap |
| `key_source_index` | sysname | NC index used as CI swap key source.  NULL if no safe key or CI swap disabled |
| `partition_count` | int | Number of partitions.  > 1 blocks CI swap |
| `has_schema_bound_views` | int | 1 if schema-bound views depend on this table (blocks CI swap) |
| `has_indexed_views` | int | 1 if indexed views reference this table (blocks CI swap) |
| `has_fk_references` | int | 1 if foreign keys reference this table (informational, does not block CI swap) |
| `fk_ref_count` | int | Count of FK references to this table |
| `filegroup_name` | sysname | Heap's filegroup.  CI swap uses `ON [filegroup]` clause for non-PRIMARY |
| `is_temporal_history` | bit | 1 if temporal history table.  CI swap blocked; rebuild only |

### Action and Commands

| Column | Type | Description |
|--------|------|-------------|
| `action_chosen` | varchar(32) | `HEAP_REBUILD_ONLINE`, `HEAP_REBUILD_OFFLINE`, or `CI_SWAP_ONLINE` |
| `command_text` | nvarchar(max) | The rebuild command (3-part name) |
| `ci_drop_command` | nvarchar(max) | DROP INDEX command for CI swap cleanup.  NULL for heap rebuilds |
| `verify_command` | nvarchar(max) | Paste-ready `dm_db_index_physical_stats` query to verify forwarded records after rebuild |

### Estimation (when @EstimateTime = 1)

| Column | Type | Description |
|--------|------|-------------|
| `est_pages_per_sec` | float | Throughput rate from CommandLog history (pages/sec by action type) |
| `est_seconds` | int | Estimated rebuild time in seconds |
| `est_duration` | nvarchar(20) | Human-readable estimate (`HH:MM:SS` format) |

### Query Store Snapshot (when @CpuSource is QUERY_STORE or QUICKIESTORE)

| Column | Type | Description |
|--------|------|-------------|
| `qs_snapshot_time_utc` | datetime2(3) | UTC timestamp when QS data was captured |
| `qs_total_logical_reads` | bigint | Total logical reads across all plans referencing this heap |
| `qs_total_physical_reads` | bigint | Total physical reads |
| `qs_total_duration_ms` | bigint | Total duration in ms |
| `qs_total_executions` | bigint | Total execution count |
| `qs_plan_count` | int | Distinct plan_ids referencing this heap |
| `qs_query_count` | int | Distinct query_ids (a query can have multiple plans) |

### Usage Analysis

| Column | Type | Description |
|--------|------|-------------|
| `usage_hint` | varchar(30) | `WRITE_ONLY` (zero reads), `WRITE_HEAVY` (more updates than reads), or NULL (normal read pattern).  Forwarded records recur on write-heavy heaps |
| `ranking_score` | decimal(8,4) | LOG10-normalized composite score.  Higher = more impactful.  Formula: `0.4*LOG10(fetch_rate/hr+1) + 0.4*LOG10(cpu+1) + 0.2*LOG10(fwd_pct+1)`, penalized for write-heavy patterns |
| `ranking_algo_version` | nvarchar(10) | Ranking formula version (e.g., `v1`).  Incremented only when the formula changes, enabling apples-to-apples CommandLog trending |
| `heap_compression` | varchar(4) | Data compression on the heap: `NONE`, `ROW`, or `PAGE`.  Preserved during rebuild |
| `replication_hint` | varchar(20) | Replication status: `PUBLISHED`, `MERGE_PUBLISHED`, `CDC`, combinations, or NULL.  CDC + CI swap warns about capture instance |
| `lock_escalation` | varchar(10) | Lock escalation setting: `TABLE`, `AUTO`, or `DISABLE`.  `TABLE` warns for online rebuilds |

### Trending (from CommandLog history)

| Column | Type | Description |
|--------|------|-------------|
| `prev_forwarded_pct` | decimal(6,2) | Forwarded record % at the last rebuild of this table (from CommandLog).  NULL if never rebuilt |
| `rebuilds_in_90d` | int | Number of times this table was rebuilt in the last 90 days.  High values suggest a clustered index may be more appropriate than repeated rebuilds |

### Server Context

| Column | Type | Description |
|--------|------|-------------|
| `sqlserver_start_time` | datetime | SQL Server instance start time (from `sys.dm_os_sys_info`).  Contextualizes `forwarded_fetch_count` age: low counts after a recent restart mean little |
| `uptime_hours` | decimal(10,1) | Hours since SQL Server started.  Used internally for fetch-rate normalization (min 1.0).  Helps operators gauge counter reliability |

### Impact Projections

| Column | Type | Description |
|--------|------|-------------|
| `size_mb` | decimal(18,2) | Heap size in MB (`page_count / 128.0`) |
| `est_space_savings_mb` | decimal(18,2) | Projected space recovery when `avg_page_space_pct < 75%`.  NULL when pages are already dense |
| `est_ci_swap_overhead_mb` | decimal(18,2) | Temp CI sort space estimate for CI_SWAP targets.  NULL for heap rebuilds |
| `est_log_mb` | decimal(18,2) | Estimated transaction log consumption (FULL recovery model only).  NULL for SIMPLE recovery |
| `days_since_last_rebuild` | int | Days since last successful rebuild (from CommandLog).  NULL if never rebuilt or no CommandLog |

### IO Wait Stats

| Column | Type | Description |
|--------|------|-------------|
| `page_io_latch_wait_count` | bigint | Page IO latch wait count from `dm_db_index_operational_stats`.  High values indicate disk pressure independent of forwarded records |
| `page_io_latch_wait_ms` | bigint | Page IO latch wait time in milliseconds |

## How It Works

1. **Database selection** - parses `@Databases` using the Ola Hallengren pattern (wildcards, exclusions, AG awareness).  AG secondaries are automatically skipped because you can't rebuild on a read-only replica, no matter how badly you want to.
2. **Heap discovery** - heap `object_id`s are materialized first from `sys.indexes WHERE type = 0`, then each heap is scanned individually via `dm_db_index_physical_stats` with `SAMPLED` mode.  This skips all non-heap objects.  Memory-optimized tables and tables with columnstore indexes are excluded.  Runtime `forwarded_fetch_count` from `dm_db_index_operational_stats` is captured alongside the physical stats.
3. **Ranking** - targets are scored using a LOG10-normalized weighted formula: `0.4*LOG10(fetch_rate/hr+1) + 0.4*LOG10(cpu+1) + 0.2*LOG10(fwd_pct+1)`.  LOG10 compresses wildly different scales (fetch counts in millions, CPU in thousands, percentages in single digits) into a comparable 0-10 range.  Query Store CPU is mapped to heap objects via showplan XML, but only for `Table Scan` operators.  Write-heavy heaps (more updates than reads) are penalized because forwarded records recur quickly after rebuild.  The `ranking_score` column shows the computed score, and `ranking_basis` tells you the CPU source (`QS_CPU`, `QS_NO_DATA`, or `FWD_PCT`).
4. **Key detection** - for CI swap, finds the smallest safe unique non-nullable NC index with no LOB key columns and total key size <= 1700 bytes.  The `nci_count` column shows how many NCIs will get rebuilt twice if you go the CI swap route.
5. **LOB guard** - CI swap is skipped if the table has `text`, `ntext`, `image`, `xml`, or `MAX`-length columns (`DROP INDEX ONLINE` doesn't support LOB).
6. **Command generation** - builds 3-part-name commands (`[DB].[Schema].[Table]`) so execution is context-agnostic.  Run it from master, run it from the target database, doesn't matter.
7. **Execution** - iterates targets with lock timeout prefix/suffix, time limit checks, per-rebuild CommandLog entries, and post-rebuild verification that the forwarded records are actually gone.

## CPU Ranking: Where Query Store Can Mislead

CPU-prioritized ranking is a headline feature of sp_HeapDoctor, but it depends on Query Store showplan XML parsing, which has edge cases worth understanding.  The `ranking_basis` column tells you which signal was used (`QS_CPU`, `QS_NO_DATA`, or `FWD_PCT`), but doesn't explain *why*.

### How plan parsing works

The proc extracts heap references from showplan XML by finding `//RelOp[@PhysicalOp="Table Scan"]` nodes whose `Table` attribute matches a target heap name.  To avoid redundant XML parsing, plans are deduplicated by `query_plan_hash`: each unique hash is parsed once via `TRY_CONVERT(xml)`, then the mapping fans out to all plan_ids sharing that hash.

### Failure modes and fallback behavior

**NULL or truncated plan XML.**  Query Store can store plans without XML in certain configurations (deferred compilation, memory pressure during plan capture).  Very large plans may also be truncated beyond the Query Store size limit.  `TRY_CONVERT(xml)` returns NULL for these, and they are silently excluded from enrichment.  No warning is emitted per plan; however, the coverage summary message (`"X/Y targets enriched with CPU data (Z unique plans parsed from W total)"`) will show a gap between plans parsed and plans available.  If you see significantly fewer parsed plans than total plans, truncation is a likely cause.

**Stale plans after recompilation.**  QS CPU data is tied to plan_ids.  When a plan recompiles, the old plan_id retains its accumulated stats for the `@LookbackDays` window (default 7 days).  The new plan_id starts fresh.  This means recently recompiled plans may show artificially low CPU, underranking the heap.  The `query_hash`-based before/after comparison is immune to this (query_hash survives recompilation), but the ranking formula uses plan-level CPU, not query-level.

**Multi-statement plans referencing multiple heaps.**  A single plan may contain Table Scan operators on multiple heaps.  The proc attributes the full plan-level CPU to *each* heap it references.  If plan P costs 100K CPU ms and scans heaps A and B, both get 100K attributed.  This is intentional over-attribution: it ensures no heap is missed, at the cost of inflating scores for heaps that share plans with genuinely hot tables.  The `qs_plan_count` and `qs_query_count` columns help identify this: a heap with many plans is more likely to have shared attribution.

**QS enabled but empty or sparse.**  When Query Store is active but has little data (recently enabled, recently purged, or low-traffic database), some or all heaps will have no matching plans.  These targets get `ranking_basis = 'QS_NO_DATA'` and the CPU component of the ranking score is zero (`LOG10(0+1) = 0`).  Ranking falls back to `forwarded_fetch_count` (40% weight) and `forwarded_pct` (20% weight).  This is a reasonable degradation: the proc still finds and ranks heaps, just without the CPU signal.

**QS not in READ_WRITE state.**  If Query Store is in READ_ONLY, ERROR, or OFF state, the proc skips QS enrichment entirely with a warning: `"Query Store not READ_WRITE; ranking by forwarded_pct only."` All targets get `ranking_basis = 'FWD_PCT'`.

**@LookbackDays exceeds QS retention.**  The proc warns when `@LookbackDays` is larger than the QS retention policy, but proceeds with whatever data is available.  The effective lookback is capped by what QS actually retained, not by the parameter value.

### When QS_CPU ranking is unreliable

If you suspect QS data quality issues, run with `@CpuSource = 'NONE'` to rank purely by structural metrics (forwarded_fetch_count + forwarded_pct).  This skips all QS overhead and gives a conservative ranking based on physical stats and runtime fetch counters.  Compare the two rankings to see whether QS data is meaningfully changing the priority order.

## What's Automatically Excluded

The discovery phase silently skips objects that would fail or cause problems during rebuild:

- **Memory-optimized tables** - in-memory OLTP tables don't have forwarded records
- **Tables with columnstore indexes** - incompatible with heap rebuild
- **System-versioned temporal tables** - the temporal parent is always excluded.  History table heaps are excluded by default but can be included via `@IncludeTemporalHistory = 1` (auto-manages SYSTEM_VERSIONING lifecycle during rebuilds)
- **Graph tables** - node and edge tables are excluded (`is_node`, `is_edge`)
- **Ledger tables** (SQL Server 2022+) - append-only tables are excluded (`sys.tables.ledger_type`).  Safe no-op on older versions
- **Always Encrypted columns** - excluded from CI swap key selection only (the heap itself is still rebuilt, but the proc won't pick an AE column as a clustered index key)

## Compression Preservation

Heaps with ROW or PAGE compression are rebuilt with the same compression level.  The `heap_compression` column in the result set shows the current setting.  Both `ALTER TABLE ... REBUILD` and CI swap commands include the `DATA_COMPRESSION` clause when the heap is compressed.  If a previous CI swap run was interrupted (leaving a temp clustered index behind), the proc detects the leftover `CX__Temp__` index and prepends a DROP before the new CREATE.

## Environmental Warnings

During execution, the proc checks for conditions that may affect rebuild performance or safety and emits RAISERROR warnings (severity 10, non-fatal):

- **SQL 2017 version check** - clear error at startup if `ProductMajorVersion < 14` (STRING_AGG dependency)
- **TDE-encrypted databases** - warns about 30-50% throughput reduction from encryption overhead
- **AG synchronous replicas** - warns when large rebuilds (> 100K pages) will generate log traffic to sync-commit secondaries
- **AG failover detection** - per-rebuild `DATABASEPROPERTYEX` check; SKIPs remaining targets in a failed-over database
- **RCSI version store pressure** - warns when large online rebuilds may generate significant version store activity
- **FULL recovery model** - warns when estimated log generation exceeds 1 GB (rebuilds generate full logging)
- **Log space pre-flight** - per-rebuild check; SKIPs when `est_log_mb` exceeds available log free space
- **Tempdb pre-flight** - post-discovery advisory when tempdb free space is low relative to the largest CI_SWAP target sort space estimate
- **Active backups** - warns when a BACKUP is running on the target database (concurrent Sch-M may conflict)
- **Replication/CDC** - warns about log reader traffic for published tables and capture instance issues for CDC + CI swap
- **FK references** - informational advisory when a CI_SWAP target has FK references (lookup paths change during the swap window)
- **INSTEAD OF triggers** - informational NOTE for CI swap targets (DDL doesn't fire DML triggers)
- **Lock escalation = TABLE** - warns that online rebuilds may escalate to a full table lock.  Enhanced for CI_SWAP: warns that Sch-M blocks ALL readers including NOLOCK
- **Write-heavy heaps** - warns that forwarded records will recur quickly after rebuild
- **Churn detection** - warns when a heap has >= 5 rebuilds in 90 days (suggests a clustered index is needed, not more rebuilds)
- **Resume staleness** - warns when resuming from a plan-only scan > 7 days old
- **Statistics invalidation** - notes that auto-update statistics will fire on next query after rebuild
- **LOB TOCTOU re-check** - at execution time, re-verifies LOB columns before CI swap to guard against schema changes between plan and execution
- **Deprecation advisory** - `sp_trace_generateevent` wrapped in TRY/CATCH on SQL 2022+ (deprecated but still functional)
- **CommandLog schema validation** - auto-disables logging when the CommandLog table schema is incompatible (prevents cryptic INSERT errors on old Ola Hallengren schema versions)
- **Re-entrancy guard** - if another sp_HeapDoctor session is already running, the proc exits immediately with a warning rather than running concurrently.  Uses `sp_getapplock` with session scope.  `@Force = 1` bypasses an orphaned applock from a KILLed session

## CI Swap Technique

Instead of `ALTER TABLE ... REBUILD`, CI swap:
1. Creates a temporary clustered index using an existing safe unique NC key
2. Drops the clustered index to return the table to a heap

This eliminates forwarded records by physically reordering the data.  The temp CI name follows the pattern `CX__Temp__<TableName>`.

**When CI swap is NOT attempted:**
- No suitable unique, non-filtered, non-nullable NC index exists
- Table contains LOB columns (`text`, `ntext`, `image`, `xml`, MAX types)
- `@AllowCiSwap = 0` (default)
- Not on Enterprise/Developer edition
- Forced Query Store plans exist on the table
- CDC-tracked table (protects capture instances from silent breakage)
- Multi-partition heap (`partition_count > 1`)
- Schema-bound views depend on the table
- Indexed views reference the table
- Temporal history table (`is_temporal_history = 1`)
- Computed columns excluded from CI swap key candidates

**Trade-off:** Every nonclustered index on the table gets rebuilt when the clustered index is created, *and again* when it's dropped.  Check the `nci_count` column in the output before committing to this.  A table with 2 NCIs?  Sure.  A table with 15 NCIs?  Maybe just do the heap rebuild.

## Write-Heavy Heaps

Heaps flagged as `WRITE_HEAVY` or `WRITE_ONLY` have more updates than reads.  Rebuilding these is a band-aid: the same update patterns that created the forwarded records will recreate them.  sp_HeapDoctor deprioritizes them in the ranking (0.5x penalty for WRITE_HEAVY, 0.25x for WRITE_ONLY), but "deprioritize" doesn't mean "ignore forever."

### The cost of doing nothing

Forwarded records don't plateau.  They accumulate, and the penalties get worse the longer you wait:

- **I/O amplification** - every forwarded fetch is an extra page read.  A scan that should touch 1,000 pages ends up touching 1,500+ because half the rows have been shunted elsewhere.  Multiply that by concurrency and it adds up fast.
- **Buffer pool pollution** - those extra page reads push useful data out of cache, so now other queries are slower too.
- **Space waste** - the forwarding stub (~9 bytes) stays on the original page even though the row left.  Pages get less dense, the heap grows, and you're paying for storage that holds pointers instead of data.
- **It only goes one direction** - `forwarded_record_count` can go up or stay the same.  It never goes down without a rebuild.

### The real fix is a clustered index

A CI eliminates forwarded records permanently.  Row growth causes page splits, not forwarding pointers.  For most write-heavy tables, the cost of maintaining a CI during writes is far less than the cumulative read penalty from forwarded records piling up.  If the table has a natural key, just add the CI.

### When the heap has to stay a heap

Vendor schema you can't touch, LOB-heavy tables where a CI won't help, staging tables that get truncated anyway.  In those cases:

1. **Rebuild on a separate schedule.**  Use `@SkipWriteHeavy = 1` for your regular maintenance window so you spend that time on heaps where rebuilds actually last.  Then run a separate, less frequent pass for the write-heavy ones.
2. **Don't rebuild too often.**  Use `@MinDaysSinceRebuild` to enforce a cooldown period so you're not burning I/O rebuilding the same table every week.
3. **Pay attention to the churn warning.**  If a heap triggers ">= 5 rebuilds in 90 days," that's the proc telling you this table needs a CI, not more rebuilds.

```sql
-- Weekly: skip write-heavy heaps, spend the window on high-ROI targets
EXEC dbo.sp_HeapDoctor @Databases = N'USER_DATABASES', @SkipWriteHeavy = 1, @PlanOnly = 0;

-- Monthly: write-heavy heaps only, skip anything rebuilt in the last 14 days
EXEC dbo.sp_HeapDoctor @Databases = N'USER_DATABASES', @MinDaysSinceRebuild = 14, @PlanOnly = 0;
```

## Remediation Time Estimation

When `@EstimateTime = 1`, each target gets a predicted rebuild time based on two data sources:

1. **CommandLog history** (plan-only and execute modes) - queries previous `HEAP_REBUILD_*` / `CI_SWAP_*` entries from the last `@EstimateLookbackDays` days (default 90).  Computes average pages/sec by action type (online, offline, CI swap separately, because they have very different throughput).  Shows sample count for confidence assessment.  If no history exists, estimates are NULL.

2. **Live calibration** (execute mode only) - after each rebuild completes, the proc measures actual pages/sec per action type and updates remaining targets with matching rates.  This handles hardware differences between servers and avoids mixing ONLINE and CI_SWAP rates (CI swap is typically slower due to NCI rebuild overhead).

The `est_duration` column shows the estimate in `HH:MM:SS` format.  A banner line shows the total estimated remediation time across all targets.

```sql
-- Plan-only with time estimates
EXEC dbo.sp_HeapDoctor
    @Databases     = 'USER_DATABASES',
    @EstimateTime  = 1,
    @PlanOnly      = 1;
```

**First run:** No history means no estimates.  Run a small batch with `@TopN = 3` first to seed CommandLog, then subsequent runs will have throughput data.

### Measuring Rebuild Throughput

Every successful rebuild stores `DurationMs` and `ActualPagesPerSec` in its CommandLog `ExtendedInfo` XML.  Use this to measure and trend throughput across servers, action types, and time:

```sql
-- Throughput by action type (last 90 days)
SELECT
    CommandType,
    COUNT(*) AS rebuilds,
    AVG(ExtendedInfo.value('(/ExtendedInfo/ActualPagesPerSec)[1]', 'int')) AS avg_pps,
    MIN(ExtendedInfo.value('(/ExtendedInfo/ActualPagesPerSec)[1]', 'int')) AS min_pps,
    MAX(ExtendedInfo.value('(/ExtendedInfo/ActualPagesPerSec)[1]', 'int')) AS max_pps,
    AVG(ExtendedInfo.value('(/ExtendedInfo/DurationMs)[1]', 'int')) AS avg_duration_ms
FROM dbo.CommandLog
WHERE CommandType IN ('HEAP_REBUILD_ONLINE', 'HEAP_REBUILD_OFFLINE', 'CI_SWAP_ONLINE')
  AND ISNULL(ErrorNumber, 0) = 0
  AND DATEDIFF(DAY, StartTime, SYSDATETIME()) <= 90
GROUP BY CommandType;
```

The summary `HEAP_REBUILD_END` entry also includes `TotalPagesRebuilt` and `AvgPagesPerSec` for the entire run (not gated on `@EstimateTime`; `AvgPagesPerSec` is populated when at least one rebuild exceeds 100ms).  CI_SWAP `DurationMs` reflects only the CREATE CI step, not the subsequent DROP.

## CommandLog Integration

When `@LogToTable = 'Y'` and `dbo.CommandLog` exists:

- **`HEAP_REBUILD_START`** - logged at run start with parameters XML
- **Per-rebuild entries** - logged with `CommandType` = `HEAP_REBUILD_ONLINE` / `HEAP_REBUILD_OFFLINE` / `CI_SWAP_ONLINE`, `IndexType = 0` (heap), and `IndexName` (temp CI name for CI_SWAP, NULL for heap rebuilds)
- **Skipped entries** - when `@MaxRunSeconds` is reached, remaining targets are logged with `ErrorMessage = 'SKIPPED: @MaxRunSeconds reached.'`
- **`HEAP_REBUILD_END`** - logged at run end with summary XML (succeeded/failed/skipped counts)

Each per-rebuild entry includes `ExtendedInfo` XML:

```xml
<ExtendedInfo>
  <Version>2026.05.11.7</Version>
  <PageCount>12345</PageCount>
  <SizeMB>96.48</SizeMB>
  <ForwardedRecords>5000</ForwardedRecords>
  <ForwardedPct>3.50</ForwardedPct>
  <ForwardedFetchCount>85000</ForwardedFetchCount>
  <TotalCpuMs>150000</TotalCpuMs>
  <PostRebuildForwardedRecords>0</PostRebuildForwardedRecords>
  <DurationMs>3456</DurationMs>
  <ActualPagesPerSec>3572</ActualPagesPerSec>
  <!-- Qs* elements populated when @CpuSource is QUERY_STORE or QUICKIESTORE -->
  <QsSnapshotTimeUtc>2026-02-17T04:30:00.123</QsSnapshotTimeUtc>
  <QsTotalLogicalReads>2500000</QsTotalLogicalReads>
  <!-- ... additional elements: RankingScore, RecordCount, NciCount, RunID, etc. -->
</ExtendedInfo>
```

The `Qs*` elements are populated when `@CpuSource` is `QUERY_STORE` or `QUICKIESTORE` and the heap has Query Store data.  They are omitted when `@CpuSource = 'NONE'`.  The `QsQueryHashes` list contains distinct `query_hash` values (hex format) for queries whose plans reference the heap via Table Scan operators.  These hashes are stable across plan recompilation and CI_SWAP DDL changes, making them suitable for before/after comparison in Query Store.

Query rebuild history:

```sql
SELECT * FROM dbo.CommandLog
WHERE CommandType LIKE 'HEAP_REBUILD%'
ORDER BY StartTime DESC;
```

### Before/After Comparison

After a rebuild, you can compare current Query Store performance against the before-snapshot stored in CommandLog.  The `QsQueryHashes` element provides stable query identifiers that survive plan recompilation:

```sql
-- Compare before-rebuild snapshot with current QS performance for a specific table
DECLARE @table_name sysname = N'MyTable';

;WITH BeforeSnapshot AS (
    SELECT
        ObjectName,
        StartTime,
        ExtendedInfo.value('(/ExtendedInfo/QsTotalLogicalReads)[1]', 'bigint') AS before_logical_reads,
        ExtendedInfo.value('(/ExtendedInfo/QsTotalDurationMs)[1]', 'bigint') AS before_duration_ms,
        ExtendedInfo.value('(/ExtendedInfo/QsTotalExecutions)[1]', 'bigint') AS before_executions,
        ExtendedInfo.value('(/ExtendedInfo/QsQueryHashes)[1]', 'nvarchar(max)') AS query_hashes
    FROM dbo.CommandLog
    WHERE CommandType IN ('HEAP_REBUILD_ONLINE','HEAP_REBUILD_OFFLINE','CI_SWAP_ONLINE')
      AND ObjectName = @table_name
      AND ErrorNumber = 0
      AND ExtendedInfo.exist('(/ExtendedInfo/QsQueryHashes)[1]') = 1
),
-- Split comma-separated query_hashes and look up current QS stats
CurrentQS AS (
    SELECT
        SUM(CONVERT(bigint, rs.count_executions) * CONVERT(bigint, rs.avg_logical_io_reads)) AS current_logical_reads,
        SUM(CONVERT(bigint, rs.count_executions) * CONVERT(bigint, rs.avg_duration)) / 1000 AS current_duration_ms,
        SUM(CONVERT(bigint, rs.count_executions)) AS current_executions
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_plan p ON rs.plan_id = p.plan_id
    JOIN sys.query_store_query q ON p.query_id = q.query_id
    WHERE CONVERT(varchar(18), q.query_hash, 1) IN (
        SELECT TRIM(value)
        FROM BeforeSnapshot
        CROSS APPLY STRING_SPLIT(query_hashes, ',')
    )
)
SELECT
    b.ObjectName,
    b.StartTime AS rebuild_time,
    b.before_logical_reads,
    c.current_logical_reads,
    CASE WHEN b.before_logical_reads > 0
         THEN CAST(100.0 * (b.before_logical_reads - c.current_logical_reads)
              / b.before_logical_reads AS decimal(5,1))
         END AS pct_reduction,
    b.before_duration_ms,
    c.current_duration_ms
FROM BeforeSnapshot b
CROSS JOIN CurrentQS c;
```

This query joins the before-snapshot `query_hash` values against current Query Store data.  A positive `pct_reduction` means the rebuild improved logical read performance for those queries.

## Obfuscation for External Sharing

When sharing diagnostic reports with consultants, forums, or audit teams, real database and table names can expose sensitive information about your environment.  The obfuscation feature replaces all object names with deterministic hex pseudonyms (e.g., `DB_AA92F53B`, `S_9F96C397`, `T_43306ED0`) in result sets, CommandLog entries, and execution logs.  RAISERROR progress messages in the session continue to show real names.

### Basic usage

```sql
-- Plan-only with obfuscated names (safe to share)
EXEC dbo.sp_HeapDoctor
    @Databases    = 'USER_DATABASES',
    @ObfuscateKey = 'my secret passphrase',
    @PlanOnly     = 1;
```

Output columns `database_name`, `schema_name`, `table_name`, `key_source_index`, `command_text`, `ci_drop_command`, and `verify_command` all show pseudonyms instead of real names.  The pseudonym format is `PREFIX_` + 8 hex characters (SHA2_256 derived), where prefixes are `DB_` (database), `S_` (schema), `T_` (table), and `I_` (index).

### Execute with obfuscation

```sql
-- Execute rebuilds; CommandLog entries use pseudonyms
EXEC dbo.sp_HeapDoctor
    @Databases    = 'USER_DATABASES',
    @ObfuscateKey = 'my secret passphrase',
    @PlanOnly     = 0;

-- Output includes:
-- "Obfuscation applied to 5 targets.
--  RunID=153ACF40-D520-4472-ABE1-8A9BC99203A7
--  (provide with @RevealKey to decrypt)."
```

Save the RunID.  You'll need it to reveal the mapping later.

### Revealing the real names

```sql
-- Decrypt the mapping from a previous obfuscated run
EXEC dbo.sp_HeapDoctor
    @RevealKey   = 'my secret passphrase',
    @RevealRunID = '153ACF40-D520-4472-ABE1-8A9BC99203A7';
```

Returns a result set mapping each pseudonym back to the real object name:

| pseudonym | object_type | real_name |
|-----------|-------------|-----------|
| DB_AA92F53B | DB | ProductionDB |
| S_9F96C397 | Schema | dbo |
| T_43306ED0 | Table | Orders |
| T_8B2F1A77 | Table | Customers |

### Cross-environment comparison

When comparing obfuscated reports from multiple servers (dev, staging, prod), use `@ObfuscateSeed` to ensure the same tables get the same pseudonyms:

```sql
-- Same key + seed = same pseudonyms across environments
-- Run on Server A:
EXEC dbo.sp_HeapDoctor
    @ObfuscateKey  = 'shared passphrase',
    @ObfuscateSeed = 'Q1-2026-audit',
    @PlanOnly      = 1;

-- Run on Server B with same key and seed:
EXEC dbo.sp_HeapDoctor
    @ObfuscateKey  = 'shared passphrase',
    @ObfuscateSeed = 'Q1-2026-audit',
    @PlanOnly      = 1;
```

Tables with the same name on both servers will have identical pseudonyms, enabling side-by-side comparison without exposing real names.  Without `@ObfuscateSeed`, each run auto-seeds with its unique RunID, producing different pseudonyms even with the same key.

### Finding available RunIDs

If you lost the RunID from the session output, query CommandLog to find obfuscated runs:

```sql
-- List all obfuscated sp_HeapDoctor runs with their RunIDs
-- (checks both execution runs and plan-only scan summaries)
SELECT
    ID,
    StartTime,
    CommandType,
    COALESCE(
        ExtendedInfo.value('(/Parameters/RunID)[1]', 'uniqueidentifier'),
        ExtendedInfo.value('(/ScanSummary/RunID)[1]', 'uniqueidentifier')
    ) AS RunID,
    COALESCE(
        ExtendedInfo.value('(/Parameters/ObfuscateSeed)[1]', 'nvarchar(128)'),
        ExtendedInfo.value('(/ScanSummary/ObfuscateSeed)[1]', 'nvarchar(128)')
    ) AS Seed,
    Command AS DatabasesScanned
FROM dbo.CommandLog
WHERE CommandType IN ('HEAP_REBUILD_START', 'HEAP_SCAN_SUMMARY')
  AND CAST(ExtendedInfo AS nvarchar(max)) LIKE '%ObfuscatedMappingHex%'
ORDER BY StartTime DESC;
```

### Joining reveal mapping to CommandLog history

After reveal, you can decode your full rebuild history by joining the mapping back to CommandLog:

```sql
-- Step 1: Reveal the mapping into a temp table
IF OBJECT_ID('tempdb..#Mapping') IS NOT NULL DROP TABLE #Mapping;
CREATE TABLE #Mapping (pseudonym nvarchar(20), object_type varchar(10), real_name sysname);

INSERT #Mapping
EXEC dbo.sp_HeapDoctor
    @RevealKey   = 'my secret passphrase',
    @RevealRunID = '153ACF40-D520-4472-ABE1-8A9BC99203A7';

-- Step 2: Join to CommandLog to see real names alongside rebuild results
SELECT
    c.StartTime,
    c.EndTime,
    DATEDIFF(SECOND, c.StartTime, c.EndTime) AS duration_sec,
    c.CommandType,
    ISNULL(m.real_name, c.DatabaseName) AS real_database,
    ISNULL(t.real_name, c.ObjectName) AS real_table,
    c.ErrorNumber,
    c.ErrorMessage
FROM dbo.CommandLog c
LEFT JOIN #Mapping m ON m.pseudonym = c.DatabaseName AND m.object_type = 'DB'
LEFT JOIN #Mapping t ON t.pseudonym = c.ObjectName  AND t.object_type = 'Table'
WHERE c.CommandType IN ('HEAP_REBUILD_ONLINE','HEAP_REBUILD_OFFLINE','CI_SWAP_ONLINE')
  AND CAST(c.ExtendedInfo AS nvarchar(max)) LIKE '%<RunID>153ACF40-D520-4472-ABE1-8A9BC99203A7</RunID>%'
ORDER BY c.StartTime;
```

### End-to-end workflow: cross-environment analysis

This workflow lets you analyze heap performance on a company server and safely bring the results to a non-company machine for analysis, then map findings back to real objects.

```sql
-- STEP 1: On your company server, generate an obfuscated plan-only report.
--         Use @ObfuscateSeed for consistent pseudonyms across servers.
EXEC dbo.sp_HeapDoctor
    @Databases     = 'USER_DATABASES',
    @ObfuscateKey  = 'acme-2026-audit',
    @ObfuscateSeed = 'prod-q1',
    @PlanOnly      = 1;
-- Output includes:
-- "Obfuscation applied to 5 targets.
--  RunID=153ACF40-D520-4472-ABE1-8A9BC99203A7"
-- Save this RunID! You'll need it to reveal later.

-- STEP 2: Copy the obfuscated result set to your analysis machine.
--         Use SSMS "Copy with Headers" or bcp. All object names are pseudonyms
--         (DB_AA92F53B, T_43306ED0, etc.) but metrics are real:
--         page_count, forwarded_pct, ranking_score, size_mb, total_cpu_ms, etc.

-- STEP 3: Analyze on your non-company machine.
--         Identify highest-impact heaps by ranking_score, size_mb, forwarded_pct.
--         Write notes like: "T_43306ED0 (rank 7.45, 1.2 GB, 48% forwarded) - rebuild first"
--         "T_8B2F1A77 (rank 3.12, 200 MB) - low priority, write-heavy"

-- STEP 4: Back on company server, reveal the mapping.
EXEC dbo.sp_HeapDoctor
    @RevealKey   = 'acme-2026-audit',
    @RevealRunID = '153ACF40-D520-4472-ABE1-8A9BC99203A7';
-- Returns: T_43306ED0 = Orders, T_8B2F1A77 = AuditLog, etc.
-- Now apply your recommendations using real names.
```

**Multi-server comparison with consistent pseudonyms:**

```sql
-- Run on Server A (dev):
EXEC dbo.sp_HeapDoctor
    @ObfuscateKey = 'compare-key', @ObfuscateSeed = 'env-compare', @PlanOnly = 1;

-- Run on Server B (prod):
EXEC dbo.sp_HeapDoctor
    @ObfuscateKey = 'compare-key', @ObfuscateSeed = 'env-compare', @PlanOnly = 1;

-- Tables with the same name produce identical pseudonyms on both servers.
-- Compare forwarded_pct, ranking_score, size_mb side by side in a spreadsheet.
```

**Tips for the cross-environment workflow:**

- Always use `@ObfuscateSeed` when comparing multiple servers (without it, each run uses a unique seed)
- `@LogToTable = 'Y'` (default) is required for plan-only reveal to work
- The RunID appears in session output and is also queryable from CommandLog (see "Finding available RunIDs" above)
- Numeric columns (page_count, forwarded_pct, total_cpu_ms, size_mb, est_log_mb, ranking_score) are never obfuscated
- To track trends over time, run periodic plan-only scans; each creates a HEAP_SCAN_SUMMARY entry in CommandLog

### Important notes

- **Plan-only support**: Plan-only runs store the encrypted mapping in the HEAP_SCAN_SUMMARY CommandLog entry when `@LogToTable = 'Y'` (default). Reveal mode checks both HEAP_REBUILD_START (execution runs) and HEAP_SCAN_SUMMARY (plan-only runs). If `@LogToTable = 'N'`, no mapping is stored and a warning is emitted.
- **Wrong key**: If you provide the wrong `@RevealKey`, the decryption fails with an error rather than returning wrong data.
- **RAISERROR messages**: Progress messages in the session always show real names (they are ephemeral and not captured in result sets or logs).  This is by design; you need to see real names to monitor the session.
- **Existing columns**: Physical stats, CPU metrics, ranking scores, and all numeric columns remain unobfuscated.  Only object name columns and generated command strings are pseudonymized.

## Plan-Then-Execute Workflow

Running `@PlanOnly=1` generates a target list and stores it as a `HEAP_SCAN_SUMMARY` entry in CommandLog (when `@LogToTable='Y'`, which is the default).  This means you can review the targets, step away, come back the next day, and execute exactly those targets without waiting for another full discovery pass:

```sql
-- Step 1: Review targets (stores HEAP_SCAN_SUMMARY in CommandLog)
EXEC dbo.sp_HeapDoctor
    @Databases = 'USER_DATABASES',
    @PlanOnly  = 1;
-- Output shows:  RunID=26D0C3AC-4B04-4E1F-98B9-43E5B87EE06D

-- Step 2: Execute from the plan (skips discovery entirely)
EXEC dbo.sp_HeapDoctor
    @ResumeRunID = '26D0C3AC-4B04-4E1F-98B9-43E5B87EE06D',
    @PlanOnly    = 0;
```

The resume path loads every column from the stored XML: page counts, ranking scores, commands, QS snapshots, the works.  Discovery, Query Store analysis, trending columns, and impact projections are all skipped.  The only thing that still runs is the TOCTOU check (verifying each table still exists before rebuilding).

You can also use `@Tables` to execute a subset of the resumed targets:

```sql
-- Execute only one table from a multi-table plan
EXEC dbo.sp_HeapDoctor
    @ResumeRunID = '26D0C3AC-4B04-4E1F-98B9-43E5B87EE06D',
    @Tables      = 'dbo.Orders',
    @PlanOnly    = 0;
```

**What `@ResumeRunID` validates:**

- The RunID must reference a `HEAP_SCAN_SUMMARY` entry (not a `HEAP_REBUILD_START` from an execution run)
- The stored procedure version must match the current version (catches "upgraded proc between plan and execute")
- Obfuscated summaries are rejected (you cannot resume from a plan-only run that used `@ObfuscateKey`; run without obfuscation first)
- `@Databases` is ignored in resume mode (a warning is printed if you pass it)
- `@Tables` is applied as a post-load filter to select a subset of resumed targets
- `@TopN` is applied as a post-load filter to limit the number of targets executed

**Finding the RunID:**

The RunID appears in the RAISERROR output during the plan-only run, and is also queryable from CommandLog:

```sql
SELECT TOP 5
    ID,
    StartTime,
    ExtendedInfo.value('(/ScanSummary/RunID)[1]', 'uniqueidentifier') AS RunID,
    ExtendedInfo.value('(/ScanSummary/TargetCount)[1]', 'int') AS Targets,
    ExtendedInfo.value('(/ScanSummary/TotalSizeMB)[1]', 'decimal(18,2)') AS TotalSizeMB
FROM dbo.CommandLog
WHERE CommandType = 'HEAP_SCAN_SUMMARY'
ORDER BY ID DESC;
```

## Known Limitations and Notes

### Heap rebuild side effects

`ALTER TABLE ... REBUILD` does more than eliminate forwarded records.  It also reclaims ghost records, compacts pages, and can change the physical page ordering.  After a rebuild, you may see space usage increase or decrease depending on pre-rebuild page density.  A heap with many half-empty pages will compact into fewer, fuller pages, but a heap where forwarded records pointed to overflow pages may appear to grow in page count once those rows are consolidated.  The `avg_page_space_used_in_percent` value in the target list helps anticipate this.

### Lock behavior

Online heap rebuilds (Enterprise/Developer/Azure SQL DB) acquire a Sch-M (schema modification) lock at the start and end of the operation.  `@LockTimeoutMs` applies to the entire `ALTER TABLE ... REBUILD` command, not separately to the Sch-M acquisition phase.  This means you cannot distinguish "timed out acquiring Sch-M at the start" from "timed out during the actual rebuild" in the error message.

The pre-flight lock check (`dm_tran_locks`) warns when other sessions hold locks on the target table before the rebuild attempt, which helps anticipate Sch-M contention.  However, the check is advisory only and does not prevent the rebuild.

### Online-to-offline fallback

In rare edge cases, SQL Server may change the execution mode of an online rebuild.  The proc trusts the `ErrorNumber` from `sp_executesql`: if a rebuild completes with `ErrorNumber = 0`, it is logged as a success.  The proc cannot detect whether the operation actually ran online or offline.  If this distinction matters, check `sys.dm_exec_requests` from a separate session during execution.

### @Databases parser

The `@Databases` parameter implements a simplified version of the [Ola Hallengren](https://ola.hallengren.com) parsing pattern.  It supports `USER_DATABASES`, `ALL_DATABASES`, `SYSTEM_DATABASES`, `AVAILABILITY_GROUP_DATABASES`, wildcards (`%`), exclusions (`-`), and comma-separated lists.  It escapes `_` wildcards in LIKE patterns.  However, it has not been tested against every edge case in Ola's full implementation (e.g., escaped brackets in database names, complex AG topologies).  If you encounter a parsing difference, please file an issue.

### XE observability

During execution (`@PlanOnly = 0`), the proc raises `sp_trace_generateevent` events (User Configurable:0, event_class 82) at rebuild start, success/failure, and run completion.  These are visible to Extended Events sessions and monitoring tools (SentryOne, DPA, etc.) without parsing SSMS output.  The events are silently skipped if the caller does not have `ALTER TRACE` permission.

To capture these events:

```sql
CREATE EVENT SESSION HeapDoctorMonitor ON SERVER
ADD EVENT sqlserver.user_event(
    WHERE sqlserver.like_i_sql_unicode_string(user_info, N'sp_HeapDoctor%')
)
ADD TARGET package0.ring_buffer;
ALTER EVENT SESSION HeapDoctorMonitor ON SERVER STATE = START;
```

### Platform support

The proc is pure T-SQL and works on Windows, Linux, and container deployments of SQL Server.  Test scripts use `sqlcmd` with flags for both Windows auth (`-E`) and SQL auth (`-U`/`-P`).  On Linux or container deployments, use SQL auth or Azure AD (`-G`), and add `-C` to trust self-signed certificates if needed.

## Version History

### v2026.05.11.7 *(current)*

- **Test suite now public.** The `tests/` folder is no longer fully gitignored; the 29 `.sql` test files (`01_setup_test_data.sql` through `28_test_parallel_phase_a.sql` plus `99_*.sql`) are now in the repo. They use generic placeholders (`YourServer`, `YourPassword`) and contain no credentials, hostnames, or environment-specific identifiers. Run individually against any test SQL Server with `sqlcmd -S <host> -U <user> -P <password> -i tests/<file>.sql`. The local-only `README_TESTING.md` and shell test runner stay gitignored — they contain environment defaults.
- **Identify the actual applock holder when the re-entrancy guard fails.** When `sp_getapplock` returns < 0 inside `sp_HeapDoctor`, the proc now queries `sys.dm_tran_locks` joined to `sys.dm_exec_sessions` to find the holder and includes that in the error message — SPID, login, program, host, status, open-transaction count, and how long the session has been idle. If the holder is sleeping with no open transaction (the common "leftover SSMS query window" case), the error message recommends `KILL <spid>;` as the resolution. Otherwise it warns the session looks active and suggests verifying before passing `@Force = 1`.

### v2026.05.11.4

- **Polish:** workers in parallel mode no longer emit an empty result set in SSMS or write an empty `@OutputTable`. Region 19 (the `SELECT FROM #Targets` plus `@OutputTable` INSERT) is now gated on `@parallel_worker = 0`. Workers intentionally have an empty `#Targets` (they skipped discovery), so producing output from them was just noise.
- **Docs:** `@Help` and the parallel-mode section above now explicitly warn that a `KILL`ed worker leaves its claimed queue row stuck. Phase B will add automatic dead-worker recovery; until then, operators need to clear stale `dbo.QueueHeapRebuild` rows manually after a worker crash.
- **Test:** new `tests/29_test_parallel_concurrency.sh` launches N concurrent `sqlcmd` processes and asserts `COUNT(DISTINCT SessionID) >= 2` on `dbo.QueueHeapRebuild`. This is the assertion that would have caught the v2026.05.11.2 leader-only regression. PASS on SQL 2019, 2022, 2025 (3 / 4 / 3 distinct workers respectively).

### v2026.05.11.3

- **Fix:** Parallel mode workers (`@HeapsInParallel = N'Y'` not the leader) raced ahead of the leader's discovery, found an empty `dbo.QueueHeapRebuild`, and exited without claiming. Only the leader ever did work — so v2026.05.11.2 ran with multiple sessions but didn't actually parallelize. Now: the leader acquires an Exclusive `sp_getapplock` on `'sp_HeapDoctor_Discovery'` inside its leader-election transaction and holds it until the queue is populated; workers attempt a Shared lock on the same resource, which blocks behind the leader's Exclusive until release. Once the leader finishes populating, workers proceed into the consumer loop in lockstep.
- Workers also no longer hit the "zero targets, nothing to do" early-exit in region 15 — they intentionally have an empty `#Targets` (they skipped discovery), and need to fall through to the execution loop to claim from the queue.
- **Verified concurrent claim with 4 sessions + 50 demo heaps:** three distinct `SessionID`s on `dbo.QueueHeapRebuild` (36 + 15 + 4 = 55 rows), proving actual rebuild-time overlap across sessions.

### v2026.05.11.2

- **New:** `@HeapsInParallel nvarchar(1) = N'N'` — queue-based parallel rebuild (Phase A). When set to `'Y'`, sp_HeapDoctor uses Ola Hallengren's `dbo.Queue` parent table plus an auto-created `dbo.QueueHeapRebuild` child to coordinate work across multiple sessions. Run the same `EXEC` from N SQL Agent steps (or any N sessions); the first session to insert into `dbo.Queue` becomes the leader (runs discovery + populates the queue), subsequent sessions are workers (skip discovery and consume). All sessions then drain the queue concurrently via atomic `UPDATE ... OUTPUT` claims (`ROWLOCK, READPAST`) so contention skips rather than blocks.

  ```sql
  -- SQL Agent: identical step, run N times in parallel
  EXEC dbo.sp_HeapDoctor
      @Databases       = N'USER_DATABASES',
      @Execute         = N'Y',
      @HeapsInParallel = N'Y';
  ```

  > **Operational warning (Phase A):** if a worker session is `KILL`ed (or its connection drops) mid-rebuild, its claimed queue row stays `TableStartTime IS NOT NULL, TableEndTime IS NULL` indefinitely. Other workers will *not* re-claim it. The forwarded records on that specific heap won't get rebuilt until you either manually clear the row (`UPDATE dbo.QueueHeapRebuild SET TableStartTime = NULL WHERE TableEndTime IS NULL AND SessionID = <dead_spid>;`) or `DROP TABLE dbo.QueueHeapRebuild` and re-run. Dead-worker recovery is on the Phase B roadmap.

  Phase A intentionally defers dead-worker recovery, mop-up discovery, parameter fingerprint conflict detection, and orphan-row sweep. Requires Ola's `Queue.sql` to be installed in the target database (https://ola.hallengren.com/scripts/Queue.sql). `@PlanOnly = 1` is rejected with parallel mode.

- The `@invocation_command` written to `dbo.CommandLog` records `@HeapsInParallel = N'Y'` when set, and it is the exact string used as the `dbo.Queue.Parameters` key — so two sessions invoking the same `EXEC` deterministically share a `QueueID`.

- `@Help` ADVANCED PARAMETERS block split into four RAISERROR sub-blocks (it had silently been truncating earlier ADVANCED entries on Linux `sqlcmd`).

### v2026.05.11.1

- **New:** `@ExcludeDatabases nvarchar(max) = NULL` and `@ExcludeTables nvarchar(max) = NULL` parameters. Dedicated comma-separated exclusion patterns; users no longer need to embed `-` prefixes inside `@Databases` / `@Tables`. Wildcards (`%`) and multiple comma-separated patterns are supported. NULL `@Databases` + `@ExcludeDatabases` set implies `USER_DATABASES`; NULL `@Tables` + `@ExcludeTables` set implies `%` (all tables). Example: `EXEC sp_HeapDoctor @ExcludeDatabases = N'master, model, msdb, tempdb', @ExcludeTables = N'dbo.Archive%, dbo.Staging%';`
- Both new params are logged to `dbo.CommandLog` via `@invocation_command` so audit trails preserve the user's original (separate) input.
- `@Help` COMMON PARAMETERS block split 3-way to fit the added params under the Linux `sqlcmd` ~970-char per-RAISERROR output truncation limit.

### v2026.05.11

- **New:** `@IncludeHealthyHeaps bit = 0` parameter bypasses both forwarded-record discovery filters (the implicit `forwarded_record_count > 0` check and `@MinForwardedPct`) so heaps with zero forwarded records are included in results. `@MinPages` / `@MaxPages` and all safety guards (memory-optimized, columnstore, temporal, CDC, etc.) still apply. Primary use case: force-rebuild a known heap by combining with `@Tables`, e.g. `EXEC sp_HeapDoctor @Tables = N'dbo.Orders', @IncludeHealthyHeaps = 1, @PlanOnly = 0`. Tested on SQL Server 2019, 2022, and 2025.
- The `@invocation_command` written to CommandLog now includes `@IncludeHealthyHeaps = 1` when set, for audit traceability.
- `@Help` COMMON PARAMETERS RAISERROR block split in two so the new parameter renders in full under the Linux `sqlcmd` ~970-char per-RAISERROR output limit.

### v2026.03.23

- **Fix:** `@QsRw` variable undeclared in discovery SQL when `CpuSource=NONE` or `QUICKIESTORE`, causing error 137 and zero targets returned

### v2026.03.11.1

- `ranking_basis` now distinguishes `QS_DISABLED` from `QS_NO_DATA` (#160)
- Filtered NCI statistics warning fires for all rebuild paths, not just CI swap (#163)
- FK child statistics update no longer gated on `ci_drop_failed` (#164)
- LOG_SPACE_INSUFFICIENT message mentions autogrowth not considered (#153)
- Pre-flight lock check distinguishes sleeping sessions with open transactions (#167)
- VLF temp table bug fix: CREATE once before loop instead of per iteration (#168)

### v2026.03.11

- **Fix:** SYSTEM_VERSIONING re-enable failure now halts remaining targets in the database instead of silently continuing (#149)
- Copy-pasteable `@ResumeRunID` EXEC statement emitted after plan-only runs (#159)
- 24 persona-review issues triaged: 8 fixed, 12 BY_DESIGN, 4 WONTFIX

### v2026.03.09

- 19 remaining issues across 7 batches (v0302k-v0302q)

### v2026.03.06

- Apply Erik Darling T-SQL style guide (~850 changes across sp_HeapDoctor.sql)
- `integer` not `int`, `COUNT_BIG()` not `COUNT()`, `CONVERT()` not `CAST()`, `/* */` comments only

### v2026.03.04

- Adopt CalVer versioning (YYYY.MM.DD); prior version: 1.0.2026.0302j
- **Security:** `@OutputTable` PARSENAME+QUOTENAME validation prevents SQL injection (#131, #132)
- **Fix:** `@UpdateStatsAfterRebuild` now uses `USE [db]` + 2-part name, fixing UPDATE STATISTICS cross-database (#143)
- **Fix:** `@GenerateScript` RAISERROR uses `%s` format to handle `%` in object names (#122)
- **Fix:** Stale stats note corrected -- factually accurate message about modification counter (#93)
- **Fix:** CI swap guard: XML indexes (type 3) and spatial indexes (type 4) added to exclusion list (#105)
- **Docs:** `@Help` CI SWAP RESTRICTIONS block -- partitioned heap and temporal history table CI swap blocks now explicitly documented with rationale (#137, #140)
- **Docs:** `@GenerateScript` `@Help` note -- SYSTEM_VERSIONING wrappers for temporal tables require manual addition (#119)
- **Docs:** CommandLog START ExtendedInfo comment -- clarifies included vs. omitted params for maintainers (#107)
- **Triage:** 19 BY_DESIGN GitHub issues closed with factual explanations; 19 NEEDS_INVESTIGATION issues labeled

### v1.0.2026.0302i

- Resumable CI swap (`@UseResumable`) + temporal history support (`@IncludeTemporalHistory`)
- Paused CI swap operations auto-detected via `sys.index_resumable_operations` and resumed on next run
- `@OutputTable` -- persist results for automation and trending
- `@GenerateScript` -- output copy-paste T-SQL rebuild scripts

## Credits

- [Ola Hallengren's SQL Server Maintenance Solution](https://ola.hallengren.com) - `@Databases` parameter pattern, `CommandLog` logging pattern
- [Erik Darling's sp_QuickieStore](https://github.com/erikdarlingdata/DarlingData) - optional CPU source integration

## License

[MIT License](https://opensource.org/licenses/MIT)
