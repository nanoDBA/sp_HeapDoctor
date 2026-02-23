SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

/*

sp_HeapDoctor - Heap Forwarded Record Mitigation

Copyright (c) 2026 Community Contribution

Purpose:    Find heaps with forwarded records, rank them by CPU impact, and rebuild
            them to eliminate forwarded records and reclaim space.

            Forwarded records occur when a variable-length row on a heap grows beyond
            its original page. SQL Server leaves a forwarding pointer on the old page
            and moves the row to a new page. This doubles the I/O cost for every read
            that hits the forwarding pointer. At scale, forwarded records silently
            degrade scan and seek performance on heaps.

            This procedure automates the detection-and-fix cycle that most DBAs do
            manually: find heaps with forwarded records, decide which matter most
            (by CPU cost), and rebuild them - with online operations where possible.

Based on:   Ola Hallengren's SQL Server Maintenance Solution (MIT License)
            https://ola.hallengren.com
            Patterns: @Databases parameter, CommandLog logging, @TimeLimit

            Erik Darling's sp_QuickieStore
            https://github.com/erikdarlingdata/DarlingData
            Integration: Optional CPU source via sp_QuickieStore output

License:    MIT License

            Permission is hereby granted, free of charge, to any person obtaining a copy
            of this software and associated documentation files (the "Software"), to deal
            in the Software without restriction, including without limitation the rights
            to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
            copies of the Software, and to permit persons to whom the Software is
            furnished to do so, subject to the following conditions:

            The above copyright notice and this permission notice shall be included in all
            copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
            IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
            FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
            AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
            LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
            OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
            SOFTWARE.

Version:    1.0.2026.0224

History:    1.0.2026.0224 - @Tables parameter and @ResumeRunID (plan-then-execute workflow)
                          - @Tables: Include/exclude specific tables: @Tables = 'dbo.Orders, -dbo.Staging%'
                          - Schema optional: 'Orders' matches any schema, 'dbo.Orders' matches exact
                          - Wildcards (%), exclusions (-), comma-separated (same syntax as @Databases)
                          - Works with @Databases for cross-database table targeting
                          - @ResumeRunID: execute targets from a prior @PlanOnly=1 scan
                          - Skips discovery + QS analysis; uses commands stored in HEAP_SCAN_SUMMARY
                          - HEAP_SCAN_SUMMARY XML enriched with all #Targets columns for resume
                          - HEAP_REBUILD_START includes ResumedFromRunID for audit trail
                          - Version match and obfuscation checks on resume
            1.0.2026.0223 - Throughput/ETA improvements
                          - Per-rebuild ExtendedInfo now includes DurationMs and ActualPagesPerSec
                            (enables post-hoc throughput trending from CommandLog)
                          - Live throughput tracking is now unconditional (not gated on @EstimateTime)
                          - Summary always reports TotalPagesRebuilt and AvgPagesPerSec
                          - Live calibration uses per-action-type rates (ONLINE/OFFLINE/CI_SWAP)
                          - Historical estimation shows sample count for confidence assessment
            1.0.2026.0222 - Cross-environment obfuscation workflow
                          - Plan-only runs now store encrypted mapping in HEAP_SCAN_SUMMARY
                            (enables reveal for plan-only analysis without executing rebuilds)
                          - Reveal mode checks both HEAP_REBUILD_START and HEAP_SCAN_SUMMARY
                          - Enhanced @Help with cross-environment workflow guidance
            1.0.2026.0221 - Batch 11: Enhanced logging and impact projections
                          - Suppress ANSI_WARNINGS noise from DMV aggregation in discovery scan
                          - New columns: size_mb, est_space_savings_mb, est_ci_swap_overhead_mb,
                            est_log_mb, days_since_last_rebuild
                          - Plan-only scan logging: HEAP_SCAN_SUMMARY entry in CommandLog when
                            @LogToTable='Y' enables trending without executing rebuilds
                          - Enhanced per-rebuild ExtendedInfo: RecordCount, NciCount, EstSeconds,
                            DaysSinceLastRebuild
            1.0.2026.0220 - Batch 10: Obfuscation/Reveal
                          - @ObfuscateKey: replace real names with 8-char hex pseudonyms in
                            result sets and CommandLog (database, schema, table, index, commands)
                          - @ObfuscateSeed: optional seed for deterministic pseudonyms across
                            environments (same key+seed = same pseudonyms on any server)
                          - @RevealKey + @RevealRunID: decrypt a prior run's mapping from CommandLog
                          - Encrypted mapping stored in HEAP_REBUILD_START or HEAP_SCAN_SUMMARY ExtendedInfo XML
                          - RAISERROR messages show real names (session-local, ephemeral)
                          - Uses HASHBYTES('SHA2_256') for pseudonyms, ENCRYPTBYPASSPHRASE for mapping
            1.0.2026.0219d - Batch 9: Polish and documentation
                          - Sub-second duration formatting, error truncation 1000 chars
                          - Version in all ExtendedInfo XML, MAXRECURSION 0, DATALENGTH in CTE
                          - @Help: permissions, time zones, tiered layout with examples
                          - Ledger table exclusion (SQL 2022+), AG sync-commit warning
                          - Backup running check, trending columns from CommandLog history
            1.0.2026.0219c - Batch 8: Medium-priority improvements
                          - Re-entrancy guard (sp_getapplock), RunID correlation in ExtendedInfo
                          - TOCTOU existence check, graph table guard, output parameters
                          - QS LIKE refinement, CI swap forced plan check, TDE detection
                          - #ExecLog temp table, collation-safe JOINs, verify_command column
                          - Azure DTU warning, statistics invalidation warning
            1.0.2026.0219b - Batch 7: Environmental guards and warnings
                          - Replication awareness: replication_hint column
                          - Lock escalation warning for online rebuilds
                          - Leftover temp CI detection and DROP+CREATE resume
                          - Bulk update (BU) lock detection in pre-flight check
                          - RCSI version store pressure warning
                          - Transaction log impact warning for FULL recovery
                          - @ScanThrottleMs parameter for throttled scanning
            1.0.2026.0219 - Batch 6: Critical bug fixes
                          - GETUTCDATE() for uptime calculation (was GETDATE())
                          - RETURN 1 when rebuilds fail so SQL Agent sees failure
                          - Temporal table exclusion via sys.tables.temporal_type
                          - Always Encrypted column exclusion in CI swap key finder
                          - Partitioned heap aggregation: GROUP BY object_id on dm_db_index_physical_stats
                          - Compression preservation: DATA_COMPRESSION carried through CI swap and ALTER TABLE REBUILD
                          - CI swap key byte limit raised from 900 to 1700
            1.0.2026.0218 - LOG10-normalized weighted ranking algorithm
                          - Replaces raw-sum formula with LOG10-normalized scoring:
                            0.4*LOG10(fetch_rate/hr+1) + 0.4*LOG10(cpu+1) + 0.2*LOG10(fwd_pct+1)
                          - Fetch rate normalization via sqlserver_start_time uptime hours
                          - Write-heavy penalty: score * 0.5 for WRITE_HEAVY, * 0.25 for WRITE_ONLY
                          - Structural severity uses fwd_pct alone (not fwd_pct*page_count) to avoid size bias
                          - ranking_score column exposed in result set and ExtendedInfo XML
            1.0.2026.0217e - forwarded_fetch_count in ranking, XE observability
                          - Ranking formula now incorporates forwarded_fetch_count as
                            runtime impact signal alongside CPU and structural severity.
                            Formula: COALESCE(cpu,0) + ISNULL(fwd_fetch,0)/1000 + fwd_pct*pages
                          - XE observability via sp_trace_generateevent
                          - Raises User Configurable:0 events (event_class 82) at rebuild
                            start, success, failure, and run completion
                          - Monitoring tools (SentryOne, DPA, custom XE sessions) can track
                            progress by capturing user_event filtered on 'sp_HeapDoctor%'
                          - Silently skipped if ALTER TRACE permission is not available
            1.0.2026.0217c - @Execute alias, documentation improvements
                          - @Execute nvarchar(1) parameter: Ola Hallengren convention alias
                            for @PlanOnly (Y=execute, N=plan only). Overrides @PlanOnly when set.
                          - README: heap rebuild side effects, Sch-M lock behavior, Linux awareness,
                            @Databases parser simplification note, online-to-offline limitation
            1.0.2026.0217b - Usage pattern detection, scan phase time check, pre-flight lock check
                          - usage_hint column: flags WRITE_ONLY / WRITE_HEAVY heaps via
                            dm_db_index_usage_stats (staging/ETL identification)
                          - Scan phase elapsed check: stops scanning remaining databases
                            when @MaxRunSeconds is exceeded during discovery
                          - Pre-flight active session check: warns when other sessions hold
                            locks on the target table before attempting Sch-M acquisition
            1.0.2026.0217 - Query Store performance snapshot capture
                          - Before-snapshot of QS runtime stats per heap: logical reads,
                            physical reads, duration, executions, plan/query counts
                          - query_hash list per heap for stable before/after tracking
                            (survives plan recompilation and CI_SWAP DDL changes)
                          - Snapshot data persisted in CommandLog ExtendedInfo XML
                          - Works with both QUERY_STORE and QUICKIESTORE CPU sources
            1.0.2026.0216 - Initial release
                          - Query Store CPU ranking via showplan XML object mapping
                          - sp_QuickieStore integration as alternative CPU source
                          - CI swap: auto-detects safe unique NC key, LOB-aware guard
                          - Online/offline rebuild with edition detection
                          - Ola Hallengren @Databases parameter (USER_DATABASES, wildcards,
                            exclusions, comma-separated)
                          - CommandLog logging (HEAP_REBUILD_START/END bracketing,
                            per-rebuild ExtendedInfo XML)
                          - Per-rebuild LOCK_TIMEOUT (prepend/restore pattern)
                          - MAXDOP on all rebuild paths
                          - @MaxRunSeconds time limit with SKIPPED logging
                          - 3-part names on all generated commands
                          - RAISERROR WITH NOWAIT progress throughout
                          - Azure SQL DB / Managed Instance edition detection
                          - XPath filter: Table Scan RelOps only (no false CPU from index seeks)
                          - QS XML pre-filter: LIKE on plan text before TRY_CONVERT(xml)
                          - Mixed ranking: CPU + (forwarded_pct * page_count)
                          - ranking_basis, nci_count columns in output
                          - Post-rebuild verification via dm_db_index_physical_stats
                          - Memory-optimized table and columnstore index guards
                          - @Debug parameter (database list, target details)
                          - @OnlinePreference='ON' warns on offline fallback
                          - Input validation (@LockTimeoutMs, @MaxRunSeconds, @EstimateLookbackDays)
                          - SKIPPED targets logged to CommandLog with ExtendedInfo
                          - CI swap DROP failure handling, lock timeout restore in CATCH blocks
                          - Remediation time estimation via CommandLog history + live calibration

Key Features:
    - CPU-prioritized rebuilds via Query Store showplan XML
    - sp_QuickieStore integration as alternative CPU source
    - CI swap technique with auto key detection + LOB awareness
    - Online rebuild support (Enterprise/Developer edition detection)
    - Ola Hallengren @Databases and @Tables parameters for targeted scanning
    - CommandLog logging with HEAP_REBUILD_START/END bracketing
    - Per-rebuild lock timeout with session restore
    - @MaxRunSeconds time limit (remaining targets logged as SKIPPED)
    - @PlanOnly dry-run mode (default) with target list + command output
    - Remediation time estimation via CommandLog history + live calibration
    - Query Store performance snapshot (logical reads, duration, executions, query_hashes)
      persisted in ExtendedInfo XML for before/after trending

DROP-IN COMPATIBILITY with Ola Hallengren's SQL Server Maintenance Solution:
    https://ola.hallengren.com

    REQUIRED:
      - dbo.CommandLog table in the current database
        (https://ola.hallengren.com/scripts/CommandLog.sql)
        Set @LogToTable = 'N' if you don't have it.

    NOT REQUIRED:
      - dbo.CommandExecute - this proc handles its own command execution

Requirements:
    - SQL Server 2017+ or later (uses STRING_AGG which requires 2017+;
      also uses TRY_CONVERT, IIF, SYSDATETIME, sp_describe_first_result_set)
    - Enterprise or Developer edition for online rebuilds (Standard uses offline)

Limitations:
    - QUICKIESTORE CPU source works for the current database context only.
      Multi-database CPU ranking requires QUERY_STORE (per-database QS queries).
    - SAMPLED mode for dm_db_index_physical_stats: can be slow on databases with
      many tables/indexes. @MinPages helps skip small heaps.
    - CI swap is a trade-off: nonclustered indexes get rebuilt when a clustered
      index is created and again when dropped.
      Use @AllowCiSwap only when you understand the trade-off (the proc guards
      against LOB columns and requires a safe unique key).
    - AG secondary databases are automatically skipped (read-only, cannot rebuild).

===============================================================================
How to use it
===============================================================================

1) Plan-only for the current database (recommended starting point)

EXEC dbo.sp_HeapDoctor
    @PlanOnly          = 1;

2) Scan all user databases

EXEC dbo.sp_HeapDoctor
    @Databases         = 'USER_DATABASES',
    @PlanOnly          = 1;

3) Specific databases with exclusions

EXEC dbo.sp_HeapDoctor
    @Databases         = 'USER_DATABASES, -ReportingArchive',
    @MinPages          = 5000,
    @PlanOnly          = 1;

3b) Target specific tables

EXEC dbo.sp_HeapDoctor
    @Tables            = 'dbo.Orders, dbo.OrderDetails',
    @PlanOnly          = 1;

3c) Target tables by pattern, exclude staging

EXEC dbo.sp_HeapDoctor
    @Tables            = 'dbo.%, -dbo.Staging%',
    @Databases         = 'USER_DATABASES',
    @PlanOnly          = 1;

3d) Target tables by name only (any schema)

EXEC dbo.sp_HeapDoctor
    @Tables            = 'Heap%',
    @PlanOnly          = 1;

4) Execute online rebuilds with lock timeout

EXEC dbo.sp_HeapDoctor
    @PlanOnly          = 0,
    @OnlinePreference  = 'AUTO',
    @LockTimeoutMs     = 5000;

5) Use sp_QuickieStore as CPU source (single-database only)

EXEC dbo.sp_HeapDoctor
    @CpuSource           = 'QUICKIESTORE',
    @QuickieExecSql      = N'EXEC dbo.sp_QuickieStore @Top=200, @SortOrder=''cpu'';',
    @QuickiePlanIdColumn = N'plan_id',
    @QuickieCpuUsColumn  = N'avg_cpu_time',
    @QuickieCpuUnit      = 'us',
    @PlanOnly            = 1;

6) CI-swap when safe unique key exists (Enterprise/Developer only)

EXEC dbo.sp_HeapDoctor
    @AllowCiSwap       = 1,
    @PreferCiSwap      = 1,
    @OnlinePreference  = 'AUTO',
    @PlanOnly          = 1;

7) Execute with time limit and parallelism control

EXEC dbo.sp_HeapDoctor
    @PlanOnly          = 0,
    @MaxRunSeconds     = 3600,
    @Maxdop            = 2;

8) Skip CPU ranking entirely (just use forwarded_pct)

EXEC dbo.sp_HeapDoctor
    @CpuSource         = 'NONE',
    @Databases         = 'USER_DATABASES',
    @PlanOnly          = 1;

9) Execute without CommandLog logging

EXEC dbo.sp_HeapDoctor
    @PlanOnly          = 0,
    @LogToTable        = N'N';

10) Execute using Ola Hallengren convention (@Execute = Y/N)

EXEC dbo.sp_HeapDoctor
    @Execute           = N'Y',
    @OnlinePreference  = 'AUTO',
    @LockTimeoutMs     = 5000;

11) Query CommandLog for rebuild history

SELECT *
FROM dbo.CommandLog
WHERE CommandType LIKE 'HEAP_REBUILD%'
ORDER BY StartTime DESC;

-- Recent run summaries:
SELECT CommandType, StartTime, EndTime, ExtendedInfo
FROM dbo.CommandLog
WHERE CommandType IN ('HEAP_REBUILD_START', 'HEAP_REBUILD_END')
ORDER BY StartTime DESC;

===============================================================================
Notes
===============================================================================

@Databases parameter (Ola Hallengren pattern):
  NULL            = current database only
  USER_DATABASES  = all user databases (excludes master, msdb, model, tempdb)
  ALL_DATABASES   = same as USER_DATABASES (excludes system DBs)
  SYSTEM_DATABASES = master, msdb, model only
  AVAILABILITY_GROUP_DATABASES = databases in AG
  Wildcards:      'Prod%' matches ProdDB, ProdArchive, etc.
  Exclusions:     'USER_DATABASES, -ReportingArchive' = all user DBs except one
  Comma-separated: 'DB1, DB2, DB3'

@Tables parameter (Ola Hallengren pattern):
  NULL            = all tables (no filter)
  schema.table    = specific table: 'dbo.Orders'
  table only      = any schema: 'Orders' (same as '%.Orders')
  Wildcards:      'dbo.Order%' matches dbo.Orders, dbo.OrderDetails, etc.
  Schema wildcard: 'dbo.%' matches all tables in dbo schema
  Exclusions:     'dbo.%, -dbo.Staging%' = all dbo tables except staging
  Comma-separated: 'dbo.T1, dbo.T2, sales.T3'

CI-swap path:
  Creates a temporary clustered index using a safe unique NC key, then drops it.
  This eliminates forwarded records by physically reordering the data. The DROP
  returns the table to heap structure. CI swap will NOT be attempted if:
  - No suitable unique, non-filtered, non-nullable NC index exists
  - The table contains LOB columns (text, ntext, image, xml, MAX types)
    because DROP INDEX WITH (ONLINE = ON) does not support LOB columns.

Lock timeout:
  @LockTimeoutMs is prepended to each rebuild command so the timeout applies
  within the same execution scope as the rebuild. The original session
  @@LOCK_TIMEOUT is restored after each command.

SAMPLED mode:
  The initial heap scan uses dm_db_index_physical_stats with SAMPLED mode
  per database. This can be slow on databases with many tables. @MinPages
  helps skip small tables.

Commands use 3-part names:
  All generated rebuild commands use [DatabaseName].[SchemaName].[TableName]
  so they execute correctly regardless of the session's current database context.

CommandLog (Ola Hallengren pattern):
  When @LogToTable = 'Y' (default) and dbo.CommandLog exists in the current
  database, each rebuild is logged with: DatabaseName, SchemaName, ObjectName,
  Command, CommandType (HEAP_REBUILD_ONLINE / HEAP_REBUILD_OFFLINE /
  CI_SWAP_ONLINE), StartTime, EndTime, ErrorNumber, ErrorMessage, and
  ExtendedInfo XML containing PageCount, SizeMB, ForwardedRecords, ForwardedPct,
  TotalCpuMs. A HEAP_REBUILD_START and HEAP_REBUILD_END entry bracket the
  overall run.
  Create the CommandLog table from: https://ola.hallengren.com/scripts/CommandLog.sql
*/

