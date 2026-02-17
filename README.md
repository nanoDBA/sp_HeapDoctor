# sp_HeapDoctor

**Heap Forwarded Record Mitigation for SQL Server**

Your heaps have forwarded records.  You know they do.  You've been meaning to deal with them for months.  sp_HeapDoctor finds them, ranks them by how much CPU they're actually costing you, and rebuilds them so you can stop pretending that heap is fine.

## The Problem

When a variable-length row on a heap grows beyond its original page, SQL Server doesn't move it cleanly.  It leaves a forwarding pointer on the old page and puts the row on a new page.  Every single read that follows that pointer does **double the I/O**.  At scale, forwarded records silently degrade scan and seek performance on heaps, and "silently" is the operative word because nothing in your monitoring is going to flag this until you go looking.

Most DBAs fix this manually: run `dm_db_index_physical_stats`, squint at the results, decide which tables matter, write ALTER TABLE REBUILD, hope they picked the right ones.  sp_HeapDoctor does all of that, except it uses Query Store CPU data instead of squinting.

## Key Features

- **CPU-prioritized rebuilds** - ranks heaps by Query Store CPU cost, not just forwarded record count.  Rebuilds the heaps that actually hurt, not the ones that are just large.
- **Query Store showplan XML mapping** - parses showplan `//RelOp[@PhysicalOp="Table Scan"]` nodes to attribute CPU to heap objects.  Only counts Table Scan operators; index seeks on your NCIs don't count.
- **sp_QuickieStore integration** - alternative CPU source via Erik Darling's [sp_QuickieStore](https://github.com/erikdarlingdata/DarlingData), because some of us prefer Erik's opinions about query performance.
- **CI swap technique** - creates a temp clustered index using a safe unique NC key, then drops it.  Auto-detects keys, guards against LOB columns, and shows the NCI rebuild cost before you commit to it.
- **Online rebuild support** - auto-detects Enterprise/Developer/Azure SQL DB.  Falls back to offline on Standard, because Microsoft would like you to upgrade.
- **Multi-database targeting** - Ola Hallengren `@Databases` parameter (`USER_DATABASES`, wildcards, exclusions, comma-separated).  If you already know how Ola's tools work, you already know how this works.
- **CommandLog logging** - `HEAP_REBUILD_START`/`END` bracketing with per-rebuild `ExtendedInfo` XML.  Post-rebuild verification confirms the forwarded records are actually gone, because trust but verify.
- **Per-rebuild lock timeout** - `SET LOCK_TIMEOUT` prefix/suffix with session restore.  Your blocking chain will thank you.
- **Time limit** - `@MaxRunSeconds` with graceful stop (remaining targets logged as `SKIPPED`).  Maintenance windows end whether you're done or not.
- **Plan-only mode** - `@PlanOnly = 1` (default) shows targets and commands without executing.  Look before you leap.  This is the default for a reason.

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
```

## Parameters

### Target Selection

| Parameter | Default | Description |
|-----------|---------|-------------|
| `@Databases` | `NULL` | `NULL` = current DB.  Supports `USER_DATABASES`, `ALL_DATABASES`, `SYSTEM_DATABASES`, `AVAILABILITY_GROUP_DATABASES`, wildcards (`%`), exclusions (`-`), comma-separated |
| `@LookbackDays` | `7` | Query Store lookback window in days |
| `@TopN` | `25` | Max targets per database |
| `@MinPages` | `1000` | Skip heaps smaller than this (page count) |
| `@MaxPages` | `NULL` | Skip heaps larger than this (`NULL` = no cap) |
| `@MinForwardedPct` | `2.00` | Minimum forwarded record % to qualify |

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

### Execution

| Parameter | Default | Description |
|-----------|---------|-------------|
| `@PlanOnly` | `1` | `1` = print commands only, `0` = execute |
| `@Maxdop` | `NULL` | MAXDOP on index operations (`NULL` = omit) |
| `@LockTimeoutMs` | `NULL` | Per-rebuild lock timeout in ms |
| `@MaxRunSeconds` | `NULL` | Stop after N seconds (`NULL` = no limit) |

### Estimation

| Parameter | Default | Description |
|-----------|---------|-------------|
| `@EstimateTime` | `0` | Show estimated rebuild time per target based on CommandLog history and live calibration |
| `@EstimateLookbackDays` | `90` | CommandLog history window for throughput rates (days) |

### Logging

| Parameter | Default | Description |
|-----------|---------|-------------|
| `@LogToTable` | `'Y'` | `Y` = log to `dbo.CommandLog`, `N` = no logging |
| `@Debug` | `0` | Extra diagnostic output (database list, target details, environment info) |
| `@Help` | `0` | Print parameter documentation and return |

## How It Works

1. **Database selection** - parses `@Databases` using the Ola Hallengren pattern (wildcards, exclusions, AG awareness).  AG secondaries are automatically skipped because you can't rebuild on a read-only replica, no matter how badly you want to.
2. **Heap discovery** - `dm_db_index_physical_stats` with `SAMPLED` mode finds heaps with forwarded records above thresholds.  Memory-optimized tables and tables with columnstore indexes are excluded because they're a different animal entirely.
3. **CPU ranking** - Query Store runtime stats are mapped to heap objects via showplan XML, but only for `Table Scan` operators.  A query that does an index seek on your heap's NCI doesn't touch forwarded records, so it doesn't count.  The `ranking_basis` column tells you whether each target was ranked by QS CPU (`QS_CPU`), had no QS data (`QS_NO_DATA`), or you skipped CPU entirely (`FWD_PCT`).
4. **Key detection** - for CI swap, finds the smallest safe unique non-nullable NC index with no LOB key columns and total key size <= 900 bytes.  The `nci_count` column shows how many NCIs will get rebuilt twice if you go the CI swap route.
5. **LOB guard** - CI swap is skipped if the table has `text`, `ntext`, `image`, `xml`, or `MAX`-length columns (`DROP INDEX ONLINE` doesn't support LOB).
6. **Command generation** - builds 3-part-name commands (`[DB].[Schema].[Table]`) so execution is context-agnostic.  Run it from master, run it from the target database, doesn't matter.
7. **Execution** - iterates targets with lock timeout prefix/suffix, time limit checks, per-rebuild CommandLog entries, and post-rebuild verification that the forwarded records are actually gone.

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

**Trade-off:** Every nonclustered index on the table gets rebuilt when the clustered index is created, *and again* when it's dropped.  Check the `nci_count` column in the output before committing to this.  A table with 2 NCIs?  Sure.  A table with 15 NCIs?  Maybe just do the heap rebuild.

## CommandLog Integration

When `@LogToTable = 'Y'` and `dbo.CommandLog` exists:

- **`HEAP_REBUILD_START`** - logged at run start with parameters XML
- **Per-rebuild entries** - logged with `CommandType` = `HEAP_REBUILD_ONLINE` / `HEAP_REBUILD_OFFLINE` / `CI_SWAP_ONLINE`
- **Skipped entries** - when `@MaxRunSeconds` is reached, remaining targets are logged with `ErrorMessage = 'SKIPPED: @MaxRunSeconds reached.'`
- **`HEAP_REBUILD_END`** - logged at run end with summary XML (succeeded/failed/skipped counts)

Each per-rebuild entry includes `ExtendedInfo` XML:
```xml
<ExtendedInfo>
  <PageCount>12345</PageCount>
  <SizeMB>96.48</SizeMB>
  <ForwardedRecords>5000</ForwardedRecords>
  <ForwardedPct>3.50</ForwardedPct>
  <TotalCpuMs>150000</TotalCpuMs>
  <PostRebuildForwardedRecords>0</PostRebuildForwardedRecords>
</ExtendedInfo>
```

Query rebuild history:
```sql
SELECT * FROM dbo.CommandLog
WHERE CommandType LIKE 'HEAP_REBUILD%'
ORDER BY StartTime DESC;
```

## Credits

- [Ola Hallengren's SQL Server Maintenance Solution](https://ola.hallengren.com) - `@Databases` parameter pattern, `CommandLog` logging pattern
- [Erik Darling's sp_QuickieStore](https://github.com/erikdarlingdata/DarlingData) - optional CPU source integration

## License

[MIT License](https://opensource.org/licenses/MIT)