CREATE OR ALTER PROCEDURE dbo.sp_HeapDoctor
(
    @Help                    bit            = 0,               -- 1 = print parameter documentation and return

    -- Target selection
    @Databases               nvarchar(max)  = NULL,            -- NULL = current DB. Supports: USER_DATABASES, ALL_DATABASES,
                                                                -- SYSTEM_DATABASES, AVAILABILITY_GROUP_DATABASES,
                                                                -- wildcards (%), exclusions (-), comma-separated
    @Tables                  nvarchar(max)  = NULL,            -- NULL = all tables. Supports: schema.table, wildcards (%),
                                                                -- exclusions (-), comma-separated. Schema optional (defaults to %).
    @LookbackDays            int            = 7,
    @TopN                    int            = 25,               -- per database
    @MinPages                bigint         = 1000,
    @MaxPages                bigint         = NULL,            -- NULL = no cap; else only heaps with page_count <= @MaxPages
    @MinForwardedPct         decimal(6,2)   = 2.00,

    -- CPU source
    @CpuSource               varchar(20)    = 'QUERY_STORE',   -- QUERY_STORE | QUICKIESTORE | NONE
    @QuickieExecSql          nvarchar(max)  = NULL,            -- e.g. N'EXEC dbo.sp_QuickieStore @Top=50, @SortOrder=''cpu'';'
    @QuickiePlanIdColumn     sysname        = N'plan_id',      -- column name in Quickie output
    @QuickieCpuUsColumn      sysname        = N'avg_cpu_time', -- OR cpu_us / cpu_ms etc; see @QuickieCpuUnit
    @QuickieCpuUnit          varchar(10)    = 'us',            -- us | ms  (unit of @QuickieCpuUsColumn)

    -- Actions
    @OnlinePreference        varchar(10)    = 'AUTO',          -- AUTO (use edition), ON (require), OFF (force offline)
    @AllowCiSwap             bit            = 0,               -- enable CI swap path at all
    @PreferCiSwap            bit            = 0,               -- if 1, use CI swap when safe key exists + online allowed

    -- Execution
    @PlanOnly                bit            = 1,               -- 1 = print commands only, 0 = execute
    @Execute                 nvarchar(1)    = NULL,            -- Ola Hallengren convention: Y = execute (@PlanOnly=0), N = plan only (@PlanOnly=1)
    @Maxdop                  int            = NULL,            -- optional MAXDOP on index ops (NULL = omit)
    @LockTimeoutMs           int            = NULL,            -- NULL = don't set; milliseconds for SET LOCK_TIMEOUT per rebuild
    @MaxRunSeconds           int            = NULL,            -- when PlanOnly=0, stop after N seconds (NULL = no limit)
    @ScanThrottleMs          int            = NULL,            -- NULL = no throttle; ms to WAITFOR between database scans

    -- Logging
    @LogToTable              nvarchar(1)    = N'Y',            -- Y = log to dbo.CommandLog (current DB), N = no logging

    -- Output verbosity
    @Debug                   bit            = 0,

    -- Throughput estimation
    @EstimateTime            bit            = 0,               -- 1 = show estimated rebuild time per target
    @EstimateLookbackDays    int            = 90,              -- CommandLog history window for throughput rates

    -- Output parameters (for automation; only populated when provided)
    @TargetsFound            int            = NULL OUTPUT,
    @Succeeded               int            = NULL OUTPUT,
    @Failed                  int            = NULL OUTPUT,
    @Skipped                 int            = NULL OUTPUT,

    -- Obfuscation (for sharing diagnostic reports externally)
    @ObfuscateKey            nvarchar(128)  = NULL,            -- when provided, replaces real names with pseudonyms in result sets and CommandLog
    @ObfuscateSeed           nvarchar(128)  = NULL,            -- optional seed for cross-environment consistency; NULL = use @RunID (unique per run)
    @RevealKey               nvarchar(128)  = NULL,            -- decrypt a prior obfuscated run's mapping from CommandLog
    @RevealRunID             uniqueidentifier = NULL,           -- required with @RevealKey; RunID from the run to decrypt

    -- Resume from prior plan-only scan
    @ResumeRunID             uniqueidentifier = NULL            -- load targets from a prior @PlanOnly=1 HEAP_SCAN_SUMMARY; skips discovery
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Version nvarchar(20) = N'1.0.2026.0224';
    DECLARE @RunID uniqueidentifier = NEWID();

    -- Obfuscation state
    DECLARE @obfuscate      bit            = CASE WHEN @ObfuscateKey IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @passphrase     nvarchar(max)  = NULL;
    DECLARE @effective_seed nvarchar(128)  = NULL;

    ----------------------------------------------------------------------------
    -- @Help: print parameter documentation and return
    ----------------------------------------------------------------------------
    IF @Help = 1
    BEGIN
        RAISERROR(N'
sp_HeapDoctor v%s

Find heaps with forwarded records, rank by CPU impact, rebuild.

COMMON PARAMETERS:
  @Help              bit     = 0       Print this help and return.
  @Databases         nvarchar(max) = NULL  NULL=current DB. USER_DATABASES, ALL_DATABASES,
                                        SYSTEM_DATABASES, AVAILABILITY_GROUP_DATABASES,
                                        wildcards (%%), exclusions (-), comma-separated.
  @Tables            nvarchar(max) = NULL  NULL=all tables. schema.table format,
                                        wildcards (%%), exclusions (-), comma-separated.
                                        Schema optional (omit = any schema).
  @PlanOnly          bit     = 1       1=print commands only, 0=execute.
  @Execute           nvarchar(1) = NULL  Ola convention: Y=execute, N=plan only. Overrides @PlanOnly.
  @TopN              int     = 25      Max targets per database.
  @MinPages          bigint  = 1000    Skip heaps smaller than this (page_count).
  @MinForwardedPct   decimal = 2.00    Min forwarded record %% to qualify.
  @LogToTable        nvarchar(1) = Y   Y=log to dbo.CommandLog, N=no logging.

ADVANCED PARAMETERS:
  @CpuSource         varchar = QUERY_STORE  QUERY_STORE | QUICKIESTORE | NONE
  @LookbackDays      int     = 7       Query Store lookback window in days.
  @MaxPages          bigint  = NULL    Skip heaps larger than this (NULL=no cap).
  @OnlinePreference  varchar = AUTO     AUTO | ON (require) | OFF (force offline)
  @AllowCiSwap       bit     = 0       Allow CI swap rebuild path.
  @PreferCiSwap      bit     = 0       Prefer CI swap when safe key exists + online allowed.
  @Maxdop            int     = NULL    MAXDOP on index ops (NULL=omit, 0=unlimited).
  @LockTimeoutMs     int     = NULL    Per-rebuild lock timeout in ms (NULL=don''t set).
  @MaxRunSeconds     int     = NULL    Stop after N seconds (NULL=no limit).
  @ScanThrottleMs    int     = NULL    Wait ms between database scans (0-60000, NULL=off).
  @Debug             bit     = 0       Extra diagnostic output.
  @EstimateTime      bit     = 0       Show estimated rebuild time per target.
  @EstimateLookbackDays int  = 90      CommandLog history window for throughput rates.
', 10, 1, @Version) WITH NOWAIT;

        RAISERROR(N'
QUICKIESTORE PARAMETERS:
  @QuickieExecSql    nvarchar(max) = NULL   EXEC statement for sp_QuickieStore.
  @QuickiePlanIdColumn sysname = plan_id    Column name in Quickie output.
  @QuickieCpuUsColumn  sysname = avg_cpu_time  CPU column in Quickie output.
  @QuickieCpuUnit    varchar = us       Unit of CPU column: us | ms

OBFUSCATION PARAMETERS:
  @ObfuscateKey      nvarchar(128) = NULL   Replace real names with 8-char hex pseudonyms.
  @ObfuscateSeed     nvarchar(128) = NULL   Optional seed for cross-environment consistency.
                                            Same key+seed on different servers = same pseudonyms.
  @RevealKey         nvarchar(128) = NULL   Decrypt a prior run''s mapping from CommandLog.
  @RevealRunID       uniqueidentifier = NULL  Required with @RevealKey.

  Cross-environment workflow:
    1. Run with @ObfuscateKey (+ @ObfuscateSeed for multi-server). Note the RunID.
    2. Copy obfuscated result set to analysis machine. All metrics are real; names are pseudonyms.
    3. To decode: EXEC sp_HeapDoctor @RevealKey=N''<key>'', @RevealRunID=N''<RunID>'';
  Plan-only runs store mapping in HEAP_SCAN_SUMMARY when @LogToTable=''Y'' (default).

RESUME PARAMETER:
  @ResumeRunID       uniqueidentifier = NULL  Load targets from a prior @PlanOnly=1 scan.
                                              Skips discovery + QS analysis. Uses stored commands.

  Plan-then-execute workflow:
    1. Run with @PlanOnly=1 (default). Note the RunID from output.
    2. Review targets. When ready, execute the same targets:
       EXEC sp_HeapDoctor @ResumeRunID=N''<RunID>'', @PlanOnly=0;
  Requires @LogToTable=''Y'' (default) on the plan-only run.
  @Databases and @CpuSource are ignored in resume mode.
  @Tables and @TopN are applied as post-load filters (select a subset to execute).
  Execution params (@MaxRunSeconds, @LockTimeoutMs) are honored.
  Cannot resume obfuscated scans. Version must match.

EXAMPLES:
  EXEC sp_HeapDoctor;
  EXEC sp_HeapDoctor @Databases = N''USER_DATABASES'', @PlanOnly = 0;
  EXEC sp_HeapDoctor @Databases = N''USER_DATABASES'', @Execute = N''Y'';
  EXEC sp_HeapDoctor @Tables = N''dbo.Orders, dbo.OrderDetails'';
  EXEC sp_HeapDoctor @Tables = N''dbo.%%, -dbo.Staging%%'';
  EXEC sp_HeapDoctor @Tables = N''Heap%%'', @Databases = N''USER_DATABASES'';
  EXEC sp_HeapDoctor @ObfuscateKey = N''MySecretKey'';
  EXEC sp_HeapDoctor @RevealKey = N''MyKey'', @RevealRunID = N''<RunID-from-output>'';
  -- Plan-then-execute:
  EXEC sp_HeapDoctor @Databases = N''MyDB'';  -- plan-only, note RunID
  EXEC sp_HeapDoctor @ResumeRunID = N''<RunID>'', @PlanOnly = 0;
  -- Resume a subset:
  EXEC sp_HeapDoctor @ResumeRunID = N''<RunID>'', @Tables = N''dbo.Orders'', @PlanOnly = 0;

REQUIREMENTS: SQL Server 2017+ (STRING_AGG). Enterprise/Developer for ONLINE.
COMMANDLOG:   dbo.CommandLog (Ola Hallengren). https://ola.hallengren.com/scripts/CommandLog.sql
PERMISSIONS:  VIEW DATABASE STATE, ALTER on target tables, INSERT on dbo.CommandLog,
              ALTER TRACE (optional, for XE events).
TIME ZONES:   CommandLog = local (SYSDATETIME). QS snapshots = UTC (SYSUTCDATETIME).
', 10, 1) WITH NOWAIT;
        RETURN;
    END

    ----------------------------------------------------------------------------
    -- @RevealKey: decrypt obfuscated mapping from a prior run's CommandLog
    -- Short-circuits before re-entrancy guard (read-only, should not block).
    ----------------------------------------------------------------------------
    IF @RevealKey IS NOT NULL
    BEGIN
        DECLARE @Msg_reveal nvarchar(4000);

        -- @RevealRunID is required
        IF @RevealRunID IS NULL
        BEGIN
            RAISERROR(N'@RevealKey requires @RevealRunID. Provide the RunID from the obfuscated run.', 16, 1);
            RETURN;
        END

        -- Cannot combine with @ObfuscateKey
        IF @ObfuscateKey IS NOT NULL
        BEGIN
            RAISERROR(N'@RevealKey and @ObfuscateKey cannot be used together. Choose one mode.', 16, 1);
            RETURN;
        END

        -- CommandLog must exist
        IF NOT EXISTS (
            SELECT 1 FROM sys.objects o
            JOIN sys.schemas s ON s.schema_id = o.schema_id
            WHERE o.type = N'U' AND s.name = N'dbo' AND o.name = N'CommandLog'
        )
        BEGIN
            RAISERROR(N'@RevealKey requires dbo.CommandLog. The encrypted mapping is stored there.', 16, 1);
            RETURN;
        END

        -- Retrieve the encrypted mapping - check HEAP_REBUILD_START first (exec), then HEAP_SCAN_SUMMARY (plan-only)
        DECLARE @reveal_xml xml;
        DECLARE @reveal_source nvarchar(30);

        -- 1. Try HEAP_REBUILD_START (execution-mode runs)
        SELECT TOP (1) @reveal_xml = ExtendedInfo, @reveal_source = N'HEAP_REBUILD_START'
        FROM dbo.CommandLog
        WHERE CommandType = N'HEAP_REBUILD_START'
          AND ExtendedInfo.exist(N'/Parameters/RunID[text()=sql:variable("@RevealRunID")]') = 1
        ORDER BY ID DESC;

        -- 2. Fall back to HEAP_SCAN_SUMMARY (plan-only runs)
        IF @reveal_xml IS NULL
        BEGIN
            SELECT TOP (1) @reveal_xml = ExtendedInfo, @reveal_source = N'HEAP_SCAN_SUMMARY'
            FROM dbo.CommandLog
            WHERE CommandType = N'HEAP_SCAN_SUMMARY'
              AND ExtendedInfo.exist(N'/ScanSummary/RunID[text()=sql:variable("@RevealRunID")]') = 1
            ORDER BY ID DESC;
        END

        IF @reveal_xml IS NULL
        BEGIN
            SET @Msg_reveal = N'No obfuscated run found for RunID ' + CAST(@RevealRunID AS nvarchar(36))
                            + N'. Verify the RunID and that the run used @ObfuscateKey.';
            RAISERROR(@Msg_reveal, 16, 1);
            RETURN;
        END

        -- Read the hex-encoded encrypted mapping (XPath depends on source)
        DECLARE @hex_mapping nvarchar(max);
        DECLARE @stored_seed nvarchar(128);

        IF @reveal_source = N'HEAP_REBUILD_START'
        BEGIN
            SET @hex_mapping = @reveal_xml.value(N'(/Parameters/ObfuscatedMappingHex)[1]', N'nvarchar(max)');
            SET @stored_seed = @reveal_xml.value(N'(/Parameters/ObfuscateSeed)[1]', N'nvarchar(128)');
        END
        ELSE
        BEGIN
            SET @hex_mapping = @reveal_xml.value(N'(/ScanSummary/ObfuscatedMappingHex)[1]', N'nvarchar(max)');
            SET @stored_seed = @reveal_xml.value(N'(/ScanSummary/ObfuscateSeed)[1]', N'nvarchar(128)');
        END

        IF @hex_mapping IS NULL
        BEGIN
            RAISERROR(N'RunID found but no encrypted mapping stored. The run may not have used @ObfuscateKey, or @LogToTable was N.', 16, 1);
            RETURN;
        END

        -- If no stored seed, the original run used @RunID as seed
        DECLARE @reveal_passphrase nvarchar(max) = @RevealKey + ISNULL(@stored_seed, CAST(@RevealRunID AS nvarchar(36)));

        -- Decrypt the mapping
        DECLARE @encrypted_blob varbinary(max) = CONVERT(varbinary(max), @hex_mapping, 2);
        DECLARE @decrypted_bytes varbinary(max) = DECRYPTBYPASSPHRASE(@reveal_passphrase, @encrypted_blob);

        IF @decrypted_bytes IS NULL
        BEGIN
            RAISERROR(N'Decryption failed. The @RevealKey does not match the key used for this RunID.', 16, 1);
            RETURN;
        END

        DECLARE @mapping_xml xml;
        SET @mapping_xml = TRY_CONVERT(xml, CONVERT(nvarchar(max), @decrypted_bytes));

        IF @mapping_xml IS NULL
        BEGIN
            RAISERROR(N'Decrypted data is not valid XML. The @RevealKey may be incorrect.', 16, 1);
            RETURN;
        END

        -- Output the pseudonym-to-real-name mapping
        SELECT
            t.c.value(N'(pseudonym)[1]',   N'nvarchar(20)')  AS pseudonym,
            t.c.value(N'(object_type)[1]', N'varchar(10)')   AS object_type,
            t.c.value(N'(real_name)[1]',   N'sysname')       AS real_name
        FROM @mapping_xml.nodes(N'/ObfuscatedMapping/Object') AS t(c)
        ORDER BY object_type, pseudonym;

        RETURN;
    END

    ----------------------------------------------------------------------------
    -- @Execute alias (Ola Hallengren convention): Y = execute, N = plan only
    -- When provided, overrides @PlanOnly.
    ----------------------------------------------------------------------------
    IF @Execute IS NOT NULL
    BEGIN
        SET @Execute = UPPER(@Execute);
        IF @Execute = N'Y'
            SET @PlanOnly = 0;
        ELSE IF @Execute = N'N'
            SET @PlanOnly = 1;
        ELSE
        BEGIN
            RAISERROR(N'Invalid @Execute value. Use Y or N.', 16, 1);
            RETURN;
        END
    END

    /*
    Capture original LOCK_TIMEOUT to restore after each rebuild command.
    @@LOCK_TIMEOUT returns -1 for infinite wait, or timeout in milliseconds.
    */
    DECLARE @OriginalLockTimeout int = @@LOCK_TIMEOUT;

    ----------------------------------------------------------------------------
    -- Input validation
    ----------------------------------------------------------------------------
    DECLARE @Msg nvarchar(4000);
    DECLARE @CpuSourceUpper varchar(20) = UPPER(@CpuSource);
    SET @OnlinePreference = UPPER(@OnlinePreference);

    IF @CpuSourceUpper NOT IN ('QUERY_STORE', 'QUICKIESTORE', 'NONE')
    BEGIN
        RAISERROR(N'Invalid @CpuSource. Use QUERY_STORE, QUICKIESTORE, or NONE.', 16, 1);
        RETURN;
    END

    IF @CpuSourceUpper = 'QUICKIESTORE' AND @QuickieExecSql IS NULL
    BEGIN
        RAISERROR(N'CpuSource=QUICKIESTORE requires @QuickieExecSql.', 16, 1);
        RETURN;
    END

    IF @OnlinePreference NOT IN ('AUTO', 'ON', 'OFF')
    BEGIN
        RAISERROR(N'Invalid @OnlinePreference. Use AUTO, ON, or OFF.', 16, 1);
        RETURN;
    END

    IF @Maxdop IS NOT NULL AND @Maxdop < 0
    BEGIN
        RAISERROR(N'@Maxdop cannot be negative.', 16, 1);
        RETURN;
    END

    IF @LockTimeoutMs IS NOT NULL AND @LockTimeoutMs < 0
    BEGIN
        RAISERROR(N'@LockTimeoutMs cannot be negative. Use NULL for no timeout.', 16, 1);
        RETURN;
    END

    IF @MaxRunSeconds IS NOT NULL AND @MaxRunSeconds < 0
    BEGIN
        RAISERROR(N'@MaxRunSeconds cannot be negative.', 16, 1);
        RETURN;
    END

    IF @ScanThrottleMs IS NOT NULL AND (@ScanThrottleMs < 0 OR @ScanThrottleMs > 60000)
    BEGIN
        RAISERROR(N'@ScanThrottleMs must be between 0 and 60000 (60 seconds). Use NULL for no throttle.', 16, 1);
        RETURN;
    END

    IF @EstimateLookbackDays IS NOT NULL AND @EstimateLookbackDays <= 0
    BEGIN
        RAISERROR(N'@EstimateLookbackDays must be a positive integer.', 16, 1);
        RETURN;
    END

    IF @ObfuscateSeed IS NOT NULL AND @ObfuscateKey IS NULL
        RAISERROR(N'WARNING: @ObfuscateSeed is ignored without @ObfuscateKey.', 10, 1) WITH NOWAIT;

    ----------------------------------------------------------------------------
    -- 8B: Re-entrancy guard
    -- Prevents concurrent executions from interfering with each other.
    -- Uses sp_getapplock with session-scoped exclusive lock.
    ----------------------------------------------------------------------------
    DECLARE @lock_result int;
    EXEC @lock_result = sp_getapplock
        @Resource = N'sp_HeapDoctor',
        @LockMode = N'Exclusive',
        @LockTimeout = 0,
        @LockOwner = N'Session';

    IF @lock_result < 0
    BEGIN
        RAISERROR(N'Another instance of sp_HeapDoctor is already running in this SQL Server instance. Aborting.', 16, 1);
        RETURN;
    END

    -- Initialize obfuscation passphrase (after re-entrancy guard succeeds)
    IF @obfuscate = 1
    BEGIN
        SET @effective_seed = ISNULL(@ObfuscateSeed, CAST(@RunID AS nvarchar(36)));
        SET @passphrase     = @ObfuscateKey + @effective_seed;
    END

    ----------------------------------------------------------------------------
    -- Environment / capability gating
    ----------------------------------------------------------------------------
    DECLARE @Edition nvarchar(128) = CONVERT(nvarchar(128), SERVERPROPERTY('Edition'));
    DECLARE @EngineEdition int = CONVERT(int, SERVERPROPERTY('EngineEdition'));
    /*
    EngineEdition: 3 = Enterprise/Developer, 5 = Azure SQL Database, 8 = Managed Instance.
    All support online index operations. Edition string check is kept as fallback.
    */
    DECLARE @CanOnline bit = CASE
        WHEN @EngineEdition IN (3, 5, 8) THEN 1
        WHEN @Edition LIKE '%Enterprise%' OR @Edition LIKE '%Developer%' THEN 1
        ELSE 0
    END;

    DECLARE @Online bit =
        CASE
            WHEN @OnlinePreference = 'ON'  THEN IIF(@CanOnline = 1, 1, 0)
            WHEN @OnlinePreference = 'OFF' THEN 0
            ELSE IIF(@CanOnline = 1, 1, 0)  -- AUTO
        END;

    IF @OnlinePreference = 'ON' AND @CanOnline = 0
    BEGIN
        RAISERROR(N'WARNING: @OnlinePreference = ON but this edition does not support online index operations. Falling back to offline rebuilds.', 10, 1) WITH NOWAIT;
    END

    DECLARE @start_time datetime2(3) = SYSDATETIME();

    /*
    CommandLog integration (Ola Hallengren pattern).
    Logs to dbo.CommandLog in the current database if it exists and @LogToTable = 'Y'.
    */
    DECLARE @commandlog_exists bit = 0;
    SET @LogToTable = UPPER(@LogToTable);

    IF @LogToTable = N'Y'
    BEGIN
        IF EXISTS
        (
            SELECT 1
            FROM sys.objects AS o
            JOIN sys.schemas AS s ON s.schema_id = o.schema_id
            WHERE o.type = N'U'
            AND   s.name = N'dbo'
            AND   o.name = N'CommandLog'
        )
        BEGIN
            SET @commandlog_exists = 1;
        END
        ELSE
        BEGIN
            RAISERROR(N'WARNING: dbo.CommandLog does not exist in the current database. Set @LogToTable = N''N'' or create the table. Logging disabled for this run.', 10, 1) WITH NOWAIT;
            SET @commandlog_exists = 0;
        END
    END

    RAISERROR(N'===============================================================================', 10, 1) WITH NOWAIT;
    RAISERROR(N' sp_HeapDoctor - Heap Forwarded Record Mitigation', 10, 1) WITH NOWAIT;
    RAISERROR(N'===============================================================================', 10, 1) WITH NOWAIT;
    RAISERROR(N'', 10, 1) WITH NOWAIT;

    SET @Msg = N'Version:     ' + @Version;
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    SET @Msg = N'Edition:     ' + @Edition;
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    SET @Msg = N'Online ops:  ' + CASE WHEN @Online = 1 THEN N'YES' ELSE N'NO' END;
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    SET @Msg = N'CPU source:  ' + @CpuSourceUpper;
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    SET @Msg = N'Mode:        ' + CASE WHEN @PlanOnly = 1 THEN N'PLAN ONLY' ELSE N'EXECUTE' END;
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    RAISERROR(N'Scan mode:   SAMPLED (forwarded record counts are estimates)', 10, 1) WITH NOWAIT;

    -- Resume mode flag (set to 1 when @ResumeRunID loads targets from CommandLog)
    DECLARE @resume_loaded bit = 0;
    DECLARE @resume_xml xml = NULL;

    ----------------------------------------------------------------------------
    -- Parse @Databases (Ola Hallengren pattern)
    -- Supports: USER_DATABASES, ALL_DATABASES, SYSTEM_DATABASES,
    --           AVAILABILITY_GROUP_DATABASES, wildcards (%), exclusions (-),
    --           comma-separated list
    ----------------------------------------------------------------------------
    DECLARE @SelectedDatabases TABLE
    (
        DatabaseItem          nvarchar(256) NOT NULL,
        DatabaseType          char(1)       NULL,      -- S=system, U=user
        AvailabilityGroup     bit           NULL,
        StartPosition         int           NOT NULL,
        Selected              bit           NOT NULL
    );

    DECLARE @tmpDatabases TABLE
    (
        ID                    int           IDENTITY(1,1) NOT NULL PRIMARY KEY,
        DatabaseName          sysname       NOT NULL,
        DatabaseType          char(1)       NOT NULL,
        AvailabilityGroup     bit           NOT NULL DEFAULT 0,
        Selected              bit           NOT NULL DEFAULT 0,
        Completed             bit           NOT NULL DEFAULT 0
    );

    IF @Databases IS NOT NULL
    BEGIN
        SELECT @Databases = LTRIM(RTRIM(REPLACE(REPLACE(@Databases, CHAR(10), N''), CHAR(13), N'')));

        ;WITH DatabaseSplitter AS
        (
            SELECT
                DatabaseItem = LTRIM(RTRIM(
                    CASE
                        WHEN CHARINDEX(N',', @Databases) > 0
                        THEN SUBSTRING(@Databases, 1, CHARINDEX(N',', @Databases) - 1)
                        ELSE @Databases
                    END
                )),
                Remainder =
                    CASE
                        WHEN CHARINDEX(N',', @Databases) > 0
                        THEN SUBSTRING(@Databases, CHARINDEX(N',', @Databases) + 1, LEN(@Databases))
                        ELSE N''
                    END,
                StartPosition = 1

            UNION ALL

            SELECT
                DatabaseItem = LTRIM(RTRIM(
                    CASE
                        WHEN CHARINDEX(N',', Remainder) > 0
                        THEN SUBSTRING(Remainder, 1, CHARINDEX(N',', Remainder) - 1)
                        ELSE Remainder
                    END
                )),
                Remainder =
                    CASE
                        WHEN CHARINDEX(N',', Remainder) > 0
                        THEN SUBSTRING(Remainder, CHARINDEX(N',', Remainder) + 1, DATALENGTH(Remainder))
                        ELSE N''
                    END,
                StartPosition = StartPosition + 1
            FROM DatabaseSplitter
            WHERE DATALENGTH(Remainder) > 0
        ),
        Databases2 AS
        (
            SELECT
                DatabaseItem =
                    CASE
                        WHEN DatabaseItem LIKE N'-%'
                        THEN LTRIM(STUFF(DatabaseItem, 1, 1, N''))
                        ELSE DatabaseItem
                    END,
                StartPosition,
                Selected =
                    CASE
                        WHEN DatabaseItem LIKE N'-%'
                        THEN CONVERT(bit, 0)
                        ELSE CONVERT(bit, 1)
                    END
            FROM DatabaseSplitter
            WHERE DatabaseItem <> N''
        ),
        Databases3 AS
        (
            SELECT
                DatabaseItem =
                    CASE
                        WHEN DatabaseItem IN (N'ALL_DATABASES', N'SYSTEM_DATABASES',
                                              N'USER_DATABASES', N'AVAILABILITY_GROUP_DATABASES')
                        THEN N'%'
                        ELSE DatabaseItem
                    END,
                DatabaseType =
                    CASE
                        WHEN DatabaseItem = N'SYSTEM_DATABASES' THEN 'S'
                        WHEN DatabaseItem = N'USER_DATABASES' THEN 'U'
                        WHEN DatabaseItem = N'ALL_DATABASES' THEN 'U'
                        ELSE NULL
                    END,
                AvailabilityGroup =
                    CASE
                        WHEN DatabaseItem = N'AVAILABILITY_GROUP_DATABASES'
                        THEN CONVERT(bit, 1)
                        ELSE NULL
                    END,
                StartPosition,
                Selected
            FROM Databases2
        )
        INSERT INTO @SelectedDatabases
            (DatabaseItem, DatabaseType, AvailabilityGroup, StartPosition, Selected)
        SELECT DatabaseItem, DatabaseType, AvailabilityGroup, StartPosition, Selected
        FROM Databases3
        OPTION (MAXRECURSION 0);
    END

    INSERT INTO @tmpDatabases (DatabaseName, DatabaseType, AvailabilityGroup, Selected, Completed)
    SELECT
        d.name,
        CASE
            WHEN d.name IN (N'master', N'msdb', N'model') OR d.is_distributor = 1
            THEN 'S'
            ELSE 'U'
        END,
        CASE
            WHEN EXISTS
            (
                SELECT 1
                FROM sys.dm_hadr_database_replica_states AS drs
                WHERE drs.database_id = d.database_id
                AND   drs.is_local = 1
            )
            THEN CONVERT(bit, 1)
            ELSE CONVERT(bit, 0)
        END,
        0, -- Selected
        0  -- Completed
    FROM sys.databases AS d
    WHERE d.name <> N'tempdb'
    AND   d.source_database_id IS NULL
    AND   d.state = 0
    AND   d.is_read_only = 0
    AND   NOT EXISTS
    (
        -- Exclude AG secondary replicas (cannot rebuild on secondary)
        SELECT 1
        FROM sys.dm_hadr_database_replica_states AS drs
        WHERE drs.database_id = d.database_id
        AND   drs.is_local = 1
        AND   drs.is_primary_replica = 0
    );

    -- Apply inclusions
    UPDATE td
    SET td.Selected = sd.Selected
    FROM @tmpDatabases AS td
    INNER JOIN @SelectedDatabases AS sd
        ON td.DatabaseName LIKE REPLACE(sd.DatabaseItem, N'_', N'[_]')
        AND (td.DatabaseType = sd.DatabaseType OR sd.DatabaseType IS NULL)
        AND (td.AvailabilityGroup = sd.AvailabilityGroup OR sd.AvailabilityGroup IS NULL)
    WHERE sd.Selected = 1;

    -- Apply exclusions (must come after inclusions)
    UPDATE td
    SET td.Selected = sd.Selected
    FROM @tmpDatabases AS td
    INNER JOIN @SelectedDatabases AS sd
        ON td.DatabaseName LIKE REPLACE(sd.DatabaseItem, N'_', N'[_]')
        AND (td.DatabaseType = sd.DatabaseType OR sd.DatabaseType IS NULL)
        AND (td.AvailabilityGroup = sd.AvailabilityGroup OR sd.AvailabilityGroup IS NULL)
    WHERE sd.Selected = 0;

    -- Default to current database if @Databases is NULL
    IF @Databases IS NULL
    BEGIN
        UPDATE @tmpDatabases SET Selected = 1 WHERE DatabaseName = DB_NAME();
    END

    DECLARE @DatabaseCount int;
    SELECT @DatabaseCount = COUNT(*) FROM @tmpDatabases WHERE Selected = 1;

    IF @DatabaseCount = 0
    BEGIN
        RAISERROR(N'No databases matched the @Databases pattern.', 16, 1);
        EXEC sp_releaseapplock @Resource = N'sp_HeapDoctor', @LockOwner = N'Session';
        RETURN;
    END

    SET @Msg = N'Databases:   ' + CAST(@DatabaseCount AS nvarchar(10)) + N' selected';
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;

    IF @Tables IS NOT NULL
    BEGIN
        -- Escape % as %% for RAISERROR format-string safety
        SET @Msg = N'Tables:      filtered (' + REPLACE(@Tables, N'%', N'%%') + N')';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    END

    IF @Debug = 1
    BEGIN
        RAISERROR(N'', 10, 1) WITH NOWAIT;
        DECLARE @dbg_CanOnline int = CAST(@CanOnline AS int), @dbg_Online int = CAST(@Online AS int);
        RAISERROR(N'[DEBUG] EngineEdition = %d, CanOnline = %d, Online = %d', 10, 1, @EngineEdition, @dbg_CanOnline, @dbg_Online) WITH NOWAIT;
        RAISERROR(N'[DEBUG] Selected databases:', 10, 1) WITH NOWAIT;

        DECLARE @dbg_cursor sysname;
        DECLARE dbg_db CURSOR LOCAL FAST_FORWARD FOR
            SELECT DatabaseName FROM @tmpDatabases WHERE Selected = 1 ORDER BY ID;
        OPEN dbg_db;
        FETCH NEXT FROM dbg_db INTO @dbg_cursor;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @Msg = N'[DEBUG]   ' + @dbg_cursor;
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            FETCH NEXT FROM dbg_db INTO @dbg_cursor;
        END
        CLOSE dbg_db;
        DEALLOCATE dbg_db;
    END

    RAISERROR(N'', 10, 1) WITH NOWAIT;

    ----------------------------------------------------------------------------
    -- Parse @Tables (Ola Hallengren pattern)
    -- Supports: schema.table, wildcards (%), exclusions (-), comma-separated.
    -- Schema is optional; if omitted, defaults to % (any schema).
    -- #SelectedTables is visible inside sp_executesql discovery SQL.
    ----------------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#SelectedTables') IS NOT NULL DROP TABLE #SelectedTables;

    CREATE TABLE #SelectedTables
    (
        SchemaPattern   nvarchar(256) NOT NULL,
        TablePattern    nvarchar(256) NOT NULL,
        Selected        bit           NOT NULL
    );

    IF @Tables IS NOT NULL
    BEGIN
        SELECT @Tables = LTRIM(RTRIM(REPLACE(REPLACE(@Tables, CHAR(10), N''), CHAR(13), N'')));

        ;WITH TableSplitter AS
        (
            SELECT
                TableItem = LTRIM(RTRIM(
                    CASE
                        WHEN CHARINDEX(N',', @Tables) > 0
                        THEN SUBSTRING(@Tables, 1, CHARINDEX(N',', @Tables) - 1)
                        ELSE @Tables
                    END
                )),
                Remainder =
                    CASE
                        WHEN CHARINDEX(N',', @Tables) > 0
                        THEN SUBSTRING(@Tables, CHARINDEX(N',', @Tables) + 1, LEN(@Tables))
                        ELSE N''
                    END

            UNION ALL

            SELECT
                TableItem = LTRIM(RTRIM(
                    CASE
                        WHEN CHARINDEX(N',', Remainder) > 0
                        THEN SUBSTRING(Remainder, 1, CHARINDEX(N',', Remainder) - 1)
                        ELSE Remainder
                    END
                )),
                Remainder =
                    CASE
                        WHEN CHARINDEX(N',', Remainder) > 0
                        THEN SUBSTRING(Remainder, CHARINDEX(N',', Remainder) + 1, DATALENGTH(Remainder))
                        ELSE N''
                    END
            FROM TableSplitter
            WHERE DATALENGTH(Remainder) > 0
        ),
        Tables2 AS
        (
            -- Extract exclusion prefix (-)
            SELECT
                TableItem =
                    CASE
                        WHEN TableItem LIKE N'-%'
                        THEN LTRIM(STUFF(TableItem, 1, 1, N''))
                        ELSE TableItem
                    END,
                Selected =
                    CASE
                        WHEN TableItem LIKE N'-%'
                        THEN CONVERT(bit, 0)
                        ELSE CONVERT(bit, 1)
                    END
            FROM TableSplitter
            WHERE TableItem <> N''
        ),
        Tables3 AS
        (
            -- Split schema.table on dot; default schema to % if not specified
            SELECT
                SchemaPattern =
                    CASE
                        WHEN CHARINDEX(N'.', TableItem) > 0
                        THEN LEFT(TableItem, CHARINDEX(N'.', TableItem) - 1)
                        ELSE N'%'
                    END,
                TablePattern =
                    CASE
                        WHEN CHARINDEX(N'.', TableItem) > 0
                        THEN SUBSTRING(TableItem, CHARINDEX(N'.', TableItem) + 1, LEN(TableItem))
                        ELSE TableItem
                    END,
                Selected
            FROM Tables2
        )
        INSERT INTO #SelectedTables (SchemaPattern, TablePattern, Selected)
        SELECT SchemaPattern, TablePattern, Selected
        FROM Tables3
        OPTION (MAXRECURSION 0);

        IF @Debug = 1
        BEGIN
            DECLARE @tbl_include_count int, @tbl_exclude_count int;
            SELECT @tbl_include_count = SUM(CASE WHEN Selected = 1 THEN 1 ELSE 0 END),
                   @tbl_exclude_count = SUM(CASE WHEN Selected = 0 THEN 1 ELSE 0 END)
            FROM #SelectedTables;
            SET @Msg = N'[DEBUG] @Tables: ' + CAST(@tbl_include_count AS nvarchar(10)) + N' include pattern(s), '
                     + CAST(@tbl_exclude_count AS nvarchar(10)) + N' exclude pattern(s)';
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        END
    END

    ----------------------------------------------------------------------------
    -- Temp tables (shared across database iterations)
    ----------------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#Targets') IS NOT NULL DROP TABLE #Targets;

    CREATE TABLE #Targets
    (
        target_id                int            IDENTITY(1,1) NOT NULL PRIMARY KEY,
        database_name            sysname        NOT NULL,
        object_id                int            NOT NULL,
        schema_name              sysname        NOT NULL,
        table_name               sysname        NOT NULL,
        page_count               bigint         NOT NULL,
        record_count             bigint         NULL,
        forwarded_record_count   bigint         NOT NULL,
        forwarded_pct            decimal(6,2)   NOT NULL,
        forwarded_fetch_count    bigint         NULL,
        avg_page_space_pct       decimal(5,2)   NULL,
        avg_frag_pct             decimal(5,2)   NULL,
        ghost_record_count       bigint         NULL,
        total_cpu_ms             bigint         NULL,
        ranking_basis            varchar(20)    NOT NULL DEFAULT 'FWD_PCT',
        nci_count                int            NOT NULL DEFAULT 0,
        key_source_index         sysname        NULL,
        temp_key_cols            nvarchar(max)  NULL,
        has_lob_columns          bit            NOT NULL DEFAULT 0,
        action_chosen            varchar(32)    NOT NULL,
        command_text             nvarchar(max)  NOT NULL,
        ci_drop_command          nvarchar(max)  NULL,
        est_pages_per_sec        float          NULL,
        est_seconds              int            NULL,
        est_duration             nvarchar(20)   NULL,
        qs_snapshot_time_utc     datetime2(3)   NULL,
        qs_total_logical_reads   bigint         NULL,
        qs_total_physical_reads  bigint         NULL,
        qs_total_duration_ms     bigint         NULL,
        qs_total_executions      bigint         NULL,
        qs_plan_count            int            NULL,
        qs_query_count           int            NULL,
        qs_query_hashes          nvarchar(max)  NULL,
        usage_hint               varchar(30)    NULL,
        ranking_score            decimal(8,4)   NULL,
        heap_compression         tinyint        NOT NULL DEFAULT 0,
        replication_hint         varchar(20)    NULL,
        lock_escalation          tinyint        NOT NULL DEFAULT 0,
        verify_command           nvarchar(max)  NULL,
        prev_forwarded_pct       decimal(6,2)   NULL,
        rebuilds_in_90d          int            NULL,
        size_mb                  decimal(18,2)  NULL,
        est_space_savings_mb     decimal(18,2)  NULL,
        est_ci_swap_overhead_mb  decimal(18,2)  NULL,
        est_log_mb               decimal(18,2)  NULL,
        days_since_last_rebuild  int            NULL,
        sort_order               int            NOT NULL DEFAULT 0,
        -- Obfuscation: pseudo_ columns hold pseudonyms when @ObfuscateKey is provided.
        -- Real columns remain untouched for TOCTOU checks, execution, and RAISERROR.
        pseudo_database_name     sysname        NULL,
        pseudo_schema_name       sysname        NULL,
        pseudo_table_name        sysname        NULL,
        pseudo_key_index         sysname        NULL,
        pseudo_command_text      nvarchar(max)  NULL,
        pseudo_ci_drop           nvarchar(max)  NULL,
        pseudo_verify_cmd        nvarchar(max)  NULL
    );

    CREATE TABLE #ExecLog
    (
        target_id     int           NOT NULL,
        database_name sysname       NOT NULL,
        full_name     nvarchar(512) NOT NULL,
        action        varchar(32)   NOT NULL,
        start_time    datetime2(3)  NOT NULL,
        end_time      datetime2(3)  NULL,
        succeeded     bit           NULL,
        error_number  int           NULL,
        error_message nvarchar(4000) NULL
    );

    ----------------------------------------------------------------------------
    -- @ResumeRunID: load targets from a prior plan-only HEAP_SCAN_SUMMARY
    ----------------------------------------------------------------------------
    IF @ResumeRunID IS NOT NULL
    BEGIN
        -- Mutual exclusivity
        IF @RevealKey IS NOT NULL
        BEGIN
            RAISERROR(N'@ResumeRunID and @RevealKey cannot be used together.', 16, 1);
            EXEC sp_releaseapplock @Resource = N'sp_HeapDoctor', @LockOwner = N'Session';
            RETURN;
        END

        -- CommandLog must exist
        IF @commandlog_exists = 0
        BEGIN
            RAISERROR(N'@ResumeRunID requires dbo.CommandLog (stores the plan-only scan results).', 16, 1);
            EXEC sp_releaseapplock @Resource = N'sp_HeapDoctor', @LockOwner = N'Session';
            RETURN;
        END

        -- Look up HEAP_SCAN_SUMMARY by RunID
        SELECT TOP (1) @resume_xml = ExtendedInfo
        FROM dbo.CommandLog
        WHERE CommandType = N'HEAP_SCAN_SUMMARY'
          AND ExtendedInfo.exist(N'/ScanSummary/RunID[text()=sql:variable("@ResumeRunID")]') = 1
        ORDER BY ID DESC;

        IF @resume_xml IS NULL
        BEGIN
            -- Check if it's an execution run (helpful error)
            IF EXISTS (
                SELECT 1 FROM dbo.CommandLog
                WHERE CommandType = N'HEAP_REBUILD_START'
                  AND ExtendedInfo.exist(N'/Parameters/RunID[text()=sql:variable("@ResumeRunID")]') = 1
            )
            BEGIN
                SET @Msg = N'RunID ' + CAST(@ResumeRunID AS nvarchar(36))
                         + N' is an execution run, not a plan-only scan. Use a RunID from a @PlanOnly=1 run.';
                RAISERROR(@Msg, 16, 1);
            END
            ELSE
            BEGIN
                SET @Msg = N'No plan-only scan found for RunID ' + CAST(@ResumeRunID AS nvarchar(36))
                         + N'. Run sp_HeapDoctor with @PlanOnly=1, @LogToTable=''Y'' first.';
                RAISERROR(@Msg, 16, 1);
            END
            EXEC sp_releaseapplock @Resource = N'sp_HeapDoctor', @LockOwner = N'Session';
            RETURN;
        END

        -- Version match check
        DECLARE @resume_version nvarchar(20) = @resume_xml.value(N'(/ScanSummary/Version)[1]', N'nvarchar(20)');
        IF @resume_version <> @Version
        BEGIN
            SET @Msg = N'Version mismatch: plan-only scan used v' + ISNULL(@resume_version, N'(unknown)')
                     + N' but current proc is v' + @Version
                     + N'. Re-run with @PlanOnly=1 to generate a compatible scan.';
            RAISERROR(@Msg, 16, 1);
            EXEC sp_releaseapplock @Resource = N'sp_HeapDoctor', @LockOwner = N'Session';
            RETURN;
        END

        -- Block obfuscated summaries (pseudo names stored, real names needed for execution)
        IF @resume_xml.exist(N'/ScanSummary/ObfuscatedMappingHex[text()]') = 1
        BEGIN
            RAISERROR(N'Cannot resume from an obfuscated plan-only scan. Run without @ObfuscateKey first.', 16, 1);
            EXEC sp_releaseapplock @Resource = N'sp_HeapDoctor', @LockOwner = N'Session';
            RETURN;
        END

        -- Populate #Targets from XML
        INSERT INTO #Targets
        (
            database_name, object_id, schema_name, table_name,
            page_count, record_count, forwarded_record_count, forwarded_pct,
            forwarded_fetch_count, avg_page_space_pct, avg_frag_pct, ghost_record_count,
            total_cpu_ms, ranking_basis, nci_count, key_source_index, has_lob_columns,
            action_chosen, command_text, ci_drop_command, verify_command,
            est_pages_per_sec, est_seconds, est_duration,
            usage_hint, ranking_score,
            heap_compression, replication_hint, lock_escalation,
            sort_order,
            prev_forwarded_pct, rebuilds_in_90d,
            size_mb, est_space_savings_mb, est_ci_swap_overhead_mb, est_log_mb,
            days_since_last_rebuild,
            qs_snapshot_time_utc, qs_total_logical_reads, qs_total_physical_reads,
            qs_total_duration_ms, qs_total_executions, qs_plan_count, qs_query_count,
            qs_query_hashes
        )
        SELECT
            t.c.value(N'@DatabaseName',          N'sysname'),
            0,  -- object_id placeholder (only used during discovery)
            t.c.value(N'@SchemaName',            N'sysname'),
            t.c.value(N'@TableName',             N'sysname'),
            t.c.value(N'@PageCount',             N'bigint'),
            t.c.value(N'@RecordCount',           N'bigint'),
            t.c.value(N'@ForwardedRecordCount',  N'bigint'),
            t.c.value(N'@ForwardedPct',          N'decimal(6,2)'),
            t.c.value(N'@ForwardedFetchCount',   N'bigint'),
            t.c.value(N'@AvgPageSpacePct',       N'decimal(5,2)'),
            t.c.value(N'@AvgFragPct',            N'decimal(5,2)'),
            t.c.value(N'@GhostRecordCount',      N'bigint'),
            t.c.value(N'@TotalCpuMs',            N'bigint'),
            t.c.value(N'@RankingBasis',          N'varchar(20)'),
            t.c.value(N'@NciCount',              N'int'),
            t.c.value(N'@KeySourceIndex',        N'sysname'),
            t.c.value(N'@HasLobColumns',         N'bit'),
            t.c.value(N'@ActionChosen',          N'varchar(32)'),
            t.c.value(N'@CommandText',           N'nvarchar(max)'),
            t.c.value(N'@CiDropCommand',         N'nvarchar(max)'),
            t.c.value(N'@VerifyCommand',         N'nvarchar(max)'),
            t.c.value(N'@EstPagesPerSec',        N'float'),
            t.c.value(N'@EstSeconds',            N'int'),
            t.c.value(N'@EstDuration',           N'nvarchar(20)'),
            t.c.value(N'@UsageHint',             N'varchar(30)'),
            t.c.value(N'@RankingScore',          N'decimal(8,4)'),
            t.c.value(N'@HeapCompression',       N'tinyint'),
            t.c.value(N'@ReplicationHint',       N'varchar(20)'),
            t.c.value(N'@LockEscalation',        N'tinyint'),
            t.c.value(N'@SortOrder',             N'int'),
            t.c.value(N'@PrevForwardedPct',      N'decimal(6,2)'),
            t.c.value(N'@RebuildsIn90d',         N'int'),
            t.c.value(N'@SizeMB',               N'decimal(18,2)'),
            t.c.value(N'@EstSpaceSavingsMB',     N'decimal(18,2)'),
            t.c.value(N'@EstCiSwapOverheadMb',   N'decimal(18,2)'),
            t.c.value(N'@EstLogMB',              N'decimal(18,2)'),
            t.c.value(N'@DaysSinceLastRebuild',  N'int'),
            TRY_CONVERT(datetime2(3), t.c.value(N'@QsSnapshotTimeUtc', N'nvarchar(30)'), 126),
            t.c.value(N'@QsTotalLogicalReads',   N'bigint'),
            t.c.value(N'@QsTotalPhysicalReads',  N'bigint'),
            t.c.value(N'@QsTotalDurationMs',     N'bigint'),
            t.c.value(N'@QsTotalExecutions',     N'bigint'),
            t.c.value(N'@QsPlanCount',           N'int'),
            t.c.value(N'@QsQueryCount',          N'int'),
            t.c.value(N'@QsQueryHashes',         N'nvarchar(max)')
        FROM @resume_xml.nodes(N'/ScanSummary/Targets/Target') AS t(c);

        SET @resume_loaded = 1;

        DECLARE @resume_target_count int = (SELECT COUNT(*) FROM #Targets);
        DECLARE @resume_cpu_source nvarchar(20) = @resume_xml.value(N'(/ScanSummary/CpuSource)[1]', N'nvarchar(20)');
        DECLARE @resume_db_count int = @resume_xml.value(N'(/ScanSummary/DatabasesScanned)[1]', N'int');

        RAISERROR(N'', 10, 1) WITH NOWAIT;
        SET @Msg = N'RESUME MODE: loading ' + CAST(@resume_target_count AS nvarchar(10))
                 + N' target(s) from plan-only RunID=' + CAST(@ResumeRunID AS nvarchar(36));
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        SET @Msg = N'  Original CPU source: ' + ISNULL(@resume_cpu_source, N'NONE')
                 + N', databases scanned: ' + ISNULL(CAST(@resume_db_count AS nvarchar(10)), N'?');
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;

        IF @Databases IS NOT NULL
            RAISERROR(N'  NOTE: @Databases is ignored in resume mode (targets loaded from prior scan).', 10, 1) WITH NOWAIT;

        -- Apply @Tables filter to resumed targets (post-load filter)
        IF @Tables IS NOT NULL AND EXISTS (SELECT 1 FROM #SelectedTables)
        BEGIN
            DECLARE @pre_filter_count int = @resume_target_count;

            -- Include filter: keep only targets matching inclusion patterns
            IF EXISTS (SELECT 1 FROM #SelectedTables WHERE Selected = 1)
            BEGIN
                DELETE t FROM #Targets t
                WHERE NOT EXISTS (
                    SELECT 1 FROM #SelectedTables st
                    WHERE st.Selected = 1
                      AND t.schema_name LIKE REPLACE(st.SchemaPattern, N'_', N'[_]')
                      AND t.table_name  LIKE REPLACE(st.TablePattern,  N'_', N'[_]')
                );
            END

            -- Exclude filter: remove targets matching exclusion patterns
            DELETE t FROM #Targets t
            WHERE EXISTS (
                SELECT 1 FROM #SelectedTables st
                WHERE st.Selected = 0
                  AND t.schema_name LIKE REPLACE(st.SchemaPattern, N'_', N'[_]')
                  AND t.table_name  LIKE REPLACE(st.TablePattern,  N'_', N'[_]')
            );

            DECLARE @post_filter_count int = (SELECT COUNT(*) FROM #Targets);
            IF @post_filter_count < @pre_filter_count
            BEGIN
                DECLARE @tables_safe nvarchar(4000) = REPLACE(@Tables, N'%', N'%%');
                SET @Msg = N'  @Tables filter applied: ' + CAST(@pre_filter_count AS nvarchar(10))
                         + N' -> ' + CAST(@post_filter_count AS nvarchar(10))
                         + N' target(s) (' + @tables_safe + N')';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            END
        END

        -- Apply @TopN limit to resumed targets (keep top N by sort_order)
        IF @TopN IS NOT NULL
        BEGIN
            DECLARE @pre_topn_count int = (SELECT COUNT(*) FROM #Targets);
            IF @pre_topn_count > @TopN
            BEGIN
                DELETE FROM #Targets
                WHERE sort_order > (
                    SELECT sort_order FROM (
                        SELECT sort_order, ROW_NUMBER() OVER (ORDER BY sort_order) AS rn
                        FROM #Targets
                    ) ranked WHERE rn = @TopN
                );

                SET @Msg = N'  @TopN filter applied: ' + CAST(@pre_topn_count AS nvarchar(10))
                         + N' -> ' + CAST(@TopN AS nvarchar(10)) + N' target(s)';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            END
        END

        RAISERROR(N'', 10, 1) WITH NOWAIT;
    END

    ----------------------------------------------------------------------------
    -- Per-database discovery loop (skipped in resume mode)
    ----------------------------------------------------------------------------
    IF @resume_loaded = 0
    BEGIN
    DECLARE
        @CurrentDatabaseName sysname,
        @CurrentDatabaseID   int,
        @discovery_sql       nvarchar(max),
        @discovery_errors    int = 0;

    -- Uptime hours for fetch-rate normalization (converts cumulative dm_db_index_operational_stats
    -- counters to per-hour rates, making them comparable across servers with different uptimes).
    DECLARE @UptimeHours float;
    SELECT @UptimeHours = DATEDIFF(SECOND, sqlserver_start_time, GETUTCDATE()) / 3600.0
    FROM sys.dm_os_sys_info;
    -- Guard: minimum 1 hour to avoid division-by-near-zero on fresh restarts
    SET @UptimeHours = CASE WHEN @UptimeHours < 1.0 THEN 1.0 ELSE @UptimeHours END;

    WHILE EXISTS (SELECT 1 FROM @tmpDatabases WHERE Selected = 1 AND Completed = 0)
    BEGIN
        SELECT TOP (1)
            @CurrentDatabaseID = ID,
            @CurrentDatabaseName = DatabaseName
        FROM @tmpDatabases
        WHERE Selected = 1 AND Completed = 0
        ORDER BY ID;

        SET @Msg = N'Scanning database: ' + @CurrentDatabaseName;
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;

        /*
        Build per-database discovery SQL.
        This runs inside the target database context via USE [db] and inserts
        results directly into #Targets (visible from parent scope).

        The discovery query:
        1) Finds heaps with forwarded records via dm_db_index_physical_stats
        2) Optionally reads CPU data from Query Store
        3) Maps plan CPU to heap objects via showplan XML
        4) Finds safe CI swap keys
        5) Checks for LOB columns
        6) Ranks and selects top N targets
        7) Generates rebuild commands
        */
        SET @discovery_sql = N'
USE ' + QUOTENAME(@CurrentDatabaseName) + N';

-- Per-database temp tables (scoped to this sp_executesql call)
CREATE TABLE #Heaps
(
    object_id              int           NOT NULL PRIMARY KEY,
    schema_name            sysname       NOT NULL,
    table_name             sysname       NOT NULL,
    page_count             bigint        NOT NULL,
    record_count           bigint        NULL,
    forwarded_record_count bigint        NOT NULL,
    forwarded_pct          decimal(6,2)  NOT NULL,
    avg_page_space_pct     decimal(5,2)  NULL,
    avg_frag_pct           decimal(5,2)  NULL,
    ghost_record_count     bigint        NULL,
    forwarded_fetch_count  bigint        NULL,
    user_seeks             bigint        NULL,
    user_scans             bigint        NULL,
    user_lookups           bigint        NULL,
    user_updates           bigint        NULL,
    heap_compression       tinyint       NOT NULL DEFAULT 0,
    replication_hint       varchar(20)   NULL,
    lock_escalation        tinyint       NOT NULL DEFAULT 0
);

CREATE TABLE #CpuByPlan
(
    plan_id              bigint NOT NULL PRIMARY KEY,
    total_cpu_ms         bigint NOT NULL,
    total_logical_reads  bigint NOT NULL,
    total_physical_reads bigint NOT NULL,
    total_duration_ms    bigint NOT NULL,
    total_executions     bigint NOT NULL
);

CREATE TABLE #CpuByObject
(
    object_id            int            NOT NULL PRIMARY KEY,
    total_cpu_ms         bigint         NOT NULL,
    total_logical_reads  bigint         NOT NULL DEFAULT 0,
    total_physical_reads bigint         NOT NULL DEFAULT 0,
    total_duration_ms    bigint         NOT NULL DEFAULT 0,
    total_executions     bigint         NOT NULL DEFAULT 0,
    plan_count           int            NOT NULL DEFAULT 0,
    query_count          int            NOT NULL DEFAULT 0,
    query_hashes         nvarchar(max)  NULL
);

-- 1) Find heaps with forwarded records
-- Pre-filter: materialize heap object_ids first, then CROSS APPLY physical stats
-- only for heaps. This avoids scanning non-heap objects.
DECLARE @Msg_inner nvarchar(4000);

CREATE TABLE #HeapObjects
(
    object_id   int     NOT NULL PRIMARY KEY,
    schema_name sysname NOT NULL,
    table_name  sysname NOT NULL
);

INSERT #HeapObjects (object_id, schema_name, table_name)
SELECT o.object_id, s.name, o.name
FROM sys.tables o
JOIN sys.schemas s ON o.schema_id = s.schema_id
JOIN sys.indexes ix ON ix.object_id = o.object_id AND ix.type = 0
WHERE o.is_memory_optimized = 0
  AND o.temporal_type = 0
  AND o.is_node = 0 AND o.is_edge = 0
  AND NOT EXISTS (SELECT 1 FROM sys.indexes ci WHERE ci.object_id = o.object_id AND ci.type IN (5,6))
';
        -- 9I: Ledger table exclusion (SQL 2022+ only; column doesn't exist on older versions)
        IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 16
            SET @discovery_sql += N'  AND o.ledger_type = 0';

        -- @Tables filter: #SelectedTables is populated at outer scope, visible here.
        -- When #SelectedTables is empty (@Tables IS NULL), both conditions are no-ops.
        SET @discovery_sql += N'
  -- Table include filter
  AND (NOT EXISTS (SELECT 1 FROM #SelectedTables WHERE Selected = 1)
       OR EXISTS (SELECT 1 FROM #SelectedTables st
                  WHERE st.Selected = 1
                  AND s.name LIKE REPLACE(st.SchemaPattern, N''_'', N''[_]'')
                  AND o.name LIKE REPLACE(st.TablePattern, N''_'', N''[_]'')))
  -- Table exclude filter
  AND NOT EXISTS (SELECT 1 FROM #SelectedTables st
                  WHERE st.Selected = 0
                  AND s.name LIKE REPLACE(st.SchemaPattern, N''_'', N''[_]'')
                  AND o.name LIKE REPLACE(st.TablePattern, N''_'', N''[_]''))';

        SET @discovery_sql += N';

DECLARE @HeapTableCount int = (SELECT COUNT(*) FROM #HeapObjects);
SET @Msg_inner = N''  '' + CAST(@HeapTableCount AS nvarchar(10)) + N'' heap table(s) to scan (non-heap objects skipped).'';
RAISERROR(@Msg_inner, 10, 1) WITH NOWAIT;

SET ANSI_WARNINGS OFF;  -- suppress "Null value is eliminated by an aggregate" from DMV aggregation

INSERT #Heaps (object_id, schema_name, table_name, page_count, record_count, forwarded_record_count, forwarded_pct, avg_page_space_pct, avg_frag_pct, ghost_record_count, forwarded_fetch_count, user_seeks, user_scans, user_lookups, user_updates, heap_compression, replication_hint, lock_escalation)
SELECT
    ho.object_id,
    ho.schema_name,
    ho.table_name,
    ips.page_count,
    ips.record_count,
    ips.forwarded_record_count,
    CAST(100.0 * ips.forwarded_record_count / NULLIF(ips.record_count,0) AS decimal(6,2)),
    CAST(ips.avg_page_space_used_in_percent AS decimal(5,2)),
    CAST(ips.avg_fragmentation_in_percent AS decimal(5,2)),
    ips.ghost_record_count,
    os.forwarded_fetch_count,
    us.user_seeks,
    us.user_scans,
    us.user_lookups,
    us.user_updates,
    ISNULL(dc.heap_compression, 0),
    -- Replication awareness
    CASE
        WHEN tp.is_published = 1 AND tp.is_tracked_by_cdc = 1 THEN N''PUBLISHED_CDC''
        WHEN tp.is_merge_published = 1 AND tp.is_tracked_by_cdc = 1 THEN N''MERGE_PUB_CDC''
        WHEN tp.is_published = 1 THEN N''PUBLISHED''
        WHEN tp.is_merge_published = 1 THEN N''MERGE_PUBLISHED''
        WHEN tp.is_tracked_by_cdc = 1 THEN N''CDC''
        ELSE NULL
    END,
    ISNULL(tp.lock_escalation, 0)
FROM #HeapObjects ho
CROSS APPLY (
    -- Aggregate per-partition rows for partitioned heaps.
    -- dm_db_index_physical_stats returns one row per partition when partition_number=NULL.
    SELECT
        SUM(page_count) AS page_count,
        SUM(record_count) AS record_count,
        SUM(forwarded_record_count) AS forwarded_record_count,
        AVG(avg_page_space_used_in_percent) AS avg_page_space_used_in_percent,
        AVG(avg_fragmentation_in_percent) AS avg_fragmentation_in_percent,
        SUM(ghost_record_count) AS ghost_record_count
    FROM sys.dm_db_index_physical_stats(DB_ID(), ho.object_id, 0, NULL, ''SAMPLED'')
) ips
OUTER APPLY (
    SELECT SUM(forwarded_fetch_count) AS forwarded_fetch_count
    FROM sys.dm_db_index_operational_stats(DB_ID(), ho.object_id, 0, NULL)
) os
OUTER APPLY (
    SELECT user_seeks, user_scans, user_lookups, user_updates
    FROM sys.dm_db_index_usage_stats
    WHERE database_id = DB_ID() AND object_id = ho.object_id AND index_id = 0
) us
OUTER APPLY (
    -- Heap compression: 0=NONE, 1=ROW, 2=PAGE.
    -- MAX across partitions for partitioned heaps with mixed compression.
    SELECT MAX(data_compression) AS heap_compression
    FROM sys.partitions
    WHERE object_id = ho.object_id AND index_id = 0
) dc
OUTER APPLY (
    -- Table properties for replication awareness and lock escalation.
    SELECT t.is_published, t.is_merge_published, t.is_tracked_by_cdc, t.lock_escalation
    FROM sys.tables t
    WHERE t.object_id = ho.object_id
) tp
WHERE ips.forwarded_record_count > 0
  AND ips.page_count >= @MinPages_param
  AND (@MaxPages_param IS NULL OR ips.page_count <= @MaxPages_param)
  AND (100.0 * ips.forwarded_record_count / NULLIF(ips.record_count,0)) >= @MinForwardedPct_param;

SET ANSI_WARNINGS ON;

DROP TABLE #HeapObjects;

DECLARE @HeapCount_inner int = (SELECT COUNT(*) FROM #Heaps);
SET @Msg_inner = N''  Found '' + CAST(@HeapCount_inner AS nvarchar(10)) + N'' heap(s) with forwarded records.'';
RAISERROR(@Msg_inner, 10, 1) WITH NOWAIT;

IF @HeapCount_inner = 0 RETURN;

-- Create #PlanObjMap unconditionally (referenced in Ranked CTE and forced plan cursors).
-- Only populated when CpuSource = QUERY_STORE.
CREATE TABLE #PlanObjMap
(
    plan_id      bigint   NOT NULL,
    query_id     bigint   NOT NULL,
    query_hash   binary(8) NOT NULL,
    schema_name  sysname  NOT NULL,
    table_name   sysname  NOT NULL
);
';

        -- 2) CPU source (conditional)
        IF @CpuSourceUpper = 'QUERY_STORE'
        BEGIN
            SET @discovery_sql += N'
-- 2) CPU from Query Store
DECLARE @QsActualState nvarchar(60);
DECLARE @QsDesiredState nvarchar(60);
DECLARE @QsRetentionDays int;
DECLARE @QsRw bit;

SELECT
    @QsActualState  = actual_state_desc,
    @QsDesiredState = desired_state_desc,
    @QsRetentionDays = stale_query_threshold_days
FROM sys.database_query_store_options;

SET @QsRw = CASE WHEN @QsActualState = ''READ_WRITE'' THEN 1 ELSE 0 END;

-- Warn if QS is READ_ONLY (data may be stale)
IF @QsActualState = ''READ_ONLY'' AND @QsDesiredState = ''READ_WRITE''
BEGIN
    RAISERROR(N''  WARNING: Query Store is READ_ONLY (desired READ_WRITE). Data may be stale - check MAX_STORAGE_SIZE_MB.'', 10, 1) WITH NOWAIT;
    SET @QsRw = 1; -- still read QS data, just warn
END
ELSE IF @QsActualState NOT IN (''READ_WRITE'', ''READ_ONLY'')
BEGIN
    RAISERROR(N''  WARNING: Query Store is not active (state: %s). CPU data unavailable.'', 10, 1, @QsActualState) WITH NOWAIT;
END

-- Warn if lookback exceeds retention policy
IF @QsRw = 1 AND @QsRetentionDays IS NOT NULL AND @LookbackDays_param > @QsRetentionDays
BEGIN
    DECLARE @QsRetMsg nvarchar(200) = N''  WARNING: @LookbackDays ('' + CAST(@LookbackDays_param AS nvarchar(10))
        + N'') exceeds QS retention ('' + CAST(@QsRetentionDays AS nvarchar(10)) + N'' days). Results limited to actual retention.'';
    RAISERROR(@QsRetMsg, 10, 1) WITH NOWAIT;
END

IF @QsRw = 1
BEGIN
    ;WITH CpuByPlan AS
    (
        SELECT
            rs.plan_id,
            total_cpu_us = SUM(CONVERT(bigint, rs.count_executions) * CONVERT(bigint, rs.avg_cpu_time)),
            total_logical_reads = SUM(CONVERT(bigint, rs.count_executions) * CONVERT(bigint, rs.avg_logical_io_reads)),
            total_physical_reads = SUM(CONVERT(bigint, rs.count_executions) * CONVERT(bigint, rs.avg_physical_io_reads)),
            total_duration_us = SUM(CONVERT(bigint, rs.count_executions) * CONVERT(bigint, rs.avg_duration)),
            total_executions = SUM(CONVERT(bigint, rs.count_executions))
        FROM sys.query_store_runtime_stats rs
        JOIN sys.query_store_runtime_stats_interval rsi
          ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
        WHERE rsi.start_time >= DATEADD(DAY, -@LookbackDays_param, SYSUTCDATETIME())
        GROUP BY rs.plan_id
    )
    INSERT #CpuByPlan(plan_id, total_cpu_ms, total_logical_reads, total_physical_reads, total_duration_ms, total_executions)
    SELECT plan_id,
        CONVERT(bigint, total_cpu_us / 1000),
        total_logical_reads,
        total_physical_reads,
        CONVERT(bigint, total_duration_us / 1000),
        total_executions
    FROM CpuByPlan
    WHERE total_cpu_us > 0;

    -- 3) Map plan CPU to heap objects via showplan XML
    IF EXISTS (SELECT 1 FROM #CpuByPlan)
    BEGIN
        ;WITH XMLNAMESPACES (DEFAULT ''http://schemas.microsoft.com/sqlserver/2004/07/showplan''),
        HeapPlans AS
        (
            -- Pre-filter: only parse plans whose text contains a heap table name
            SELECT p.plan_id, p.query_id, q.query_hash,
                TRY_CONVERT(xml, p.query_plan) AS plan_xml
            FROM sys.query_store_plan p
            JOIN #CpuByPlan cp ON cp.plan_id = p.plan_id
            JOIN sys.query_store_query q ON p.query_id = q.query_id
            WHERE EXISTS (SELECT 1 FROM #Heaps h WHERE p.query_plan LIKE N''%Table="[[]'' + h.table_name + N'']%'')
        )
        -- Filter to Table Scan RelOps only. These are the operations that traverse
        -- forwarded record pointers. Index Seeks/Scans on NCIs don''t hit them.
        INSERT #PlanObjMap (plan_id, query_id, query_hash, schema_name, table_name)
        SELECT DISTINCT
            hp.plan_id,
            hp.query_id,
            hp.query_hash,
            REPLACE(REPLACE(obj.value(''@Schema'',''sysname''), N''['', N''''), N'']'', N'''') AS schema_name,
            REPLACE(REPLACE(obj.value(''@Table'', ''sysname''), N''['', N''''), N'']'', N'''') AS table_name
        FROM HeapPlans hp
        CROSS APPLY hp.plan_xml.nodes(''//RelOp[@PhysicalOp="Table Scan"]/*/Object[@Schema and @Table]'') AS n(obj)
        WHERE hp.plan_xml IS NOT NULL;

        -- Aggregate metrics by object
        INSERT #CpuByObject(object_id, total_cpu_ms, total_logical_reads, total_physical_reads, total_duration_ms, total_executions, plan_count, query_count)
        SELECT h.object_id,
            SUM(cp.total_cpu_ms),
            SUM(cp.total_logical_reads),
            SUM(cp.total_physical_reads),
            SUM(cp.total_duration_ms),
            SUM(cp.total_executions),
            COUNT(DISTINCT pm.plan_id),
            COUNT(DISTINCT pm.query_id)
        FROM #Heaps h
        JOIN #PlanObjMap pm ON pm.schema_name COLLATE DATABASE_DEFAULT = h.schema_name COLLATE DATABASE_DEFAULT
                           AND pm.table_name  COLLATE DATABASE_DEFAULT = h.table_name  COLLATE DATABASE_DEFAULT
        JOIN #CpuByPlan cp ON cp.plan_id = pm.plan_id
        GROUP BY h.object_id;

        -- Collect distinct query_hash values per heap object (for performance tracking)
        ;WITH DistinctHashes AS
        (
            SELECT DISTINCT h.object_id, pm.query_hash
            FROM #Heaps h
            JOIN #PlanObjMap pm ON pm.schema_name COLLATE DATABASE_DEFAULT = h.schema_name COLLATE DATABASE_DEFAULT
                               AND pm.table_name  COLLATE DATABASE_DEFAULT = h.table_name  COLLATE DATABASE_DEFAULT
        )
        UPDATE cbo
        SET cbo.query_hashes = sub.query_hashes
        FROM #CpuByObject cbo
        JOIN (
            SELECT object_id, STRING_AGG(CONVERT(varchar(18), query_hash, 1), '','') AS query_hashes
            FROM DistinctHashes
            GROUP BY object_id
        ) sub ON cbo.object_id = sub.object_id;
        -- Report unmatchable plan coverage
        DECLARE @qs_total_plans int = (SELECT COUNT(*) FROM #CpuByPlan);
        DECLARE @qs_matched_plans int = (SELECT COUNT(DISTINCT plan_id) FROM #PlanObjMap);
        DECLARE @qs_unmatched int = @qs_total_plans - @qs_matched_plans;

        IF @qs_unmatched > 0
        BEGIN
            DECLARE @qs_cov_msg nvarchar(200) = N''  QS coverage: '' + CAST(@qs_matched_plans AS nvarchar(10))
                + N''/'' + CAST(@qs_total_plans AS nvarchar(10)) + N'' plans mapped to heaps (''
                + CAST(@qs_unmatched AS nvarchar(10)) + N'' had NULL XML or no Table Scan on target heaps).'';
            RAISERROR(@qs_cov_msg, 10, 1) WITH NOWAIT;
        END
    END
END
ELSE
BEGIN
    RAISERROR(N''  Query Store not READ_WRITE; ranking by forwarded_pct only.'', 10, 1) WITH NOWAIT;
END
';
        END
        ELSE IF @CpuSourceUpper = 'NONE'
        BEGIN
            SET @discovery_sql += N'
-- 2) No CPU source; ranking by forwarded_pct only
';
        END
        -- QUICKIESTORE is handled separately below (not per-database dynamic SQL)

        -- 4-7) Key finder, LOB check, ranking, target generation
        SET @discovery_sql += N'
-- 4) Build target list: key finder + LOB check + ranking + command generation
;WITH LobTables AS
(
    SELECT DISTINCT c.object_id
    FROM sys.columns c
    JOIN sys.types t ON c.user_type_id = t.user_type_id
    WHERE t.name IN (N''text'', N''ntext'', N''image'', N''xml'')
       OR c.max_length = -1
),
CandidateKeys AS
(
    SELECT
        i.object_id,
        i.name AS index_name,
        STRING_AGG(QUOTENAME(c.name), N'','') WITHIN GROUP (ORDER BY ic.key_ordinal) AS key_cols,
        SUM(CASE WHEN c.max_length < 0 THEN 99999 ELSE c.max_length END) AS key_bytes,
        COUNT(*) AS key_col_count
    FROM sys.indexes i
    JOIN sys.index_columns ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id AND ic.is_included_column = 0
    JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
    JOIN sys.types t ON c.user_type_id = t.user_type_id
    WHERE i.type = 2
      AND i.is_unique = 1
      AND i.has_filter = 0
      AND i.is_disabled = 0
      AND i.is_hypothetical = 0
      AND ic.key_ordinal > 0
      AND c.is_nullable = 0
      AND ISNULL(c.encryption_type, 0) = 0
      AND c.max_length <> -1
      AND t.name NOT IN (N''text'',N''ntext'',N''image'',N''xml'')
    GROUP BY i.object_id, i.name
    HAVING SUM(CASE WHEN c.max_length < 0 THEN 99999 ELSE c.max_length END) <= 1700
),
BestKey AS
(
    SELECT *, ROW_NUMBER() OVER (PARTITION BY object_id ORDER BY key_col_count ASC, key_bytes ASC, index_name ASC) AS rn
    FROM CandidateKeys
),
NciCounts AS
(
    SELECT object_id, COUNT(*) AS nci_count
    FROM sys.indexes
    WHERE type = 2
    GROUP BY object_id
),
Ranked AS
(
    SELECT
        h.object_id, h.schema_name, h.table_name,
        h.page_count, h.record_count, h.forwarded_record_count, h.forwarded_pct,
        h.avg_page_space_pct, h.avg_frag_pct, h.ghost_record_count,
        h.forwarded_fetch_count,
        cbo.total_cpu_ms,
        CASE
            WHEN @CpuSource_param = ''NONE'' THEN ''FWD_PCT''
            WHEN cbo.total_cpu_ms IS NOT NULL THEN ''QS_CPU''
            ELSE ''QS_NO_DATA''
        END AS ranking_basis,
        ISNULL(nc.nci_count, 0) AS nci_count,
        bk.index_name AS key_source_index,
        bk.key_cols AS temp_key_cols,
        CASE WHEN lt.object_id IS NOT NULL THEN 1 ELSE 0 END AS has_lob_columns,
        h.heap_compression,
        h.replication_hint,
        h.lock_escalation,
        -- Leftover temp CI from failed previous run
        CASE WHEN EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = h.object_id
             AND name = N''CX__Temp__'' + LEFT(h.table_name, 108)) THEN 1 ELSE 0 END AS has_leftover_ci,
        -- 8I: Forced plan check - CI swap invalidates forced plans
        CASE WHEN EXISTS (SELECT 1 FROM #PlanObjMap pm
             JOIN sys.query_store_plan qp ON qp.plan_id = pm.plan_id
             WHERE pm.schema_name COLLATE DATABASE_DEFAULT = h.schema_name
               AND pm.table_name  COLLATE DATABASE_DEFAULT = h.table_name
               AND qp.is_forced_plan = 1) THEN 1 ELSE 0 END AS has_forced_plans,
        -- QS performance snapshot (NULL when CpuSource=NONE or QS not available)
        CASE WHEN cbo.object_id IS NOT NULL THEN SYSUTCDATETIME() ELSE NULL END AS qs_snapshot_time_utc,
        cbo.total_logical_reads  AS qs_total_logical_reads,
        cbo.total_physical_reads AS qs_total_physical_reads,
        cbo.total_duration_ms    AS qs_total_duration_ms,
        cbo.total_executions     AS qs_total_executions,
        cbo.plan_count           AS qs_plan_count,
        cbo.query_count          AS qs_query_count,
        cbo.query_hashes         AS qs_query_hashes,
        -- Usage pattern hint (identify staging/ETL heaps)
        CASE
            WHEN h.user_scans IS NULL AND h.user_seeks IS NULL AND h.user_updates IS NULL THEN NULL
            WHEN ISNULL(h.user_updates, 0) > 0
                 AND (ISNULL(h.user_scans, 0) + ISNULL(h.user_seeks, 0) + ISNULL(h.user_lookups, 0)) = 0
                THEN ''WRITE_ONLY''
            WHEN ISNULL(h.user_updates, 0) > (ISNULL(h.user_scans, 0) + ISNULL(h.user_seeks, 0) + ISNULL(h.user_lookups, 0))
                THEN ''WRITE_HEAVY''
            ELSE NULL
        END AS usage_hint,
        -- LOG10-normalized ranking score: compresses all signals to comparable ~0-10 range.
        -- Weights: 0.4 fetch_rate + 0.4 CPU + 0.2 structural severity.
        -- Write-heavy penalty: 0.5 for WRITE_HEAVY, 0.25 for WRITE_ONLY (rebuild ROI is poor).
        CAST(
            (0.4 * LOG10(ISNULL(h.forwarded_fetch_count, 0) / @UptimeHours_param + 1)
           + 0.4 * LOG10(COALESCE(cbo.total_cpu_ms, 0) + 1)
           + 0.2 * LOG10(h.forwarded_pct + 1))
          * CASE
                WHEN ISNULL(h.user_updates, 0) > 0
                     AND (ISNULL(h.user_scans, 0) + ISNULL(h.user_seeks, 0) + ISNULL(h.user_lookups, 0)) = 0
                    THEN 0.25
                WHEN ISNULL(h.user_updates, 0) > (ISNULL(h.user_scans, 0) + ISNULL(h.user_seeks, 0) + ISNULL(h.user_lookups, 0))
                    THEN 0.5
                ELSE 1.0
            END
        AS decimal(8,4)) AS ranking_score,
        ROW_NUMBER() OVER (ORDER BY
            -- LOG10-normalized weighted score (higher = more impactful)
            (0.4 * LOG10(ISNULL(h.forwarded_fetch_count, 0) / @UptimeHours_param + 1)
           + 0.4 * LOG10(COALESCE(cbo.total_cpu_ms, 0) + 1)
           + 0.2 * LOG10(h.forwarded_pct + 1))
          * CASE
                WHEN ISNULL(h.user_updates, 0) > 0
                     AND (ISNULL(h.user_scans, 0) + ISNULL(h.user_seeks, 0) + ISNULL(h.user_lookups, 0)) = 0
                    THEN 0.25
                WHEN ISNULL(h.user_updates, 0) > (ISNULL(h.user_scans, 0) + ISNULL(h.user_seeks, 0) + ISNULL(h.user_lookups, 0))
                    THEN 0.5
                ELSE 1.0
            END
        DESC) AS target_rank
    FROM #Heaps h
    LEFT JOIN #CpuByObject cbo ON h.object_id = cbo.object_id
    LEFT JOIN BestKey bk ON h.object_id = bk.object_id AND bk.rn = 1
    LEFT JOIN LobTables lt ON h.object_id = lt.object_id
    LEFT JOIN NciCounts nc ON h.object_id = nc.object_id
)
INSERT #Targets
(
    database_name, object_id, schema_name, table_name, page_count, record_count,
    forwarded_record_count, forwarded_pct, forwarded_fetch_count,
    avg_page_space_pct, avg_frag_pct, ghost_record_count,
    total_cpu_ms, ranking_basis, nci_count,
    key_source_index, temp_key_cols, has_lob_columns, heap_compression,
    replication_hint, lock_escalation,
    action_chosen, command_text, ci_drop_command,
    qs_snapshot_time_utc, qs_total_logical_reads, qs_total_physical_reads,
    qs_total_duration_ms, qs_total_executions, qs_plan_count, qs_query_count, qs_query_hashes,
    usage_hint, ranking_score, verify_command
)
SELECT TOP (@TopN_param)
    DB_NAME(),
    r.object_id, r.schema_name, r.table_name,
    r.page_count, r.record_count, r.forwarded_record_count, r.forwarded_pct,
    r.forwarded_fetch_count,
    r.avg_page_space_pct, r.avg_frag_pct, r.ghost_record_count, r.total_cpu_ms,
    r.ranking_basis, r.nci_count,
    r.key_source_index, r.temp_key_cols, r.has_lob_columns, r.heap_compression,
    r.replication_hint, r.lock_escalation,
    -- action_chosen (8I: forced plans prevent CI swap)
    CASE
        WHEN @AllowCiSwap_param = 1 AND @PreferCiSwap_param = 1 AND @Online_param = 1
             AND r.temp_key_cols IS NOT NULL AND r.has_lob_columns = 0
             AND r.has_forced_plans = 0
            THEN ''CI_SWAP_ONLINE''
        WHEN @Online_param = 1 THEN ''HEAP_REBUILD_ONLINE''
        ELSE ''HEAP_REBUILD_OFFLINE''
    END,
    -- command_text: preserve heap compression in CI swap and ALTER TABLE REBUILD
    CASE
        WHEN @AllowCiSwap_param = 1 AND @PreferCiSwap_param = 1 AND @Online_param = 1
             AND r.temp_key_cols IS NOT NULL AND r.has_lob_columns = 0
             AND r.has_forced_plans = 0
        THEN
            -- Leftover temp CI cleanup: prepend DROP if a previous run left a temp CI
            CASE WHEN r.has_leftover_ci = 1
                THEN N''DROP INDEX '' + QUOTENAME(N''CX__Temp__'' + LEFT(r.table_name, 108))
                   + N'' ON '' + QUOTENAME(DB_NAME()) + N''.'' + QUOTENAME(r.schema_name) + N''.'' + QUOTENAME(r.table_name) + N''; ''
                ELSE N'''' END +
            N''CREATE CLUSTERED INDEX '' +
            QUOTENAME(N''CX__Temp__'' + LEFT(r.table_name, 108)) +
            N'' ON '' + QUOTENAME(DB_NAME()) + N''.'' + QUOTENAME(r.schema_name) + N''.'' + QUOTENAME(r.table_name) +
            N'' ('' + r.temp_key_cols + N'') WITH (ONLINE = ON'' +
            CASE WHEN r.heap_compression = 1 THEN N'', DATA_COMPRESSION = ROW''
                 WHEN r.heap_compression = 2 THEN N'', DATA_COMPRESSION = PAGE''
                 ELSE N'''' END +
            COALESCE(N'', MAXDOP = '' + CAST(@Maxdop_param AS nvarchar(10)), N'''') + N'');''
        WHEN @Online_param = 1
        THEN
            N''ALTER TABLE '' + QUOTENAME(DB_NAME()) + N''.'' + QUOTENAME(r.schema_name) + N''.'' + QUOTENAME(r.table_name) +
            N'' REBUILD WITH (ONLINE = ON'' +
            CASE WHEN r.heap_compression = 1 THEN N'', DATA_COMPRESSION = ROW''
                 WHEN r.heap_compression = 2 THEN N'', DATA_COMPRESSION = PAGE''
                 ELSE N'''' END +
            COALESCE(N'', MAXDOP = '' + CAST(@Maxdop_param AS nvarchar(10)), N'''') + N'');''
        ELSE
            N''ALTER TABLE '' + QUOTENAME(DB_NAME()) + N''.'' + QUOTENAME(r.schema_name) + N''.'' + QUOTENAME(r.table_name) +
            N'' REBUILD'' +
            CASE WHEN r.heap_compression > 0 OR @Maxdop_param IS NOT NULL
                THEN N'' WITH ('' +
                    CASE WHEN r.heap_compression = 1 THEN N''DATA_COMPRESSION = ROW''
                         WHEN r.heap_compression = 2 THEN N''DATA_COMPRESSION = PAGE''
                         ELSE N'''' END +
                    CASE WHEN r.heap_compression > 0 AND @Maxdop_param IS NOT NULL THEN N'', '' ELSE N'''' END +
                    COALESCE(N''MAXDOP = '' + CAST(@Maxdop_param AS nvarchar(10)), N'''') +
                    N'')''
                ELSE N'''' END +
            N'';''
    END,
    -- ci_drop_command
    CASE
        WHEN @AllowCiSwap_param = 1 AND @PreferCiSwap_param = 1 AND @Online_param = 1
             AND r.temp_key_cols IS NOT NULL AND r.has_lob_columns = 0
        THEN
            N''DROP INDEX '' +
            QUOTENAME(N''CX__Temp__'' + LEFT(r.table_name, 108)) +
            N'' ON '' + QUOTENAME(DB_NAME()) + N''.'' + QUOTENAME(r.schema_name) + N''.'' + QUOTENAME(r.table_name) +
            N'' WITH (ONLINE = ON'' +
            COALESCE(N'', MAXDOP = '' + CAST(@Maxdop_param AS nvarchar(10)), N'''') + N'');''
        ELSE NULL
    END,
    -- QS performance snapshot
    r.qs_snapshot_time_utc,
    r.qs_total_logical_reads,
    r.qs_total_physical_reads,
    r.qs_total_duration_ms,
    r.qs_total_executions,
    r.qs_plan_count,
    r.qs_query_count,
    r.qs_query_hashes,
    r.usage_hint,
    r.ranking_score,
    -- 8O: Verification command for change management
    N''SELECT forwarded_record_count FROM sys.dm_db_index_physical_stats(DB_ID(N'''''' + QUOTENAME(DB_NAME()) + N''''''), OBJECT_ID(N'''''' + QUOTENAME(DB_NAME()) + N''.'' + QUOTENAME(r.schema_name) + N''.'' + QUOTENAME(r.table_name) + N''''''), 0, NULL, N''''SAMPLED'''');''
FROM Ranked r
ORDER BY r.target_rank;

SET @Msg_inner = N''  Selected '' + CAST(@@ROWCOUNT AS nvarchar(10)) + N'' target(s).'';
RAISERROR(@Msg_inner, 10, 1) WITH NOWAIT;

-- Replication awareness warnings
IF EXISTS (SELECT 1 FROM #Targets WHERE database_name = DB_NAME() AND replication_hint IS NOT NULL)
BEGIN
    DECLARE repl_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT schema_name, table_name, replication_hint FROM #Targets
        WHERE database_name = DB_NAME() AND replication_hint IS NOT NULL;
    DECLARE @repl_schema sysname, @repl_table sysname, @repl_hint varchar(20);
    OPEN repl_cursor;
    FETCH NEXT FROM repl_cursor INTO @repl_schema, @repl_table, @repl_hint;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Msg_inner = N''  WARNING: '' + QUOTENAME(@repl_schema) + N''.'' + QUOTENAME(@repl_table)
            + N'' is '' + @repl_hint + N''. Rebuild will generate replication log traffic.'';
        RAISERROR(@Msg_inner, 10, 1) WITH NOWAIT;
        FETCH NEXT FROM repl_cursor INTO @repl_schema, @repl_table, @repl_hint;
    END
    CLOSE repl_cursor;
    DEALLOCATE repl_cursor;
END

-- 8I: Forced plan warning
IF EXISTS (SELECT 1 FROM #Targets t
           WHERE t.database_name = DB_NAME()
             AND t.action_chosen <> ''CI_SWAP_ONLINE''
             AND t.temp_key_cols IS NOT NULL
             AND t.has_lob_columns = 0
             AND EXISTS (SELECT 1 FROM #PlanObjMap pm
                         JOIN sys.query_store_plan qp ON qp.plan_id = pm.plan_id
                         WHERE pm.schema_name COLLATE DATABASE_DEFAULT = t.schema_name
                           AND pm.table_name  COLLATE DATABASE_DEFAULT = t.table_name
                           AND qp.is_forced_plan = 1))
BEGIN
    DECLARE fp_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT t.schema_name, t.table_name FROM #Targets t
        WHERE t.database_name = DB_NAME()
          AND t.action_chosen <> ''CI_SWAP_ONLINE''
          AND t.temp_key_cols IS NOT NULL
          AND t.has_lob_columns = 0
          AND EXISTS (SELECT 1 FROM #PlanObjMap pm
                      JOIN sys.query_store_plan qp ON qp.plan_id = pm.plan_id
                      WHERE pm.schema_name COLLATE DATABASE_DEFAULT = t.schema_name
                        AND pm.table_name  COLLATE DATABASE_DEFAULT = t.table_name
                        AND qp.is_forced_plan = 1);
    DECLARE @fp_schema sysname, @fp_table sysname;
    OPEN fp_cursor;
    FETCH NEXT FROM fp_cursor INTO @fp_schema, @fp_table;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Msg_inner = N''  WARNING: '' + QUOTENAME(@fp_schema) + N''.'' + QUOTENAME(@fp_table)
            + N'' has forced QS plans. Using heap rebuild instead of CI swap to avoid plan invalidation.'';
        RAISERROR(@Msg_inner, 10, 1) WITH NOWAIT;
        FETCH NEXT FROM fp_cursor INTO @fp_schema, @fp_table;
    END
    CLOSE fp_cursor;
    DEALLOCATE fp_cursor;
END
';

        /*
        Execute the per-database discovery.
        All parameters are passed in to avoid SQL injection from @Databases input.
        */
        BEGIN TRY
            EXEC sys.sp_executesql
                @discovery_sql,
                N'@MinPages_param bigint, @MaxPages_param bigint, @MinForwardedPct_param decimal(6,2),
                  @LookbackDays_param int, @TopN_param int,
                  @AllowCiSwap_param bit, @PreferCiSwap_param bit, @Online_param bit,
                  @Maxdop_param int, @CpuSource_param varchar(20), @UptimeHours_param float',
                @MinPages_param = @MinPages,
                @MaxPages_param = @MaxPages,
                @MinForwardedPct_param = @MinForwardedPct,
                @LookbackDays_param = @LookbackDays,
                @TopN_param = @TopN,
                @AllowCiSwap_param = @AllowCiSwap,
                @PreferCiSwap_param = @PreferCiSwap,
                @Online_param = @Online,
                @Maxdop_param = @Maxdop,
                @CpuSource_param = @CpuSourceUpper,
                @UptimeHours_param = @UptimeHours;
        END TRY
        BEGIN CATCH
            SET @discovery_errors += 1;
            SET @Msg = N'  ERROR scanning ' + @CurrentDatabaseName + N': '
                     + CAST(ERROR_NUMBER() AS nvarchar(10)) + N' - ' + LEFT(ERROR_MESSAGE(), 1000);
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        END CATCH;

        -- Set sort_order = target_id for newly inserted rows
        UPDATE #Targets SET sort_order = target_id WHERE sort_order = 0;

        -- Mark database as completed
        UPDATE @tmpDatabases SET Completed = 1 WHERE ID = @CurrentDatabaseID;

        -- Scan throttle: WAITFOR between database scans
        -- Reduces dm_db_index_physical_stats latch contention on busy servers.
        IF @ScanThrottleMs IS NOT NULL AND @ScanThrottleMs > 0
        BEGIN
            DECLARE @ThrottleDelay varchar(12);
            SET @ThrottleDelay = '00:00:'
                + RIGHT('00' + CAST(@ScanThrottleMs / 1000 AS varchar(2)), 2)
                + '.' + RIGHT('000' + CAST(@ScanThrottleMs % 1000 AS varchar(3)), 3);
            WAITFOR DELAY @ThrottleDelay;
        END

        -- Scan phase time check: stop scanning if @MaxRunSeconds is exceeded
        -- Preserve execution time when scan phase is slow
        IF @MaxRunSeconds IS NOT NULL
           AND DATEDIFF(SECOND, @start_time, SYSDATETIME()) >= @MaxRunSeconds
        BEGIN
            DECLARE @scan_remaining_dbs int;
            SELECT @scan_remaining_dbs = COUNT(*) FROM @tmpDatabases WHERE Selected = 1 AND Completed = 0;

            IF @scan_remaining_dbs > 0
            BEGIN
                SET @Msg = N'Time limit reached during scan phase. Skipping '
                         + CAST(@scan_remaining_dbs AS nvarchar(10)) + N' remaining database(s).';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            END
            BREAK;
        END
    END

    /*
    QUICKIESTORE: handled outside the database loop because sp_QuickieStore
    typically runs in the current database context and returns cross-database results.
    TODO: This path needs design thought for multi-database scenarios.
    For now, it only works with single-database mode.
    */
    IF @CpuSourceUpper = 'QUICKIESTORE'
    BEGIN
        RAISERROR(N'Reading CPU data from sp_QuickieStore...', 10, 1) WITH NOWAIT;

        IF @DatabaseCount > 1
        BEGIN
            RAISERROR(N'WARNING: QUICKIESTORE CPU source only applies to the current database context. Multi-database CPU ranking not available.', 10, 1) WITH NOWAIT;
        END

        /*
        Build the CREATE TABLE DDL from sp_describe_first_result_set metadata.
        */
        IF OBJECT_ID('tempdb..#CpuByPlan') IS NOT NULL DROP TABLE #CpuByPlan;

        CREATE TABLE #CpuByPlan
        (
            plan_id              bigint NOT NULL PRIMARY KEY,
            total_cpu_ms         bigint NOT NULL,
            total_logical_reads  bigint NOT NULL DEFAULT 0,
            total_physical_reads bigint NOT NULL DEFAULT 0,
            total_duration_ms    bigint NOT NULL DEFAULT 0,
            total_executions     bigint NOT NULL DEFAULT 0
        );

        DECLARE @ddl nvarchar(max) = N'CREATE TABLE #Quickie(';
        DECLARE @ColCount int = 0;

        ;WITH meta AS
        (
            SELECT column_ordinal, name, system_type_name, is_nullable, error_number
            FROM sys.sp_describe_first_result_set(@QuickieExecSql, NULL, 0)
        )
        SELECT
            @ddl = @ddl + QUOTENAME(name) + N' ' + system_type_name + N' ' +
                   CASE WHEN is_nullable = 1 THEN N'NULL' ELSE N'NOT NULL' END + N',' + CHAR(10),
            @ColCount = @ColCount + 1
        FROM meta
        WHERE error_number IS NULL
          AND name IS NOT NULL
        ORDER BY column_ordinal;

        IF @ColCount = 0
        BEGIN
            RAISERROR(N'sp_describe_first_result_set returned no columns for @QuickieExecSql. Cannot proceed.', 16, 1);
            EXEC sp_releaseapplock @Resource = N'sp_HeapDoctor', @LockOwner = N'Session';
            RETURN;
        END

        SET @ddl = LEFT(@ddl, DATALENGTH(@ddl) / 2 - 2) + N');';

        IF CHARINDEX(QUOTENAME(@QuickiePlanIdColumn), @ddl) = 0
        OR CHARINDEX(QUOTENAME(@QuickieCpuUsColumn), @ddl) = 0
        BEGIN
            RAISERROR(N'Quickie output metadata does not contain required columns. Check @QuickiePlanIdColumn / @QuickieCpuUsColumn.', 16, 1);
            EXEC sp_releaseapplock @Resource = N'sp_HeapDoctor', @LockOwner = N'Session';
            RETURN;
        END

        DECLARE @QuickieBatch nvarchar(max) =
            @ddl + N'
INSERT #Quickie EXEC sys.sp_executesql @InnerSql;

INSERT #CpuByPlan(plan_id, total_cpu_ms)
SELECT
    CONVERT(bigint, ' + QUOTENAME(@QuickiePlanIdColumn) + N') AS plan_id,
    CONVERT(bigint,
        CASE
            WHEN @Unit = ''ms'' THEN ' + QUOTENAME(@QuickieCpuUsColumn) + N'
            ELSE ' + QUOTENAME(@QuickieCpuUsColumn) + N' / 1000.0
        END
    ) AS total_cpu_ms
FROM #Quickie
WHERE ' + QUOTENAME(@QuickiePlanIdColumn) + N' IS NOT NULL;
';

        EXEC sys.sp_executesql
            @QuickieBatch,
            N'@InnerSql nvarchar(max), @Unit varchar(10)',
            @InnerSql = @QuickieExecSql,
            @Unit = @QuickieCpuUnit;

        SET @Msg = N'Loaded ' + CAST((SELECT COUNT(*) FROM #CpuByPlan) AS nvarchar(10)) + N' plan(s) with CPU data from QuickieStore.';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;

        -- Update #Targets with CPU data for the current database
        -- (QuickieStore CPU mapping via plan XML)
        DECLARE @QueryStoreRW bit =
            CASE WHEN EXISTS (SELECT 1 FROM sys.database_query_store_options WHERE actual_state_desc = 'READ_WRITE')
                 THEN 1 ELSE 0 END;

        IF @QueryStoreRW = 1 AND EXISTS (SELECT 1 FROM #CpuByPlan)
        BEGIN
            -- Enrich #CpuByPlan with full QS metrics for QUICKIESTORE path
            -- (QUICKIESTORE only provides CPU; we supplement from QS runtime stats)
            ;WITH PlanMetrics AS
            (
                SELECT
                    rs.plan_id,
                    SUM(CONVERT(bigint, rs.count_executions) * CONVERT(bigint, rs.avg_logical_io_reads)) AS total_logical_reads,
                    SUM(CONVERT(bigint, rs.count_executions) * CONVERT(bigint, rs.avg_physical_io_reads)) AS total_physical_reads,
                    SUM(CONVERT(bigint, rs.count_executions) * CONVERT(bigint, rs.avg_duration)) / 1000 AS total_duration_ms,
                    SUM(CONVERT(bigint, rs.count_executions)) AS total_executions
                FROM sys.query_store_runtime_stats rs
                JOIN sys.query_store_runtime_stats_interval rsi
                  ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
                WHERE rsi.start_time >= DATEADD(DAY, -@LookbackDays, SYSUTCDATETIME())
                  AND rs.plan_id IN (SELECT plan_id FROM #CpuByPlan)
                GROUP BY rs.plan_id
            )
            UPDATE cp
            SET cp.total_logical_reads  = ISNULL(pm.total_logical_reads, 0),
                cp.total_physical_reads = ISNULL(pm.total_physical_reads, 0),
                cp.total_duration_ms    = ISNULL(pm.total_duration_ms, 0),
                cp.total_executions     = ISNULL(pm.total_executions, 0)
            FROM #CpuByPlan cp
            LEFT JOIN PlanMetrics pm ON cp.plan_id = pm.plan_id;

            ;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan'),
            HeapPlans AS
            (
                -- Pre-filter: only parse plans whose text contains a target table name
                SELECT p.plan_id, p.query_id, q.query_hash,
                    TRY_CONVERT(xml, p.query_plan) AS plan_xml
                FROM sys.query_store_plan p
                JOIN #CpuByPlan cp ON cp.plan_id = p.plan_id
                JOIN sys.query_store_query q ON p.query_id = q.query_id
                WHERE EXISTS (SELECT 1 FROM #Targets t2 WHERE t2.database_name = DB_NAME()
                              AND p.query_plan LIKE N'%Table="[[]' + t2.table_name + N']%')
            ),
            PlanObj AS
            (
                -- Filter to Table Scan RelOps only
                SELECT DISTINCT
                    hp.plan_id,
                    hp.query_id,
                    hp.query_hash,
                    REPLACE(REPLACE(obj.value('@Schema','sysname'), N'[', N''), N']', N'') AS schema_name,
                    REPLACE(REPLACE(obj.value('@Table','sysname'),  N'[', N''), N']', N'') AS table_name
                FROM HeapPlans hp
                CROSS APPLY hp.plan_xml.nodes('//RelOp[@PhysicalOp="Table Scan"]/*/Object[@Schema and @Table]') AS n(obj)
                WHERE hp.plan_xml IS NOT NULL
            )
            UPDATE t
            SET t.total_cpu_ms          = sub.total_cpu_ms,
                t.ranking_basis         = 'QS_CPU',
                t.qs_snapshot_time_utc  = SYSUTCDATETIME(),
                t.qs_total_logical_reads  = sub.total_logical_reads,
                t.qs_total_physical_reads = sub.total_physical_reads,
                t.qs_total_duration_ms    = sub.total_duration_ms,
                t.qs_total_executions     = sub.total_executions,
                t.qs_plan_count           = sub.plan_count,
                t.qs_query_count          = sub.query_count,
                t.qs_query_hashes         = sub.query_hashes
            FROM #Targets t
            JOIN (
                SELECT t2.target_id,
                    SUM(cp.total_cpu_ms) AS total_cpu_ms,
                    SUM(cp.total_logical_reads) AS total_logical_reads,
                    SUM(cp.total_physical_reads) AS total_physical_reads,
                    SUM(cp.total_duration_ms) AS total_duration_ms,
                    SUM(cp.total_executions) AS total_executions,
                    COUNT(DISTINCT po.plan_id) AS plan_count,
                    COUNT(DISTINCT po.query_id) AS query_count,
                    (
                        SELECT STRING_AGG(CONVERT(varchar(18), dh.query_hash, 1), ',')
                        FROM (SELECT DISTINCT po2.query_hash
                              FROM PlanObj po2
                              WHERE po2.schema_name = t2.schema_name AND po2.table_name = t2.table_name) dh
                    ) AS query_hashes
                FROM #Targets t2
                JOIN PlanObj po ON po.schema_name = t2.schema_name AND po.table_name = t2.table_name
                JOIN #CpuByPlan cp ON cp.plan_id = po.plan_id
                WHERE t2.database_name = DB_NAME()
                GROUP BY t2.target_id, t2.schema_name, t2.table_name
            ) sub ON t.target_id = sub.target_id;
        END

        DROP TABLE #CpuByPlan;

        /*
        Re-rank targets after QUICKIESTORE CPU update. The execution loop iterates
        by sort_order, so we reassign sort_order to reflect the updated ranking.
        */
        -- Recalculate ranking_score with updated CPU from QUICKIESTORE
        UPDATE #Targets
        SET ranking_score = CAST(
            (0.4 * LOG10(ISNULL(forwarded_fetch_count, 0) / @UptimeHours + 1)
           + 0.4 * LOG10(COALESCE(total_cpu_ms, 0) + 1)
           + 0.2 * LOG10(forwarded_pct + 1))
          * CASE usage_hint
                WHEN 'WRITE_ONLY' THEN 0.25
                WHEN 'WRITE_HEAVY' THEN 0.5
                ELSE 1.0
            END
        AS decimal(8,4));

        ;WITH Reranked AS
        (
            SELECT
                target_id,
                sort_order,
                ROW_NUMBER() OVER (
                    ORDER BY ranking_score DESC
                ) AS new_rank
            FROM #Targets
        )
        UPDATE Reranked SET sort_order = new_rank;
    END

    END -- IF @resume_loaded = 0 (skip discovery + QUICKIESTORE in resume mode)

    ----------------------------------------------------------------------------
    -- Final target count
    ----------------------------------------------------------------------------
    DECLARE @TargetCount int = (SELECT COUNT(*) FROM #Targets);

    RAISERROR(N'', 10, 1) WITH NOWAIT;
    SET @Msg = N'Total targets across all databases: ' + CAST(@TargetCount AS nvarchar(10));
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;

    IF @resume_loaded = 0 AND @discovery_errors > 0
    BEGIN
        SET @Msg = N'WARNING: ' + CAST(@discovery_errors AS nvarchar(10))
                 + N' database(s) had errors during discovery scan. Check messages above.';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    END

    -- 8A: Usage_hint uptime warning
    -- If SQL Server restarted recently, dm_db_index_usage_stats hasn't accumulated enough data
    -- for reliable WRITE_HEAVY/WRITE_ONLY classification.
    IF @UptimeHours < 24.0
       AND EXISTS (SELECT 1 FROM #Targets WHERE usage_hint IS NOT NULL)
    BEGIN
        SET @Msg = N'WARNING: SQL Server restarted '
                 + CAST(CAST(@UptimeHours AS decimal(6,1)) AS nvarchar(20))
                 + N' hours ago. usage_hint (WRITE_HEAVY/WRITE_ONLY) may be unreliable due to insufficient dm_db_index_usage_stats accumulation.';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    END

    -- RCSI version store pressure warning
    -- Online rebuilds on RCSI databases generate version store data in tempdb.
    BEGIN
        DECLARE @rcsi_dbs nvarchar(max);
        SELECT @rcsi_dbs = STRING_AGG(sub.database_name, N', ')
        FROM (SELECT DISTINCT t.database_name
              FROM #Targets t
              JOIN sys.databases d ON d.name = t.database_name COLLATE DATABASE_DEFAULT
              WHERE d.is_read_committed_snapshot_on = 1
                AND t.page_count > 100000) sub;

        IF @rcsi_dbs IS NOT NULL
        BEGIN
            SET @Msg = N'WARNING: RCSI enabled on [' + @rcsi_dbs
                     + N']. Online rebuild of large heaps will generate version store data in tempdb.';
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        END
    END

    -- Transaction log impact warning
    -- FULL recovery databases generate significant log for rebuilds.
    BEGIN
        DECLARE @full_recovery_dbs nvarchar(max);
        DECLARE @total_est_log_gb decimal(10,2);

        SELECT @full_recovery_dbs = STRING_AGG(sub.database_name, N', ')
        FROM (SELECT DISTINCT t.database_name
              FROM #Targets t
              JOIN sys.databases d ON d.name = t.database_name COLLATE DATABASE_DEFAULT
              WHERE d.recovery_model_desc = N'FULL') sub;

        SELECT @total_est_log_gb = CAST(SUM(t.page_count) * 8192.0 / 1073741824 AS decimal(10,2))
        FROM #Targets t
        JOIN sys.databases d ON d.name = t.database_name COLLATE DATABASE_DEFAULT
        WHERE d.recovery_model_desc = N'FULL';

        IF @full_recovery_dbs IS NOT NULL AND @total_est_log_gb > 1.0
        BEGIN
            SET @Msg = N'WARNING: Database(s) [' + @full_recovery_dbs
                     + N'] use FULL recovery. Estimated ~'
                     + CAST(@total_est_log_gb AS nvarchar(20))
                     + N' GB of transaction log will be generated. Ensure frequent log backups.';
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        END
    END

    -- 8N: TDE detection and throughput warning
    BEGIN
        DECLARE @tde_dbs nvarchar(max);
        SELECT @tde_dbs = STRING_AGG(sub.database_name, N', ')
        FROM (SELECT DISTINCT t.database_name
              FROM #Targets t
              WHERE EXISTS (
                  SELECT 1
                  FROM sys.dm_database_encryption_keys dek
                  WHERE dek.database_id = DB_ID(t.database_name)
                    AND dek.encryption_state >= 3
              )) sub;

        IF @tde_dbs IS NOT NULL
        BEGIN
            SET @Msg = N'WARNING: Database(s) [' + @tde_dbs
                     + N'] have TDE enabled. Rebuild throughput may be 30-50%% lower than unencrypted databases.';
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        END
    END

    -- 9J: AG sync-commit warning
    BEGIN
        DECLARE @ag_sync_dbs nvarchar(max);
        SELECT @ag_sync_dbs = STRING_AGG(sub.database_name, N', ')
        FROM (SELECT DISTINCT t.database_name
              FROM #Targets t
              WHERE EXISTS (
                  SELECT 1
                  FROM sys.dm_hadr_database_replica_states drs
                  WHERE drs.database_id = DB_ID(t.database_name)
                    AND drs.is_local = 0
                    AND drs.synchronization_state = 1  -- SYNCHRONIZED (sync commit)
              )) sub;

        IF @ag_sync_dbs IS NOT NULL
        BEGIN
            DECLARE @ag_large_pages bigint;
            SELECT @ag_large_pages = SUM(t.page_count)
            FROM #Targets t
            WHERE EXISTS (
                SELECT 1
                FROM sys.dm_hadr_database_replica_states drs
                WHERE drs.database_id = DB_ID(t.database_name)
                  AND drs.is_local = 0
                  AND drs.synchronization_state = 1
            );

            IF @ag_large_pages > 100000  -- Only warn for large rebuilds (>800 MB)
            BEGIN
                SET @Msg = N'WARNING: Database(s) [' + @ag_sync_dbs
                         + N'] use synchronous AG commit. Rebuild throughput may be limited by secondary replica I/O.';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            END
        END
    END

    -- 9K: Backup running check
    BEGIN
        DECLARE @backup_dbs nvarchar(max);
        SELECT @backup_dbs = STRING_AGG(sub.database_name, N', ')
        FROM (SELECT DISTINCT t.database_name
              FROM #Targets t
              WHERE EXISTS (
                  SELECT 1
                  FROM sys.dm_exec_requests r
                  WHERE r.database_id = DB_ID(t.database_name)
                    AND r.command LIKE N'BACKUP%'
              )) sub;

        IF @backup_dbs IS NOT NULL
        BEGIN
            SET @Msg = N'WARNING: Backup operation active on database(s) [' + @backup_dbs
                     + N']. Rebuild will increase backup duration.';
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        END
    END

    RAISERROR(N'', 10, 1) WITH NOWAIT;

    IF @TargetCount = 0
    BEGIN
        RAISERROR(N'No heaps met thresholds in any database. Nothing to do.', 10, 1) WITH NOWAIT;
        EXEC sp_releaseapplock @Resource = N'sp_HeapDoctor', @LockOwner = N'Session';
        RETURN;
    END

    IF @Debug = 1
    BEGIN
        RAISERROR(N'[DEBUG] Target details:', 10, 1) WITH NOWAIT;
        DECLARE @dbg_tid int, @dbg_db sysname, @dbg_tbl sysname, @dbg_action varchar(32),
                @dbg_pages bigint, @dbg_fwd decimal(6,2), @dbg_cpu bigint, @dbg_basis varchar(20),
                @dbg_score decimal(8,4);
        DECLARE dbg_tgt CURSOR LOCAL FAST_FORWARD FOR
            SELECT target_id, database_name, table_name, action_chosen,
                   page_count, forwarded_pct, total_cpu_ms, ranking_basis, ranking_score
            FROM #Targets ORDER BY sort_order;
        OPEN dbg_tgt;
        FETCH NEXT FROM dbg_tgt INTO @dbg_tid, @dbg_db, @dbg_tbl, @dbg_action,
                                     @dbg_pages, @dbg_fwd, @dbg_cpu, @dbg_basis, @dbg_score;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @Msg = N'[DEBUG]   #' + CAST(@dbg_tid AS nvarchar(10))
                     + N' ' + @dbg_db + N'.' + @dbg_tbl
                     + N' | ' + @dbg_action
                     + N' | pages=' + CAST(@dbg_pages AS nvarchar(20))
                     + N' fwd=' + CAST(@dbg_fwd AS nvarchar(10)) + N'%%'
                     + N' cpu=' + ISNULL(CAST(@dbg_cpu AS nvarchar(20)), N'NULL')
                     + N' basis=' + @dbg_basis
                     + N' score=' + ISNULL(CAST(@dbg_score AS nvarchar(20)), N'NULL');
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            FETCH NEXT FROM dbg_tgt INTO @dbg_tid, @dbg_db, @dbg_tbl, @dbg_action,
                                         @dbg_pages, @dbg_fwd, @dbg_cpu, @dbg_basis, @dbg_score;
        END
        CLOSE dbg_tgt;
        DEALLOCATE dbg_tgt;
    END

    ----------------------------------------------------------------------------
    -- Throughput estimation (history-based)
    ----------------------------------------------------------------------------
    DECLARE @hist_online_pps    float = NULL;
    DECLARE @hist_offline_pps   float = NULL;
    DECLARE @hist_ciswap_pps    float = NULL;
    DECLARE @hist_any_pps       float = NULL;
    DECLARE @hist_source        varchar(20) = 'NONE';
    DECLARE @hist_sample_count  int = 0;

    IF @EstimateTime = 1 AND @commandlog_exists = 1
    BEGIN
        ;WITH HistRates AS
        (
            SELECT
                CommandType,
                AVG(
                    CAST(ExtendedInfo.value('(/ExtendedInfo/PageCount)[1]', 'bigint') AS float)
                    / NULLIF(DATEDIFF(MILLISECOND, StartTime, EndTime) / 1000.0, 0)
                ) AS avg_pps,
                COUNT(*) AS sample_count
            FROM dbo.CommandLog
            WHERE CommandType IN ('HEAP_REBUILD_ONLINE', 'HEAP_REBUILD_OFFLINE', 'CI_SWAP_ONLINE')
              AND ISNULL(ErrorNumber, 0) = 0
              AND EndTime IS NOT NULL
              AND DATEDIFF(MILLISECOND, StartTime, EndTime) > 100
              AND DATEDIFF(DAY, StartTime, SYSDATETIME()) <= @EstimateLookbackDays
              AND ExtendedInfo.value('(/ExtendedInfo/PageCount)[1]', 'bigint') IS NOT NULL
            GROUP BY CommandType
        )
        SELECT
            @hist_online_pps  = MAX(CASE WHEN CommandType = 'HEAP_REBUILD_ONLINE'  THEN avg_pps END),
            @hist_offline_pps = MAX(CASE WHEN CommandType = 'HEAP_REBUILD_OFFLINE' THEN avg_pps END),
            @hist_ciswap_pps  = MAX(CASE WHEN CommandType = 'CI_SWAP_ONLINE'       THEN avg_pps END),
            @hist_any_pps     = SUM(avg_pps * sample_count) / NULLIF(SUM(sample_count), 0),
            @hist_sample_count = SUM(sample_count)
        FROM HistRates;

        IF @hist_any_pps IS NOT NULL
            SET @hist_source = 'HISTORY';
    END

    IF @EstimateTime = 1
    BEGIN
        IF @hist_source = 'NONE'
        BEGIN
            RAISERROR(N'EstimateTime: No historical rebuild data found in CommandLog. Estimates unavailable until first execution with @LogToTable=''Y''.', 10, 1) WITH NOWAIT;
        END
        ELSE
        BEGIN
            SET @Msg = N'EstimateTime: Historical throughput (pages/sec):'
                     + CASE WHEN @hist_online_pps  IS NOT NULL THEN N'  ONLINE='  + CAST(CAST(@hist_online_pps  AS int) AS nvarchar(20)) ELSE N'' END
                     + CASE WHEN @hist_offline_pps IS NOT NULL THEN N'  OFFLINE=' + CAST(CAST(@hist_offline_pps AS int) AS nvarchar(20)) ELSE N'' END
                     + CASE WHEN @hist_ciswap_pps  IS NOT NULL THEN N'  CI_SWAP=' + CAST(CAST(@hist_ciswap_pps  AS int) AS nvarchar(20)) ELSE N'' END
                     + N'  (' + CAST(@hist_sample_count AS nvarchar(10)) + N' sample' + CASE WHEN @hist_sample_count <> 1 THEN N's' ELSE N'' END + N')';
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;

            IF @hist_sample_count < 3
            BEGIN
                RAISERROR(N'EstimateTime: WARNING - estimate based on fewer than 3 samples. Run a few more rebuilds to improve accuracy.', 10, 1) WITH NOWAIT;
            END

            -- Populate estimate columns on #Targets
            UPDATE #Targets
            SET est_pages_per_sec = CASE action_chosen
                    WHEN 'HEAP_REBUILD_ONLINE'  THEN COALESCE(@hist_online_pps,  @hist_any_pps)
                    WHEN 'HEAP_REBUILD_OFFLINE' THEN COALESCE(@hist_offline_pps, @hist_any_pps)
                    WHEN 'CI_SWAP_ONLINE'       THEN COALESCE(@hist_ciswap_pps,  @hist_any_pps)
                    ELSE @hist_any_pps
                END;

            UPDATE #Targets
            SET est_seconds = CEILING(page_count / NULLIF(est_pages_per_sec, 0))
            WHERE est_pages_per_sec IS NOT NULL;

            UPDATE #Targets
            SET est_duration = CASE WHEN est_seconds / 3600 < 10
                                    THEN '0' + CAST(est_seconds / 3600 AS varchar(10))
                                    ELSE CAST(est_seconds / 3600 AS varchar(10))
                               END + ':'
                             + RIGHT('00' + CAST((est_seconds % 3600) / 60 AS varchar(2)), 2) + ':'
                             + RIGHT('00' + CAST(est_seconds % 60 AS varchar(2)), 2)
            WHERE est_seconds IS NOT NULL;

            -- Print total estimate summary
            DECLARE @total_est_sec int;
            SELECT @total_est_sec = SUM(est_seconds) FROM #Targets WHERE est_seconds IS NOT NULL;

            IF @total_est_sec IS NOT NULL
            BEGIN
                SET @Msg = N'EstimateTime: Total estimated remediation: '
                         + CASE WHEN @total_est_sec / 3600 < 10
                                THEN '0' + CAST(@total_est_sec / 3600 AS varchar(10))
                                ELSE CAST(@total_est_sec / 3600 AS varchar(10))
                           END + ':'
                         + RIGHT('00' + CAST((@total_est_sec % 3600) / 60 AS varchar(2)), 2) + ':'
                         + RIGHT('00' + CAST(@total_est_sec % 60 AS varchar(2)), 2)
                         + N' (' + CAST(@total_est_sec AS nvarchar(20)) + N's) based on '
                         + CAST(@EstimateLookbackDays AS nvarchar(10)) + N'-day history';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            END
        END
        RAISERROR(N'', 10, 1) WITH NOWAIT;
    END

    -- Warn about write-heavy heaps (rebuilding is a band-aid for staging/ETL tables)
    IF EXISTS (SELECT 1 FROM #Targets WHERE usage_hint IS NOT NULL)
    BEGIN
        DECLARE @write_cnt int = (SELECT COUNT(*) FROM #Targets WHERE usage_hint IS NOT NULL);
        SET @Msg = N'WARNING: ' + CAST(@write_cnt AS nvarchar(10))
                 + N' target(s) flagged as write-heavy (more updates than reads). '
                 + N'Forwarded records may recur. Consider adding a clustered index.';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        RAISERROR(N'', 10, 1) WITH NOWAIT;
    END

    -- Azure SQL Database DTU/vCore warning
    IF @EngineEdition = 5
    BEGIN
        RAISERROR(N'WARNING: Azure SQL Database detected. Online rebuilds consume significant DTU/vCore resources. Consider running during off-peak hours.', 10, 1) WITH NOWAIT;
        RAISERROR(N'', 10, 1) WITH NOWAIT;
    END

    -- 9L: Trending columns from CommandLog history (skip in resume mode: already in XML)
    IF @resume_loaded = 0 AND @commandlog_exists = 1
    BEGIN
        UPDATE t
        SET
            t.prev_forwarded_pct = hist.prev_fwd_pct,
            t.rebuilds_in_90d = hist.rebuild_count,
            t.days_since_last_rebuild = hist.days_since
        FROM #Targets t
        OUTER APPLY (
            SELECT TOP 1
                CASE WHEN cl.ExtendedInfo IS NOT NULL
                     THEN cl.ExtendedInfo.value('(/ExtendedInfo/ForwardedPct)[1]', 'decimal(6,2)')
                     ELSE NULL END AS prev_fwd_pct,
                NULL AS rebuild_count,  -- placeholder, computed separately
                DATEDIFF(DAY, cl.EndTime, SYSDATETIME()) AS days_since
            FROM dbo.CommandLog cl
            WHERE cl.DatabaseName = t.database_name
              AND cl.ObjectName = t.table_name
              AND cl.SchemaName = t.schema_name
              AND cl.CommandType IN ('HEAP_REBUILD_ONLINE', 'HEAP_REBUILD_OFFLINE', 'CI_SWAP_ONLINE')
              AND cl.ErrorNumber = 0
            ORDER BY cl.EndTime DESC
        ) hist;

        UPDATE t
        SET t.rebuilds_in_90d = cnt.rebuild_count
        FROM #Targets t
        CROSS APPLY (
            SELECT COUNT(*) AS rebuild_count
            FROM dbo.CommandLog cl
            WHERE cl.DatabaseName = t.database_name
              AND cl.ObjectName = t.table_name
              AND cl.SchemaName = t.schema_name
              AND cl.CommandType IN ('HEAP_REBUILD_ONLINE', 'HEAP_REBUILD_OFFLINE', 'CI_SWAP_ONLINE')
              AND cl.ErrorNumber = 0
              AND cl.EndTime >= DATEADD(DAY, -90, SYSDATETIME())
        ) cnt;
    END

    ----------------------------------------------------------------------------
    -- Size and impact projections (skip in resume mode: already in XML)
    ----------------------------------------------------------------------------
    IF @resume_loaded = 0
    BEGIN
        UPDATE #Targets
        SET
            size_mb = CAST(page_count AS decimal(18,2)) / 128.0,
            est_ci_swap_overhead_mb = CASE
                WHEN action_chosen = 'CI_SWAP_ONLINE'
                THEN CAST(page_count AS decimal(18,2)) / 128.0
                ELSE NULL END,
            est_space_savings_mb = CASE
                WHEN avg_page_space_pct IS NOT NULL AND avg_page_space_pct < 75.0
                THEN CAST(page_count AS decimal(18,2)) * (1.0 - avg_page_space_pct / 100.0) / 128.0
                ELSE NULL END;

        -- est_log_mb: per-target log estimate for FULL recovery databases
        UPDATE t
        SET t.est_log_mb = CAST(t.page_count AS decimal(18,2)) * 8192.0 / 1048576.0
        FROM #Targets t
        JOIN sys.databases d ON d.name = t.database_name COLLATE DATABASE_DEFAULT
        WHERE d.recovery_model_desc = N'FULL';
    END

    ----------------------------------------------------------------------------
    -- Obfuscation: build encrypted mapping, then populate pseudo_ columns.
    -- Must build mapping FIRST (needs real names), then populate pseudonyms.
    ----------------------------------------------------------------------------
    DECLARE @obfu_mapping_encrypted varbinary(max) = NULL;

    IF @obfuscate = 1
    BEGIN
        -- 8a: Build encrypted mapping (stored in HEAP_REBUILD_START or HEAP_SCAN_SUMMARY)
        IF @commandlog_exists = 1
        BEGIN
            DECLARE @obfu_mapping_xml nvarchar(max);
            SET @obfu_mapping_xml = CAST((
                SELECT object_type, real_name, pseudonym
                FROM (
                    SELECT DISTINCT
                        N'DB' AS object_type,
                        database_name AS real_name,
                        N'DB_' + LEFT(CONVERT(nvarchar(64), HASHBYTES(N'SHA2_256', @passphrase + database_name), 2), 8) AS pseudonym
                    FROM #Targets
                    UNION ALL
                    SELECT DISTINCT
                        N'Schema',
                        schema_name,
                        N'S_' + LEFT(CONVERT(nvarchar(64), HASHBYTES(N'SHA2_256', @passphrase + schema_name), 2), 8)
                    FROM #Targets
                    UNION ALL
                    SELECT DISTINCT
                        N'Table',
                        table_name,
                        N'T_' + LEFT(CONVERT(nvarchar(64), HASHBYTES(N'SHA2_256', @passphrase + table_name), 2), 8)
                    FROM #Targets
                    UNION ALL
                    SELECT DISTINCT
                        N'Index',
                        key_source_index,
                        N'I_' + LEFT(CONVERT(nvarchar(64), HASHBYTES(N'SHA2_256', @passphrase + key_source_index), 2), 8)
                    FROM #Targets
                    WHERE key_source_index IS NOT NULL
                ) objs
                FOR XML RAW(N'Object'), ROOT(N'ObfuscatedMapping'), ELEMENTS
            ) AS nvarchar(max));

            SET @obfu_mapping_encrypted = ENCRYPTBYPASSPHRASE(
                @passphrase,
                CONVERT(varbinary(max), @obfu_mapping_xml)
            );
        END

        -- 8b: Populate pseudo_ columns using #ObfuMap for atomic real->pseudo transformation
        IF OBJECT_ID('tempdb..#ObfuMap') IS NOT NULL DROP TABLE #ObfuMap;

        CREATE TABLE #ObfuMap
        (
            target_id          int            NOT NULL PRIMARY KEY,
            real_db_quoted     nvarchar(258)  NOT NULL,
            real_schema_quoted nvarchar(258)  NOT NULL,
            real_table_quoted  nvarchar(258)  NOT NULL,
            pseudo_db          sysname        NOT NULL,
            pseudo_schema      sysname        NOT NULL,
            pseudo_table       sysname        NOT NULL,
            real_index         sysname        NULL,
            pseudo_index       sysname        NULL,
            real_table_name    sysname        NOT NULL
        );

        INSERT #ObfuMap
        SELECT
            target_id,
            QUOTENAME(database_name),
            QUOTENAME(schema_name),
            QUOTENAME(table_name),
            N'DB_' + LEFT(CONVERT(nvarchar(64), HASHBYTES(N'SHA2_256', @passphrase + database_name), 2), 8),
            N'S_'  + LEFT(CONVERT(nvarchar(64), HASHBYTES(N'SHA2_256', @passphrase + schema_name), 2), 8),
            N'T_'  + LEFT(CONVERT(nvarchar(64), HASHBYTES(N'SHA2_256', @passphrase + table_name), 2), 8),
            key_source_index,
            CASE WHEN key_source_index IS NOT NULL
                 THEN N'I_' + LEFT(CONVERT(nvarchar(64), HASHBYTES(N'SHA2_256', @passphrase + key_source_index), 2), 8)
                 ELSE NULL END,
            table_name
        FROM #Targets;

        -- Apply pseudonyms to pseudo_ columns + REPLACE real names in command strings
        UPDATE t
        SET
            t.pseudo_database_name = m.pseudo_db,
            t.pseudo_schema_name   = m.pseudo_schema,
            t.pseudo_table_name    = m.pseudo_table,
            t.pseudo_key_index     = m.pseudo_index,
            t.pseudo_command_text  = REPLACE(REPLACE(REPLACE(
                                        REPLACE(t.command_text,
                                            N'CX__Temp__' + LEFT(m.real_table_name, 108),
                                            N'CX__Temp__' + LEFT(m.pseudo_table, 108)),
                                        m.real_db_quoted,     QUOTENAME(m.pseudo_db)),
                                        m.real_schema_quoted, QUOTENAME(m.pseudo_schema)),
                                        m.real_table_quoted,  QUOTENAME(m.pseudo_table)),
            t.pseudo_ci_drop       = CASE WHEN t.ci_drop_command IS NOT NULL
                                     THEN REPLACE(REPLACE(REPLACE(
                                            REPLACE(t.ci_drop_command,
                                                N'CX__Temp__' + LEFT(m.real_table_name, 108),
                                                N'CX__Temp__' + LEFT(m.pseudo_table, 108)),
                                            m.real_db_quoted,     QUOTENAME(m.pseudo_db)),
                                            m.real_schema_quoted, QUOTENAME(m.pseudo_schema)),
                                            m.real_table_quoted,  QUOTENAME(m.pseudo_table))
                                     ELSE NULL END,
            t.pseudo_verify_cmd    = CASE WHEN t.verify_command IS NOT NULL
                                     THEN REPLACE(REPLACE(REPLACE(t.verify_command,
                                            m.real_db_quoted,     QUOTENAME(m.pseudo_db)),
                                            m.real_schema_quoted, QUOTENAME(m.pseudo_schema)),
                                            m.real_table_quoted,  QUOTENAME(m.pseudo_table))
                                     ELSE NULL END
        FROM #Targets t
        JOIN #ObfuMap m ON m.target_id = t.target_id;

        DROP TABLE #ObfuMap;

        -- 8c: Emit obfuscation notice
        DECLARE @obfu_target_count int = (SELECT COUNT(*) FROM #Targets);
        SET @Msg = N'Obfuscation applied to ' + CAST(@obfu_target_count AS nvarchar(10))
                 + N' targets. RunID=' + CAST(@RunID AS nvarchar(36))
                 + N' (provide with @RevealKey to decrypt).';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;

        IF ISNULL(@LogToTable, N'N') <> N'Y'
            RAISERROR(N'NOTE: @ObfuscateKey used with @LogToTable<>Y - encrypted mapping not stored. Set @LogToTable=Y to enable reveal.', 10, 1) WITH NOWAIT;
        ELSE IF @commandlog_exists = 0
            RAISERROR(N'WARNING: @ObfuscateKey used but dbo.CommandLog table not found. Encrypted mapping will not be stored; reveal mode unavailable for this run.', 10, 1) WITH NOWAIT;

        RAISERROR(N'', 10, 1) WITH NOWAIT;
    END

    ----------------------------------------------------------------------------
    -- Output: target list + commands (single result set for INSERT...EXEC compatibility)
    ----------------------------------------------------------------------------
    SELECT
        @Version AS version,
        target_id,
        sort_order,
        CASE WHEN @obfuscate = 1 THEN pseudo_database_name ELSE database_name END AS database_name,
        CASE WHEN @obfuscate = 1 THEN pseudo_schema_name   ELSE schema_name   END AS schema_name,
        CASE WHEN @obfuscate = 1 THEN pseudo_table_name    ELSE table_name    END AS table_name,
        page_count,
        record_count,
        forwarded_record_count,
        forwarded_pct,
        forwarded_fetch_count,
        avg_page_space_pct,
        avg_frag_pct,
        ghost_record_count,
        total_cpu_ms,
        ranking_basis,
        nci_count,
        CASE WHEN @obfuscate = 1 THEN pseudo_key_index     ELSE key_source_index END AS key_source_index,
        action_chosen,
        est_pages_per_sec,
        est_seconds,
        est_duration,
        qs_snapshot_time_utc,
        qs_total_logical_reads,
        qs_total_physical_reads,
        qs_total_duration_ms,
        qs_total_executions,
        qs_plan_count,
        qs_query_count,
        usage_hint,
        ranking_score,
        CASE heap_compression WHEN 1 THEN 'ROW' WHEN 2 THEN 'PAGE' ELSE 'NONE' END AS heap_compression,
        replication_hint,
        CASE lock_escalation WHEN 0 THEN 'TABLE' WHEN 1 THEN 'DISABLE' WHEN 2 THEN 'AUTO' ELSE 'UNKNOWN' END AS lock_escalation,
        CASE WHEN @obfuscate = 1 THEN pseudo_command_text   ELSE command_text   END AS command_text,
        CASE WHEN @obfuscate = 1 THEN pseudo_ci_drop        ELSE ci_drop_command END AS ci_drop_command,
        CASE WHEN @obfuscate = 1 THEN pseudo_verify_cmd     ELSE verify_command  END AS verify_command,
        prev_forwarded_pct,
        rebuilds_in_90d,
        size_mb,
        est_space_savings_mb,
        est_ci_swap_overhead_mb,
        est_log_mb,
        days_since_last_rebuild
    FROM #Targets
    ORDER BY sort_order;

    ----------------------------------------------------------------------------
    -- Plan-only scan logging: persist discovery results to CommandLog
    ----------------------------------------------------------------------------
    IF @PlanOnly = 1 AND @LogToTable = 'Y' AND @commandlog_exists = 1 AND @resume_loaded = 0
    BEGIN
        INSERT INTO dbo.CommandLog
            (DatabaseName, SchemaName, ObjectName, ObjectType, Command, CommandType,
             StartTime, EndTime, ErrorNumber, ErrorMessage, ExtendedInfo)
        VALUES
        (
            ISNULL(@Databases, DB_NAME()),
            N'dbo',
            N'sp_HeapDoctor',
            N'P',
            N'EXECUTE dbo.sp_HeapDoctor @Databases = N''' + REPLACE(ISNULL(@Databases, DB_NAME()), N'''', N'''''') + N''', @PlanOnly = 1...',
            N'HEAP_SCAN_SUMMARY',
            @start_time,
            SYSDATETIME(),
            0,
            NULL,
            (
                SELECT
                    @Version AS Version,
                    @RunID AS RunID,
                    @TargetCount AS TargetCount,
                    @DatabaseCount AS DatabasesScanned,
                    (SELECT SUM(page_count) FROM #Targets) AS TotalPageCount,
                    CAST((SELECT SUM(page_count) FROM #Targets) AS decimal(18,2)) / 128.0 AS TotalSizeMB,
                    @CpuSourceUpper AS CpuSource,
                    DATEDIFF(SECOND, @start_time, SYSDATETIME()) AS ElapsedSeconds,
                    CASE WHEN @obfuscate = 1 THEN @effective_seed ELSE NULL END AS ObfuscateSeed,
                    CASE WHEN @obfuscate = 1 THEN CONVERT(nvarchar(max), @obfu_mapping_encrypted, 2) ELSE NULL END AS ObfuscatedMappingHex,
                    (
                        SELECT
                            CASE WHEN @obfuscate = 1 THEN pseudo_database_name ELSE database_name END AS DatabaseName,
                            CASE WHEN @obfuscate = 1 THEN pseudo_schema_name   ELSE schema_name   END AS SchemaName,
                            CASE WHEN @obfuscate = 1 THEN pseudo_table_name    ELSE table_name    END AS TableName,
                            page_count AS PageCount,
                            size_mb AS SizeMB,
                            record_count AS RecordCount,
                            forwarded_record_count AS ForwardedRecordCount,
                            forwarded_pct AS ForwardedPct,
                            forwarded_fetch_count AS ForwardedFetchCount,
                            avg_page_space_pct AS AvgPageSpacePct,
                            avg_frag_pct AS AvgFragPct,
                            ghost_record_count AS GhostRecordCount,
                            total_cpu_ms AS TotalCpuMs,
                            ranking_score AS RankingScore,
                            ranking_basis AS RankingBasis,
                            action_chosen AS ActionChosen,
                            CASE WHEN @obfuscate = 1 THEN pseudo_command_text ELSE command_text END AS CommandText,
                            CASE WHEN @obfuscate = 1 THEN pseudo_ci_drop      ELSE ci_drop_command END AS CiDropCommand,
                            CASE WHEN @obfuscate = 1 THEN pseudo_verify_cmd   ELSE verify_command END AS VerifyCommand,
                            CASE WHEN @obfuscate = 1 THEN pseudo_key_index    ELSE key_source_index END AS KeySourceIndex,
                            CAST(has_lob_columns AS int) AS HasLobColumns,
                            usage_hint AS UsageHint,
                            nci_count AS NciCount,
                            heap_compression AS HeapCompression,
                            replication_hint AS ReplicationHint,
                            lock_escalation AS LockEscalation,
                            sort_order AS SortOrder,
                            est_pages_per_sec AS EstPagesPerSec,
                            est_seconds AS EstSeconds,
                            est_duration AS EstDuration,
                            est_log_mb AS EstLogMB,
                            est_space_savings_mb AS EstSpaceSavingsMB,
                            est_ci_swap_overhead_mb AS EstCiSwapOverheadMb,
                            days_since_last_rebuild AS DaysSinceLastRebuild,
                            prev_forwarded_pct AS PrevForwardedPct,
                            rebuilds_in_90d AS RebuildsIn90d,
                            CONVERT(nvarchar(30), qs_snapshot_time_utc, 126) AS QsSnapshotTimeUtc,
                            qs_total_logical_reads AS QsTotalLogicalReads,
                            qs_total_physical_reads AS QsTotalPhysicalReads,
                            qs_total_duration_ms AS QsTotalDurationMs,
                            qs_total_executions AS QsTotalExecutions,
                            qs_plan_count AS QsPlanCount,
                            qs_query_count AS QsQueryCount,
                            qs_query_hashes AS QsQueryHashes
                        FROM #Targets
                        ORDER BY sort_order
                        FOR XML RAW(N'Target'), TYPE
                    ) AS Targets
                FOR XML RAW(N'ScanSummary'), ELEMENTS, TYPE
            )
        );
    END

    ----------------------------------------------------------------------------
    -- Execute if requested
    ----------------------------------------------------------------------------
    IF @PlanOnly = 0
    BEGIN
        RAISERROR(N'===============================================================================', 10, 1) WITH NOWAIT;
        RAISERROR(N' Executing Rebuilds', 10, 1) WITH NOWAIT;
        RAISERROR(N'===============================================================================', 10, 1) WITH NOWAIT;
        RAISERROR(N'', 10, 1) WITH NOWAIT;

        DECLARE
            @i              int = 0,
            @cur_sort       int,
            @tid            int,
            @db             sysname,
            @schema         sysname,
            @tbl            sysname,
            @full           nvarchar(512),
            @action         varchar(32),
            @cmd            nvarchar(max),
            @ci_drop        nvarchar(max),
            @exec_cmd       nvarchar(max),
            @start          datetime2(3),
            @end            datetime2(3),
            @RunStart       datetime2(3) = SYSDATETIME(),
            @succeeded_cnt  int = 0,
            @failed_cnt     int = 0,
            @skipped_cnt    int = 0,
            @elapsed_ms     int,
            @elapsed_fmt    nvarchar(20),
            @cur_page_count      bigint,
            @cur_fwd_count       bigint,
            @cur_fwd_pct         decimal(6,2),
            @cur_fwd_fetch_count bigint,
            @cur_page_space_pct  decimal(5,2),
            @cur_frag_pct        decimal(5,2),
            @cur_ghost_count     bigint,
            @cur_cpu_ms          bigint,
            @extended_info       xml,
            @err_number          int,
            @err_message         nvarchar(4000),
            @verify_sql          nvarchar(max),
            @post_fwd_count      bigint,
            @ci_drop_failed      bit,
            @cur_index_name      sysname,
            -- QS performance snapshot (per-target, from #Targets)
            @cur_qs_snapshot_utc    datetime2(3),
            @cur_qs_logical_reads   bigint,
            @cur_qs_physical_reads  bigint,
            @cur_qs_duration_ms     bigint,
            @cur_qs_executions      bigint,
            @cur_qs_plan_count      int,
            @cur_qs_query_count     int,
            @cur_qs_query_hashes    nvarchar(max),
            @cur_usage_hint         varchar(30),
            @cur_ranking_score      decimal(8,4),
            @cur_replication_hint   varchar(20),
            @cur_lock_escalation    tinyint,
            @cur_record_count       bigint,
            @cur_nci_count          int,
            @cur_est_seconds        int,
            @cur_days_since_rebuild int,
            @preflight_sessions     int,
            @preflight_bu_sessions  int,
            @trace_msg              nvarchar(128),
            -- Live calibration for throughput (always tracked; used for estimates when @EstimateTime=1)
            @live_pages_rebuilt   bigint = 0,
            @live_elapsed_ms     bigint = 0,
            @live_pps            float  = NULL,
            -- Per-action-type live calibration
            @live_online_pages   bigint = 0,
            @live_online_ms      bigint = 0,
            @live_offline_pages  bigint = 0,
            @live_offline_ms     bigint = 0,
            @live_ciswap_pages   bigint = 0,
            @live_ciswap_ms      bigint = 0,
            @remaining_pages     bigint,
            @remaining_est_sec   int,
            @rebuild_elapsed_ms  bigint,
            -- Obfuscation: pseudo values for CommandLog/ExecLog (real values stay for RAISERROR/execution)
            @pseudo_db              sysname,
            @pseudo_schema          sysname,
            @pseudo_tbl             sysname,
            @pseudo_cmd             nvarchar(max),
            @pseudo_ci_drop         nvarchar(max),
            @pseudo_cur_index_name  sysname;

        /*
        Build LOCK_TIMEOUT prefix/suffix to prepend/append to each command.
        Ensures the timeout applies within the same sp_executesql scope as the
        rebuild, and restores the original session value afterward.
        */
        DECLARE @LockPrefix nvarchar(200) = N'';
        DECLARE @LockSuffix nvarchar(200) = N'';

        IF @LockTimeoutMs IS NOT NULL
        BEGIN
            SET @LockPrefix = N'SET LOCK_TIMEOUT ' + CONVERT(nvarchar(20), @LockTimeoutMs) + N'; ';
            SET @LockSuffix = N' SET LOCK_TIMEOUT ' + CONVERT(nvarchar(20), @OriginalLockTimeout) + N';';

            SET @Msg = N'Lock timeout: ' + CAST(@LockTimeoutMs AS nvarchar(20)) + N' ms per rebuild.';
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        END

        /*
        Log run START to CommandLog
        */
        IF @commandlog_exists = 1
        BEGIN
            INSERT INTO dbo.CommandLog
                (DatabaseName, SchemaName, ObjectName, ObjectType, Command, CommandType, StartTime, ExtendedInfo)
            VALUES
            (
                ISNULL(@Databases, DB_NAME()),
                N'dbo',
                N'sp_HeapDoctor',
                N'P',
                N'EXECUTE dbo.sp_HeapDoctor @Databases = N''' + REPLACE(ISNULL(@Databases, DB_NAME()), N'''', N'''''') + N'''...',
                N'HEAP_REBUILD_START',
                @start_time,
                (
                    SELECT
                        @Version AS Version,
                        @TargetCount AS TargetCount,
                        @CpuSourceUpper AS CpuSource,
                        CASE WHEN @Online = 1 THEN N'ON' ELSE N'OFF' END AS OnlineMode,
                        @LookbackDays AS LookbackDays,
                        @TopN AS TopN,
                        @MinPages AS MinPages,
                        @MaxPages AS MaxPages,
                        @MinForwardedPct AS MinForwardedPct,
                        @Maxdop AS Maxdop,
                        @LockTimeoutMs AS LockTimeoutMs,
                        @MaxRunSeconds AS MaxRunSeconds,
                        @Tables AS Tables,
                        CASE WHEN @AllowCiSwap = 1 THEN N'Y' ELSE N'N' END AS AllowCiSwap,
                        CASE WHEN @PreferCiSwap = 1 THEN N'Y' ELSE N'N' END AS PreferCiSwap,
                        CASE WHEN @EstimateTime = 1 THEN N'Y' ELSE N'N' END AS EstimateTime,
                        @RunID AS RunID,
                        CASE WHEN @resume_loaded = 1 THEN @ResumeRunID ELSE NULL END AS ResumedFromRunID,
                        CASE WHEN @obfuscate = 1 THEN @effective_seed ELSE NULL END AS ObfuscateSeed,
                        CASE WHEN @obfuscate = 1 THEN CONVERT(nvarchar(max), @obfu_mapping_encrypted, 2) ELSE NULL END AS ObfuscatedMappingHex
                    FOR XML RAW(N'Parameters'), ELEMENTS
                )
            );
        END

        /*
        WHILE loop - iterate by sort_order.
        Commands already use 3-part names (db.schema.table) so no USE statement needed.
        */
        WHILE 1 = 1
        BEGIN
            -- Get next target
            SELECT TOP (1)
                @cur_sort       = sort_order,
                @tid            = target_id,
                @db             = database_name,
                @schema         = schema_name,
                @tbl            = table_name,
                @full           = QUOTENAME(database_name) + N'.' + QUOTENAME(schema_name) + N'.' + QUOTENAME(table_name),
                @action         = action_chosen,
                @cmd            = command_text,
                @ci_drop        = ci_drop_command,
                @cur_page_count    = page_count,
                @cur_fwd_count     = forwarded_record_count,
                @cur_fwd_pct       = forwarded_pct,
                @cur_fwd_fetch_count = forwarded_fetch_count,
                @cur_page_space_pct = avg_page_space_pct,
                @cur_frag_pct      = avg_frag_pct,
                @cur_ghost_count   = ghost_record_count,
                @cur_cpu_ms        = total_cpu_ms,
                @cur_qs_snapshot_utc   = qs_snapshot_time_utc,
                @cur_qs_logical_reads  = qs_total_logical_reads,
                @cur_qs_physical_reads = qs_total_physical_reads,
                @cur_qs_duration_ms    = qs_total_duration_ms,
                @cur_qs_executions     = qs_total_executions,
                @cur_qs_plan_count     = qs_plan_count,
                @cur_qs_query_count    = qs_query_count,
                @cur_qs_query_hashes   = qs_query_hashes,
                @cur_usage_hint        = usage_hint,
                @cur_ranking_score     = ranking_score,
                @cur_replication_hint  = replication_hint,
                @cur_lock_escalation   = lock_escalation,
                @cur_record_count      = record_count,
                @cur_nci_count         = nci_count,
                @cur_est_seconds       = est_seconds,
                @cur_days_since_rebuild = days_since_last_rebuild,
                -- Obfuscation: pseudo values (NULL when not obfuscating)
                @pseudo_db             = pseudo_database_name,
                @pseudo_schema         = pseudo_schema_name,
                @pseudo_tbl            = pseudo_table_name,
                @pseudo_cmd            = pseudo_command_text,
                @pseudo_ci_drop        = pseudo_ci_drop
            FROM #Targets
            WHERE sort_order > @i
            ORDER BY sort_order;

            IF @@ROWCOUNT = 0 BREAK;

            SET @i = @cur_sort;

            SET @cur_index_name = CASE WHEN @action = 'CI_SWAP_ONLINE'
                                       THEN N'CX__Temp__' + LEFT(@tbl, 108)
                                       ELSE NULL END;
            SET @pseudo_cur_index_name = CASE WHEN @action = 'CI_SWAP_ONLINE' AND @obfuscate = 1
                                              THEN N'CX__Temp__' + LEFT(@pseudo_tbl, 108)
                                              ELSE @cur_index_name END;

            /*
            TOCTOU check: verify object still exists before rebuild.
            Table may have been dropped between discovery and execution.
            */
            IF OBJECT_ID(@full) IS NULL
            BEGIN
                SET @Msg = N'  SKIPPED: ' + @full + N' no longer exists.';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                SET @skipped_cnt += 1;
                INSERT #ExecLog(target_id, database_name, full_name, action, start_time, end_time, succeeded, error_message)
                VALUES (@tid,
                    CASE WHEN @obfuscate = 1 THEN @pseudo_db ELSE @db END,
                    CASE WHEN @obfuscate = 1
                         THEN QUOTENAME(@pseudo_db) + N'.' + QUOTENAME(@pseudo_schema) + N'.' + QUOTENAME(@pseudo_tbl)
                         ELSE @full END,
                    @action, SYSDATETIME(), SYSDATETIME(), NULL, N'SKIPPED: Object no longer exists.');
                CONTINUE;
            END

            /*
            Time limit check
            */
            IF @MaxRunSeconds IS NOT NULL
               AND DATEDIFF(SECOND, @RunStart, SYSDATETIME()) >= @MaxRunSeconds
            BEGIN
                RAISERROR(N'', 10, 1) WITH NOWAIT;
                SET @Msg = N'Time limit (' + CAST(@MaxRunSeconds AS nvarchar(10)) + N' seconds) reached. Stopping gracefully.';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;

                -- Log all remaining targets as SKIPPED (both in-memory and CommandLog)
                INSERT #ExecLog(target_id, database_name, full_name, action, start_time, end_time, succeeded, error_message)
                SELECT
                    target_id,
                    CASE WHEN @obfuscate = 1 THEN pseudo_database_name ELSE database_name END,
                    CASE WHEN @obfuscate = 1
                         THEN QUOTENAME(pseudo_database_name) + N'.' + QUOTENAME(pseudo_schema_name) + N'.' + QUOTENAME(pseudo_table_name)
                         ELSE QUOTENAME(database_name) + N'.' + QUOTENAME(schema_name) + N'.' + QUOTENAME(table_name) END,
                    action_chosen,
                    SYSDATETIME(),
                    SYSDATETIME(),
                    NULL,
                    N'SKIPPED: @MaxRunSeconds reached.'
                FROM #Targets
                WHERE sort_order >= @cur_sort;

                SET @skipped_cnt += (SELECT COUNT(*) FROM #Targets WHERE sort_order >= @cur_sort);

                -- Persist SKIPPED entries to CommandLog
                IF @commandlog_exists = 1
                BEGIN
                    INSERT INTO dbo.CommandLog
                        (DatabaseName, SchemaName, ObjectName, ObjectType, IndexName, IndexType,
                         Command, CommandType,
                         StartTime, EndTime, ErrorNumber, ErrorMessage, ExtendedInfo)
                    SELECT
                        CASE WHEN @obfuscate = 1 THEN pseudo_database_name ELSE database_name END,
                        CASE WHEN @obfuscate = 1 THEN pseudo_schema_name   ELSE schema_name   END,
                        CASE WHEN @obfuscate = 1 THEN pseudo_table_name    ELSE table_name    END,
                        N'U',
                        CASE WHEN action_chosen = 'CI_SWAP_ONLINE'
                             THEN N'CX__Temp__' + LEFT(CASE WHEN @obfuscate = 1 THEN pseudo_table_name ELSE table_name END, 108)
                             ELSE NULL END,
                        0,
                        CASE WHEN @obfuscate = 1 THEN pseudo_command_text ELSE command_text END,
                        action_chosen,
                        SYSDATETIME(),
                        SYSDATETIME(),
                        NULL,
                        N'SKIPPED: @MaxRunSeconds reached.',
                        (
                            SELECT
                                @Version AS Version,
                                page_count AS PageCount,
                                CAST(page_count AS decimal(18,2)) / 128.0 AS SizeMB,
                                forwarded_record_count AS ForwardedRecords,
                                forwarded_pct AS ForwardedPct,
                                forwarded_fetch_count AS ForwardedFetchCount,
                                avg_page_space_pct AS AvgPageSpacePct,
                                avg_frag_pct AS AvgFragPct,
                                ghost_record_count AS GhostRecordCount,
                                total_cpu_ms AS TotalCpuMs,
                                qs_snapshot_time_utc AS QsSnapshotTimeUtc,
                                qs_total_logical_reads AS QsTotalLogicalReads,
                                qs_total_physical_reads AS QsTotalPhysicalReads,
                                qs_total_duration_ms AS QsTotalDurationMs,
                                qs_total_executions AS QsTotalExecutions,
                                qs_plan_count AS QsPlanCount,
                                qs_query_count AS QsQueryCount,
                                qs_query_hashes AS QsQueryHashes,
                                usage_hint AS UsageHint,
                                ranking_score AS RankingScore,
                                replication_hint AS ReplicationHint,
                                lock_escalation AS LockEscalation,
                                record_count AS RecordCount,
                                nci_count AS NciCount,
                                est_seconds AS EstSeconds,
                                days_since_last_rebuild AS DaysSinceLastRebuild,
                                @RunID AS RunID
                            FOR XML RAW(N'ExtendedInfo'), ELEMENTS
                        )
                    FROM #Targets
                    WHERE sort_order >= @cur_sort;
                END

                BREAK;
            END

            /*
            Progress message
            */
            SET @Msg = N'[' + CAST(@succeeded_cnt + @failed_cnt + 1 AS nvarchar(10)) + N'/' + CAST(@TargetCount AS nvarchar(10)) + N'] '
                     + @action + N' on ' + @full;

            -- Append per-target estimate if available
            IF @EstimateTime = 1
            BEGIN
                SET @remaining_est_sec = NULL;
                SELECT @remaining_est_sec = est_seconds FROM #Targets WHERE target_id = @tid;

                IF @remaining_est_sec IS NOT NULL
                    SET @Msg = @Msg + N'  (est: ' + CAST(@remaining_est_sec AS nvarchar(10)) + N's)';
            END

            RAISERROR(@Msg, 10, 1) WITH NOWAIT;

            -- XE observability: raise user event with key metrics
            BEGIN TRY
                SET @trace_msg = LEFT(
                    N'sp_HeapDoctor: [' + CAST(@succeeded_cnt + @failed_cnt + 1 AS nvarchar(10))
                    + N'/' + CAST(@TargetCount AS nvarchar(10)) + N'] '
                    + @action + N' ' + @full
                    + N' ' + CAST(@cur_page_count AS nvarchar(10)) + N'p'
                    + N' ' + CAST(@cur_fwd_pct AS nvarchar(10)) + N'%fwd'
                    + ISNULL(N' fc=' + CAST(@cur_fwd_fetch_count AS nvarchar(15)), N'')
                    + ISNULL(N' cpu=' + CAST(@cur_cpu_ms AS nvarchar(15)), N''), 128);
                EXEC sp_trace_generateevent @event_class = 82, @userinfo = @trace_msg;
            END TRY
            BEGIN CATCH
                -- ALTER TRACE permission may not be available; silently continue
            END CATCH

            SET @start = SYSDATETIME();
            INSERT #ExecLog(target_id, database_name, full_name, action, start_time)
            VALUES (@tid,
                CASE WHEN @obfuscate = 1 THEN @pseudo_db ELSE @db END,
                CASE WHEN @obfuscate = 1
                     THEN QUOTENAME(@pseudo_db) + N'.' + QUOTENAME(@pseudo_schema) + N'.' + QUOTENAME(@pseudo_tbl)
                     ELSE @full END,
                @action, @start);

            /*
            Pre-flight: check for active sessions with locks on the target table.
            Sch-M acquisition will block (and be blocked by) these sessions.
            Warn before wasting a lock timeout cycle.
            */
            SET @preflight_sessions = 0;
            BEGIN TRY
                SET @verify_sql = N'SELECT @cnt = COUNT(DISTINCT request_session_id)
                    FROM sys.dm_tran_locks
                    WHERE resource_database_id = DB_ID(@db_param)
                      AND resource_type = N''OBJECT''
                      AND resource_associated_entity_id = OBJECT_ID(@full_param)
                      AND request_session_id <> @@SPID
                      AND request_status = N''GRANT'';';
                EXEC sys.sp_executesql @verify_sql,
                    N'@db_param sysname, @full_param nvarchar(512), @cnt int OUTPUT',
                    @db_param = @db, @full_param = @full, @cnt = @preflight_sessions OUTPUT;
            END TRY
            BEGIN CATCH
                SET @preflight_sessions = 0; -- don't block on pre-flight errors
            END CATCH

            IF ISNULL(@preflight_sessions, 0) > 0
            BEGIN
                SET @Msg = N'  NOTE: ' + CAST(@preflight_sessions AS nvarchar(10))
                         + N' active session(s) hold locks on ' + @full
                         + N'. Sch-M acquisition may block or be blocked.';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            END

            -- Bulk update (BU) lock detection
            SET @preflight_bu_sessions = 0;
            BEGIN TRY
                SET @verify_sql = N'SELECT @cnt = COUNT(DISTINCT request_session_id)
                    FROM sys.dm_tran_locks
                    WHERE resource_database_id = DB_ID(@db_param)
                      AND resource_type = N''OBJECT''
                      AND resource_associated_entity_id = OBJECT_ID(@full_param)
                      AND request_session_id <> @@SPID
                      AND request_mode = N''BU''
                      AND request_status = N''GRANT'';';
                EXEC sys.sp_executesql @verify_sql,
                    N'@db_param sysname, @full_param nvarchar(512), @cnt int OUTPUT',
                    @db_param = @db, @full_param = @full, @cnt = @preflight_bu_sessions OUTPUT;
            END TRY
            BEGIN CATCH
                SET @preflight_bu_sessions = 0;
            END CATCH

            IF ISNULL(@preflight_bu_sessions, 0) > 0
            BEGIN
                SET @Msg = N'  WARNING: Active bulk insert detected on ' + @full
                         + N'. Rebuild will block until bulk operation completes.';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            END

            -- Lock escalation warning for online rebuilds
            IF @cur_lock_escalation = 0 AND @action IN ('HEAP_REBUILD_ONLINE', 'CI_SWAP_ONLINE')
            BEGIN
                SET @Msg = N'  NOTE: lock_escalation=TABLE on ' + @full
                         + N'. Online rebuild may escalate to table lock.';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            END

            -- Replication warning during execution
            IF @cur_replication_hint IS NOT NULL
            BEGIN
                SET @Msg = N'  NOTE: ' + @full + N' is ' + @cur_replication_hint
                         + N'. Rebuild generates replication log traffic.';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;

                -- CDC + CI swap specific warning
                IF @cur_replication_hint LIKE '%CDC%' AND @action = 'CI_SWAP_ONLINE'
                BEGIN
                    SET @Msg = N'  WARNING: CDC-tracked table with CI swap. DDL may require capture instance recreation.';
                    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                END
            END

            /*
            Execute the main command (with lock timeout prefix/suffix)
            */
            SET @exec_cmd = @LockPrefix + @cmd + @LockSuffix;

            BEGIN TRY
                EXEC sys.sp_executesql @exec_cmd;

                SET @end = SYSDATETIME();
                SET @elapsed_ms = DATEDIFF(MILLISECOND, @start, @end);
                SET @elapsed_fmt = CASE WHEN @elapsed_ms < 1000
                    THEN CAST(CAST(@elapsed_ms AS decimal(5,1)) / 1000 AS nvarchar(10)) + N's'
                    ELSE CAST(@elapsed_ms / 1000 AS nvarchar(10)) + N's'
                END;

                UPDATE #ExecLog
                  SET end_time = @end, succeeded = 1
                WHERE target_id = @tid;

                SET @Msg = N'  OK (' + @elapsed_fmt + N')';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;

                /*
                CI swap step 2: DROP the temp clustered index to return to heap.
                If DROP fails, the table is left as a clustered table (not a heap).
                We log success for the forwarded-record fix (the CREATE did the work)
                but warn loudly so the DBA can manually drop the temp CI.
                */
                SET @ci_drop_failed = 0;
                IF @ci_drop IS NOT NULL
                BEGIN
                    SET @Msg = N'  Dropping temp clustered index on ' + @full + N'...';
                    RAISERROR(@Msg, 10, 1) WITH NOWAIT;

                    BEGIN TRY
                        SET @exec_cmd = @LockPrefix + @ci_drop + @LockSuffix;
                        EXEC sys.sp_executesql @exec_cmd;

                        SET @Msg = N'  DROP OK';
                        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                    END TRY
                    BEGIN CATCH
                        SET @ci_drop_failed = 1;

                        SET @Msg = N'  WARNING: CI swap CREATE succeeded but DROP FAILED on ' + @full
                                 + N'. Error ' + CAST(ERROR_NUMBER() AS nvarchar(10))
                                 + N': ' + LEFT(ERROR_MESSAGE(), 1000)
                                 + N'. The table is now a clustered table, NOT a heap.'
                                 + N' Forwarded records are eliminated, but you must manually drop the temp index.';
                        RAISERROR(@Msg, 16, 1) WITH NOWAIT;

                        -- Restore lock timeout (prefix ran but suffix did not due to error)
                        IF @LockTimeoutMs IS NOT NULL
                            EXEC sys.sp_executesql @LockSuffix;
                    END CATCH
                END

                SET @succeeded_cnt += 1;

                /*
                Post-rebuild verification: confirm forwarded records are gone.
                Uses SAMPLED mode for speed. This is a spot-check, not a guarantee.
                Skipped when CI swap DROP failed (table is now clustered, index_id = 1 not 0).
                */
                SET @post_fwd_count = NULL;
                IF @ci_drop_failed = 1
                BEGIN
                    -- CI DROP failed; table is now clustered (index_id=1), not heap.
                    -- Forwarded records are eliminated by the CREATE, but we can't verify via index_id=0.
                    SET @Msg = N'  Skipping post-rebuild verification (table is now clustered due to DROP failure).';
                    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                    SET @post_fwd_count = 0; -- forwarded records ARE gone (CREATE eliminated them)
                END
                ELSE
                BEGIN
                    BEGIN TRY
                        SET @verify_sql = N'SELECT @fwd_out = forwarded_record_count
                            FROM sys.dm_db_index_physical_stats(DB_ID(@db_param), OBJECT_ID(@full_param), 0, NULL, ''SAMPLED'')
                            WHERE index_id = 0;';
                        EXEC sys.sp_executesql @verify_sql,
                            N'@db_param sysname, @full_param nvarchar(512), @fwd_out bigint OUTPUT',
                            @db_param = @db, @full_param = @full, @fwd_out = @post_fwd_count OUTPUT;
                    END TRY
                    BEGIN CATCH
                        SET @post_fwd_count = NULL; -- verification failed, don't block
                    END CATCH

                    IF @post_fwd_count IS NOT NULL AND @post_fwd_count > 0
                    BEGIN
                        SET @Msg = N'  WARNING: Post-rebuild check found ' + CAST(@post_fwd_count AS nvarchar(20))
                                 + N' forwarded records still present on ' + @full + N'.';
                        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                    END
                    ELSE IF @post_fwd_count = 0
                    BEGIN
                        SET @Msg = N'  Verified: 0 forwarded records.';
                        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                    END
                END

                -- 8J: Statistics invalidation warning
                SET @Msg = N'  Note: Statistics on ' + @full + N' are now stale. Auto-update will trigger on next query.';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;

                -- XE observability: rebuild succeeded with key metrics
                BEGIN TRY
                    SET @trace_msg = LEFT(N'sp_HeapDoctor: OK ' + @full
                        + N' ' + @elapsed_fmt
                        + N' ' + CAST(@cur_page_count AS nvarchar(10)) + N'p'
                        + ISNULL(N' fc=' + CAST(@cur_fwd_fetch_count AS nvarchar(15)), N'')
                        + N' post=' + ISNULL(CAST(@post_fwd_count AS nvarchar(10)), N'?'), 128);
                    EXEC sp_trace_generateevent @event_class = 82, @userinfo = @trace_msg;
                END TRY
                BEGIN CATCH END CATCH

                /*
                Live calibration: accumulate throughput data from this rebuild.
                Always tracked (not gated on @EstimateTime) so Summary always has throughput.
                Only counts rebuilds that took > 100ms for rate calc (sub-100ms too noisy).
                */
                SET @rebuild_elapsed_ms = @elapsed_ms; -- reuse from line above (same @start/@end)

                -- Always count pages rebuilt (not gated on timing threshold)
                SET @live_pages_rebuilt += @cur_page_count;

                IF @rebuild_elapsed_ms > 100
                BEGIN
                    -- Accumulate timing for rate calculation (sub-100ms too noisy for meaningful rate)
                    SET @live_elapsed_ms   += @rebuild_elapsed_ms;

                    -- Per-action-type rates for more accurate estimates
                    IF @action = N'HEAP_REBUILD_ONLINE'
                    BEGIN
                        SET @live_online_pages += @cur_page_count;
                        SET @live_online_ms    += @rebuild_elapsed_ms;
                    END
                    ELSE IF @action = N'HEAP_REBUILD_OFFLINE'
                    BEGIN
                        SET @live_offline_pages += @cur_page_count;
                        SET @live_offline_ms    += @rebuild_elapsed_ms;
                    END
                    ELSE IF @action = N'CI_SWAP_ONLINE'
                    BEGIN
                        SET @live_ciswap_pages += @cur_page_count;
                        SET @live_ciswap_ms    += @rebuild_elapsed_ms;
                    END

                    -- Combined rate uses only timed pages (not @live_pages_rebuilt which includes sub-500ms)
                    SET @live_pps = CAST((@live_online_pages + @live_offline_pages + @live_ciswap_pages) AS float)
                                  / NULLIF(@live_elapsed_ms / 1000.0, 0);

                    -- Update remaining target estimates with per-action-type live rates
                    IF @EstimateTime = 1
                    BEGIN
                        UPDATE #Targets
                        SET est_pages_per_sec = CASE action_chosen
                                WHEN N'HEAP_REBUILD_ONLINE'  THEN COALESCE(
                                    CASE WHEN @live_online_ms > 0 THEN CAST(@live_online_pages AS float) / (@live_online_ms / 1000.0) END,
                                    @live_pps)
                                WHEN N'HEAP_REBUILD_OFFLINE' THEN COALESCE(
                                    CASE WHEN @live_offline_ms > 0 THEN CAST(@live_offline_pages AS float) / (@live_offline_ms / 1000.0) END,
                                    @live_pps)
                                WHEN N'CI_SWAP_ONLINE'       THEN COALESCE(
                                    CASE WHEN @live_ciswap_ms > 0 THEN CAST(@live_ciswap_pages AS float) / (@live_ciswap_ms / 1000.0) END,
                                    @live_pps)
                                ELSE @live_pps
                            END,
                            est_seconds = CEILING(page_count / NULLIF(
                                CASE action_chosen
                                    WHEN N'HEAP_REBUILD_ONLINE'  THEN COALESCE(
                                        CASE WHEN @live_online_ms > 0 THEN CAST(@live_online_pages AS float) / (@live_online_ms / 1000.0) END,
                                        @live_pps)
                                    WHEN N'HEAP_REBUILD_OFFLINE' THEN COALESCE(
                                        CASE WHEN @live_offline_ms > 0 THEN CAST(@live_offline_pages AS float) / (@live_offline_ms / 1000.0) END,
                                        @live_pps)
                                    WHEN N'CI_SWAP_ONLINE'       THEN COALESCE(
                                        CASE WHEN @live_ciswap_ms > 0 THEN CAST(@live_ciswap_pages AS float) / (@live_ciswap_ms / 1000.0) END,
                                        @live_pps)
                                    ELSE @live_pps
                                END, 0))
                        WHERE sort_order > @i;

                        UPDATE #Targets
                        SET est_duration = CASE WHEN est_seconds / 3600 < 10
                                                THEN '0' + CAST(est_seconds / 3600 AS varchar(10))
                                                ELSE CAST(est_seconds / 3600 AS varchar(10))
                                           END + ':'
                                         + RIGHT('00' + CAST((est_seconds % 3600) / 60 AS varchar(2)), 2) + ':'
                                         + RIGHT('00' + CAST(est_seconds % 60 AS varchar(2)), 2)
                        WHERE sort_order > @i AND est_seconds IS NOT NULL;

                        -- Compute and display remaining time estimate using per-target estimates
                        SELECT @remaining_est_sec = SUM(est_seconds) FROM #Targets WHERE sort_order > @i AND est_seconds IS NOT NULL;

                        IF @remaining_est_sec IS NOT NULL AND @remaining_est_sec > 0
                        BEGIN

                            SET @Msg = N'  Live rate: ' + CAST(CAST(@live_pps AS int) AS nvarchar(20)) + N' pages/sec'
                                     + N'  |  Remaining: ~'
                                     + CASE WHEN @remaining_est_sec / 3600 < 10
                                            THEN '0' + CAST(@remaining_est_sec / 3600 AS varchar(10))
                                            ELSE CAST(@remaining_est_sec / 3600 AS varchar(10))
                                       END + ':'
                                     + RIGHT('00' + CAST((@remaining_est_sec % 3600) / 60 AS varchar(2)), 2) + ':'
                                     + RIGHT('00' + CAST(@remaining_est_sec % 60 AS varchar(2)), 2);
                            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                        END
                    END
                END

                /*
                Log success to CommandLog
                */
                IF @commandlog_exists = 1
                BEGIN
                    SET @extended_info = (
                        SELECT
                            @Version AS Version,
                            @cur_page_count AS PageCount,
                            CAST(@cur_page_count AS decimal(18,2)) / 128.0 AS SizeMB,
                            @cur_fwd_count AS ForwardedRecords,
                            @cur_fwd_pct AS ForwardedPct,
                            @cur_fwd_fetch_count AS ForwardedFetchCount,
                            @cur_page_space_pct AS AvgPageSpacePct,
                            @cur_frag_pct AS AvgFragPct,
                            @cur_ghost_count AS GhostRecordCount,
                            @cur_cpu_ms AS TotalCpuMs,
                            @post_fwd_count AS PostRebuildForwardedRecords,
                            @elapsed_ms AS DurationMs,
                            CASE WHEN @elapsed_ms > 100
                                 THEN CAST(CAST(@cur_page_count AS float) / (@elapsed_ms / 1000.0) AS int)
                            END AS ActualPagesPerSec,
                            @cur_qs_snapshot_utc AS QsSnapshotTimeUtc,
                            @cur_qs_logical_reads AS QsTotalLogicalReads,
                            @cur_qs_physical_reads AS QsTotalPhysicalReads,
                            @cur_qs_duration_ms AS QsTotalDurationMs,
                            @cur_qs_executions AS QsTotalExecutions,
                            @cur_qs_plan_count AS QsPlanCount,
                            @cur_qs_query_count AS QsQueryCount,
                            @cur_qs_query_hashes AS QsQueryHashes,
                            @cur_usage_hint AS UsageHint,
                            @cur_ranking_score AS RankingScore,
                            @cur_replication_hint AS ReplicationHint,
                            @cur_lock_escalation AS LockEscalation,
                            @cur_record_count AS RecordCount,
                            @cur_nci_count AS NciCount,
                            @cur_est_seconds AS EstSeconds,
                            @cur_days_since_rebuild AS DaysSinceLastRebuild,
                            @RunID AS RunID
                        FOR XML RAW(N'ExtendedInfo'), ELEMENTS
                    );

                    INSERT INTO dbo.CommandLog
                        (DatabaseName, SchemaName, ObjectName, ObjectType, IndexName, IndexType,
                         Command, CommandType,
                         StartTime, EndTime, ErrorNumber, ErrorMessage, ExtendedInfo)
                    VALUES
                        (CASE WHEN @obfuscate = 1 THEN @pseudo_db     ELSE @db     END,
                         CASE WHEN @obfuscate = 1 THEN @pseudo_schema ELSE @schema END,
                         CASE WHEN @obfuscate = 1 THEN @pseudo_tbl    ELSE @tbl    END,
                         N'U',
                         CASE WHEN @obfuscate = 1 THEN @pseudo_cur_index_name ELSE @cur_index_name END,
                         0,
                         CASE WHEN @obfuscate = 1 THEN @pseudo_cmd ELSE @cmd END, @action,
                         @start, @end, 0, NULL, @extended_info);
                END
            END TRY
            BEGIN CATCH
                SET @end = SYSDATETIME();
                SET @elapsed_ms = DATEDIFF(MILLISECOND, @start, @end);
                SET @elapsed_fmt = CASE WHEN @elapsed_ms < 1000
                    THEN CAST(CAST(@elapsed_ms AS decimal(5,1)) / 1000 AS nvarchar(10)) + N's'
                    ELSE CAST(@elapsed_ms / 1000 AS nvarchar(10)) + N's'
                END;

                SET @err_number = ERROR_NUMBER();
                SET @err_message = ERROR_MESSAGE();

                -- Restore lock timeout (prefix ran but suffix did not due to error)
                IF @LockTimeoutMs IS NOT NULL
                    EXEC sys.sp_executesql @LockSuffix;

                UPDATE #ExecLog
                  SET end_time = @end,
                      succeeded = 0,
                      error_number = @err_number,
                      error_message = @err_message
                WHERE target_id = @tid;

                SET @Msg = N'  FAILED (' + @elapsed_fmt + N'): '
                         + N'Error ' + CAST(@err_number AS nvarchar(10)) + N' - '
                         + LEFT(@err_message, 300);
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;

                -- XE observability: rebuild failed
                BEGIN TRY
                    SET @trace_msg = LEFT(N'sp_HeapDoctor: FAILED ' + @full + N' E' + CAST(@err_number AS nvarchar(10)), 128);
                    EXEC sp_trace_generateevent @event_class = 82, @userinfo = @trace_msg;
                END TRY
                BEGIN CATCH END CATCH

                SET @failed_cnt += 1;

                /*
                Log failure to CommandLog
                */
                IF @commandlog_exists = 1
                BEGIN
                    SET @extended_info = (
                        SELECT
                            @Version AS Version,
                            @cur_page_count AS PageCount,
                            CAST(@cur_page_count AS decimal(18,2)) / 128.0 AS SizeMB,
                            @cur_fwd_count AS ForwardedRecords,
                            @cur_fwd_pct AS ForwardedPct,
                            @cur_fwd_fetch_count AS ForwardedFetchCount,
                            @cur_page_space_pct AS AvgPageSpacePct,
                            @cur_frag_pct AS AvgFragPct,
                            @cur_ghost_count AS GhostRecordCount,
                            @cur_cpu_ms AS TotalCpuMs,
                            @elapsed_ms AS DurationMs,
                            @cur_qs_snapshot_utc AS QsSnapshotTimeUtc,
                            @cur_qs_logical_reads AS QsTotalLogicalReads,
                            @cur_qs_physical_reads AS QsTotalPhysicalReads,
                            @cur_qs_duration_ms AS QsTotalDurationMs,
                            @cur_qs_executions AS QsTotalExecutions,
                            @cur_qs_plan_count AS QsPlanCount,
                            @cur_qs_query_count AS QsQueryCount,
                            @cur_qs_query_hashes AS QsQueryHashes,
                            @cur_usage_hint AS UsageHint,
                            @cur_ranking_score AS RankingScore,
                            @cur_replication_hint AS ReplicationHint,
                            @cur_lock_escalation AS LockEscalation,
                            @cur_record_count AS RecordCount,
                            @cur_nci_count AS NciCount,
                            @cur_est_seconds AS EstSeconds,
                            @cur_days_since_rebuild AS DaysSinceLastRebuild,
                            @RunID AS RunID
                        FOR XML RAW(N'ExtendedInfo'), ELEMENTS
                    );

                    INSERT INTO dbo.CommandLog
                        (DatabaseName, SchemaName, ObjectName, ObjectType, IndexName, IndexType,
                         Command, CommandType,
                         StartTime, EndTime, ErrorNumber, ErrorMessage, ExtendedInfo)
                    VALUES
                        (CASE WHEN @obfuscate = 1 THEN @pseudo_db     ELSE @db     END,
                         CASE WHEN @obfuscate = 1 THEN @pseudo_schema ELSE @schema END,
                         CASE WHEN @obfuscate = 1 THEN @pseudo_tbl    ELSE @tbl    END,
                         N'U',
                         CASE WHEN @obfuscate = 1 THEN @pseudo_cur_index_name ELSE @cur_index_name END,
                         0,
                         CASE WHEN @obfuscate = 1 THEN @pseudo_cmd ELSE @cmd END, @action,
                         @start, @end, @err_number, @err_message, @extended_info);
                END
            END CATCH;
        END

        /*
        Summary
        */
        RAISERROR(N'', 10, 1) WITH NOWAIT;
        RAISERROR(N'===============================================================================', 10, 1) WITH NOWAIT;
        SET @Msg = N' Done. Succeeded: ' + CAST(@succeeded_cnt AS nvarchar(10))
                 + N'  Failed: ' + CAST(@failed_cnt AS nvarchar(10))
                 + N'  Skipped: ' + CAST(@skipped_cnt AS nvarchar(10))
                 + CASE WHEN @discovery_errors > 0
                        THEN N'  ScanErrors: ' + CAST(@discovery_errors AS nvarchar(10))
                        ELSE N'' END
                 + N'  Elapsed: ' + CAST(DATEDIFF(SECOND, @RunStart, SYSDATETIME()) AS nvarchar(10)) + N's'
                 + CASE WHEN @live_pps IS NOT NULL
                        THEN N'  AvgRate: ' + CAST(CAST(@live_pps AS int) AS nvarchar(20)) + N' pages/sec'
                        ELSE N'' END;
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        RAISERROR(N'===============================================================================', 10, 1) WITH NOWAIT;

        -- XE observability: run complete
        BEGIN TRY
            SET @trace_msg = LEFT(N'sp_HeapDoctor: Done S=' + CAST(@succeeded_cnt AS nvarchar(10))
                + N' F=' + CAST(@failed_cnt AS nvarchar(10))
                + N' K=' + CAST(@skipped_cnt AS nvarchar(10))
                + N' ' + CAST(DATEDIFF(SECOND, @RunStart, SYSDATETIME()) AS nvarchar(10)) + N's', 128);
            EXEC sp_trace_generateevent @event_class = 82, @userinfo = @trace_msg;
        END TRY
        BEGIN CATCH END CATCH

        /*
        Log run END to CommandLog
        */
        IF @commandlog_exists = 1
        BEGIN
            INSERT INTO dbo.CommandLog
                (DatabaseName, SchemaName, ObjectName, ObjectType, Command, CommandType,
                 StartTime, EndTime, ErrorNumber, ErrorMessage, ExtendedInfo)
            VALUES
            (
                ISNULL(@Databases, DB_NAME()),
                N'dbo',
                N'sp_HeapDoctor',
                N'P',
                N'EXECUTE dbo.sp_HeapDoctor @Databases = N''' + REPLACE(ISNULL(@Databases, DB_NAME()), N'''', N'''''') + N'''...',
                N'HEAP_REBUILD_END',
                @start_time,
                SYSDATETIME(),
                0,
                NULL,
                (
                    SELECT
                        @Version AS Version,
                        @succeeded_cnt AS Succeeded,
                        @failed_cnt AS Failed,
                        @skipped_cnt AS Skipped,
                        @discovery_errors AS ScanErrors,
                        @TargetCount AS TotalTargets,
                        DATEDIFF(SECOND, @RunStart, SYSDATETIME()) AS ElapsedSeconds,
                        CASE
                            WHEN @failed_cnt > 0 THEN N'COMPLETED_WITH_ERRORS'
                            WHEN @discovery_errors > 0 THEN N'COMPLETED_WITH_SCAN_ERRORS'
                            WHEN @skipped_cnt > 0 THEN N'COMPLETED_WITH_SKIPS'
                            ELSE N'SUCCESS'
                        END AS StopReason,
                        @live_pages_rebuilt AS TotalPagesRebuilt,
                        CAST(@live_pps AS int) AS AvgPagesPerSec,
                        @RunID AS RunID
                    FOR XML RAW(N'Summary'), ELEMENTS
                )
            );
        END

        SELECT * FROM #ExecLog ORDER BY start_time, target_id;
    END

    -- Populate output parameters for automation
    SET @TargetsFound = @TargetCount;
    IF @PlanOnly = 0
    BEGIN
        SET @Succeeded = @succeeded_cnt;
        SET @Failed = @failed_cnt;
        SET @Skipped = @skipped_cnt;
    END

    -- Release re-entrancy guard
    EXEC sp_releaseapplock @Resource = N'sp_HeapDoctor', @LockOwner = N'Session';

    -- Return non-zero so SQL Agent jobs see failure
    IF @failed_cnt > 0
        RETURN 1;
END
GO

EXEC sp_MS_marksystemobject 'sp_HeapDoctor';
GO
