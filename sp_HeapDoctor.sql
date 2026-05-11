/*#region 00-HEADER /* License, version history, CREATE PROCEDURE, parameters */ */
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

Version:    2026.05.11.1 (CalVer: YYYY.MM.DD; same-day patches append .1, .2, etc.)

History:    2026.05.11.1 - Add @ExcludeDatabases and @ExcludeTables parameters
                          - Dedicated comma-separated exclusion patterns (no - prefix needed in value).
                          - Merged into @Databases / @Tables as -<pattern> entries before parsing,
                            so the existing recursive-CTE include/exclude parsers are reused.
                          - NULL @Databases + @ExcludeDatabases set implies USER_DATABASES.
                          - NULL @Tables + @ExcludeTables set implies % (all tables).
                          - Both logged to CommandLog via @invocation_command (original user input
                            preserved separately from the merged form).
                          - @Help COMMON PARAMETERS RAISERROR split 3-way to fit new params under
                            the Linux sqlcmd ~970-char per-RAISERROR output limit.
            2026.05.11 - Add @IncludeHealthyHeaps parameter
                          - Bypasses both forwarded-record discovery filters (forwarded_record_count > 0
                            AND @MinForwardedPct) so heaps with zero forwarded records are included.
                          - @MinPages / @MaxPages and all safety guards still apply.
                          - Primary use case: force-rebuild a known heap via @Tables scoping.
                          - @invocation_command logs @IncludeHealthyHeaps = 1 to CommandLog when non-default.
                          - @Help COMMON PARAMETERS RAISERROR split into two blocks (after @TopN) so the
                            added param renders under the Linux sqlcmd ~970-char output limit.
            2026.03.23 - Fix @QsRw undeclared variable bug in CpuSource=NONE and QUICKIESTORE paths
            2026.03.11.1 - Fix 6 reopened issues (#153, #160, #163, #164, #167, #168)
                          - #160: ranking_basis splits QS_NO_DATA into QS_DISABLED vs QS_NO_DATA
                          - #163: Filtered NCI stats warning now fires for all rebuild paths (was CI swap only)
                          - #164: FK child stats update no longer gated on ci_drop_failed
                          - #153: LOG_SPACE_INSUFFICIENT message mentions autogrowth not considered
                          - #167: Pre-flight lock check distinguishes sleeping sessions with open transactions
                          - #168: VLF temp table created once before loop (was CREATE/DROP per iteration)
            2026.03.11 - Fix #149: SYSTEM_VERSIONING re-enable failure now halts database targets
                          - #159: Copy-pasteable @ResumeRunID EXEC emitted after plan-only runs
            2026.03.09 - 19 remaining issues across 7 batches (v0302k-v0302q)
            2026.03.06 - Apply Erik Darling T-SQL style guide (~850 changes)
            2026.03.04 - Adopt CalVer versioning (YYYY.MM.DD); prior: 1.0.2026.0302j
            2026.03.04 - Security + correctness fixes (#93, #105, #122, #131, #132, #143)
                          - @OutputTable: PARSENAME+QUOTENAME validation prevents SQL injection (#131, #132)
                          - @UpdateStatsAfterRebuild: USE [db] + 2-part name fixes UPDATE STATISTICS (#143)
                          - @GenerateScript: RAISERROR uses %s format to handle % in object names (#122)
                          - Stale stats note: factually accurate message about modification counter (#93)
                          - CI swap guard: add XML index (type 3) and spatial (type 4) to exclusion (#105)
                          - Docs: @Help CI SWAP RESTRICTIONS block — partitioned heap and temporal history
                            table CI swap blocks now explicitly documented with rationale (#137, #140)
                          - Fix: @GenerateScript @Help note — corrected to reflect automatic
                            SYSTEM_VERSIONING wrapper generation for temporal targets (#119)
                          - Docs: CommandLog START ExtendedInfo comment — clarifies included vs. omitted
                            params for future maintainers (#107)
                          - 19 BY_DESIGN GitHub issues closed with explanations
            1.0.2026.0302i - Resumable CI swap + temporal history (#85, #84)
                          - @UseResumable: RESUMABLE = ON for CI swap CREATE INDEX (SQL 2019+, default ON)
                          - Paused operations auto-detected via sys.index_resumable_operations and resumed
                          - @IncludeTemporalHistory: includes temporal history table heaps in discovery
                          - SYSTEM_VERSIONING disable/enable lifecycle wraps rebuild for history tables
                          - CI swap blocked for temporal history tables (REBUILD only)
                          - New column: is_temporal_history
            1.0.2026.0302h - @OutputTable + @GenerateScript (#16, #23)
            1.0.2026.0302g - IO latch wait stats + cold-start ETA (#22, #88)
            1.0.2026.0302f - Observability (#65, #82, #67)
            1.0.2026.0302e - @UpdateStatsAfterRebuild + stale stats NCI message (#19, #91)
            1.0.2026.0302d - @Debug scheduler/memory, @FillFactor, memory-optimized exclusion (#24, #77, #70, #21)
            1.0.2026.0302c - Safety guards + new parameters (#68, #75, #78, #63, #89, #18)
                          - SQL 2017 version check, INSTEAD OF trigger detection, lock_escalation warning
                          - AG failover check, @AllowReplicationRebuild, @CheckPermissionsOnly
            1.0.2026.0302b - Pre-flight safety checks (#74, #79, #20)
                          - FK reference detection, per-rebuild log space pre-flight, tempdb pre-flight warning
            1.0.2026.0302  - Region markers + @Force + LOB TOCTOU + CommandLog schema validation (#25, #33, #71)
            1.0.2026.0227 - CI swap safety guards (#26, #62, #66, #72, #73, #76, #80, #83)
                          - SET XACT_ABORT OFF at proc start (prevents CATCH block skip when caller sets ON)
                          - Computed columns excluded from CandidateKeys CTE (c.is_computed = 0)
                          - Schema-bound view detection: CI swap blocked, falls back to heap rebuild
                          - Indexed view detection: CI swap blocked, falls back to heap rebuild
                          - CDC-tracked tables: CI swap blocked to protect capture instances
                          - Partitioned heap detection: CI swap blocked (partition_count > 1)
                          - Filegroup-aware CI swap: ON [filegroup] clause preserves heap's data_space
                          - Row count validation after rebuild (warns on > 1% + 10 row variance)
                          - New result set columns: partition_count, has_schema_bound_views, has_indexed_views, filegroup_name
                          - HEAP_SCAN_SUMMARY XML and resume mode updated for new columns
                          - Test runner regex fix for PASS/FAIL counting (#14)
            1.0.2026.0226 - GitHub issues #1-3, #7-12: observability, filtering, HEAP_SCAN_SUMMARY enhancements
                          - Full @invocation_command in CommandLog Command column (fixes truncation)
                          - sqlserver_start_time/uptime_hours in result set and HEAP_SCAN_SUMMARY XML
                          - ranking_algo_version column in result set and HEAP_SCAN_SUMMARY XML
                          - @SkipWriteHeavy parameter to exclude write-heavy heaps entirely
                          - @MinDaysSinceRebuild parameter to skip recently-rebuilt heaps
                          - HEAP_SCAN_SUMMARY written even with zero targets for trending
                          - Churn detection warning (>= 5 rebuilds in 90 days)
                          - Per-database breakdown in HEAP_SCAN_SUMMARY (Databases element)
                          - Resume staleness warning + superseded plan-only run detection
            1.0.2026.0225 - Two-phase ranking + plan_hash dedup for QS XML parsing performance
                          - Structural ranking first (forwarded_fetch_count + forwarded_pct), QS enrichment after
                          - QS XML parsing only for top @TopN targets per database (not all heaps)
                          - plan_hash dedup: TRY_CONVERT(xml) once per unique query_plan_hash, fan out to all plan_ids
                          - LIKE pre-filter checks #Targets instead of #Heaps (~8x fewer string scans)
                          - Global sort_order re-rank after enrichment (matches QUICKIESTORE pattern)
                          - Forced plan check uses lightweight LIKE on sys.query_store_plan (no XML)
            1.0.2026.0224 - @Tables parameter and @ResumeRunID (plan-then-execute workflow)
                          - @Tables: Include/exclude specific tables: @Tables = 'dbo.Orders, -dbo.Staging%'
                          - Schema optional: 'Orders' matches any schema, 'dbo.Orders' matches exact
                          - Wildcards (%), exclusions (-), comma-separated (same syntax as @Databases)
                          - Works with @Databases for cross-database table targeting
                          - @ResumeRunID: execute targets from a prior @PlanOnly=1 scan
                          - Skips discovery + QS analysis; uses commands stored in HEAP_SCAN_SUMMARY
                          - HEAP_SCAN_SUMMARY XML enriched with all #Targets columns for resume
                          - HEAP_REBUILD_START includes ResumedFromRunID for audit trail
                          - Version match and obfuscation checks on resume
                          - @Tables and @TopN applied as post-load filters in resume mode
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

/* Recent run summaries: */
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
    @Help                    bit            = 0, /* 1 = print parameter documentation and return */

    /* Target selection */
    @Databases               nvarchar(max)  = NULL, /* NULL = current DB. Supports: USER_DATABASES, ALL_DATABASES, */
                                                                /* SYSTEM_DATABASES, AVAILABILITY_GROUP_DATABASES, */
                                                                /* wildcards (%), exclusions (-), comma-separated */
    @ExcludeDatabases        nvarchar(max)  = NULL, /* Comma-separated DB patterns to exclude (wildcards OK; no - prefix needed). */
                                                                /* Merged into @Databases as -<pattern> entries. If @Databases is NULL, implies USER_DATABASES. */
    @Tables                  nvarchar(max)  = NULL, /* NULL = all tables. Supports: schema.table, wildcards (%), */
                                                                /* exclusions (-), comma-separated. Schema optional (defaults to %). */
    @ExcludeTables           nvarchar(max)  = NULL, /* Comma-separated schema.table patterns to exclude (no - prefix needed). */
                                                                /* Merged into @Tables as -<pattern> entries. If @Tables is NULL, implies %. */
    @LookbackDays            integer            = 7,
    @TopN                    integer            = 25, /* per database */
    @MinPages                bigint         = 1000,
    @MaxPages                bigint         = NULL, /* NULL = no cap; else only heaps with page_count <= @MaxPages */
    @MinForwardedPct         decimal(6,2)   = 2.00,
    @IncludeHealthyHeaps     bit            = 0, /* 1 = bypass forwarded-record discovery filters (include heaps with 0 forwarded records / below @MinForwardedPct). Use with @Tables to force-rebuild a specific heap. */
    @SkipWriteHeavy          bit            = 0, /* 1 = exclude WRITE_HEAVY and WRITE_ONLY heaps entirely */
    @MinDaysSinceRebuild     integer            = NULL, /* NULL = no filter; skip heaps rebuilt fewer than N days ago */

    /* CPU source */
    @CpuSource               varchar(20)    = 'QUERY_STORE', /* QUERY_STORE | QUICKIESTORE | NONE */
    @QuickieExecSql          nvarchar(max)  = NULL, /* e.g. N'EXEC dbo.sp_QuickieStore @Top=50, @SortOrder=''cpu'';' */
    @QuickiePlanIdColumn     sysname        = N'plan_id', /* column name in Quickie output */
    @QuickieCpuUsColumn      sysname        = N'avg_cpu_time', /* OR cpu_us / cpu_ms etc; see @QuickieCpuUnit */
    @QuickieCpuUnit          varchar(10)    = 'us', /* us | ms  (unit of @QuickieCpuUsColumn) */

    /* Actions */
    @OnlinePreference        varchar(10)    = 'AUTO', /* AUTO (use edition), ON (require), OFF (force offline) */
    @AllowCiSwap             bit            = 0, /* enable CI swap path at all */
    @PreferCiSwap            bit            = 0, /* if 1, use CI swap when safe key exists + online allowed */

    /* Execution */
    @PlanOnly                bit            = 1, /* 1 = print commands only, 0 = execute */
    @Execute                 nvarchar(1)    = NULL, /* Ola Hallengren convention: Y = execute (@PlanOnly=0), N = plan only (@PlanOnly=1) */
    @Maxdop                  integer            = NULL, /* optional MAXDOP on index ops (NULL = omit) */
    @LockTimeoutMs           integer            = NULL, /* NULL = don't set; milliseconds for SET LOCK_TIMEOUT per rebuild */
    @MaxRunSeconds           integer            = NULL, /* when PlanOnly=0, stop after N seconds (NULL = no limit) */
    @ScanThrottleMs          integer            = NULL, /* NULL = no throttle; ms to WAITFOR between database scans */

    /* Logging */
    @LogToTable              nvarchar(1)    = N'Y', /* Y = log to dbo.CommandLog (current DB), N = no logging */

    /* Output verbosity */
    @Debug                   bit            = 0,

    /* Discovery scan */
    @ScanMode                nvarchar(20)   = N'SAMPLED', /* #135: dm_db_index_physical_stats mode (SAMPLED/DETAILED/LIMITED) */

    /* Throughput estimation */
    @EstimateTime            bit            = 0, /* 1 = show estimated rebuild time per target */
    @EstimateLookbackDays    integer            = 90, /* CommandLog history window for throughput rates */
    @BaselineRebuildMBPerMin integer            = NULL, /* cold-start: MB/min rate when no CommandLog history exists */

    /* Output parameters (for automation; only populated when provided) */
    @TargetsFound            integer            = NULL OUTPUT,
    @Succeeded               integer            = NULL OUTPUT,
    @Failed                  integer            = NULL OUTPUT,
    @Skipped                 integer            = NULL OUTPUT,

    /* Obfuscation (for sharing diagnostic reports externally) */
    @ObfuscateKey            nvarchar(128)  = NULL, /* when provided, replaces real names with pseudonyms in result sets and CommandLog */
    @ObfuscateSeed           nvarchar(128)  = NULL, /* optional seed for cross-environment consistency; NULL = use @RunID (unique per run) */
    @RevealKey               nvarchar(128)  = NULL, /* decrypt a prior obfuscated run's mapping from CommandLog */
    @RevealRunID             uniqueidentifier = NULL, /* required with @RevealKey; RunID from the run to decrypt */

    /* Resume from prior plan-only scan */
    @ResumeRunID             uniqueidentifier = NULL, /* load targets from a prior @PlanOnly=1 HEAP_SCAN_SUMMARY; skips discovery */

    /* Pre-flight */
    @CheckPermissionsOnly    bit            = 0, /* #18: check required permissions and return (no DDL/DML) */

    /* CI swap options */
    @FillFactor              tinyint        = 0, /* #77: fill factor for CI swap CREATE INDEX (0 = server default) */

    /* Post-rebuild */
    @UpdateStatsAfterRebuild bit            = 0, /* #19: run UPDATE STATISTICS WITH FULLSCAN after each rebuild */

    /* Safety */
    @AllowReplicationRebuild bit            = 0, /* #89: opt-in for published heaps (default: skip) */
    @Force                   bit            = 0, /* bypass re-entrancy guard (use when prior run was KILLed and applock is orphaned) */

    /* Output */
    @OutputTable             nvarchar(256)  = NULL, /* #16: persist results to a table (e.g. 'dbo.HeapDoctorHistory') */
    @GenerateScript          bit            = 0, /* #23: output executable T-SQL script per target */

    /* Temporal */
    @IncludeTemporalHistory  bit            = 0, /* #84: include temporal history heaps in discovery */

    /* Resumable */
    @UseResumable            bit            = 1 /* #85: use RESUMABLE = ON for CI swap (SQL 2019+, default ON) */
)
/*#endregion 00-HEADER */

/*#region 01-PREAMBLE /* SET options, version constants, state variables */ */
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF; /* Ensure CATCH blocks execute even if caller set XACT_ABORT ON (#66) */

    DECLARE @Version nvarchar(20) = N'2026.05.11.1';
    /* Ranking algorithm version: increment only when the ranking formula changes, not on every proc release. */
    /* v1 = LOG10-normalized weighted (0.4*fetch_rate + 0.4*cpu + 0.2*fwd_pct) * write_penalty. Since 2026.0218. */
    DECLARE @RankingAlgoVersion nvarchar(10) = N'v1';
    DECLARE @RunID uniqueidentifier = NEWID();

    /* Obfuscation state */
    DECLARE @obfuscate      bit            = CASE WHEN @ObfuscateKey IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @passphrase     nvarchar(max)  = NULL;
    DECLARE @effective_seed nvarchar(128)  = NULL;

    /* Reproducible invocation command for CommandLog (built after input validation) */
    DECLARE @invocation_command nvarchar(max) = NULL;

/*#endregion 01-PREAMBLE */

/*#region 02-HELP /* @Help parameter documentation output */ */
    /*-------------------------------------------------------------------------- */
    /* @Help: print parameter documentation and return */
    /*-------------------------------------------------------------------------- */
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
  @ExcludeDatabases  nvarchar(max) = NULL  Patterns to exclude (no - prefix). Combines with @Databases;
                                        implies USER_DATABASES when @Databases is NULL.
', 10, 1, @Version) WITH NOWAIT;

        RAISERROR(N'  @Tables            nvarchar(max) = NULL  NULL=all tables. schema.table format,
                                        wildcards (%%), exclusions (-), comma-separated.
                                        Schema optional (omit = any schema).
  @ExcludeTables     nvarchar(max) = NULL  Patterns to exclude (no - prefix). Combines with @Tables;
                                        implies all tables when @Tables is NULL.
  @PlanOnly          bit     = 1       1=print commands only, 0=execute.
  @Execute           nvarchar(1) = NULL  Ola convention: Y=execute, N=plan only. Overrides @PlanOnly.
  @TopN              integer     = 25      Max targets per database.
', 10, 1) WITH NOWAIT;

        RAISERROR(N'  @MinPages          bigint  = 1000    Discovery filter: heaps below this page count are excluded.
  @MinForwardedPct   decimal = 2.00    Min forwarded %% (= forwarded_records / total_rows * 100).
  @IncludeHealthyHeaps bit  = 0       1=bypass forwarded-record filters; include heaps with 0 forwarded
                                        records. Combine with @Tables to force-rebuild a specific heap.
  @SkipWriteHeavy    bit     = 0       1=exclude WRITE_HEAVY and WRITE_ONLY heaps entirely.
  @MinDaysSinceRebuild integer   = NULL    Skip heaps rebuilt fewer than N days ago (requires CommandLog).
  @LogToTable        nvarchar(1) = Y   Y=log to dbo.CommandLog, N=no logging.
', 10, 1) WITH NOWAIT;

        RAISERROR(N'ADVANCED PARAMETERS:
  @CpuSource         varchar = QUERY_STORE  QUERY_STORE | QUICKIESTORE | NONE
  @LookbackDays      integer     = 7       Query Store lookback window in days.
  @MaxPages          bigint  = NULL    Skip heaps larger than this (NULL=no cap).
  @OnlinePreference  varchar = AUTO     AUTO | ON (require) | OFF (force offline)
  @AllowCiSwap       bit     = 0       Allow CI swap rebuild path.
  @PreferCiSwap      bit     = 0       Prefer CI swap when safe key exists + online allowed.
  @FillFactor        tinyint = 0       Fill factor for CI swap CREATE INDEX (0=server default, 1-100).
  @Maxdop            integer     = NULL    MAXDOP on index ops (NULL=omit, 0=unlimited).
  @LockTimeoutMs     integer     = NULL    Per-rebuild lock timeout in ms (NULL=don''t set).
  @MaxRunSeconds     integer     = NULL    Stop after N seconds (NULL=no limit).
  @ScanThrottleMs    integer     = NULL    Wait ms between database scans (0-60000, NULL=off).
  @Debug             bit     = 0       Extra diagnostic output.
  @ScanMode          nvarchar(20) = N''SAMPLED'' Discovery scan mode for dm_db_index_physical_stats.
                                        SAMPLED: ~1%% of pages (fast, may miss recent fragmentation).
                                        DETAILED: all pages (accurate, slower on large databases).
                                        LIMITED: allocation pages only (fastest, coarse fragmentation).
  @EstimateTime      bit     = 0       Show estimated rebuild time per target.
  @EstimateLookbackDays integer  = 90      CommandLog history window for throughput rates.
  @BaselineRebuildMBPerMin integer = NULL  Cold-start: assumed MB/min when no CommandLog history
                                        exists. Typical range 100-2000 (SSD vs HDD).
  @UpdateStatsAfterRebuild bit = 0    Run UPDATE STATISTICS WITH FULLSCAN after each rebuild.
  @CheckPermissionsOnly bit  = 0       Check required permissions per database and return.
  @AllowReplicationRebuild bit = 0    Published heaps skipped unless 1 (replication log flood risk).
  @Force             bit     = 0       Bypass re-entrancy guard (orphaned applock from KILLed run).
  @OutputTable       nvarchar(256) = NULL  Persist results to a table (auto-created if missing).
                                        e.g. dbo.HeapDoctorHistory. Includes RunID + CapturedAt.
  @GenerateScript    bit     = 0       Output executable T-SQL script (implies @PlanOnly=1).
                                        Temporal history targets include SYSTEM_VERSIONING
                                        disable/enable wrappers automatically (Steps 1/2/3).
  @IncludeTemporalHistory bit = 0      Include temporal history table heaps in discovery.
                                        Rebuild requires SYSTEM_VERSIONING disable/enable on parent.
                                        CI swap is blocked for history tables (REBUILD only).
  @UseResumable      bit     = 1       RESUMABLE = ON for CI swap CREATE INDEX (SQL 2019+).
                                        On interrupt, index build is paused (not rolled back).
                                        Resume detection: paused ops auto-resumed on next run.
', 10, 1) WITH NOWAIT;

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
', 10, 1) WITH NOWAIT;

        RAISERROR(N'EXAMPLES:
  EXEC sp_HeapDoctor;
  EXEC sp_HeapDoctor @Databases = N''USER_DATABASES'', @PlanOnly = 0;
  EXEC sp_HeapDoctor @Databases = N''USER_DATABASES'', @Execute = N''Y'';
  EXEC sp_HeapDoctor @Tables = N''dbo.Orders, dbo.OrderDetails'';
  EXEC sp_HeapDoctor @Tables = N''dbo.%%, -dbo.Staging%%'';
  EXEC sp_HeapDoctor @Tables = N''Heap%%'', @Databases = N''USER_DATABASES'';
  EXEC sp_HeapDoctor @ObfuscateKey = N''MySecretKey'';
  EXEC sp_HeapDoctor @RevealKey = N''MyKey'', @RevealRunID = N''<RunID-from-output>'';
  /* Plan-then-execute: */
  EXEC sp_HeapDoctor @Databases = N''MyDB''; /* plan-only, note RunID */
  EXEC sp_HeapDoctor @ResumeRunID = N''<RunID>'', @PlanOnly = 0;
  /* Resume a subset: */
  EXEC sp_HeapDoctor @ResumeRunID = N''<RunID>'', @Tables = N''dbo.Orders'', @PlanOnly = 0;

WRITE-HEAVY HEAPS:
  Heaps flagged as WRITE_HEAVY or WRITE_ONLY have more updates than reads. Forwarded
  records will recur quickly after a rebuild because the same update patterns that
  caused the problem will recreate it. The cumulative penalties of doing nothing:
    - I/O amplification: every forwarded fetch is an extra page read per scan
    - Buffer pool waste: forwarding stubs and scattered rows consume more memory
    - Space bloat: original pages retain stubs; the heap grows beyond what data needs
  The best fix is adding a clustered index, which eliminates forwarded records permanently.
  When a CI is not possible (vendor schema, LOB-heavy tables), rebuild periodically on a
  less aggressive schedule. Use @SkipWriteHeavy=1 to focus maintenance windows on heaps
  where rebuilds last longer, then run a separate pass for write-heavy heaps less often.
  The churn warning (>= 5 rebuilds in 90 days) flags heaps that need a CI, not more rebuilds.
  Use @MinDaysSinceRebuild to prevent wasteful back-to-back rebuilds on churning heaps.
', 10, 1) WITH NOWAIT;

        RAISERROR(N'CI SWAP LOCKING:
  Sch-M locks acquired during CI swap block ALL readers, including NOLOCK/READ UNCOMMITTED.
  Applications that rely on NOLOCK for non-blocking reads will queue during CI swap.
  Tables with lock_escalation=TABLE compound this risk. Use @LockTimeoutMs to limit wait.

CI SWAP RESTRICTIONS:
  The following table types are blocked from CI swap and fall back to HEAP_REBUILD:
  - Partitioned heaps (partition_count > 1): creating a CI on a partitioned heap requires
    a matching partition scheme and function. sp_HeapDoctor cannot resolve this dependency
    automatically. Use ALTER TABLE ... REBUILD instead and manage partitioning separately.
  - Temporal history tables (is_temporal_history = 1): SYSTEM_VERSIONING prevents DDL on
    the history table while versioning is active. sp_HeapDoctor disables SYSTEM_VERSIONING,
    performs HEAP_REBUILD, then re-enables it. CI swap is not used for history tables.
  - Tables with LOB columns, schema-bound views, indexed views, CDC tracking, or forced plans.
  The result set columns partition_count and is_temporal_history indicate these conditions.
  FK REFERENCES: CI swap changes row locators in FK child tables from RID to CI key (and back).
  Only same-database FK constraints (sys.foreign_keys) are detected. Cross-database FKs enforced
  via triggers, synonyms, or application logic are invisible to sp_HeapDoctor. (#110)

DISCOVERY FILTERS:
  @MinPages, @MinForwardedPct, and @TopN are discovery-time filters. Heaps that do not
  meet these thresholds are excluded from results entirely, even in @PlanOnly mode.
  Set @MinPages=0, @MinForwardedPct=0 for a complete audit of all heaps.
  @IncludeHealthyHeaps=1 bypasses BOTH forwarded filters (forwarded_record_count > 0
  and @MinForwardedPct) so heaps with zero forwarded records are included. @MinPages and
  @MaxPages still apply. Typical use: force-rebuild a known heap via @Tables. Without
  @Tables scoping, a server-wide run with @IncludeHealthyHeaps=1 will queue every heap
  in the instance; ranking_score collapses toward 0 so sort_order reflects little signal.
  forwarded_pct formula: forwarded_record_count / record_count * 100. The denominator
  is total rows (record_count), not pages. forwarded_record_count counts pointer stubs
  on original pages (one per forwarded row). Example: 1M rows, 50K forwarded = 5.0%%.
  @TopN + CI SWAP: @TopN selects top-N targets by ranking score before action assignment.
  A lower-ranked CI swap candidate (more efficient fix) may be excluded while a higher-ranked
  heap rebuild is included. To ensure CI swap targets are evaluated, use @TopN=NULL or a
  larger value when @AllowCiSwap=1. (#142)

SCOPE:
  Operates within the current SQL Server instance. Linked server tables are out of scope.
  Cross-database heaps are discovered when their database is included in @Databases.
  For multi-instance environments, run sp_HeapDoctor on each instance separately.

MONITORING:
  sp_HeapDoctor emits sp_trace_generateevent (event class 82) per rebuild. SQL Trace
  is deprecated in SQL 2022+. For Extended Events monitoring, see the XE session in
  tools/sp_HeapDoctor_XE_Session.sql. Intra-rebuild progress is not possible for
  atomic DDL operations (ALTER TABLE REBUILD is a single call that returns on completion).

REQUIREMENTS: SQL Server 2017+ (STRING_AGG). Enterprise/Developer for ONLINE.
COMMANDLOG:   dbo.CommandLog (Ola Hallengren). https://ola.hallengren.com/scripts/CommandLog.sql
PERMISSIONS:  VIEW DATABASE STATE, ALTER on target tables, INSERT on dbo.CommandLog,
              ALTER TRACE (optional, for sp_trace_generateevent observability).
TIME ZONES:   CommandLog = local (SYSDATETIME). QS snapshots = UTC (SYSUTCDATETIME).
', 10, 1) WITH NOWAIT;
        RETURN;
    END

/*#endregion 02-HELP */

/*#region 03-REVEAL /* @RevealKey short-circuit decryption */ */
    /*-------------------------------------------------------------------------- */
    /* @RevealKey: decrypt obfuscated mapping from a prior run's CommandLog */
    /* Short-circuits before re-entrancy guard (read-only, should not block). */
    /*-------------------------------------------------------------------------- */
    IF @RevealKey IS NOT NULL
    BEGIN
        DECLARE @Msg_reveal nvarchar(4000);

        /* @RevealRunID is required */
        IF @RevealRunID IS NULL
        BEGIN
            RAISERROR(N'@RevealKey requires @RevealRunID. Provide the RunID from the obfuscated run.', 16, 1);
            RETURN;
        END

        /* Cannot combine with @ObfuscateKey */
        IF @ObfuscateKey IS NOT NULL
        BEGIN
            RAISERROR(N'@RevealKey and @ObfuscateKey cannot be used together. Choose one mode.', 16, 1);
            RETURN;
        END

        /* CommandLog must exist */
        IF NOT EXISTS (
            SELECT 1 FROM sys.objects o
            JOIN sys.schemas s ON s.schema_id = o.schema_id
            WHERE o.type = N'U' AND s.name = N'dbo' AND o.name = N'CommandLog'
        )
        BEGIN
            RAISERROR(N'@RevealKey requires dbo.CommandLog. The encrypted mapping is stored there.', 16, 1);
            RETURN;
        END

        /* Retrieve the encrypted mapping - check HEAP_REBUILD_START first (exec), then HEAP_SCAN_SUMMARY (plan-only) */
        DECLARE @reveal_xml xml;
        DECLARE @reveal_source nvarchar(30);

        /* 1. Try HEAP_REBUILD_START (execution-mode runs) */
        SELECT TOP (1) @reveal_xml = ExtendedInfo, @reveal_source = N'HEAP_REBUILD_START'
        FROM dbo.CommandLog
        WHERE CommandType = N'HEAP_REBUILD_START'
          AND ExtendedInfo.exist(N'/Parameters/RunID[text()=sql:variable("@RevealRunID")]') = 1
        ORDER BY ID DESC;

        /* 2. Fall back to HEAP_SCAN_SUMMARY (plan-only runs) */
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
            SET @Msg_reveal = N'No obfuscated run found for RunID ' + CONVERT(nvarchar(36), @RevealRunID)
                            + N'. Verify the RunID and that the run used @ObfuscateKey.';
            RAISERROR(@Msg_reveal, 16, 1);
            RETURN;
        END

        /* Read the hex-encoded encrypted mapping (XPath depends on source) */
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

        /* If no stored seed, the original run used @RunID as seed */
        DECLARE @reveal_passphrase nvarchar(max) = @RevealKey + ISNULL(@stored_seed, CONVERT(nvarchar(36), @RevealRunID));

        /* Decrypt the mapping */
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

        /* Output the pseudonym-to-real-name mapping */
        SELECT
            t.c.value(N'(pseudonym)[1]',   N'nvarchar(20)')  AS pseudonym,
            t.c.value(N'(object_type)[1]', N'varchar(10)')   AS object_type,
            t.c.value(N'(real_name)[1]',   N'sysname')       AS real_name
        FROM @mapping_xml.nodes(N'/ObfuscatedMapping/Object') AS t(c)
        ORDER BY object_type, pseudonym;

        RETURN;
    END

/*#endregion 03-REVEAL */

/*#region 04-VALIDATION /* @Execute alias, lock timeout, input validation */ */
    /*-------------------------------------------------------------------------- */
    /* @Execute alias (Ola Hallengren convention): Y = execute, N = plan only */
    /* When provided, overrides @PlanOnly. */
    /*-------------------------------------------------------------------------- */
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
    DECLARE @OriginalLockTimeout integer = @@LOCK_TIMEOUT;

    /*-------------------------------------------------------------------------- */
    /* Input validation */
    /*-------------------------------------------------------------------------- */
    DECLARE @Msg nvarchar(4000);
    DECLARE @CpuSourceUpper varchar(20) = UPPER(@CpuSource);
    SET @OnlinePreference = UPPER(@OnlinePreference);

    /* #68: SQL Server 2017+ version check (STRING_AGG requires v14+) */
    IF CONVERT(integer, SERVERPROPERTY(N'ProductMajorVersion')) < 14
    BEGIN
        RAISERROR(N'sp_HeapDoctor requires SQL Server 2017 or later. STRING_AGG (used in QS snapshot aggregation) is not available in SQL Server 2016 and earlier.', 16, 1);
        RETURN;
    END

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

    /* #77: @FillFactor validation */
    IF @FillFactor < 0 OR @FillFactor > 100
    BEGIN
        RAISERROR(N'@FillFactor must be between 0 and 100. Use 0 for server default.', 16, 1);
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

    /* #135: @ScanMode validation */
    SET @ScanMode = UPPER(LTRIM(RTRIM(@ScanMode)));
    IF @ScanMode NOT IN (N'SAMPLED', N'DETAILED', N'LIMITED')
    BEGIN
        RAISERROR(N'@ScanMode must be SAMPLED, DETAILED, or LIMITED.', 16, 1);
        RETURN;
    END

    IF @EstimateLookbackDays IS NOT NULL AND @EstimateLookbackDays <= 0
    BEGIN
        RAISERROR(N'@EstimateLookbackDays must be a positive integer.', 16, 1);
        RETURN;
    END

    IF @BaselineRebuildMBPerMin IS NOT NULL AND @BaselineRebuildMBPerMin <= 0
    BEGIN
        RAISERROR(N'@BaselineRebuildMBPerMin must be a positive integer (typical range: 100-2000 MB/min).', 16, 1);
        RETURN;
    END

    /* #16: @OutputTable validation (#131/#132: PARSENAME+QUOTENAME to prevent SQL injection) */
    IF @OutputTable IS NOT NULL
    BEGIN
        /* Reject spaces (quick guard before PARSENAME) */
        IF CHARINDEX(N' ', @OutputTable) > 0
        BEGIN
            RAISERROR(N'@OutputTable must not contain spaces. Use schema.table format (e.g. dbo.HeapDoctorHistory).', 16, 1);
            RETURN;
        END
        -- #131/#132: Validate via PARSENAME. Only 1-part (table) or 2-part (schema.table) allowed.
        -- 3-part or 4-part names are rejected. PARSENAME returns NULL for invalid identifiers.
        IF PARSENAME(@OutputTable, 1) IS NULL OR PARSENAME(@OutputTable, 3) IS NOT NULL
        BEGIN
            RAISERROR(N'@OutputTable must use 1-part (table) or 2-part (schema.table) format with valid identifiers (e.g. dbo.HeapDoctorHistory).', 16, 1);
            RETURN;
        END
    END

    /* #23: @GenerateScript is mutually exclusive with @PlanOnly=0 when @Execute='Y' */
    IF @GenerateScript = 1
        SET @PlanOnly = 1; /* GenerateScript implies plan-only (no DDL executed) */

    -- #85: RESUMABLE = ON for CREATE INDEX requires SQL Server 2019+ (v15).
    -- Silently downgrade to @UseResumable = 0 on SQL Server 2017 (v14) to avoid error 155.
    IF @UseResumable = 1 AND CAST(SERVERPROPERTY(N'ProductMajorVersion') AS int) < 15
        SET @UseResumable = 0;

    IF @ObfuscateSeed IS NOT NULL AND @ObfuscateKey IS NULL
        RAISERROR(N'WARNING: @ObfuscateSeed is ignored without @ObfuscateKey.', 10, 1) WITH NOWAIT;

    /*-------------------------------------------------------------------------- */
    /* #18: @CheckPermissionsOnly: enumerate required permissions and return */
    /*-------------------------------------------------------------------------- */
    IF @CheckPermissionsOnly = 1
    BEGIN
        CREATE TABLE #PermCheck
        (
            database_name sysname NOT NULL,
            permission_name nvarchar(128) NOT NULL,
            granted nvarchar(1) NOT NULL
        );

        /* Check instance-level permissions */
        INSERT INTO #PermCheck(database_name, permission_name, granted)
        VALUES (N'(server)', N'ALTER TRACE', CASE WHEN HAS_PERMS_BY_NAME(NULL, NULL, N'ALTER TRACE') = 1 THEN N'Y' ELSE N'N' END);

        /* Check per-database permissions (use @Databases if set, otherwise current DB) */
        DECLARE @perm_db sysname;
        DECLARE @perm_sql nvarchar(max);

        IF @Databases IS NULL
        BEGIN
            SET @perm_db = DB_NAME();
            INSERT INTO #PermCheck(database_name, permission_name, granted)
            VALUES (@perm_db, N'VIEW DATABASE STATE',
                    CASE WHEN HAS_PERMS_BY_NAME(@perm_db, N'DATABASE', N'VIEW DATABASE STATE') = 1 THEN N'Y' ELSE N'N' END);
            INSERT INTO #PermCheck(database_name, permission_name, granted)
            VALUES (@perm_db, N'ALTER (any table)',
                    CASE WHEN HAS_PERMS_BY_NAME(@perm_db, N'DATABASE', N'ALTER') = 1 THEN N'Y' ELSE N'N' END);

            /* CommandLog check */
            IF @LogToTable = N'Y' AND OBJECT_ID(N'dbo.CommandLog') IS NOT NULL
                INSERT INTO #PermCheck(database_name, permission_name, granted)
                VALUES (@perm_db, N'INSERT on dbo.CommandLog',
                        CASE WHEN HAS_PERMS_BY_NAME(N'dbo.CommandLog', N'OBJECT', N'INSERT') = 1 THEN N'Y' ELSE N'N' END);
        END
        ELSE
        BEGIN
            DECLARE perm_cursor CURSOR LOCAL FAST_FORWARD FOR
                SELECT name FROM sys.databases
                WHERE state_desc = N'ONLINE'
                  AND HAS_DBACCESS(name) = 1
                  AND (@Databases = N'USER_DATABASES' AND database_id > 4
                    OR @Databases = N'ALL_DATABASES'
                    OR @Databases = N'SYSTEM_DATABASES' AND database_id <= 4
                    OR name LIKE REPLACE(@Databases, N'*', N'%'));
            OPEN perm_cursor;
            FETCH NEXT FROM perm_cursor INTO @perm_db;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                INSERT INTO #PermCheck(database_name, permission_name, granted)
                VALUES (@perm_db, N'VIEW DATABASE STATE',
                        CASE WHEN HAS_PERMS_BY_NAME(@perm_db, N'DATABASE', N'VIEW DATABASE STATE') = 1 THEN N'Y' ELSE N'N' END);
                INSERT INTO #PermCheck(database_name, permission_name, granted)
                VALUES (@perm_db, N'ALTER (any table)',
                        CASE WHEN HAS_PERMS_BY_NAME(@perm_db, N'DATABASE', N'ALTER') = 1 THEN N'Y' ELSE N'N' END);
                FETCH NEXT FROM perm_cursor INTO @perm_db;
            END
            CLOSE perm_cursor;
            DEALLOCATE perm_cursor;
        END

        /* Return result set */
        SELECT database_name, permission_name, granted
        FROM #PermCheck
        ORDER BY CASE WHEN granted = N'N' THEN 0 ELSE 1 END, database_name, permission_name;

        /* Summary */
        DECLARE @missing_count integer;
        SELECT @missing_count = COUNT_BIG(*) FROM #PermCheck WHERE granted = N'N';
        IF @missing_count > 0
        BEGIN
            SET @Msg = CONVERT(nvarchar(10), @missing_count) + N' missing permission(s) found. See result set above.';
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        END
        ELSE
            RAISERROR(N'All required permissions granted.', 10, 1) WITH NOWAIT;

        DROP TABLE #PermCheck;
        RETURN;
    END

/*#endregion 04-VALIDATION */

/*#region 05-REENTRY-GUARD /* sp_getapplock, obfuscation passphrase init */ */
    /*-------------------------------------------------------------------------- */
    /* 8B: Re-entrancy guard */
    /* Prevents concurrent executions from interfering with each other. */
    /* Uses sp_getapplock with session-scoped exclusive lock. */
    /*-------------------------------------------------------------------------- */
    DECLARE @lock_result integer;
    EXEC @lock_result = sp_getapplock
        @Resource = N'sp_HeapDoctor',
        @LockMode = N'Exclusive',
        @LockTimeout = 0,
        @LockOwner = N'Session';

    IF @lock_result < 0 AND @Force = 0
    BEGIN
        RAISERROR(N'Another instance of sp_HeapDoctor is already running in this SQL Server instance. Use @Force = 1 to bypass if the previous run was KILLed. Aborting.', 16, 1);
        RETURN;
    END
    ELSE IF @lock_result < 0 AND @Force = 1
    BEGIN
        RAISERROR(N'WARNING: Bypassing re-entrancy guard via @Force = 1. Ensure no concurrent instance is actually running.', 10, 1) WITH NOWAIT;
    END

    /* Initialize obfuscation passphrase (after re-entrancy guard succeeds) */
    IF @obfuscate = 1
    BEGIN
        SET @effective_seed = ISNULL(@ObfuscateSeed, CONVERT(nvarchar(36), @RunID));
        SET @passphrase     = @ObfuscateKey + @effective_seed;
    END

/*#endregion 05-REENTRY-GUARD */

/*#region 06-ENVIRONMENT /* Edition detection, CommandLog, banner, resume flag */ */
    /*-------------------------------------------------------------------------- */
    /* Environment / capability gating */
    /*-------------------------------------------------------------------------- */
    DECLARE @Edition nvarchar(128) = CONVERT(nvarchar(128), SERVERPROPERTY('Edition'));
    DECLARE @EngineEdition integer = CONVERT(integer, SERVERPROPERTY('EngineEdition'));
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
            ELSE IIF(@CanOnline = 1, 1, 0) /* AUTO */
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

            /* #71: Validate CommandLog schema compatibility before first write. */
            /* Ola Hallengren's schema has evolved; older versions may lack columns we need. */
            DECLARE @cl_missing nvarchar(max) = NULL;
            SELECT @cl_missing = STRING_AGG(r.col_name, N', ')
            FROM (VALUES
                (N'DatabaseName'), (N'SchemaName'), (N'ObjectName'), (N'ObjectType'),
                (N'IndexName'), (N'IndexType'), (N'Command'), (N'CommandType'),
                (N'StartTime'), (N'EndTime'), (N'ErrorNumber'), (N'ErrorMessage'),
                (N'ExtendedInfo')
            ) AS r(col_name)
            WHERE NOT EXISTS (
                SELECT 1 FROM sys.columns c
                WHERE c.object_id = OBJECT_ID(N'dbo.CommandLog')
                  AND c.name = r.col_name COLLATE DATABASE_DEFAULT
            );

            IF @cl_missing IS NOT NULL
            BEGIN
                SET @Msg = N'WARNING: dbo.CommandLog is missing columns: ' + @cl_missing
                         + N'. Logging disabled. Recreate from https://ola.hallengren.com/scripts/CommandLog.sql';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                SET @commandlog_exists = 0;
            END
            ELSE
            BEGIN
                /* Validate ExtendedInfo is xml type (some shops use nvarchar(max) which breaks XPath) */
                IF NOT EXISTS (
                    SELECT 1 FROM sys.columns c
                    JOIN sys.types t ON t.user_type_id = c.user_type_id
                    WHERE c.object_id = OBJECT_ID(N'dbo.CommandLog')
                      AND c.name = N'ExtendedInfo'
                      AND t.name = N'xml'
                )
                BEGIN
                    RAISERROR(N'WARNING: dbo.CommandLog.ExtendedInfo is not xml type. XPath features disabled. Logging disabled for this run.', 10, 1) WITH NOWAIT;
                    SET @commandlog_exists = 0;
                END
            END
        END
        ELSE
        BEGIN
            RAISERROR(N'WARNING: dbo.CommandLog does not exist in the current database. Set @LogToTable = N''N'' or create the table. Logging disabled for this run.', 10, 1) WITH NOWAIT;
            SET @commandlog_exists = 0;
        END
    END

    /*
    #141: Check for orphaned SYSTEM_VERSIONING breadcrumbs from prior KILLed temporal rebuilds.
    These indicate SYSTEM_VERSIONING was disabled but never re-enabled.
    */
    IF @commandlog_exists = 1
    BEGIN
        DECLARE @orphan_versioning nvarchar(max) = NULL;
        SELECT @orphan_versioning = STRING_AGG(
            N'  ' + DatabaseName + N'.' + SchemaName + N'.' + ObjectName
            + N' -- ' + Command, NCHAR(10))
        FROM dbo.CommandLog
        WHERE CommandType = N'HEAP_TEMPORAL_VERSIONING_DISABLED'
          AND EndTime IS NULL
          AND StartTime >= DATEADD(DAY, -7, SYSDATETIME());

        IF @orphan_versioning IS NOT NULL
        BEGIN
            SET @Msg = N'WARNING: Orphaned SYSTEM_VERSIONING disable detected (prior run may have been KILLed).'
                     + N' The following parent tables may need SYSTEM_VERSIONING re-enabled:';
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            RAISERROR(@orphan_versioning, 10, 1) WITH NOWAIT;
            RAISERROR(N'Execute the DDL above to restore temporal versioning.', 10, 1) WITH NOWAIT;
        END
    END

    /* Build reproducible invocation command for CommandLog (all non-default parameters) */
    SET @invocation_command = N'EXECUTE dbo.sp_HeapDoctor @Databases = N''' + REPLACE(ISNULL(@Databases, DB_NAME()), N'''', N'''''') + N'''';
    IF @ExcludeDatabases IS NOT NULL
        SET @invocation_command += N', @ExcludeDatabases = N''' + REPLACE(@ExcludeDatabases, N'''', N'''''') + N'''';
    IF @Tables IS NOT NULL
        SET @invocation_command += N', @Tables = N''' + REPLACE(@Tables, N'''', N'''''') + N'''';
    IF @ExcludeTables IS NOT NULL
        SET @invocation_command += N', @ExcludeTables = N''' + REPLACE(@ExcludeTables, N'''', N'''''') + N'''';
    SET @invocation_command += N', @PlanOnly = ' + CONVERT(nvarchar(1), @PlanOnly);
    /* #107: Always include key filter params for historical audit (even at default values) */
    SET @invocation_command += N', @LookbackDays = ' + CONVERT(nvarchar(10), @LookbackDays);
    SET @invocation_command += N', @TopN = ' + CONVERT(nvarchar(10), @TopN);
    SET @invocation_command += N', @MinPages = ' + CONVERT(nvarchar(20), @MinPages);
    IF @MaxPages IS NOT NULL
        SET @invocation_command += N', @MaxPages = ' + CONVERT(nvarchar(20), @MaxPages);
    SET @invocation_command += N', @MinForwardedPct = ' + CONVERT(nvarchar(10), @MinForwardedPct);
    IF @IncludeHealthyHeaps = 1
        SET @invocation_command += N', @IncludeHealthyHeaps = 1';
    IF @SkipWriteHeavy = 1
        SET @invocation_command += N', @SkipWriteHeavy = 1';
    IF @MinDaysSinceRebuild IS NOT NULL
        SET @invocation_command += N', @MinDaysSinceRebuild = ' + CONVERT(nvarchar(10), @MinDaysSinceRebuild);
    IF @CpuSourceUpper <> N'QUERY_STORE'
        SET @invocation_command += N', @CpuSource = N''' + @CpuSourceUpper + N'''';
    IF UPPER(@OnlinePreference) <> N'AUTO'
        SET @invocation_command += N', @OnlinePreference = N''' + UPPER(@OnlinePreference) + N'''';
    IF @AllowCiSwap = 1
        SET @invocation_command += N', @AllowCiSwap = 1';
    IF @PreferCiSwap = 1
        SET @invocation_command += N', @PreferCiSwap = 1';
    IF @Maxdop IS NOT NULL
        SET @invocation_command += N', @Maxdop = ' + CONVERT(nvarchar(10), @Maxdop);
    IF @LockTimeoutMs IS NOT NULL
        SET @invocation_command += N', @LockTimeoutMs = ' + CONVERT(nvarchar(10), @LockTimeoutMs);
    IF @MaxRunSeconds IS NOT NULL
        SET @invocation_command += N', @MaxRunSeconds = ' + CONVERT(nvarchar(10), @MaxRunSeconds);
    IF @ScanThrottleMs IS NOT NULL
        SET @invocation_command += N', @ScanThrottleMs = ' + CONVERT(nvarchar(10), @ScanThrottleMs);
    IF @LogToTable <> N'Y'
        SET @invocation_command += N', @LogToTable = N''' + @LogToTable + N'''';
    IF @EstimateTime = 1
        SET @invocation_command += N', @EstimateTime = 1';
    IF @EstimateLookbackDays <> 90
        SET @invocation_command += N', @EstimateLookbackDays = ' + CONVERT(nvarchar(10), @EstimateLookbackDays);
    IF @ObfuscateKey IS NOT NULL
        SET @invocation_command += N', @ObfuscateKey = N''***''';
    IF @ObfuscateSeed IS NOT NULL
        SET @invocation_command += N', @ObfuscateSeed = N''' + REPLACE(@ObfuscateSeed, N'''', N'''''') + N'''';
    IF @ResumeRunID IS NOT NULL
        SET @invocation_command += N', @ResumeRunID = ''' + CONVERT(nvarchar(36), @ResumeRunID) + N'''';
    IF @FillFactor > 0
        SET @invocation_command += N', @FillFactor = ' + CONVERT(nvarchar(3), @FillFactor);
    IF @UpdateStatsAfterRebuild = 1
        SET @invocation_command += N', @UpdateStatsAfterRebuild = 1';
    IF @AllowReplicationRebuild = 1
        SET @invocation_command += N', @AllowReplicationRebuild = 1';
    IF @CheckPermissionsOnly = 1
        SET @invocation_command += N', @CheckPermissionsOnly = 1';
    IF @BaselineRebuildMBPerMin IS NOT NULL
        SET @invocation_command += N', @BaselineRebuildMBPerMin = ' + CONVERT(nvarchar(10), @BaselineRebuildMBPerMin);
    IF @Force = 1
        SET @invocation_command += N', @Force = 1';
    IF @OutputTable IS NOT NULL
        SET @invocation_command += N', @OutputTable = N''' + REPLACE(@OutputTable, N'''', N'''''') + N'''';
    IF @GenerateScript = 1
        SET @invocation_command += N', @GenerateScript = 1';
    IF @IncludeTemporalHistory = 1
        SET @invocation_command += N', @IncludeTemporalHistory = 1';
    IF @UseResumable = 0
        SET @invocation_command += N', @UseResumable = 0';
    IF @ScanMode <> N'SAMPLED'
        SET @invocation_command += N', @ScanMode = N''' + @ScanMode + N'''';
    SET @invocation_command += N';';

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
    SET @Msg = N'Scan mode:   ' + @ScanMode
             + CASE @ScanMode
                   WHEN N'SAMPLED' THEN N' (forwarded record counts are estimates)'
                   WHEN N'DETAILED' THEN N' (accurate counts, slower scan)'
                   WHEN N'LIMITED' THEN N' (allocation pages only, coarse fragmentation)'
                   ELSE N'' END;
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;

    /* #65: Deprecation advisory for sp_trace_generateevent on SQL 2022+ */
    IF CONVERT(integer, SERVERPROPERTY(N'ProductMajorVersion')) >= 16
        RAISERROR(N'ADVISORY: sp_trace_generateevent (SQL Trace) is deprecated in SQL 2022+. See tools/sp_HeapDoctor_XE_Session.sql for Extended Events monitoring.', 10, 1) WITH NOWAIT;

    /* Resume mode flag (set to 1 when @ResumeRunID loads targets from CommandLog) */
    DECLARE @resume_loaded bit = 0;
    DECLARE @resume_xml xml = NULL;

    /*-------------------------------------------------------------------------- */
    /* Merge @ExcludeDatabases / @ExcludeTables into @Databases / @Tables. */
    /* These are written AFTER @invocation_command so the audit log preserves */
    /* the user's original (separate) param values, while the downstream */
    /* recursive-CTE parsers (regions 07/08) see a single combined list. */
    /*-------------------------------------------------------------------------- */
    IF @ExcludeDatabases IS NOT NULL
    BEGIN
        DECLARE @ExcludeDbTail nvarchar(max) = N'';
        SELECT @ExcludeDbTail = STRING_AGG(N', -' + LTRIM(RTRIM(value)), N'')
        FROM STRING_SPLIT(@ExcludeDatabases, N',')
        WHERE LTRIM(RTRIM(value)) <> N'';
        IF @Databases IS NULL
            SET @Databases = N'USER_DATABASES';
        SET @Databases = @Databases + ISNULL(@ExcludeDbTail, N'');
    END

    IF @ExcludeTables IS NOT NULL
    BEGIN
        DECLARE @ExcludeTblTail nvarchar(max) = N'';
        SELECT @ExcludeTblTail = STRING_AGG(N', -' + LTRIM(RTRIM(value)), N'')
        FROM STRING_SPLIT(@ExcludeTables, N',')
        WHERE LTRIM(RTRIM(value)) <> N'';
        IF @Tables IS NULL
            SET @Tables = N'%';
        SET @Tables = @Tables + ISNULL(@ExcludeTblTail, N'');
    END

/*#endregion 06-ENVIRONMENT */

/*#region 07-DATABASES-PARSE /* @Databases recursive CTE parser */ */
    /*-------------------------------------------------------------------------- */
    /* Parse @Databases (Ola Hallengren pattern) */
    /* Supports: USER_DATABASES, ALL_DATABASES, SYSTEM_DATABASES, */
    /*           AVAILABILITY_GROUP_DATABASES, wildcards (%), exclusions (-), */
    /*           comma-separated list */
    /*-------------------------------------------------------------------------- */
    DECLARE @SelectedDatabases TABLE
    (
        DatabaseItem          nvarchar(256) NOT NULL,
        DatabaseType          char(1)       NULL, /* S=system, U=user */
        AvailabilityGroup     bit           NULL,
        StartPosition         integer           NOT NULL,
        Selected              bit           NOT NULL
    );

    DECLARE @tmpDatabases TABLE
    (
        ID                    integer           IDENTITY(1,1) NOT NULL PRIMARY KEY,
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
        0, /* Selected */
        0 /* Completed */
    FROM sys.databases AS d
    WHERE d.name <> N'tempdb'
    AND   d.source_database_id IS NULL
    AND   d.state = 0
    AND   d.is_read_only = 0
    AND   NOT EXISTS
    (
        /* Exclude AG secondary replicas (cannot rebuild on secondary) */
        SELECT 1
        FROM sys.dm_hadr_database_replica_states AS drs
        WHERE drs.database_id = d.database_id
        AND   drs.is_local = 1
        AND   drs.is_primary_replica = 0
    );

    /* Apply inclusions */
    UPDATE td
    SET td.Selected = sd.Selected
    FROM @tmpDatabases AS td
    INNER JOIN @SelectedDatabases AS sd
        ON td.DatabaseName LIKE REPLACE(sd.DatabaseItem, N'_', N'[_]')
        AND (td.DatabaseType = sd.DatabaseType OR sd.DatabaseType IS NULL)
        AND (td.AvailabilityGroup = sd.AvailabilityGroup OR sd.AvailabilityGroup IS NULL)
    WHERE sd.Selected = 1;

    /* Apply exclusions (must come after inclusions) */
    UPDATE td
    SET td.Selected = sd.Selected
    FROM @tmpDatabases AS td
    INNER JOIN @SelectedDatabases AS sd
        ON td.DatabaseName LIKE REPLACE(sd.DatabaseItem, N'_', N'[_]')
        AND (td.DatabaseType = sd.DatabaseType OR sd.DatabaseType IS NULL)
        AND (td.AvailabilityGroup = sd.AvailabilityGroup OR sd.AvailabilityGroup IS NULL)
    WHERE sd.Selected = 0;

    /* Default to current database if @Databases is NULL */
    IF @Databases IS NULL
    BEGIN
        UPDATE @tmpDatabases SET Selected = 1 WHERE DatabaseName = DB_NAME();
    END

    DECLARE @DatabaseCount integer;
    SELECT @DatabaseCount = COUNT_BIG(*) FROM @tmpDatabases WHERE Selected = 1;

    IF @DatabaseCount = 0
    BEGIN
        RAISERROR(N'No databases matched the @Databases pattern.', 16, 1);
        EXEC sp_releaseapplock @Resource = N'sp_HeapDoctor', @LockOwner = N'Session';
        RETURN;
    END

    SET @Msg = N'Databases:   ' + CONVERT(nvarchar(10), @DatabaseCount) + N' selected';
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;

    IF @Tables IS NOT NULL
    BEGIN
        /* Escape % as %% for RAISERROR format-string safety */
        SET @Msg = N'Tables:      filtered (' + REPLACE(@Tables, N'%', N'%%') + N')';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    END

    IF @Debug = 1
    BEGIN
        RAISERROR(N'', 10, 1) WITH NOWAIT;
        DECLARE @dbg_CanOnline integer = CONVERT(integer, @CanOnline), @dbg_Online integer = CONVERT(integer, @Online);
        RAISERROR(N'[DEBUG] EngineEdition = %d, CanOnline = %d, Online = %d', 10, 1, @EngineEdition, @dbg_CanOnline, @dbg_Online) WITH NOWAIT;

        /* #24: Hardware context for troubleshooting */
        BEGIN TRY
            DECLARE @dbg_schedulers integer, @dbg_memory_gb integer, @dbg_numa integer;
            DECLARE @dbg_uptime_hrs decimal(10,1);
            SELECT @dbg_schedulers = cpu_count,
                   @dbg_memory_gb = CONVERT(integer, physical_memory_kb / 1048576.0),
                   @dbg_numa = ISNULL(numa_node_count, 1),
                   @dbg_uptime_hrs = CONVERT(decimal(10,1), DATEDIFF(MINUTE, sqlserver_start_time, GETUTCDATE()) / 60.0)
            FROM sys.dm_os_sys_info;
            RAISERROR(N'[DEBUG] Schedulers = %d, Physical Memory = %d GB, NUMA nodes = %d', 10, 1, @dbg_schedulers, @dbg_memory_gb, @dbg_numa) WITH NOWAIT;
            SET @Msg = N'[DEBUG] SQL uptime = ' + CONVERT(nvarchar(20), @dbg_uptime_hrs) + N' hours';
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        END TRY
        BEGIN CATCH
            RAISERROR(N'[DEBUG] Hardware info unavailable.', 10, 1) WITH NOWAIT;
        END CATCH

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

/*#endregion 07-DATABASES-PARSE */

/*#region 08-TABLES-PARSE /* @Tables recursive CTE parser, #SelectedTables */ */
    /*-------------------------------------------------------------------------- */
    /* Parse @Tables (Ola Hallengren pattern) */
    /* Supports: schema.table, wildcards (%), exclusions (-), comma-separated. */
    /* Schema is optional; if omitted, defaults to % (any schema). */
    /* #SelectedTables is visible inside sp_executesql discovery SQL. */
    /*-------------------------------------------------------------------------- */
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
            /* Extract exclusion prefix (-) */
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
            /* Split schema.table on dot; default schema to % if not specified */
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
            DECLARE @tbl_include_count integer, @tbl_exclude_count integer;
            SELECT @tbl_include_count = SUM(CASE WHEN Selected = 1 THEN 1 ELSE 0 END),
                   @tbl_exclude_count = SUM(CASE WHEN Selected = 0 THEN 1 ELSE 0 END)
            FROM #SelectedTables;
            SET @Msg = N'[DEBUG] @Tables: ' + CONVERT(nvarchar(10), @tbl_include_count) + N' include pattern(s), '
                     + CONVERT(nvarchar(10), @tbl_exclude_count) + N' exclude pattern(s)';
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        END
    END

/*#endregion 08-TABLES-PARSE */

/*#region 09-TEMP-TABLES /* #Targets and #ExecLog creation */ */
    /*-------------------------------------------------------------------------- */
    /* Temp tables (shared across database iterations) */
    /*-------------------------------------------------------------------------- */
    IF OBJECT_ID('tempdb..#Targets') IS NOT NULL DROP TABLE #Targets;

    CREATE TABLE #Targets
    (
        target_id                integer            IDENTITY(1,1) NOT NULL PRIMARY KEY,
        database_name            sysname        NOT NULL,
        object_id                integer            NOT NULL,
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
        nci_count                integer            NOT NULL DEFAULT 0,
        key_source_index         sysname        NULL,
        temp_key_cols            nvarchar(max)  NULL,
        has_lob_columns          bit            NOT NULL DEFAULT 0,
        action_chosen            varchar(32)    NOT NULL,
        command_text             nvarchar(max)  NOT NULL,
        ci_drop_command          nvarchar(max)  NULL,
        est_pages_per_sec        float          NULL,
        est_seconds              integer            NULL,
        est_duration             nvarchar(20)   NULL,
        qs_snapshot_time_utc     datetime2(3)   NULL,
        qs_total_logical_reads   bigint         NULL,
        qs_total_physical_reads  bigint         NULL,
        qs_total_duration_ms     bigint         NULL,
        qs_total_executions      bigint         NULL,
        qs_plan_count            integer            NULL,
        qs_query_count           integer            NULL,
        qs_query_hashes          nvarchar(max)  NULL,
        usage_hint               varchar(30)    NULL,
        ranking_score            decimal(8,4)   NULL,
        heap_compression         tinyint        NOT NULL DEFAULT 0,
        replication_hint         varchar(20)    NULL,
        lock_escalation          tinyint        NOT NULL DEFAULT 0,
        partition_count          integer            NOT NULL DEFAULT 1,
        has_schema_bound_views   bit            NOT NULL DEFAULT 0,
        has_indexed_views        bit            NOT NULL DEFAULT 0,
        data_space_name          sysname        NULL,
        has_fk_references        bit            NOT NULL DEFAULT 0,
        fk_ref_count             integer            NOT NULL DEFAULT 0,
        page_io_latch_wait_count bigint         NULL,
        page_io_latch_wait_ms    bigint         NULL,
        filtered_nci_count       integer            NOT NULL DEFAULT 0, /* #99: filtered NCIs on this heap */
        is_temporal_history      bit            NOT NULL DEFAULT 0, /* #84: temporal history table */
        temporal_parent_schema   sysname        NULL, /* #84: parent versioned table schema */
        temporal_parent_table    sysname        NULL, /* #84: parent versioned table name */
        verify_command           nvarchar(max)  NULL,
        prev_forwarded_pct       decimal(6,2)   NULL,
        rebuilds_in_90d          integer            NULL,
        size_mb                  decimal(18,2)  NULL,
        est_space_savings_mb     decimal(18,2)  NULL,
        est_ci_swap_overhead_mb  decimal(18,2)  NULL,
        est_log_mb               decimal(18,2)  NULL,
        days_since_last_rebuild  integer            NULL,
        sort_order               integer            NOT NULL DEFAULT 0,
        /* Obfuscation: pseudo_ columns hold pseudonyms when @ObfuscateKey is provided. */
        /* Real columns remain untouched for TOCTOU checks, execution, and RAISERROR. */
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
        target_id     integer           NOT NULL,
        database_name sysname       NOT NULL,
        full_name     nvarchar(512) NOT NULL,
        action        varchar(32)   NOT NULL,
        start_time    datetime2(3)  NOT NULL,
        end_time      datetime2(3)  NULL,
        succeeded     bit           NULL,
        error_number  integer           NULL,
        error_message nvarchar(4000) NULL
    );

/*#endregion 09-TEMP-TABLES */

/*#region 10-RESUME-LOAD /* @ResumeRunID loading from HEAP_SCAN_SUMMARY XML */ */
    /*-------------------------------------------------------------------------- */
    /* @ResumeRunID: load targets from a prior plan-only HEAP_SCAN_SUMMARY */
    /*-------------------------------------------------------------------------- */
    IF @ResumeRunID IS NOT NULL
    BEGIN
        /* Mutual exclusivity */
        IF @RevealKey IS NOT NULL
        BEGIN
            RAISERROR(N'@ResumeRunID and @RevealKey cannot be used together.', 16, 1);
            EXEC sp_releaseapplock @Resource = N'sp_HeapDoctor', @LockOwner = N'Session';
            RETURN;
        END

        /* CommandLog must exist */
        IF @commandlog_exists = 0
        BEGIN
            RAISERROR(N'@ResumeRunID requires dbo.CommandLog (stores the plan-only scan results).', 16, 1);
            EXEC sp_releaseapplock @Resource = N'sp_HeapDoctor', @LockOwner = N'Session';
            RETURN;
        END

        /* Look up HEAP_SCAN_SUMMARY by RunID */
        DECLARE @resume_scan_time datetime2(3);
        SELECT TOP (1) @resume_xml = ExtendedInfo, @resume_scan_time = StartTime
        FROM dbo.CommandLog
        WHERE CommandType = N'HEAP_SCAN_SUMMARY'
          AND ExtendedInfo.exist(N'/ScanSummary/RunID[text()=sql:variable("@ResumeRunID")]') = 1
        ORDER BY ID DESC;

        IF @resume_xml IS NULL
        BEGIN
            /* Check if it's an execution run (helpful error) */
            IF EXISTS (
                SELECT 1 FROM dbo.CommandLog
                WHERE CommandType = N'HEAP_REBUILD_START'
                  AND ExtendedInfo.exist(N'/Parameters/RunID[text()=sql:variable("@ResumeRunID")]') = 1
            )
            BEGIN
                SET @Msg = N'RunID ' + CONVERT(nvarchar(36), @ResumeRunID)
                         + N' is an execution run, not a plan-only scan. Use a RunID from a @PlanOnly=1 run.';
                RAISERROR(@Msg, 16, 1);
            END
            ELSE
            BEGIN
                SET @Msg = N'No plan-only scan found for RunID ' + CONVERT(nvarchar(36), @ResumeRunID)
                         + N'. Run sp_HeapDoctor with @PlanOnly=1, @LogToTable=''Y'' first.';
                RAISERROR(@Msg, 16, 1);
            END
            EXEC sp_releaseapplock @Resource = N'sp_HeapDoctor', @LockOwner = N'Session';
            RETURN;
        END

        /* Version match check */
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

        /* Block obfuscated summaries (pseudo names stored, real names needed for execution) */
        IF @resume_xml.exist(N'/ScanSummary/ObfuscatedMappingHex[text()]') = 1
        BEGIN
            RAISERROR(N'Cannot resume from an obfuscated plan-only scan. Run without @ObfuscateKey first.', 16, 1);
            EXEC sp_releaseapplock @Resource = N'sp_HeapDoctor', @LockOwner = N'Session';
            RETURN;
        END

        /* Staleness warning: warn if plan-only scan is > 7 days old */
        IF @resume_scan_time IS NOT NULL AND DATEDIFF(DAY, @resume_scan_time, SYSDATETIME()) > 7
        BEGIN
            SET @Msg = N'WARNING: Resuming RunID ' + CONVERT(nvarchar(36), @ResumeRunID)
                     + N' which was scanned ' + CONVERT(nvarchar(10), DATEDIFF(DAY, @resume_scan_time, SYSDATETIME()))
                     + N' days ago. Forwarded record counts and structural stats may have changed. Consider a fresh scan.';
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        END

        /* Populate #Targets from XML */
        INSERT INTO #Targets WITH (TABLOCK)
        (
            database_name, object_id, schema_name, table_name,
            page_count, record_count, forwarded_record_count, forwarded_pct,
            forwarded_fetch_count, avg_page_space_pct, avg_frag_pct, ghost_record_count,
            total_cpu_ms, ranking_basis, nci_count, key_source_index, has_lob_columns,
            action_chosen, command_text, ci_drop_command, verify_command,
            est_pages_per_sec, est_seconds, est_duration,
            usage_hint, ranking_score,
            heap_compression, replication_hint, lock_escalation,
            partition_count, has_schema_bound_views, has_indexed_views, data_space_name,
            has_fk_references, fk_ref_count,
            page_io_latch_wait_count, page_io_latch_wait_ms,
            is_temporal_history, temporal_parent_schema, temporal_parent_table,
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
            0, /* object_id placeholder (only used during discovery) */
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
            ISNULL(t.c.value(N'@PartitionCount',       N'int'), 1),
            ISNULL(t.c.value(N'@HasSchemaBoundViews',  N'bit'), 0),
            ISNULL(t.c.value(N'@HasIndexedViews',      N'bit'), 0),
            t.c.value(N'@DataSpaceName',        N'sysname'),
            ISNULL(t.c.value(N'@HasFkReferences',      N'bit'), 0),
            ISNULL(t.c.value(N'@FkRefCount',           N'int'), 0),
            t.c.value(N'@PageIoLatchWaitCount',  N'bigint'),
            t.c.value(N'@PageIoLatchWaitMs',     N'bigint'),
            ISNULL(t.c.value(N'@IsTemporalHistory',    N'bit'), 0),
            t.c.value(N'@TemporalParentSchema',  N'sysname'),
            t.c.value(N'@TemporalParentTable',   N'sysname'),
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

        DECLARE @resume_target_count integer = (SELECT COUNT_BIG(*) FROM #Targets);
        DECLARE @resume_cpu_source nvarchar(20) = @resume_xml.value(N'(/ScanSummary/CpuSource)[1]', N'nvarchar(20)');
        DECLARE @resume_db_count integer = @resume_xml.value(N'(/ScanSummary/DatabasesScanned)[1]', N'int');

        RAISERROR(N'', 10, 1) WITH NOWAIT;
        SET @Msg = N'RESUME MODE: loading ' + CONVERT(nvarchar(10), @resume_target_count)
                 + N' target(s) from plan-only RunID=' + CONVERT(nvarchar(36), @ResumeRunID);
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        SET @Msg = N'  Original CPU source: ' + ISNULL(@resume_cpu_source, N'NONE')
                 + N', databases scanned: ' + ISNULL(CONVERT(nvarchar(10), @resume_db_count), N'?');
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;

        IF @Databases IS NOT NULL
            RAISERROR(N'  NOTE: @Databases is ignored in resume mode (targets loaded from prior scan).', 10, 1) WITH NOWAIT;

        /* Apply @Tables filter to resumed targets (post-load filter) */
        IF @Tables IS NOT NULL AND EXISTS (SELECT 1 FROM #SelectedTables)
        BEGIN
            DECLARE @pre_filter_count integer = @resume_target_count;

            /* Include filter: keep only targets matching inclusion patterns */
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

            /* Exclude filter: remove targets matching exclusion patterns */
            DELETE t FROM #Targets t
            WHERE EXISTS (
                SELECT 1 FROM #SelectedTables st
                WHERE st.Selected = 0
                  AND t.schema_name LIKE REPLACE(st.SchemaPattern, N'_', N'[_]')
                  AND t.table_name  LIKE REPLACE(st.TablePattern,  N'_', N'[_]')
            );

            DECLARE @post_filter_count integer = (SELECT COUNT_BIG(*) FROM #Targets);
            IF @post_filter_count < @pre_filter_count
            BEGIN
                DECLARE @tables_safe nvarchar(4000) = REPLACE(@Tables, N'%', N'%%');
                SET @Msg = N'  @Tables filter applied: ' + CONVERT(nvarchar(10), @pre_filter_count)
                         + N' -> ' + CONVERT(nvarchar(10), @post_filter_count)
                         + N' target(s) (' + @tables_safe + N')';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            END
        END

        /* Apply @TopN limit to resumed targets (keep top N by sort_order) */
        IF @TopN IS NOT NULL
        BEGIN
            DECLARE @pre_topn_count integer = (SELECT COUNT_BIG(*) FROM #Targets);
            IF @pre_topn_count > @TopN
            BEGIN
                DELETE FROM #Targets
                WHERE sort_order > (
                    SELECT sort_order FROM (
                        SELECT sort_order, ROW_NUMBER() OVER (ORDER BY sort_order) AS rn
                        FROM #Targets
                    ) ranked WHERE rn = @TopN
                );

                SET @Msg = N'  @TopN filter applied: ' + CONVERT(nvarchar(10), @pre_topn_count)
                         + N' -> ' + CONVERT(nvarchar(10), @TopN) + N' target(s)';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            END
        END

        /* Apply @MinDaysSinceRebuild to resumed targets (uses days_since_last_rebuild from XML) */
        IF @MinDaysSinceRebuild IS NOT NULL
        BEGIN
            DECLARE @pre_mdsrb_cnt integer = (SELECT COUNT_BIG(*) FROM #Targets);
            DELETE FROM #Targets
            WHERE days_since_last_rebuild IS NOT NULL
              AND days_since_last_rebuild < @MinDaysSinceRebuild;

            DECLARE @post_mdsrb_cnt integer = (SELECT COUNT_BIG(*) FROM #Targets);
            IF @post_mdsrb_cnt < @pre_mdsrb_cnt
            BEGIN
                SET @Msg = N'  @MinDaysSinceRebuild filter applied: ' + CONVERT(nvarchar(10), @pre_mdsrb_cnt)
                         + N' -> ' + CONVERT(nvarchar(10), @post_mdsrb_cnt)
                         + N' target(s) (threshold: ' + CONVERT(nvarchar(10), @MinDaysSinceRebuild) + N' days)';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            END
        END

        RAISERROR(N'', 10, 1) WITH NOWAIT;
    END

/*#endregion 10-RESUME-LOAD */

/*#region 11-UPTIME /* sqlserver_start_time, uptime normalization */ */
    /*-------------------------------------------------------------------------- */
    /* Uptime capture (always, for result set context and fetch-rate normalization) */
    /*-------------------------------------------------------------------------- */
    DECLARE @UptimeHours float;
    DECLARE @SqlServerStartTime datetime;
    SELECT @SqlServerStartTime = sqlserver_start_time,
           @UptimeHours = DATEDIFF(SECOND, sqlserver_start_time, GETUTCDATE()) / 3600.0
    FROM sys.dm_os_sys_info;
    /* Guard: minimum 1 hour to avoid division-by-near-zero on fresh restarts */
    SET @UptimeHours = CASE WHEN @UptimeHours < 1.0 THEN 1.0 ELSE @UptimeHours END;

/*#endregion 11-UPTIME */

/*#region 12-DISCOVERY /* Per-database discovery loop (dynamic SQL) */ */
    /*-------------------------------------------------------------------------- */
    /* Per-database discovery loop (skipped in resume mode) */
    /*-------------------------------------------------------------------------- */
    IF @resume_loaded = 0
    BEGIN
    DECLARE
        @CurrentDatabaseName sysname,
        @CurrentDatabaseID   integer,
        @discovery_sql       nvarchar(max),
        @discovery_errors    integer = 0;

    /* Per-database scan stats (for HEAP_SCAN_SUMMARY XML) */
    DECLARE @DbScanStats TABLE (
        DatabaseName sysname NOT NULL,
        HeapsFound   integer     NOT NULL DEFAULT 0,
        HeapsQualified integer   NOT NULL DEFAULT 0,
        ScanSeconds  integer     NOT NULL DEFAULT 0
    );
    DECLARE @db_scan_start datetime2(3);
    DECLARE @db_pre_target_count integer;

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

        SET @db_scan_start = SYSDATETIME();
        SET @db_pre_target_count = (SELECT COUNT_BIG(*) FROM #Targets);

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

/* Per-database temp tables (scoped to this sp_executesql call) */
CREATE TABLE #Heaps
(
    object_id              integer           NOT NULL PRIMARY KEY,
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
    lock_escalation        tinyint       NOT NULL DEFAULT 0,
    partition_count        integer           NOT NULL DEFAULT 1, /* #62: partitioned heap detection */
    has_schema_bound_views bit           NOT NULL DEFAULT 0, /* #72: schema-bound views block CI swap */
    has_indexed_views      bit           NOT NULL DEFAULT 0, /* #80: indexed views block CI swap */
    data_space_name        sysname       NULL, /* #26: filegroup for CI swap ON clause */
    has_fk_references      bit           NOT NULL DEFAULT 0, /* #74: FKs referencing this heap */
    fk_ref_count           integer           NOT NULL DEFAULT 0, /* #74: count of FK references TO this heap */
    page_io_latch_wait_count bigint      NULL, /* #22: IO latch waits from operational stats */
    page_io_latch_wait_ms  bigint        NULL, /* #22: IO latch wait time ms */
    filtered_nci_count     integer           NOT NULL DEFAULT 0, /* #99: filtered NCIs on this heap */
    is_temporal_history    bit           NOT NULL DEFAULT 0, /* #84: temporal history table flag */
    temporal_parent_schema sysname       NULL, /* #84: parent versioned table schema */
    temporal_parent_table  sysname       NULL /* #84: parent versioned table name */
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
    object_id            integer            NOT NULL PRIMARY KEY,
    total_cpu_ms         bigint         NOT NULL,
    total_logical_reads  bigint         NOT NULL DEFAULT 0,
    total_physical_reads bigint         NOT NULL DEFAULT 0,
    total_duration_ms    bigint         NOT NULL DEFAULT 0,
    total_executions     bigint         NOT NULL DEFAULT 0,
    plan_count           integer            NOT NULL DEFAULT 0,
    query_count          integer            NOT NULL DEFAULT 0,
    query_hashes         nvarchar(max)  NULL
);

/* 1) Find heaps with forwarded records */
/* Pre-filter: materialize heap object_ids first, then CROSS APPLY physical stats */
/* only for heaps. This avoids scanning non-heap objects. */
DECLARE @Msg_inner nvarchar(4000);

CREATE TABLE #HeapObjects
(
    object_id   integer     NOT NULL PRIMARY KEY,
    schema_name sysname NOT NULL,
    table_name  sysname NOT NULL
);

INSERT INTO #HeapObjects (object_id, schema_name, table_name)
SELECT o.object_id, s.name, o.name
FROM sys.tables o
JOIN sys.schemas s ON o.schema_id = s.schema_id
JOIN sys.indexes ix ON ix.object_id = o.object_id AND ix.type = 0
WHERE o.is_memory_optimized = 0
  AND (o.temporal_type = 0 OR (o.temporal_type = 1 AND @IncludeTemporalHistory_param = 1))
  AND o.is_node = 0 AND o.is_edge = 0
  AND NOT EXISTS (SELECT 1 FROM sys.indexes ci WHERE ci.object_id = o.object_id AND ci.type IN (3,4,5,6))  -- #105: block XML (3), spatial (4), columnstore (5,6)
';
        /* 9I: Ledger table exclusion (SQL 2022+ only; column doesn't exist on older versions) */
        IF CONVERT(integer, SERVERPROPERTY('ProductMajorVersion')) >= 16
            SET @discovery_sql += N'  AND o.ledger_type = 0';

        /* @Tables filter: #SelectedTables is populated at outer scope, visible here. */
        /* When #SelectedTables is empty (@Tables IS NULL), both conditions are no-ops. */
        SET @discovery_sql += N'
  /* Table include filter */
  AND (NOT EXISTS (SELECT 1 FROM #SelectedTables WHERE Selected = 1)
       OR EXISTS (SELECT 1 FROM #SelectedTables st
                  WHERE st.Selected = 1
                  AND s.name LIKE REPLACE(st.SchemaPattern, N''_'', N''[_]'')
                  AND o.name LIKE REPLACE(st.TablePattern, N''_'', N''[_]'')))
  /* Table exclude filter */
  AND NOT EXISTS (SELECT 1 FROM #SelectedTables st
                  WHERE st.Selected = 0
                  AND s.name LIKE REPLACE(st.SchemaPattern, N''_'', N''[_]'')
                  AND o.name LIKE REPLACE(st.TablePattern, N''_'', N''[_]''))';

        SET @discovery_sql += N';

/* #70: Count memory-optimized tables excluded from discovery */
DECLARE @MemOptCount integer = (SELECT COUNT_BIG(*) FROM sys.tables WHERE is_memory_optimized = 1);
DECLARE @HeapTableCount integer = (SELECT COUNT_BIG(*) FROM #HeapObjects);
SET @Msg_inner = N''  '' + CONVERT(nvarchar(10), @HeapTableCount) + N'' heap table(s) to scan (non-heap objects skipped).'';
IF @MemOptCount > 0
    SET @Msg_inner = @Msg_inner + N'' ('' + CONVERT(nvarchar(10), @MemOptCount) + N'' memory-optimized table(s) excluded)'';
RAISERROR(@Msg_inner, 10, 1) WITH NOWAIT;

SET ANSI_WARNINGS OFF; /* suppress "Null value is eliminated by an aggregate" from DMV aggregation */

INSERT INTO #Heaps (object_id, schema_name, table_name, page_count, record_count, forwarded_record_count, forwarded_pct, avg_page_space_pct, avg_frag_pct, ghost_record_count, forwarded_fetch_count, user_seeks, user_scans, user_lookups, user_updates, heap_compression, replication_hint, lock_escalation, partition_count, has_schema_bound_views, has_indexed_views, data_space_name, has_fk_references, fk_ref_count, page_io_latch_wait_count, page_io_latch_wait_ms)
SELECT
    ho.object_id,
    ho.schema_name,
    ho.table_name,
    ips.page_count,
    ips.record_count,
    ips.forwarded_record_count,
    CONVERT(decimal(6,2), 100.0 * ips.forwarded_record_count / NULLIF(ips.record_count,0)),
    CONVERT(decimal(5,2), ips.avg_page_space_used_in_percent),
    CONVERT(decimal(5,2), ips.avg_fragmentation_in_percent),
    ips.ghost_record_count,
    os.forwarded_fetch_count,
    us.user_seeks,
    us.user_scans,
    us.user_lookups,
    us.user_updates,
    ISNULL(dc.heap_compression, 0),
    /* Replication awareness */
    CASE
        WHEN tp.is_published = 1 AND tp.is_tracked_by_cdc = 1 THEN N''PUBLISHED_CDC''
        WHEN tp.is_merge_published = 1 AND tp.is_tracked_by_cdc = 1 THEN N''MERGE_PUB_CDC''
        WHEN tp.is_published = 1 THEN N''PUBLISHED''
        WHEN tp.is_merge_published = 1 THEN N''MERGE_PUBLISHED''
        WHEN tp.is_tracked_by_cdc = 1 THEN N''CDC''
        ELSE NULL
    END,
    ISNULL(tp.lock_escalation, 0),
    /* #62: Partition count for partitioned heap detection */
    ISNULL(pc.partition_count, 1),
    /* #72: Schema-bound views referencing this heap */
    ISNULL(sbv.has_schema_bound_views, 0),
    /* #80: Indexed views referencing this heap */
    ISNULL(ixv.has_indexed_views, 0),
    /* #26: Filegroup name for CI swap ON clause */
    fg.filegroup_name,
    /* #74: Foreign key references TO this heap */
    ISNULL(fkr.has_fk_references, 0),
    ISNULL(fkr.fk_ref_count, 0),
    /* #22: IO latch wait stats from operational stats */
    os.page_io_latch_wait_count,
    os.page_io_latch_wait_in_ms
FROM #HeapObjects ho
CROSS APPLY (
    /* Aggregate per-partition rows for partitioned heaps. */
    /* dm_db_index_physical_stats returns one row per partition when partition_number=NULL. */
    SELECT
        SUM(page_count) AS page_count,
        SUM(record_count) AS record_count,
        SUM(forwarded_record_count) AS forwarded_record_count,
        AVG(avg_page_space_used_in_percent) AS avg_page_space_used_in_percent,
        AVG(avg_fragmentation_in_percent) AS avg_fragmentation_in_percent,
        SUM(ghost_record_count) AS ghost_record_count
    FROM sys.dm_db_index_physical_stats(DB_ID(), ho.object_id, 0, NULL, @ScanMode_param)
) ips
OUTER APPLY (
    SELECT SUM(forwarded_fetch_count) AS forwarded_fetch_count,
           SUM(page_io_latch_wait_count) AS page_io_latch_wait_count,
           SUM(page_io_latch_wait_in_ms) AS page_io_latch_wait_in_ms
    FROM sys.dm_db_index_operational_stats(DB_ID(), ho.object_id, 0, NULL)
) os
OUTER APPLY (
    SELECT user_seeks, user_scans, user_lookups, user_updates
    FROM sys.dm_db_index_usage_stats
    WHERE database_id = DB_ID() AND object_id = ho.object_id AND index_id = 0
) us
OUTER APPLY (
    /* Heap compression: 0=NONE, 1=ROW, 2=PAGE. */
    /* MAX across partitions for partitioned heaps with mixed compression. */
    SELECT MAX(data_compression) AS heap_compression
    FROM sys.partitions
    WHERE object_id = ho.object_id AND index_id = 0
) dc
OUTER APPLY (
    /* Table properties for replication awareness and lock escalation. */
    SELECT t.is_published, t.is_merge_published, t.is_tracked_by_cdc, t.lock_escalation
    FROM sys.tables t
    WHERE t.object_id = ho.object_id
) tp
OUTER APPLY (
    /* #62: Count partitions for partitioned heap detection. */
    SELECT COUNT_BIG(*) AS partition_count
    FROM sys.partitions
    WHERE object_id = ho.object_id AND index_id = 0
) pc
OUTER APPLY (
    /* #72: Detect schema-bound views referencing this table (CI swap DDL will fail). */
    SELECT CONVERT(bit, CASE WHEN EXISTS (
        SELECT 1 FROM sys.sql_expression_dependencies sed
        JOIN sys.views v ON sed.referencing_id = v.object_id
        WHERE sed.referenced_id = ho.object_id
          AND OBJECTPROPERTY(v.object_id, N''IsSchemaBound'') = 1
    ) THEN 1 ELSE 0 END) AS has_schema_bound_views
) sbv
OUTER APPLY (
    /* #80: Detect indexed views referencing this table (CI swap may fail or be slow). */
    SELECT CONVERT(bit, CASE WHEN EXISTS (
        SELECT 1 FROM sys.sql_expression_dependencies sed
        JOIN sys.views v ON sed.referencing_id = v.object_id
        JOIN sys.indexes i ON i.object_id = v.object_id AND i.type = 1
        WHERE sed.referenced_id = ho.object_id
    ) THEN 1 ELSE 0 END) AS has_indexed_views
) ixv
OUTER APPLY (
    /* #26: Filegroup name for the heap (index_id=0). CI swap must land on same filegroup. */
    SELECT ds.name AS filegroup_name
    FROM sys.indexes i
    JOIN sys.data_spaces ds ON i.data_space_id = ds.data_space_id
    WHERE i.object_id = ho.object_id AND i.index_id = 0
) fg
OUTER APPLY (
    /* #74: Foreign keys referencing this heap (the heap is the referenced/parent table). */
    /* CI swap changes the row locator from RID to CI key; FK lookups may change performance. */
    SELECT
        CONVERT(bit, CASE WHEN COUNT_BIG(*) > 0 THEN 1 ELSE 0 END) AS has_fk_references,
        COUNT_BIG(*) AS fk_ref_count
    FROM sys.foreign_keys fk
    WHERE fk.referenced_object_id = ho.object_id
) fkr
WHERE (@IncludeHealthyHeaps_param = 1 OR ips.forwarded_record_count > 0)
  AND ips.page_count >= @MinPages_param
  AND (@MaxPages_param IS NULL OR ips.page_count <= @MaxPages_param)
  AND (@IncludeHealthyHeaps_param = 1
       OR (100.0 * ips.forwarded_record_count / NULLIF(ips.record_count,0)) >= @MinForwardedPct_param);

SET ANSI_WARNINGS ON;

/* #84: Populate temporal parent info for history table heaps */
IF @IncludeTemporalHistory_param = 1
BEGIN
    UPDATE h SET
        h.is_temporal_history = 1,
        h.temporal_parent_schema = ps.name,
        h.temporal_parent_table = pt.name
    FROM #Heaps h
    JOIN sys.tables ht ON ht.object_id = h.object_id AND ht.temporal_type = 1
    JOIN sys.tables pt ON pt.history_table_id = h.object_id AND pt.temporal_type = 2
    JOIN sys.schemas ps ON pt.schema_id = ps.schema_id;
END

DROP TABLE #HeapObjects;

DECLARE @HeapCount_inner integer = (SELECT COUNT_BIG(*) FROM #Heaps);
SET @Msg_inner = N''  Found '' + CONVERT(nvarchar(10), @HeapCount_inner) + N'' heap(s) with forwarded records.'';
RAISERROR(@Msg_inner, 10, 1) WITH NOWAIT;

IF @HeapCount_inner = 0 RETURN;

/* Create #PlanObjMap unconditionally (referenced in Ranked CTE and forced plan cursors). */
/* Only populated when CpuSource = QUERY_STORE. */
CREATE TABLE #PlanObjMap
(
    plan_id      bigint   NOT NULL,
    query_id     bigint   NOT NULL,
    query_hash   binary(8) NOT NULL,
    schema_name  sysname  NOT NULL,
    table_name   sysname  NOT NULL
);
';

        /* 2) CPU source (conditional) */
        /* Two-phase approach: structural ranking first, QS enrichment after INSERT INTO #Targets. */
        /* QS state detection runs before the Ranked CTE (cheap), heavy XML parsing runs after. */
        IF @CpuSourceUpper = 'QUERY_STORE'
        BEGIN
            SET @discovery_sql += N'
/* 2) QS state detection (lightweight, before ranking) */
DECLARE @QsActualState nvarchar(60);
DECLARE @QsDesiredState nvarchar(60);
DECLARE @QsRetentionDays integer;
DECLARE @QsRw bit = 0;

SELECT
    @QsActualState  = actual_state_desc,
    @QsDesiredState = desired_state_desc,
    @QsRetentionDays = stale_query_threshold_days
FROM sys.database_query_store_options;

SET @QsRw = CASE WHEN @QsActualState = ''READ_WRITE'' THEN 1 ELSE 0 END;

IF @QsActualState = ''READ_ONLY'' AND @QsDesiredState = ''READ_WRITE''
BEGIN
    RAISERROR(N''  WARNING: Query Store is READ_ONLY (desired READ_WRITE). Data may be stale - check MAX_STORAGE_SIZE_MB.'', 10, 1) WITH NOWAIT;
    SET @QsRw = 1;
END
ELSE IF @QsActualState NOT IN (''READ_WRITE'', ''READ_ONLY'')
BEGIN
    RAISERROR(N''  WARNING: Query Store is not active (state: %s). CPU data unavailable.'', 10, 1, @QsActualState) WITH NOWAIT;
END

IF @QsRw = 1 AND @QsRetentionDays IS NOT NULL AND @LookbackDays_param > @QsRetentionDays
BEGIN
    DECLARE @QsRetMsg nvarchar(200) = N''  WARNING: @LookbackDays ('' + CONVERT(nvarchar(10), @LookbackDays_param)
        + N'') exceeds QS retention ('' + CONVERT(nvarchar(10), @QsRetentionDays) + N'' days). Results limited to actual retention.'';
    RAISERROR(@QsRetMsg, 10, 1) WITH NOWAIT;
END

IF @QsRw = 0
    RAISERROR(N''  Query Store not READ_WRITE; ranking by forwarded_pct only.'', 10, 1) WITH NOWAIT;
/* Heavy QS XML parsing deferred to after INSERT INTO #Targets (two-phase ranking) */
';
        END
        ELSE IF @CpuSourceUpper = 'NONE'
        BEGIN
            SET @discovery_sql += N'
/* 2) No CPU source; ranking by forwarded_pct only */
DECLARE @QsRw bit = 0;
';
        END
        ELSE /* QUICKIESTORE is handled separately below (not per-database dynamic SQL) */
        BEGIN
            SET @discovery_sql += N'
/* 2) QUICKIESTORE: CPU handled outside loop; structural ranking only */
DECLARE @QsRw bit = 0;
';
        END

        /* 4-7) Key finder, LOB check, ranking, target generation */
        SET @discovery_sql += N'
/* 4) Build target list: key finder + LOB check + ranking + command generation */
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
        COUNT_BIG(*) AS key_col_count
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
      AND c.is_computed = 0 /* exclude computed columns (#76) */
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
    SELECT object_id, COUNT_BIG(*) AS nci_count
    FROM sys.indexes
    WHERE type = 2
    GROUP BY object_id
),
FilteredNciCounts AS
(
    /* #99: Count filtered NCIs per object for stale-stats warning */
    SELECT object_id, CONVERT(integer, COUNT_BIG(*)) AS filtered_nci_count
    FROM sys.indexes
    WHERE type = 2
      AND has_filter = 1
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
            WHEN @QsRw = 0 THEN ''QS_DISABLED''
            ELSE ''QS_NO_DATA''
        END AS ranking_basis,
        ISNULL(nc.nci_count, 0) AS nci_count,
        bk.index_name AS key_source_index,
        bk.key_cols AS temp_key_cols,
        CASE WHEN lt.object_id IS NOT NULL THEN 1 ELSE 0 END AS has_lob_columns,
        h.heap_compression,
        h.replication_hint,
        h.lock_escalation,
        h.partition_count,
        h.has_schema_bound_views,
        h.has_indexed_views,
        h.data_space_name,
        h.has_fk_references,
        h.fk_ref_count,
        h.page_io_latch_wait_count,
        h.page_io_latch_wait_ms,
        ISNULL(fnc.filtered_nci_count, 0) AS filtered_nci_count,
        h.is_temporal_history,
        h.temporal_parent_schema,
        h.temporal_parent_table,
        /* Leftover temp CI from failed previous run */
        CASE WHEN EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = h.object_id
             AND name = N''CX__Temp__'' + LEFT(h.table_name, 108)) THEN 1 ELSE 0 END AS has_leftover_ci,
        /* 8I: Forced plan check - CI swap invalidates forced plans */
        /* Lightweight LIKE on forced plans only (no XML parsing needed). */
        /* sys.query_store_plan is safe to query when QS is OFF (returns empty set). */
        CASE WHEN @CpuSource_param = N''QUERY_STORE''
             AND EXISTS (SELECT 1 FROM sys.query_store_plan fp
                         WHERE fp.is_forced_plan = 1
                         AND fp.query_plan LIKE N''%Table="[[]'' + h.table_name + N'']%'')
        THEN 1 ELSE 0 END AS has_forced_plans,
        /* QS performance snapshot (NULL when CpuSource=NONE or QS not available) */
        CASE WHEN cbo.object_id IS NOT NULL THEN SYSUTCDATETIME() ELSE NULL END AS qs_snapshot_time_utc,
        cbo.total_logical_reads  AS qs_total_logical_reads,
        cbo.total_physical_reads AS qs_total_physical_reads,
        cbo.total_duration_ms    AS qs_total_duration_ms,
        cbo.total_executions     AS qs_total_executions,
        cbo.plan_count           AS qs_plan_count,
        cbo.query_count          AS qs_query_count,
        cbo.query_hashes         AS qs_query_hashes,
        /* Usage pattern hint (identify staging/ETL heaps) */
        CASE
            WHEN h.user_scans IS NULL AND h.user_seeks IS NULL AND h.user_updates IS NULL THEN NULL
            WHEN ISNULL(h.user_updates, 0) > 0
                 AND (ISNULL(h.user_scans, 0) + ISNULL(h.user_seeks, 0) + ISNULL(h.user_lookups, 0)) = 0
                THEN ''WRITE_ONLY''
            WHEN ISNULL(h.user_updates, 0) > (ISNULL(h.user_scans, 0) + ISNULL(h.user_seeks, 0) + ISNULL(h.user_lookups, 0))
                THEN ''WRITE_HEAVY''
            ELSE NULL
        END AS usage_hint,
        /* LOG10-normalized ranking score: compresses all signals to comparable ~0-10 range. */
        /* Weights: 0.4 fetch_rate + 0.4 CPU + 0.2 structural severity. */
        /* Write-heavy penalty: 0.5 for WRITE_HEAVY, 0.25 for WRITE_ONLY (rebuild ROI is poor). */
        CONVERT(decimal(8,4),
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
        ) AS ranking_score,
        ROW_NUMBER() OVER (ORDER BY
            /* LOG10-normalized weighted score (higher = more impactful) */
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
    LEFT JOIN FilteredNciCounts fnc ON h.object_id = fnc.object_id
)
INSERT INTO #Targets
(
    database_name, object_id, schema_name, table_name, page_count, record_count,
    forwarded_record_count, forwarded_pct, forwarded_fetch_count,
    avg_page_space_pct, avg_frag_pct, ghost_record_count,
    total_cpu_ms, ranking_basis, nci_count,
    key_source_index, temp_key_cols, has_lob_columns, heap_compression,
    replication_hint, lock_escalation,
    partition_count, has_schema_bound_views, has_indexed_views, data_space_name,
    has_fk_references, fk_ref_count,
    page_io_latch_wait_count, page_io_latch_wait_ms,
    filtered_nci_count,
    is_temporal_history, temporal_parent_schema, temporal_parent_table,
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
    r.partition_count, r.has_schema_bound_views, r.has_indexed_views, r.data_space_name,
    r.has_fk_references, r.fk_ref_count,
    r.page_io_latch_wait_count, r.page_io_latch_wait_ms,
    r.filtered_nci_count,
    r.is_temporal_history, r.temporal_parent_schema, r.temporal_parent_table,
    /* action_chosen (8I: forced plans prevent CI swap; #83: CDC blocks CI swap; #62: partitioned heaps skip CI swap; #84: temporal history blocks CI swap) */
    CASE
        WHEN @AllowCiSwap_param = 1 AND @PreferCiSwap_param = 1 AND @Online_param = 1
             AND r.temp_key_cols IS NOT NULL AND r.has_lob_columns = 0
             AND r.has_forced_plans = 0
             AND (r.replication_hint IS NULL OR r.replication_hint NOT LIKE N''%%CDC%%'') /* #83: CDC breaks capture instance */
             AND r.partition_count <= 1 /* #62: partitioned heaps cannot CI swap */
             AND r.has_schema_bound_views = 0 /* #72: schema-bound views block CI swap */
             AND r.has_indexed_views = 0 /* #80: indexed views block CI swap */
             AND r.is_temporal_history = 0 /* #84: temporal history blocks CI swap */
            THEN ''CI_SWAP_ONLINE''
        WHEN @Online_param = 1 THEN ''HEAP_REBUILD_ONLINE''
        ELSE ''HEAP_REBUILD_OFFLINE''
    END,
    /* command_text: preserve heap compression in CI swap and ALTER TABLE REBUILD */
    CASE
        WHEN @AllowCiSwap_param = 1 AND @PreferCiSwap_param = 1 AND @Online_param = 1
             AND r.temp_key_cols IS NOT NULL AND r.has_lob_columns = 0
             AND r.has_forced_plans = 0
             AND (r.replication_hint IS NULL OR r.replication_hint NOT LIKE N''%%CDC%%'')
             AND r.partition_count <= 1
             AND r.has_schema_bound_views = 0
             AND r.has_indexed_views = 0
             AND r.is_temporal_history = 0
        THEN
            /* Leftover temp CI cleanup: prepend DROP if a previous run left a temp CI */
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
            CASE WHEN @FillFactor_param > 0 THEN N'', FILLFACTOR = '' + CONVERT(nvarchar(3), @FillFactor_param) ELSE N'''' END +
            COALESCE(N'', MAXDOP = '' + CONVERT(nvarchar(10), @Maxdop_param), N'''') +
            CASE WHEN @UseResumable_param = 1 THEN N'', RESUMABLE = ON'' ELSE N'''' END + N'')'' +
            /* #26: CI swap must land on same filegroup as the heap */
            CASE WHEN r.data_space_name IS NOT NULL AND r.data_space_name <> N''PRIMARY''
                 THEN N'' ON '' + QUOTENAME(r.data_space_name) ELSE N'''' END + N'';''
        WHEN @Online_param = 1
        THEN
            N''ALTER TABLE '' + QUOTENAME(DB_NAME()) + N''.'' + QUOTENAME(r.schema_name) + N''.'' + QUOTENAME(r.table_name) +
            N'' REBUILD WITH (ONLINE = ON'' +
            CASE WHEN r.heap_compression = 1 THEN N'', DATA_COMPRESSION = ROW''
                 WHEN r.heap_compression = 2 THEN N'', DATA_COMPRESSION = PAGE''
                 ELSE N'''' END +
            COALESCE(N'', MAXDOP = '' + CONVERT(nvarchar(10), @Maxdop_param), N'''') + N'');''
        ELSE
            N''ALTER TABLE '' + QUOTENAME(DB_NAME()) + N''.'' + QUOTENAME(r.schema_name) + N''.'' + QUOTENAME(r.table_name) +
            N'' REBUILD'' +
            CASE WHEN r.heap_compression > 0 OR @Maxdop_param IS NOT NULL
                THEN N'' WITH ('' +
                    CASE WHEN r.heap_compression = 1 THEN N''DATA_COMPRESSION = ROW''
                         WHEN r.heap_compression = 2 THEN N''DATA_COMPRESSION = PAGE''
                         ELSE N'''' END +
                    CASE WHEN r.heap_compression > 0 AND @Maxdop_param IS NOT NULL THEN N'', '' ELSE N'''' END +
                    COALESCE(N''MAXDOP = '' + CONVERT(nvarchar(10), @Maxdop_param), N'''') +
                    N'')''
                ELSE N'''' END +
            N'';''
    END,
    /* ci_drop_command */
    CASE
        WHEN @AllowCiSwap_param = 1 AND @PreferCiSwap_param = 1 AND @Online_param = 1
             AND r.temp_key_cols IS NOT NULL AND r.has_lob_columns = 0
             AND r.has_forced_plans = 0
             AND (r.replication_hint IS NULL OR r.replication_hint NOT LIKE N''%%CDC%%'')
             AND r.partition_count <= 1
             AND r.has_schema_bound_views = 0
             AND r.has_indexed_views = 0
             AND r.is_temporal_history = 0
        THEN
            N''DROP INDEX '' +
            QUOTENAME(N''CX__Temp__'' + LEFT(r.table_name, 108)) +
            N'' ON '' + QUOTENAME(DB_NAME()) + N''.'' + QUOTENAME(r.schema_name) + N''.'' + QUOTENAME(r.table_name) +
            N'' WITH (ONLINE = ON'' +
            COALESCE(N'', MAXDOP = '' + CONVERT(nvarchar(10), @Maxdop_param), N'''') + N'');''
        ELSE NULL
    END,
    /* QS performance snapshot */
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
    /* 8O: Verification command for change management */
    N''SELECT forwarded_record_count FROM sys.dm_db_index_physical_stats(DB_ID(N'''''' + QUOTENAME(DB_NAME()) + N''''''), OBJECT_ID(N'''''' + QUOTENAME(DB_NAME()) + N''.'' + QUOTENAME(r.schema_name) + N''.'' + QUOTENAME(r.table_name) + N''''''), 0, NULL, N''''SAMPLED'''');''
FROM Ranked r
ORDER BY r.target_rank;

SET @Msg_inner = N''  Selected '' + CONVERT(nvarchar(10), ROWCOUNT_BIG()) + N'' target(s).'';
RAISERROR(@Msg_inner, 10, 1) WITH NOWAIT;

/* Replication awareness warnings */
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

/* 8I: Forced plan warning */
/* has_forced_plans in Ranked CTE uses lightweight LIKE on sys.query_store_plan. */
/* If CI_SWAP conditions are met but action_chosen is not CI_SWAP_ONLINE, forced plans caused the downgrade. */
IF @CpuSource_param = N''QUERY_STORE''
   AND @AllowCiSwap_param = 1 AND @PreferCiSwap_param = 1 AND @Online_param = 1
   AND EXISTS (SELECT 1 FROM #Targets t
               WHERE t.database_name = DB_NAME()
                 AND t.action_chosen <> ''CI_SWAP_ONLINE''
                 AND t.temp_key_cols IS NOT NULL
                 AND t.has_lob_columns = 0)
BEGIN
    DECLARE fp_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT t.schema_name, t.table_name FROM #Targets t
        WHERE t.database_name = DB_NAME()
          AND t.action_chosen <> ''CI_SWAP_ONLINE''
          AND t.temp_key_cols IS NOT NULL
          AND t.has_lob_columns = 0;
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

/* #83: CDC CI swap guard warnings */
IF EXISTS (SELECT 1 FROM #Targets WHERE database_name = DB_NAME()
           AND action_chosen <> ''CI_SWAP_ONLINE''
           AND replication_hint LIKE N''%%CDC%%''
           AND temp_key_cols IS NOT NULL AND has_lob_columns = 0)
BEGIN
    DECLARE cdc_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT schema_name, table_name FROM #Targets
        WHERE database_name = DB_NAME()
          AND action_chosen <> ''CI_SWAP_ONLINE''
          AND replication_hint LIKE N''%%CDC%%''
          AND temp_key_cols IS NOT NULL AND has_lob_columns = 0;
    DECLARE @cdc_schema sysname, @cdc_table sysname;
    OPEN cdc_cursor;
    FETCH NEXT FROM cdc_cursor INTO @cdc_schema, @cdc_table;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Msg_inner = N''  WARNING: '' + QUOTENAME(@cdc_schema) + N''.'' + QUOTENAME(@cdc_table)
            + N'' is CDC-tracked. Using heap rebuild instead of CI swap to protect capture instance.'';
        RAISERROR(@Msg_inner, 10, 1) WITH NOWAIT;
        FETCH NEXT FROM cdc_cursor INTO @cdc_schema, @cdc_table;
    END
    CLOSE cdc_cursor;
    DEALLOCATE cdc_cursor;
END

/* #62: Partitioned heap warnings */
IF EXISTS (SELECT 1 FROM #Targets WHERE database_name = DB_NAME()
           AND partition_count > 1
           AND temp_key_cols IS NOT NULL AND has_lob_columns = 0)
BEGIN
    DECLARE pt_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT schema_name, table_name, partition_count FROM #Targets
        WHERE database_name = DB_NAME() AND partition_count > 1
          AND temp_key_cols IS NOT NULL AND has_lob_columns = 0;
    DECLARE @pt_schema sysname, @pt_table sysname, @pt_cnt integer;
    OPEN pt_cursor;
    FETCH NEXT FROM pt_cursor INTO @pt_schema, @pt_table, @pt_cnt;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Msg_inner = N''  WARNING: '' + QUOTENAME(@pt_schema) + N''.'' + QUOTENAME(@pt_table)
            + N'' has '' + CONVERT(nvarchar(10), @pt_cnt) + N'' partitions. Using heap rebuild instead of CI swap.'';
        RAISERROR(@Msg_inner, 10, 1) WITH NOWAIT;
        FETCH NEXT FROM pt_cursor INTO @pt_schema, @pt_table, @pt_cnt;
    END
    CLOSE pt_cursor;
    DEALLOCATE pt_cursor;
END

/* #72/#80: Schema-bound/indexed view warnings */
IF EXISTS (SELECT 1 FROM #Targets WHERE database_name = DB_NAME()
           AND (has_schema_bound_views = 1 OR has_indexed_views = 1)
           AND temp_key_cols IS NOT NULL AND has_lob_columns = 0)
BEGIN
    DECLARE sv_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT schema_name, table_name, has_schema_bound_views, has_indexed_views FROM #Targets
        WHERE database_name = DB_NAME()
          AND (has_schema_bound_views = 1 OR has_indexed_views = 1)
          AND temp_key_cols IS NOT NULL AND has_lob_columns = 0;
    DECLARE @sv_schema sysname, @sv_table sysname, @sv_sb bit, @sv_ix bit;
    OPEN sv_cursor;
    FETCH NEXT FROM sv_cursor INTO @sv_schema, @sv_table, @sv_sb, @sv_ix;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Msg_inner = N''  WARNING: '' + QUOTENAME(@sv_schema) + N''.'' + QUOTENAME(@sv_table)
            + N'' has '' + CASE WHEN @sv_sb = 1 AND @sv_ix = 1 THEN N''schema-bound and indexed views''
                                WHEN @sv_sb = 1 THEN N''schema-bound views''
                                ELSE N''indexed views'' END
            + N''. Using heap rebuild instead of CI swap.'';
        RAISERROR(@Msg_inner, 10, 1) WITH NOWAIT;
        FETCH NEXT FROM sv_cursor INTO @sv_schema, @sv_table, @sv_sb, @sv_ix;
    END
    CLOSE sv_cursor;
    DEALLOCATE sv_cursor;
END

/* #74: FK reference warnings (informational -- FK relationships survive CI swap, but lookup paths change) */
IF EXISTS (SELECT 1 FROM #Targets WHERE database_name = DB_NAME() AND has_fk_references = 1
           AND action_chosen = ''CI_SWAP_ONLINE'')
BEGIN
    DECLARE fk_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT schema_name, table_name, fk_ref_count FROM #Targets
        WHERE database_name = DB_NAME() AND has_fk_references = 1
          AND action_chosen = ''CI_SWAP_ONLINE'';
    DECLARE @fk_schema sysname, @fk_table sysname, @fk_cnt integer;
    OPEN fk_cursor;
    FETCH NEXT FROM fk_cursor INTO @fk_schema, @fk_table, @fk_cnt;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Msg_inner = N''  INFO: '' + QUOTENAME(@fk_schema) + N''.'' + QUOTENAME(@fk_table)
            + N'' has '' + CONVERT(nvarchar(10), @fk_cnt) + N'' foreign key(s) referencing it. ''
            + N''CI swap will change FK lookup path from RID to CI key. Verify FK query performance after rebuild.'';
        RAISERROR(@Msg_inner, 10, 1) WITH NOWAIT;
        FETCH NEXT FROM fk_cursor INTO @fk_schema, @fk_table, @fk_cnt;
    END
    CLOSE fk_cursor;
    DEALLOCATE fk_cursor;
END
';

        /* QS enrichment: after structural ranking + INSERT INTO #Targets, enrich with CPU data. */
        /* Two-phase approach: structural ranking first (fast), QS XML parsing only for targets (bounded). */
        /* plan_hash dedup: TRY_CONVERT once per unique query_plan_hash, fan out to all plan_ids. */
        IF @CpuSourceUpper = 'QUERY_STORE'
        BEGIN
            SET @discovery_sql += N'
/* QS enrichment phase (two-phase ranking: structural first, CPU enrichment second) */
IF @QsRw = 1 AND EXISTS (SELECT 1 FROM #Targets WHERE database_name = DB_NAME())
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
    INSERT INTO #CpuByPlan(plan_id, total_cpu_ms, total_logical_reads, total_physical_reads, total_duration_ms, total_executions)
    SELECT plan_id,
        CONVERT(bigint, total_cpu_us / 1000),
        total_logical_reads,
        total_physical_reads,
        CONVERT(bigint, total_duration_us / 1000),
        total_executions
    FROM CpuByPlan
    WHERE total_cpu_us > 0;
';

            SET @discovery_sql += N'
    IF EXISTS (SELECT 1 FROM #CpuByPlan)
    BEGIN
        /* plan_hash dedup: parse XML once per unique query_plan_hash. */
        /* LIKE pre-filter checks #Targets (max @TopN per db) instead of #Heaps (all heaps). */
        CREATE TABLE #ParsedPlans (query_plan_hash binary(8) NOT NULL PRIMARY KEY, plan_xml xml NULL);

        INSERT INTO #ParsedPlans (query_plan_hash, plan_xml)
        SELECT sub.query_plan_hash, TRY_CONVERT(xml, sub.query_plan)
        FROM (
            SELECT p.query_plan_hash, p.query_plan,
                ROW_NUMBER() OVER (PARTITION BY p.query_plan_hash ORDER BY p.plan_id) AS rn
            FROM sys.query_store_plan p
            JOIN #CpuByPlan cp ON cp.plan_id = p.plan_id
            WHERE EXISTS (SELECT 1 FROM #Targets t
                          WHERE t.database_name = DB_NAME()
                          AND p.query_plan LIKE N''%Table="[[]'' + t.table_name + N'']%'')
        ) sub
        WHERE sub.rn = 1;

        /* XPath extraction: fan out parsed plans to all plan_ids sharing each plan_hash */
        ;WITH XMLNAMESPACES (DEFAULT ''http://schemas.microsoft.com/sqlserver/2004/07/showplan'')
        INSERT INTO #PlanObjMap (plan_id, query_id, query_hash, schema_name, table_name)
        SELECT DISTINCT
            p.plan_id,
            p.query_id,
            q.query_hash,
            REPLACE(REPLACE(obj.value(''@Schema'',''sysname''), N''['', N''''), N'']'', N'''') AS schema_name,
            REPLACE(REPLACE(obj.value(''@Table'', ''sysname''), N''['', N''''), N'']'', N'''') AS table_name
        FROM #ParsedPlans pp
        CROSS APPLY pp.plan_xml.nodes(''//RelOp[@PhysicalOp="Table Scan"]/*/Object[@Schema and @Table]'') AS n(obj)
        JOIN sys.query_store_plan p ON p.query_plan_hash = pp.query_plan_hash
        JOIN #CpuByPlan cp ON cp.plan_id = p.plan_id
        JOIN sys.query_store_query q ON p.query_id = q.query_id
        WHERE pp.plan_xml IS NOT NULL;
';

            SET @discovery_sql += N'
        /* Aggregate metrics by object */
        INSERT INTO #CpuByObject(object_id, total_cpu_ms, total_logical_reads, total_physical_reads, total_duration_ms, total_executions, plan_count, query_count)
        SELECT h.object_id,
            SUM(cp.total_cpu_ms),
            SUM(cp.total_logical_reads),
            SUM(cp.total_physical_reads),
            SUM(cp.total_duration_ms),
            SUM(cp.total_executions),
            COUNT_BIG(DISTINCT pm.plan_id),
            COUNT_BIG(DISTINCT pm.query_id)
        FROM #Heaps h
        JOIN #PlanObjMap pm ON pm.schema_name COLLATE DATABASE_DEFAULT = h.schema_name COLLATE DATABASE_DEFAULT
                           AND pm.table_name  COLLATE DATABASE_DEFAULT = h.table_name  COLLATE DATABASE_DEFAULT
        JOIN #CpuByPlan cp ON cp.plan_id = pm.plan_id
        GROUP BY h.object_id;

        /* Collect distinct query_hash values per heap object */
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
';

            SET @discovery_sql += N'
        /* Enrich #Targets with CPU data from QS */
        UPDATE t
        SET t.total_cpu_ms          = cbo.total_cpu_ms,
            t.ranking_basis         = N''QS_CPU'',
            t.qs_snapshot_time_utc  = SYSUTCDATETIME(),
            t.qs_total_logical_reads  = cbo.total_logical_reads,
            t.qs_total_physical_reads = cbo.total_physical_reads,
            t.qs_total_duration_ms    = cbo.total_duration_ms,
            t.qs_total_executions     = cbo.total_executions,
            t.qs_plan_count           = cbo.plan_count,
            t.qs_query_count          = cbo.query_count,
            t.qs_query_hashes         = cbo.query_hashes
        FROM #Targets t
        JOIN #CpuByObject cbo ON t.object_id = cbo.object_id
        WHERE t.database_name = DB_NAME();

        /* Report coverage */
        DECLARE @qs_total_plans integer = (SELECT COUNT_BIG(*) FROM #CpuByPlan);
        DECLARE @qs_unique_hashes integer = (SELECT COUNT_BIG(*) FROM #ParsedPlans);
        DECLARE @qs_matched_plans integer = (SELECT COUNT_BIG(DISTINCT plan_id) FROM #PlanObjMap);
        DECLARE @qs_targets_enriched integer = (SELECT COUNT_BIG(*) FROM #Targets WHERE database_name = DB_NAME() AND ranking_basis = N''QS_CPU'');
        DECLARE @qs_targets_total integer = (SELECT COUNT_BIG(*) FROM #Targets WHERE database_name = DB_NAME());

        SET @Msg_inner = N''  QS enrichment: '' + CONVERT(nvarchar(10), @qs_targets_enriched)
            + N''/'' + CONVERT(nvarchar(10), @qs_targets_total) + N'' targets enriched with CPU data (''
            + CONVERT(nvarchar(10), @qs_unique_hashes) + N'' unique plans parsed from ''
            + CONVERT(nvarchar(10), @qs_total_plans) + N'' total).'';
        RAISERROR(@Msg_inner, 10, 1) WITH NOWAIT;

        DROP TABLE #ParsedPlans;
    END
END
';
        END

        /*
        Execute the per-database discovery.
        All parameters are passed in to avoid SQL injection from @Databases input.
        */
        BEGIN TRY
            EXEC sys.sp_executesql
                @discovery_sql,
                N'@MinPages_param bigint, @MaxPages_param bigint, @MinForwardedPct_param decimal(6,2),
                  @IncludeHealthyHeaps_param bit,
                  @LookbackDays_param integer, @TopN_param integer,
                  @AllowCiSwap_param bit, @PreferCiSwap_param bit, @Online_param bit,
                  @Maxdop_param integer, @FillFactor_param tinyint, @CpuSource_param varchar(20), @UptimeHours_param float,
                  @UseResumable_param bit, @IncludeTemporalHistory_param bit,
                  @ScanMode_param nvarchar(20)',
                @MinPages_param = @MinPages,
                @MaxPages_param = @MaxPages,
                @MinForwardedPct_param = @MinForwardedPct,
                @IncludeHealthyHeaps_param = @IncludeHealthyHeaps,
                @LookbackDays_param = @LookbackDays,
                @TopN_param = @TopN,
                @AllowCiSwap_param = @AllowCiSwap,
                @PreferCiSwap_param = @PreferCiSwap,
                @Online_param = @Online,
                @Maxdop_param = @Maxdop,
                @FillFactor_param = @FillFactor,
                @CpuSource_param = @CpuSourceUpper,
                @UptimeHours_param = @UptimeHours,
                @UseResumable_param = @UseResumable,
                @IncludeTemporalHistory_param = @IncludeTemporalHistory,
                @ScanMode_param = @ScanMode;
        END TRY
        BEGIN CATCH
            SET @discovery_errors += 1;
            SET @Msg = N'  ERROR scanning ' + @CurrentDatabaseName + N': '
                     + CONVERT(nvarchar(10), ERROR_NUMBER()) + N' - ' + LEFT(ERROR_MESSAGE(), 1000);
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        END CATCH;

        /* Set sort_order = target_id for newly inserted rows */
        UPDATE #Targets SET sort_order = target_id WHERE sort_order = 0;

        /* Mark database as completed */
        UPDATE @tmpDatabases SET Completed = 1 WHERE ID = @CurrentDatabaseID;

        /* Track per-database scan stats */
        INSERT INTO @DbScanStats (DatabaseName, HeapsQualified, ScanSeconds)
        VALUES (
            @CurrentDatabaseName,
            (SELECT COUNT_BIG(*) FROM #Targets) - @db_pre_target_count,
            DATEDIFF(SECOND, @db_scan_start, SYSDATETIME())
        );

        /* Scan throttle: WAITFOR between database scans */
        /* Reduces dm_db_index_physical_stats latch contention on busy servers. */
        IF @ScanThrottleMs IS NOT NULL AND @ScanThrottleMs > 0
        BEGIN
            DECLARE @ThrottleDelay varchar(12);
            SET @ThrottleDelay = '00:00:'
                + RIGHT('00' + CONVERT(varchar(2), @ScanThrottleMs / 1000), 2)
                + '.' + RIGHT('000' + CONVERT(varchar(3), @ScanThrottleMs % 1000), 3);
            WAITFOR DELAY @ThrottleDelay;
        END

        /* Scan phase time check: stop scanning if @MaxRunSeconds is exceeded */
        /* Preserve execution time when scan phase is slow */
        IF @MaxRunSeconds IS NOT NULL
           AND DATEDIFF(SECOND, @start_time, SYSDATETIME()) >= @MaxRunSeconds
        BEGIN
            DECLARE @scan_remaining_dbs integer;
            SELECT @scan_remaining_dbs = COUNT_BIG(*) FROM @tmpDatabases WHERE Selected = 1 AND Completed = 0;

            IF @scan_remaining_dbs > 0
            BEGIN
                SET @Msg = N'Time limit reached during scan phase. Skipping '
                         + CONVERT(nvarchar(10), @scan_remaining_dbs) + N' remaining database(s).';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            END
            BREAK;
        END
    END

/*#endregion 12-DISCOVERY */

/*#region 13-QS-RERANK /* QUERY_STORE global re-rank after discovery */ */
    /*
    QUERY_STORE re-rank: after per-database discovery + enrichment, recalculate
    ranking_score with updated CPU data and reassign sort_order globally.
    This mirrors the QUICKIESTORE re-rank pattern below.
    */
    IF @CpuSourceUpper = 'QUERY_STORE'
       AND EXISTS (SELECT 1 FROM #Targets WHERE ranking_basis = 'QS_CPU')
    BEGIN
        /* Recalculate ranking_score with updated CPU */
        UPDATE #Targets
        SET ranking_score = CONVERT(decimal(8,4),
            (0.4 * LOG10(ISNULL(forwarded_fetch_count, 0) / @UptimeHours + 1)
           + 0.4 * LOG10(COALESCE(total_cpu_ms, 0) + 1)
           + 0.2 * LOG10(forwarded_pct + 1))
          * CASE usage_hint
                WHEN 'WRITE_ONLY' THEN 0.25
                WHEN 'WRITE_HEAVY' THEN 0.5
                ELSE 1.0
            END
        );

        /* Global re-rank sort_order by updated ranking_score */
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

/*#endregion 13-QS-RERANK */

/*#region 14-QUICKIESTORE /* sp_QuickieStore path (single-database) */ */
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
        DECLARE @ColCount integer = 0;

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
INSERT INTO #Quickie EXEC sys.sp_executesql @InnerSql;

INSERT INTO #CpuByPlan(plan_id, total_cpu_ms)
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

        SET @Msg = N'Loaded ' + CONVERT(nvarchar(10), (SELECT COUNT_BIG(*) FROM #CpuByPlan)) + N' plan(s) with CPU data from QuickieStore.';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;

        /* Update #Targets with CPU data for the current database */
        /* (QuickieStore CPU mapping via plan XML) */
        DECLARE @QueryStoreRW bit =
            CASE WHEN EXISTS (SELECT 1 FROM sys.database_query_store_options WHERE actual_state_desc = 'READ_WRITE')
                 THEN 1 ELSE 0 END;

        IF @QueryStoreRW = 1 AND EXISTS (SELECT 1 FROM #CpuByPlan)
        BEGIN
            /* Enrich #CpuByPlan with full QS metrics for QUICKIESTORE path */
            /* (QUICKIESTORE only provides CPU; we supplement from QS runtime stats) */
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
                /* Pre-filter: only parse plans whose text contains a target table name */
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
                /* Filter to Table Scan RelOps only */
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
                    COUNT_BIG(DISTINCT po.plan_id) AS plan_count,
                    COUNT_BIG(DISTINCT po.query_id) AS query_count,
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
        /* Recalculate ranking_score with updated CPU from QUICKIESTORE */
        UPDATE #Targets
        SET ranking_score = CONVERT(decimal(8,4),
            (0.4 * LOG10(ISNULL(forwarded_fetch_count, 0) / @UptimeHours + 1)
           + 0.4 * LOG10(COALESCE(total_cpu_ms, 0) + 1)
           + 0.2 * LOG10(forwarded_pct + 1))
          * CASE usage_hint
                WHEN 'WRITE_ONLY' THEN 0.25
                WHEN 'WRITE_HEAVY' THEN 0.5
                ELSE 1.0
            END
        );

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

    END /* IF @resume_loaded = 0 (skip discovery + QUICKIESTORE in resume mode) */

/*#endregion 14-QUICKIESTORE */

/*#region 15-POST-DISCOVERY /* Target count, warnings, zero-target exit */ */
    /*-------------------------------------------------------------------------- */
    /* Final target count */
    /*-------------------------------------------------------------------------- */
    DECLARE @TargetCount integer = (SELECT COUNT_BIG(*) FROM #Targets);

    RAISERROR(N'', 10, 1) WITH NOWAIT;
    SET @Msg = N'Total targets across all databases: ' + CONVERT(nvarchar(10), @TargetCount);
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;

    IF @resume_loaded = 0 AND @discovery_errors > 0
    BEGIN
        SET @Msg = N'WARNING: ' + CONVERT(nvarchar(10), @discovery_errors)
                 + N' database(s) had errors during discovery scan. Check messages above.';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    END

    /* 8A: Usage_hint uptime warning */
    /* If SQL Server restarted recently, dm_db_index_usage_stats hasn't accumulated enough data */
    /* for reliable WRITE_HEAVY/WRITE_ONLY classification. */
    IF @UptimeHours < 24.0
       AND EXISTS (SELECT 1 FROM #Targets WHERE usage_hint IS NOT NULL)
    BEGIN
        SET @Msg = N'WARNING: SQL Server restarted '
                 + CONVERT(nvarchar(20), CONVERT(decimal(6,1), @UptimeHours))
                 + N' hours ago. usage_hint (WRITE_HEAVY/WRITE_ONLY) may be unreliable due to insufficient dm_db_index_usage_stats accumulation.';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    END

    /* @SkipWriteHeavy: remove write-heavy heaps entirely when requested */
    IF @SkipWriteHeavy = 1
    BEGIN
        DECLARE @skip_wh_cnt integer;
        SELECT @skip_wh_cnt = COUNT_BIG(*) FROM #Targets WHERE usage_hint IN (N'WRITE_HEAVY', N'WRITE_ONLY');

        IF @skip_wh_cnt > 0
        BEGIN
            DECLARE @skip_wh_name nvarchar(512);
            DECLARE skip_wh_cursor CURSOR LOCAL FAST_FORWARD FOR
                SELECT QUOTENAME(database_name) + N'.' + QUOTENAME(schema_name) + N'.' + QUOTENAME(table_name)
                FROM #Targets WHERE usage_hint IN (N'WRITE_HEAVY', N'WRITE_ONLY') ORDER BY sort_order;
            OPEN skip_wh_cursor;
            FETCH NEXT FROM skip_wh_cursor INTO @skip_wh_name;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @Msg = N'SKIPPED (write-heavy): ' + @skip_wh_name + N' -- @SkipWriteHeavy = 1';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                FETCH NEXT FROM skip_wh_cursor INTO @skip_wh_name;
            END
            CLOSE skip_wh_cursor;
            DEALLOCATE skip_wh_cursor;

            DELETE FROM #Targets WHERE usage_hint IN (N'WRITE_HEAVY', N'WRITE_ONLY');
            SET @TargetCount = (SELECT COUNT_BIG(*) FROM #Targets);

            SET @Msg = CONVERT(nvarchar(10), @skip_wh_cnt) + N' write-heavy heap(s) excluded by @SkipWriteHeavy = 1.';
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        END
    END

    /* RCSI version store pressure warning */
    /* Online rebuilds on RCSI databases generate version store data in tempdb. */
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

    /* Transaction log impact warning */
    /* FULL recovery databases generate significant log for rebuilds. */
    BEGIN
        DECLARE @full_recovery_dbs nvarchar(max);
        DECLARE @total_est_log_gb decimal(10,2);

        SELECT @full_recovery_dbs = STRING_AGG(sub.database_name, N', ')
        FROM (SELECT DISTINCT t.database_name
              FROM #Targets t
              JOIN sys.databases d ON d.name = t.database_name COLLATE DATABASE_DEFAULT
              WHERE d.recovery_model_desc = N'FULL') sub;

        SELECT @total_est_log_gb = CONVERT(decimal(10,2), SUM(t.page_count) * 8192.0 / 1073741824)
        FROM #Targets t
        JOIN sys.databases d ON d.name = t.database_name COLLATE DATABASE_DEFAULT
        WHERE d.recovery_model_desc = N'FULL';

        IF @full_recovery_dbs IS NOT NULL AND @total_est_log_gb > 1.0
        BEGIN
            SET @Msg = N'WARNING: Database(s) [' + @full_recovery_dbs
                     + N'] use FULL recovery. Estimated ~'
                     + CONVERT(nvarchar(20), @total_est_log_gb)
                     + N' GB of transaction log will be generated. Ensure frequent log backups.';
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        END
    END

    /* 8N: TDE detection and throughput warning */
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

    /* 9J: AG sync-commit warning */
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
                    AND drs.synchronization_state = 1 /* SYNCHRONIZED (sync commit) */
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

            IF @ag_large_pages > 100000 /* Only warn for large rebuilds (>800 MB) */
            BEGIN
                SET @Msg = N'WARNING: Database(s) [' + @ag_sync_dbs
                         + N'] use synchronous AG commit. Rebuild throughput may be limited by secondary replica I/O.';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            END
        END
    END

    /* 9K: Backup running check */
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

    /*
    #145: VLF count advisory for FULL recovery databases with large targets.
    High VLF counts increase log operation overhead. DBCC LOGINFO row count = VLF count.
    Warn when VLF count > 1000 for databases containing rebuild targets.
    */
    BEGIN
        DECLARE @vlf_db sysname, @vlf_count integer, @vlf_sql nvarchar(max);
        DECLARE @vlf_warnings nvarchar(max) = N'';

        CREATE TABLE #VlfInfo (
            RecoveryUnitId integer NULL, FileId integer NULL, FileSize bigint NULL,
            StartOffset bigint NULL, FSeqNo integer NULL, Status integer NULL,
            Parity tinyint NULL, CreateLSN numeric(25,0) NULL
        );

        DECLARE vlf_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT DISTINCT t.database_name
            FROM #Targets t
            JOIN sys.databases d ON d.name = t.database_name COLLATE DATABASE_DEFAULT
            WHERE d.recovery_model_desc = N'FULL'
              AND t.page_count > 10000; /* only check for non-trivial targets */
        OPEN vlf_cursor;
        FETCH NEXT FROM vlf_cursor INTO @vlf_db;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                TRUNCATE TABLE #VlfInfo;
                SET @vlf_sql = N'USE ' + QUOTENAME(@vlf_db) + N'; DBCC LOGINFO WITH NO_INFOMSGS;';
                INSERT INTO #VlfInfo EXEC sys.sp_executesql @vlf_sql;
                SET @vlf_count = ROWCOUNT_BIG();

                IF @vlf_count > 1000
                BEGIN
                    SET @vlf_warnings += CASE WHEN @vlf_warnings = N'' THEN N'' ELSE N', ' END
                                       + @vlf_db + N' (' + CONVERT(nvarchar(10), @vlf_count) + N' VLFs)';
                END
            END TRY
            BEGIN CATCH
                /* Silently skip VLF check for this database */
            END CATCH
            FETCH NEXT FROM vlf_cursor INTO @vlf_db;
        END
        CLOSE vlf_cursor;
        DEALLOCATE vlf_cursor;
        DROP TABLE #VlfInfo;

        IF @vlf_warnings <> N''
        BEGIN
            SET @Msg = N'WARNING: High VLF count on [' + @vlf_warnings
                     + N']. Log-intensive rebuilds may be slower. Consider shrinking and re-growing the log file.';
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        END
    END

    /* #20: Tempdb free space pre-flight check for CI swap targets */
    IF EXISTS (SELECT 1 FROM #Targets WHERE action_chosen = 'CI_SWAP_ONLINE')
    BEGIN
        DECLARE @tempdb_free_mb decimal(18,2) = NULL;
        DECLARE @largest_ci_swap_mb decimal(18,2);
        DECLARE @largest_ci_swap_table sysname;

        BEGIN TRY
            SELECT @tempdb_free_mb = SUM(unallocated_extent_page_count) * 8.0 / 1024.0
            FROM tempdb.sys.dm_db_file_space_usage;
        END TRY
        BEGIN CATCH
            SET @tempdb_free_mb = NULL;
        END CATCH

        /* Estimate tempdb sort space: page_count * 8KB * 1.2 (20% buffer) converted to MB */
        SELECT TOP (1)
            @largest_ci_swap_mb = CONVERT(decimal(18,2), page_count * 8.0 * 1.2 / 1024.0),
            @largest_ci_swap_table = QUOTENAME(database_name) + N'.' + QUOTENAME(schema_name) + N'.' + QUOTENAME(table_name)
        FROM #Targets
        WHERE action_chosen = 'CI_SWAP_ONLINE'
        ORDER BY page_count DESC;

        IF @tempdb_free_mb IS NOT NULL AND @largest_ci_swap_mb IS NOT NULL
           AND @largest_ci_swap_mb > @tempdb_free_mb
        BEGIN
            SET @Msg = N'WARNING: Tempdb has ' + CONVERT(nvarchar(20), CONVERT(integer, @tempdb_free_mb))
                     + N' MB free. Largest CI swap target (' + @largest_ci_swap_table
                     + N') requires approximately ' + CONVERT(nvarchar(20), CONVERT(integer, @largest_ci_swap_mb))
                     + N' MB for sort space. Consider reducing concurrent maintenance jobs or increasing tempdb.';
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        END
    END

    /* #115: Post-discovery summary of CI swap targets with FK references */
    IF EXISTS (SELECT 1 FROM #Targets WHERE has_fk_references = 1 AND action_chosen = 'CI_SWAP_ONLINE')
    BEGIN
        DECLARE @fk_summary_list nvarchar(max);
        SELECT @fk_summary_list = STRING_AGG(
            N'  ' + QUOTENAME(database_name) + N'.' + QUOTENAME(schema_name) + N'.' + QUOTENAME(table_name)
            + N' (' + CONVERT(nvarchar(10), fk_ref_count) + N' FK ref(s))',
            NCHAR(10))
        FROM #Targets
        WHERE has_fk_references = 1 AND action_chosen = 'CI_SWAP_ONLINE';

        SET @Msg = N'WARNING: The following CI swap targets have foreign key references. '
                 + N'After CI swap, FK child table NCI row locators change from RID to CI key. '
                 + N'Query plans referencing FK child NCIs may need recompilation.';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        RAISERROR(@fk_summary_list, 10, 1) WITH NOWAIT;
    END

    /*
    #97: Per-database orphaned CI detection.
    Scan for CX__Temp__ clustered indexes left behind by prior failed CI swap DROP operations.
    These tables are invisible to discovery (index_id = 1, not 0) and require manual cleanup.
    Only scan databases in scope (not all databases on the server).
    */
    IF @resume_loaded = 0
    BEGIN
        DECLARE @orphan_db sysname, @orphan_sql nvarchar(max), @orphan_results nvarchar(max);
        DECLARE orphan_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT DatabaseName FROM @tmpDatabases WHERE Selected = 1 AND Completed = 1;
        OPEN orphan_cursor;
        FETCH NEXT FROM orphan_cursor INTO @orphan_db;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @orphan_results = NULL;
            BEGIN TRY
                SET @orphan_sql = N'SELECT @out = STRING_AGG(
                    N''  '' + QUOTENAME(s.name) + N''.'' + QUOTENAME(t.name)
                    + N'' -- '' + N''DROP INDEX '' + QUOTENAME(i.name)
                    + N'' ON '' + QUOTENAME(@db_param) + N''.'' + QUOTENAME(s.name) + N''.'' + QUOTENAME(t.name) + N'';'',
                    NCHAR(10))
                FROM ' + QUOTENAME(@orphan_db) + N'.sys.indexes i
                JOIN ' + QUOTENAME(@orphan_db) + N'.sys.tables t ON t.object_id = i.object_id
                JOIN ' + QUOTENAME(@orphan_db) + N'.sys.schemas s ON s.schema_id = t.schema_id
                WHERE i.name LIKE N''CX!_!_Temp!_!_%'' ESCAPE N''!''
                  AND i.type = 1
                  AND NOT EXISTS (
                    SELECT 1 FROM #Targets tgt
                    WHERE tgt.database_name = @db_param COLLATE DATABASE_DEFAULT
                      AND tgt.schema_name = s.name COLLATE DATABASE_DEFAULT
                      AND tgt.table_name = t.name COLLATE DATABASE_DEFAULT
                  );';
                EXEC sys.sp_executesql @orphan_sql,
                    N'@db_param sysname, @out nvarchar(max) OUTPUT',
                    @db_param = @orphan_db, @out = @orphan_results OUTPUT;
            END TRY
            BEGIN CATCH
                SET @orphan_results = NULL; /* don't block on metadata errors */
            END CATCH

            IF @orphan_results IS NOT NULL
            BEGIN
                SET @Msg = N'WARNING: Orphaned temp clustered index(es) found in [' + @orphan_db
                         + N'] from a prior failed CI swap DROP. These tables are no longer heaps and need manual cleanup:';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                RAISERROR(@orphan_results, 10, 1) WITH NOWAIT;
            END

            FETCH NEXT FROM orphan_cursor INTO @orphan_db;
        END
        CLOSE orphan_cursor;
        DEALLOCATE orphan_cursor;
    END

    RAISERROR(N'', 10, 1) WITH NOWAIT;

    IF @TargetCount = 0
    BEGIN
        RAISERROR(N'No heaps met thresholds in any database. Nothing to do.', 10, 1) WITH NOWAIT;

        /* Write HEAP_SCAN_SUMMARY even for zero targets (confirms "proc ran, found nothing") */
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
                @invocation_command,
                N'HEAP_SCAN_SUMMARY',
                @start_time,
                SYSDATETIME(),
                0,
                NULL,
                (
                    SELECT
                        @Version AS Version,
                        @RankingAlgoVersion AS RankingAlgoVersion,
                        @RunID AS RunID,
                        0 AS TargetCount,
                        @DatabaseCount AS DatabasesScanned,
                        0 AS TotalPageCount,
                        CONVERT(decimal(18,2), 0) AS TotalSizeMB,
                        @CpuSourceUpper AS CpuSource,
                        DATEDIFF(SECOND, @start_time, SYSDATETIME()) AS ElapsedSeconds,
                        CONVERT(nvarchar(30), @SqlServerStartTime, 126) AS SqlServerStartTime,
                        CONVERT(decimal(10,1), @UptimeHours) AS UptimeHours,
                        0 AS DatabasesWithTargets,
                        CONVERT(bigint, 0) AS TotalCpuMs,
                        CONVERT(bigint, 0) AS TotalForwardedRecordCount,
                        CONVERT(bigint, 0) AS TotalForwardedFetchCount,
                        (
                            SELECT
                                DatabaseName AS [Name],
                                HeapsQualified,
                                ScanSeconds
                            FROM @DbScanStats
                            ORDER BY DatabaseName
                            FOR XML RAW(N'Database'), TYPE
                        ) AS Databases
                    FOR XML RAW(N'ScanSummary'), ELEMENTS, TYPE
                )
            );
        END

        EXEC sp_releaseapplock @Resource = N'sp_HeapDoctor', @LockOwner = N'Session';
        RETURN;
    END

    IF @Debug = 1
    BEGIN
        RAISERROR(N'[DEBUG] Target details:', 10, 1) WITH NOWAIT;
        DECLARE @dbg_tid integer, @dbg_db sysname, @dbg_tbl sysname, @dbg_action varchar(32),
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
            SET @Msg = N'[DEBUG]   #' + CONVERT(nvarchar(10), @dbg_tid)
                     + N' ' + @dbg_db + N'.' + @dbg_tbl
                     + N' | ' + @dbg_action
                     + N' | pages=' + CONVERT(nvarchar(20), @dbg_pages)
                     + N' fwd=' + CONVERT(nvarchar(10), @dbg_fwd) + N'%%'
                     + N' cpu=' + ISNULL(CONVERT(nvarchar(20), @dbg_cpu), N'NULL')
                     + N' basis=' + @dbg_basis
                     + N' score=' + ISNULL(CONVERT(nvarchar(20), @dbg_score), N'NULL');
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            FETCH NEXT FROM dbg_tgt INTO @dbg_tid, @dbg_db, @dbg_tbl, @dbg_action,
                                         @dbg_pages, @dbg_fwd, @dbg_cpu, @dbg_basis, @dbg_score;
        END
        CLOSE dbg_tgt;
        DEALLOCATE dbg_tgt;
    END

/*#endregion 15-POST-DISCOVERY */

/*#region 16-THROUGHPUT /* History-based throughput estimation */ */
    /*-------------------------------------------------------------------------- */
    /* Throughput estimation (history-based) */
    /*-------------------------------------------------------------------------- */
    DECLARE @hist_online_pps    float = NULL;
    DECLARE @hist_offline_pps   float = NULL;
    DECLARE @hist_ciswap_pps    float = NULL;
    DECLARE @hist_any_pps       float = NULL;
    DECLARE @hist_source        varchar(20) = 'NONE';
    DECLARE @hist_sample_count  integer = 0;

    IF @EstimateTime = 1 AND @commandlog_exists = 1
    BEGIN
        ;WITH HistRates AS
        (
            SELECT
                CommandType,
                AVG(
                    CONVERT(float, ExtendedInfo.value('(/ExtendedInfo/PageCount)[1]', 'bigint'))
                    / NULLIF(DATEDIFF(MILLISECOND, StartTime, EndTime) / 1000.0, 0)
                ) AS avg_pps,
                COUNT_BIG(*) AS sample_count
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
            /* #88: Cold-start baseline when no CommandLog history */
            IF @BaselineRebuildMBPerMin IS NOT NULL
            BEGIN
                /* Convert MB/min to pages/sec: (MB/min * 128 pages/MB) / 60 sec/min */
                SET @hist_any_pps = @BaselineRebuildMBPerMin * 128.0 / 60.0;
                SET @hist_source = 'BASELINE';

                SET @Msg = N'EstimateTime: Using baseline rate ' + CONVERT(nvarchar(10), @BaselineRebuildMBPerMin) + N' MB/min ('
                         + CONVERT(nvarchar(20), CONVERT(integer, @hist_any_pps)) + N' pages/sec). Calibrate with prior rebuild observations.';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            END
            ELSE
            BEGIN
                RAISERROR(N'EstimateTime: No historical rebuild data found in CommandLog. Use @BaselineRebuildMBPerMin for cold-start estimates or run with @LogToTable=''Y''.', 10, 1) WITH NOWAIT;
            END
        END
        ELSE
        BEGIN
            SET @Msg = N'EstimateTime: Historical throughput (pages/sec):'
                     + CASE WHEN @hist_online_pps  IS NOT NULL THEN N'  ONLINE='  + CONVERT(nvarchar(20), CONVERT(integer, @hist_online_pps )) ELSE N'' END
                     + CASE WHEN @hist_offline_pps IS NOT NULL THEN N'  OFFLINE=' + CONVERT(nvarchar(20), CONVERT(integer, @hist_offline_pps)) ELSE N'' END
                     + CASE WHEN @hist_ciswap_pps  IS NOT NULL THEN N'  CI_SWAP=' + CONVERT(nvarchar(20), CONVERT(integer, @hist_ciswap_pps )) ELSE N'' END
                     + N'  (' + CONVERT(nvarchar(10), @hist_sample_count) + N' sample' + CASE WHEN @hist_sample_count <> 1 THEN N's' ELSE N'' END + N')';
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;

            IF @hist_sample_count < 3
            BEGIN
                RAISERROR(N'EstimateTime: WARNING - estimate based on fewer than 3 samples. Run a few more rebuilds to improve accuracy.', 10, 1) WITH NOWAIT;
            END
        END

        /* Populate estimate columns on #Targets (runs for both HISTORY and BASELINE) */
        IF @hist_any_pps IS NOT NULL
        BEGIN
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
                                    THEN '0' + CONVERT(varchar(10), est_seconds / 3600)
                                    ELSE CONVERT(varchar(10), est_seconds / 3600)
                               END + ':'
                             + RIGHT('00' + CONVERT(varchar(2), (est_seconds % 3600) / 60), 2) + ':'
                             + RIGHT('00' + CONVERT(varchar(2), est_seconds % 60), 2)
            WHERE est_seconds IS NOT NULL;

            /* Print total estimate summary */
            DECLARE @total_est_sec integer;
            SELECT @total_est_sec = SUM(est_seconds) FROM #Targets WHERE est_seconds IS NOT NULL;

            IF @total_est_sec IS NOT NULL
            BEGIN
                SET @Msg = N'EstimateTime: Total estimated remediation: '
                         + CASE WHEN @total_est_sec / 3600 < 10
                                THEN '0' + CONVERT(varchar(10), @total_est_sec / 3600)
                                ELSE CONVERT(varchar(10), @total_est_sec / 3600)
                           END + ':'
                         + RIGHT('00' + CONVERT(varchar(2), (@total_est_sec % 3600) / 60), 2) + ':'
                         + RIGHT('00' + CONVERT(varchar(2), @total_est_sec % 60), 2)
                         + N' (' + CONVERT(nvarchar(20), @total_est_sec) + N's) based on '
                         + CASE @hist_source WHEN 'BASELINE' THEN N'baseline rate' ELSE CONVERT(nvarchar(10), @EstimateLookbackDays) + N'-day history' END;
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            END
        END
        RAISERROR(N'', 10, 1) WITH NOWAIT;
    END

/*#endregion 16-THROUGHPUT */

/*#region 17-FILTERS-PROJECTIONS /* Write-heavy, trending, impact projections, churn */ */
    /* Warn about write-heavy heaps (rebuilding is a band-aid for staging/ETL tables) */
    IF EXISTS (SELECT 1 FROM #Targets WHERE usage_hint IS NOT NULL)
    BEGIN
        DECLARE @write_cnt integer = (SELECT COUNT_BIG(*) FROM #Targets WHERE usage_hint IS NOT NULL);
        SET @Msg = N'WARNING: ' + CONVERT(nvarchar(10), @write_cnt)
                 + N' target(s) flagged as write-heavy (more updates than reads). '
                 + N'Forwarded records may recur. Consider adding a clustered index.';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        RAISERROR(N'', 10, 1) WITH NOWAIT;
    END

    /* Azure SQL Database DTU/vCore warning */
    IF @EngineEdition = 5
    BEGIN
        RAISERROR(N'WARNING: Azure SQL Database detected. Online rebuilds consume significant DTU/vCore resources. Consider running during off-peak hours.', 10, 1) WITH NOWAIT;
        RAISERROR(N'', 10, 1) WITH NOWAIT;
    END

    /* 9L: Trending columns from CommandLog history (skip in resume mode: already in XML) */
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
                NULL AS rebuild_count, /* placeholder, computed separately */
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
            SELECT COUNT_BIG(*) AS rebuild_count
            FROM dbo.CommandLog cl
            WHERE cl.DatabaseName = t.database_name
              AND cl.ObjectName = t.table_name
              AND cl.SchemaName = t.schema_name
              AND cl.CommandType IN ('HEAP_REBUILD_ONLINE', 'HEAP_REBUILD_OFFLINE', 'CI_SWAP_ONLINE')
              AND cl.ErrorNumber = 0
              AND cl.EndTime >= DATEADD(DAY, -90, SYSDATETIME())
        ) cnt;
    END

    /*-------------------------------------------------------------------------- */
    /* Size and impact projections (skip in resume mode: already in XML) */
    /*-------------------------------------------------------------------------- */
    IF @resume_loaded = 0
    BEGIN
        UPDATE #Targets
        SET
            size_mb = CONVERT(decimal(18,2), page_count) / 128.0,
            est_ci_swap_overhead_mb = CASE
                WHEN action_chosen = 'CI_SWAP_ONLINE'
                THEN CONVERT(decimal(18,2), page_count) / 128.0
                ELSE NULL END,
            est_space_savings_mb = CASE
                WHEN avg_page_space_pct IS NOT NULL AND avg_page_space_pct < 75.0
                THEN CONVERT(decimal(18,2), page_count) * (1.0 - avg_page_space_pct / 100.0) / 128.0
                ELSE NULL END;

        /* est_log_mb: per-target log estimate for FULL recovery databases */
        UPDATE t
        SET t.est_log_mb = CONVERT(decimal(18,2), t.page_count) * 8192.0 / 1048576.0
        FROM #Targets t
        JOIN sys.databases d ON d.name = t.database_name COLLATE DATABASE_DEFAULT
        WHERE d.recovery_model_desc = N'FULL';
    END

    /* Churn detection: warn about heaps rebuilt 5+ times in 90 days */
    IF EXISTS (SELECT 1 FROM #Targets WHERE rebuilds_in_90d >= 5)
    BEGIN
        DECLARE @churn_name nvarchar(512);
        DECLARE @churn_cnt integer;
        DECLARE churn_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT QUOTENAME(database_name) + N'.' + QUOTENAME(schema_name) + N'.' + QUOTENAME(table_name),
                   rebuilds_in_90d
            FROM #Targets WHERE rebuilds_in_90d >= 5 ORDER BY sort_order;
        OPEN churn_cursor;
        FETCH NEXT FROM churn_cursor INTO @churn_name, @churn_cnt;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @Msg = N'WARNING: ' + @churn_name + N' has been rebuilt '
                     + CONVERT(nvarchar(10), @churn_cnt)
                     + N' times in the last 90 days. Consider investigating root cause (ETL pattern, row expansion) rather than repeated rebuilds.';
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            FETCH NEXT FROM churn_cursor INTO @churn_name, @churn_cnt;
        END
        CLOSE churn_cursor;
        DEALLOCATE churn_cursor;
    END

    /* @MinDaysSinceRebuild: skip recently-rebuilt heaps */
    IF @MinDaysSinceRebuild IS NOT NULL
    BEGIN
        IF @commandlog_exists = 0
        BEGIN
            RAISERROR(N'WARNING: @MinDaysSinceRebuild requires dbo.CommandLog for rebuild history. Filter cannot be applied without CommandLog.', 10, 1) WITH NOWAIT;
        END
        ELSE
        BEGIN
            DECLARE @skip_recent_cnt integer;
            SELECT @skip_recent_cnt = COUNT_BIG(*)
            FROM #Targets
            WHERE days_since_last_rebuild IS NOT NULL
              AND days_since_last_rebuild < @MinDaysSinceRebuild;

            IF @skip_recent_cnt > 0
            BEGIN
                DECLARE @skip_recent_name nvarchar(512);
                DECLARE @skip_recent_days integer;
                DECLARE skip_recent_cursor CURSOR LOCAL FAST_FORWARD FOR
                    SELECT QUOTENAME(database_name) + N'.' + QUOTENAME(schema_name) + N'.' + QUOTENAME(table_name),
                           days_since_last_rebuild
                    FROM #Targets
                    WHERE days_since_last_rebuild IS NOT NULL
                      AND days_since_last_rebuild < @MinDaysSinceRebuild
                    ORDER BY sort_order;
                OPEN skip_recent_cursor;
                FETCH NEXT FROM skip_recent_cursor INTO @skip_recent_name, @skip_recent_days;
                WHILE @@FETCH_STATUS = 0
                BEGIN
                    SET @Msg = N'SKIPPED (recently rebuilt): ' + @skip_recent_name
                             + N' -- rebuilt ' + CONVERT(nvarchar(10), @skip_recent_days)
                             + N' day(s) ago (threshold: ' + CONVERT(nvarchar(10), @MinDaysSinceRebuild) + N')';
                    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                    FETCH NEXT FROM skip_recent_cursor INTO @skip_recent_name, @skip_recent_days;
                END
                CLOSE skip_recent_cursor;
                DEALLOCATE skip_recent_cursor;

                DELETE FROM #Targets
                WHERE days_since_last_rebuild IS NOT NULL
                  AND days_since_last_rebuild < @MinDaysSinceRebuild;
                SET @TargetCount = (SELECT COUNT_BIG(*) FROM #Targets);

                SET @Msg = CONVERT(nvarchar(10), @skip_recent_cnt)
                         + N' recently-rebuilt heap(s) excluded by @MinDaysSinceRebuild = '
                         + CONVERT(nvarchar(10), @MinDaysSinceRebuild) + N'.';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            END
        END
    END

/*#endregion 17-FILTERS-PROJECTIONS */

/*#region 18-OBFUSCATION /* Encrypted mapping, pseudo_ columns */ */
    /*-------------------------------------------------------------------------- */
    /* Obfuscation: build encrypted mapping, then populate pseudo_ columns. */
    /* Must build mapping FIRST (needs real names), then populate pseudonyms. */
    /*-------------------------------------------------------------------------- */
    DECLARE @obfu_mapping_encrypted varbinary(max) = NULL;

    IF @obfuscate = 1
    BEGIN
        /* 8a: Build encrypted mapping (stored in HEAP_REBUILD_START or HEAP_SCAN_SUMMARY) */
        IF @commandlog_exists = 1
        BEGIN
            DECLARE @obfu_mapping_xml nvarchar(max);
            SET @obfu_mapping_xml = CONVERT(nvarchar(max), (
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
            ));

            SET @obfu_mapping_encrypted = ENCRYPTBYPASSPHRASE(
                @passphrase,
                CONVERT(varbinary(max), @obfu_mapping_xml)
            );
        END

        /* 8b: Populate pseudo_ columns using #ObfuMap for atomic real->pseudo transformation */
        IF OBJECT_ID('tempdb..#ObfuMap') IS NOT NULL DROP TABLE #ObfuMap;

        CREATE TABLE #ObfuMap
        (
            target_id          integer            NOT NULL PRIMARY KEY,
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

        INSERT INTO #ObfuMap WITH (TABLOCK)
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

        /* Apply pseudonyms to pseudo_ columns + REPLACE real names in command strings */
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

        /* 8c: Emit obfuscation notice */
        DECLARE @obfu_target_count integer = (SELECT COUNT_BIG(*) FROM #Targets);
        SET @Msg = N'Obfuscation applied to ' + CONVERT(nvarchar(10), @obfu_target_count)
                 + N' targets. RunID=' + CONVERT(nvarchar(36), @RunID)
                 + N' (provide with @RevealKey to decrypt).';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;

        IF ISNULL(@LogToTable, N'N') <> N'Y'
            RAISERROR(N'NOTE: @ObfuscateKey used with @LogToTable<>Y - encrypted mapping not stored. Set @LogToTable=Y to enable reveal.', 10, 1) WITH NOWAIT;
        ELSE IF @commandlog_exists = 0
            RAISERROR(N'WARNING: @ObfuscateKey used but dbo.CommandLog table not found. Encrypted mapping will not be stored; reveal mode unavailable for this run.', 10, 1) WITH NOWAIT;

        RAISERROR(N'', 10, 1) WITH NOWAIT;
    END

/*#endregion 18-OBFUSCATION */

/*#region 19-OUTPUT /* Result set SELECT */ */
    /*-------------------------------------------------------------------------- */
    /* Output: target list + commands (single result set for INSERT...EXEC compatibility) */
    /*-------------------------------------------------------------------------- */
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
        @RankingAlgoVersion AS ranking_algo_version,
        CASE heap_compression WHEN 1 THEN 'ROW' WHEN 2 THEN 'PAGE' ELSE 'NONE' END AS heap_compression,
        replication_hint,
        CASE lock_escalation WHEN 0 THEN 'TABLE' WHEN 1 THEN 'DISABLE' WHEN 2 THEN 'AUTO' ELSE 'UNKNOWN' END AS lock_escalation,
        partition_count,
        CONVERT(integer, has_schema_bound_views) AS has_schema_bound_views,
        CONVERT(integer, has_indexed_views) AS has_indexed_views,
        CONVERT(integer, has_fk_references) AS has_fk_references,
        fk_ref_count,
        data_space_name AS filegroup_name,
        CASE WHEN @obfuscate = 1 THEN pseudo_command_text   ELSE command_text   END AS command_text,
        CASE WHEN @obfuscate = 1 THEN pseudo_ci_drop        ELSE ci_drop_command END AS ci_drop_command,
        CASE WHEN @obfuscate = 1 THEN pseudo_verify_cmd     ELSE verify_command  END AS verify_command,
        prev_forwarded_pct,
        rebuilds_in_90d,
        size_mb,
        est_space_savings_mb,
        est_ci_swap_overhead_mb,
        est_log_mb,
        days_since_last_rebuild,
        @SqlServerStartTime AS sqlserver_start_time,
        CONVERT(decimal(10,1), @UptimeHours) AS uptime_hours,
        page_io_latch_wait_count,
        page_io_latch_wait_ms,
        is_temporal_history,
        /* #94: Machine-readable recommended action */
        CASE
            WHEN action_chosen = 'CI_SWAP_ONLINE' THEN 'CI_SWAP'
            WHEN action_chosen LIKE 'HEAP_REBUILD%' THEN 'REBUILD'
            ELSE 'MONITOR'
        END AS recommended_action
    FROM #Targets
    ORDER BY sort_order;

    /* #16: @OutputTable - persist results to a user-specified table */
    IF @OutputTable IS NOT NULL
    BEGIN
        DECLARE @output_sql nvarchar(max);
        DECLARE @output_table_exists bit = 0;
        -- #131/#132: Construct safe (injection-proof) table name using PARSENAME+QUOTENAME.
        DECLARE @ot_schema sysname = ISNULL(PARSENAME(@OutputTable, 2), N'dbo');
        DECLARE @ot_table  sysname = PARSENAME(@OutputTable, 1);
        DECLARE @safe_OutputTable nvarchar(512) = QUOTENAME(@ot_schema) + N'.' + QUOTENAME(@ot_table);

        /* Check if table exists */
        SET @output_sql = N'IF OBJECT_ID(' + QUOTENAME(@safe_OutputTable, N'''') + N') IS NOT NULL SET @exists = 1;';
        EXEC sp_executesql @output_sql, N'@exists bit OUTPUT', @exists = @output_table_exists OUTPUT;

        /* Create table if it doesn't exist */
        IF @output_table_exists = 0
        BEGIN
            SET @output_sql = N'CREATE TABLE ' + @safe_OutputTable + N' (
                run_id               uniqueidentifier NOT NULL,
                captured_at          datetime2(3)     NOT NULL DEFAULT SYSUTCDATETIME(),
                version              nvarchar(20)     NULL,
                target_id            integer              NOT NULL,
                sort_order           integer              NOT NULL,
                database_name        sysname          NOT NULL,
                schema_name          sysname          NOT NULL,
                table_name           sysname          NOT NULL,
                page_count           bigint           NOT NULL,
                record_count         bigint           NULL,
                forwarded_record_count bigint         NOT NULL,
                forwarded_pct        decimal(6,2)     NOT NULL,
                forwarded_fetch_count bigint          NULL,
                avg_page_space_pct   decimal(5,2)     NULL,
                avg_frag_pct         decimal(5,2)     NULL,
                ghost_record_count   bigint           NULL,
                total_cpu_ms         bigint           NULL,
                ranking_basis        varchar(20)      NOT NULL,
                nci_count            integer              NOT NULL,
                key_source_index     sysname          NULL,
                action_chosen        varchar(32)      NOT NULL,
                est_pages_per_sec    float            NULL,
                est_seconds          integer              NULL,
                est_duration         nvarchar(20)     NULL,
                usage_hint           varchar(30)      NULL,
                ranking_score        decimal(8,4)     NULL,
                ranking_algo_version nvarchar(10)     NULL,
                heap_compression     varchar(4)       NULL,
                replication_hint     varchar(20)      NULL,
                lock_escalation      varchar(10)      NULL,
                partition_count      integer              NULL,
                has_fk_references    integer              NULL,
                fk_ref_count         integer              NULL,
                filegroup_name       sysname          NULL,
                command_text         nvarchar(max)    NULL,
                size_mb              decimal(18,2)    NULL,
                est_log_mb           decimal(18,2)    NULL,
                days_since_last_rebuild integer           NULL,
                page_io_latch_wait_count bigint       NULL,
                page_io_latch_wait_ms bigint          NULL,
                is_temporal_history   bit             NULL,
                recommended_action    varchar(50)     NULL
            );';
            BEGIN TRY
                EXEC sp_executesql @output_sql;
                SET @Msg = N'Created output table ' + @OutputTable + N'.';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            END TRY
            BEGIN CATCH
                SET @Msg = N'WARNING: Could not create output table ' + @OutputTable + N': ' + LEFT(ERROR_MESSAGE(), 500);
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            END CATCH
        END
        ELSE
        BEGIN
            /*
            #134: Schema drift detection for existing @OutputTable.
            When the table already exists from a prior version, new columns may be missing.
            Auto-ADD missing columns with NULL defaults to prevent INSERT failures.
            */
            DECLARE @drift_sql nvarchar(max);
            DECLARE @drift_cols nvarchar(max) = N'';
            DECLARE @drift_count integer = 0;

            /* Check each expected column; ALTER TABLE ADD if missing */
            DECLARE @expected_cols TABLE (col_name sysname NOT NULL, col_def nvarchar(100) NOT NULL);
            INSERT INTO @expected_cols (col_name, col_def) VALUES
                (N'run_id', N'uniqueidentifier NULL'),
                (N'captured_at', N'datetime2(3) NULL'),
                (N'version', N'nvarchar(20) NULL'),
                (N'target_id', N'integer NULL'),
                (N'sort_order', N'integer NULL'),
                (N'database_name', N'sysname NULL'),
                (N'schema_name', N'sysname NULL'),
                (N'table_name', N'sysname NULL'),
                (N'page_count', N'bigint NULL'),
                (N'record_count', N'bigint NULL'),
                (N'forwarded_record_count', N'bigint NULL'),
                (N'forwarded_pct', N'decimal(6,2) NULL'),
                (N'forwarded_fetch_count', N'bigint NULL'),
                (N'avg_page_space_pct', N'decimal(5,2) NULL'),
                (N'avg_frag_pct', N'decimal(5,2) NULL'),
                (N'ghost_record_count', N'bigint NULL'),
                (N'total_cpu_ms', N'bigint NULL'),
                (N'ranking_basis', N'varchar(20) NULL'),
                (N'nci_count', N'integer NULL'),
                (N'key_source_index', N'sysname NULL'),
                (N'action_chosen', N'varchar(32) NULL'),
                (N'est_pages_per_sec', N'float NULL'),
                (N'est_seconds', N'integer NULL'),
                (N'est_duration', N'nvarchar(20) NULL'),
                (N'usage_hint', N'varchar(30) NULL'),
                (N'ranking_score', N'decimal(8,4) NULL'),
                (N'ranking_algo_version', N'nvarchar(10) NULL'),
                (N'heap_compression', N'varchar(4) NULL'),
                (N'replication_hint', N'varchar(20) NULL'),
                (N'lock_escalation', N'varchar(10) NULL'),
                (N'partition_count', N'integer NULL'),
                (N'has_fk_references', N'integer NULL'),
                (N'fk_ref_count', N'integer NULL'),
                (N'filegroup_name', N'sysname NULL'),
                (N'command_text', N'nvarchar(max) NULL'),
                (N'size_mb', N'decimal(18,2) NULL'),
                (N'est_log_mb', N'decimal(18,2) NULL'),
                (N'days_since_last_rebuild', N'integer NULL'),
                (N'page_io_latch_wait_count', N'bigint NULL'),
                (N'page_io_latch_wait_ms', N'bigint NULL'),
                (N'is_temporal_history', N'bit NULL'),
                (N'recommended_action', N'varchar(50) NULL');

            DECLARE @ec_name sysname, @ec_def nvarchar(100);
            DECLARE drift_cursor CURSOR LOCAL FAST_FORWARD FOR
                SELECT ec.col_name, ec.col_def
                FROM @expected_cols ec
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM sys.columns c
                    JOIN sys.objects o ON o.object_id = c.object_id
                    JOIN sys.schemas s ON s.schema_id = o.schema_id
                    WHERE s.name = @ot_schema
                      AND o.name = @ot_table
                      AND c.name = ec.col_name COLLATE DATABASE_DEFAULT
                );
            OPEN drift_cursor;
            FETCH NEXT FROM drift_cursor INTO @ec_name, @ec_def;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                BEGIN TRY
                    SET @drift_sql = N'ALTER TABLE ' + @safe_OutputTable
                                   + N' ADD ' + QUOTENAME(@ec_name) + N' ' + @ec_def + N';';
                    EXEC sp_executesql @drift_sql;
                    SET @drift_count += 1;
                    SET @drift_cols += CASE WHEN @drift_cols = N'' THEN N'' ELSE N', ' END + @ec_name;
                END TRY
                BEGIN CATCH
                    /* Silently skip columns that can't be added (type conflict, etc.) */
                END CATCH
                FETCH NEXT FROM drift_cursor INTO @ec_name, @ec_def;
            END
            CLOSE drift_cursor;
            DEALLOCATE drift_cursor;

            IF @drift_count > 0
            BEGIN
                SET @Msg = N'NOTE: Added ' + CONVERT(nvarchar(10), @drift_count)
                         + N' missing column(s) to ' + @OutputTable + N': ' + @drift_cols;
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            END
        END

        /* Insert results into output table */
        BEGIN TRY
            SET @output_sql = N'INSERT INTO ' + @safe_OutputTable + N' (
                run_id, version, target_id, sort_order,
                database_name, schema_name, table_name,
                page_count, record_count, forwarded_record_count, forwarded_pct,
                forwarded_fetch_count, avg_page_space_pct, avg_frag_pct,
                ghost_record_count, total_cpu_ms, ranking_basis, nci_count,
                key_source_index, action_chosen, est_pages_per_sec, est_seconds, est_duration,
                usage_hint, ranking_score, ranking_algo_version, heap_compression,
                replication_hint, lock_escalation, partition_count,
                has_fk_references, fk_ref_count, filegroup_name,
                command_text, size_mb, est_log_mb, days_since_last_rebuild,
                page_io_latch_wait_count, page_io_latch_wait_ms,
                is_temporal_history,
                recommended_action
            )
            SELECT
                @RunID, @Version, target_id, sort_order,
                CASE WHEN @obfuscate = 1 THEN pseudo_database_name ELSE database_name END,
                CASE WHEN @obfuscate = 1 THEN pseudo_schema_name   ELSE schema_name   END,
                CASE WHEN @obfuscate = 1 THEN pseudo_table_name    ELSE table_name    END,
                page_count, record_count, forwarded_record_count, forwarded_pct,
                forwarded_fetch_count, avg_page_space_pct, avg_frag_pct,
                ghost_record_count, total_cpu_ms, ranking_basis, nci_count,
                CASE WHEN @obfuscate = 1 THEN pseudo_key_index ELSE key_source_index END,
                action_chosen, est_pages_per_sec, est_seconds, est_duration,
                usage_hint, ranking_score, @RankingAlgoVersion,
                CASE heap_compression WHEN 1 THEN ''ROW'' WHEN 2 THEN ''PAGE'' ELSE ''NONE'' END,
                replication_hint,
                CASE lock_escalation WHEN 0 THEN ''TABLE'' WHEN 1 THEN ''DISABLE'' WHEN 2 THEN ''AUTO'' ELSE ''UNKNOWN'' END,
                partition_count,
                CONVERT(integer, has_fk_references), fk_ref_count, data_space_name,
                CASE WHEN @obfuscate = 1 THEN pseudo_command_text ELSE command_text END,
                size_mb, est_log_mb, days_since_last_rebuild,
                page_io_latch_wait_count, page_io_latch_wait_ms,
                is_temporal_history,
                CASE
                    WHEN action_chosen = ''CI_SWAP_ONLINE'' THEN ''CI_SWAP''
                    WHEN action_chosen LIKE ''HEAP_REBUILD%%'' THEN ''REBUILD''
                    ELSE ''MONITOR''
                END
            FROM #Targets
            ORDER BY sort_order;';
            EXEC sp_executesql @output_sql,
                N'@RunID uniqueidentifier, @Version nvarchar(20), @RankingAlgoVersion nvarchar(10), @obfuscate bit',
                @RunID = @RunID, @Version = @Version, @RankingAlgoVersion = @RankingAlgoVersion, @obfuscate = @obfuscate;

            DECLARE @output_row_count integer = ROWCOUNT_BIG();
            SET @Msg = N'Inserted ' + CONVERT(nvarchar(10), @output_row_count) + N' row(s) into ' + @OutputTable
                     + N'. RunID=' + CONVERT(nvarchar(36), @RunID);
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        END TRY
        BEGIN CATCH
            SET @Msg = N'WARNING: Could not insert into output table ' + @OutputTable + N': ' + LEFT(ERROR_MESSAGE(), 500);
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        END CATCH
    END

    /* #23: @GenerateScript - output executable T-SQL script per target */
    IF @GenerateScript = 1 AND EXISTS (SELECT 1 FROM #Targets)
    BEGIN
        RAISERROR(N'', 10, 1) WITH NOWAIT;
        RAISERROR(N'-- Generated rebuild script (paste into SSMS to execute):', 10, 1) WITH NOWAIT;
        RAISERROR(N'-- ================================================================', 10, 1) WITH NOWAIT;

        DECLARE @script_target_id integer;
        DECLARE @script_db sysname;
        DECLARE @script_schema sysname;
        DECLARE @script_table sysname;
        DECLARE @script_action varchar(32);
        DECLARE @script_cmd nvarchar(max);
        DECLARE @script_ci_drop nvarchar(max);
        DECLARE @script_verify nvarchar(max);
        DECLARE @script_est nvarchar(20);
        DECLARE @script_size decimal(18,2);
        DECLARE @script_sort integer;
        DECLARE @script_line nvarchar(4000);
        /* #119/#146: Temporal history fields for SYSTEM_VERSIONING wrappers */
        DECLARE @script_is_temporal bit;
        DECLARE @script_parent_schema sysname;
        DECLARE @script_parent_table sysname;
        DECLARE @script_versioning_off nvarchar(max);
        DECLARE @script_versioning_on nvarchar(max);

        DECLARE script_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT sort_order, target_id,
                   CASE WHEN @obfuscate = 1 THEN pseudo_database_name ELSE database_name END,
                   CASE WHEN @obfuscate = 1 THEN pseudo_schema_name   ELSE schema_name   END,
                   CASE WHEN @obfuscate = 1 THEN pseudo_table_name    ELSE table_name    END,
                   action_chosen,
                   CASE WHEN @obfuscate = 1 THEN pseudo_command_text  ELSE command_text  END,
                   CASE WHEN @obfuscate = 1 THEN pseudo_ci_drop       ELSE ci_drop_command END,
                   CASE WHEN @obfuscate = 1 THEN pseudo_verify_cmd    ELSE verify_command  END,
                   est_duration, size_mb,
                   ISNULL(is_temporal_history, 0),
                   temporal_parent_schema,
                   temporal_parent_table
            FROM #Targets
            ORDER BY sort_order;
        OPEN script_cursor;
        FETCH NEXT FROM script_cursor INTO @script_sort, @script_target_id, @script_db, @script_schema, @script_table,
              @script_action, @script_cmd, @script_ci_drop, @script_verify, @script_est, @script_size,
              @script_is_temporal, @script_parent_schema, @script_parent_table;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @script_line = N'-- [' + CONVERT(nvarchar(10), @script_sort) + N'] '
                             + REPLACE(REPLACE(@script_db + N'.' + @script_schema + N'.' + @script_table, N'%', N'%%'), N'''', N'''''')
                             + N'  (' + @script_action
                             + CASE WHEN @script_size IS NOT NULL THEN N', ' + CONVERT(nvarchar(20), @script_size) + N' MB' ELSE N'' END
                             + CASE WHEN @script_est IS NOT NULL THEN N', est ' + @script_est ELSE N'' END
                             + N')';
            -- #122: Use %s format to safely emit commands that may contain % in object names.
            RAISERROR(N'%s', 10, 1, @script_line) WITH NOWAIT;

            /* #119/#146: Wrap temporal history targets with SYSTEM_VERSIONING OFF/ON */
            IF @script_is_temporal = 1 AND @script_parent_schema IS NOT NULL
            BEGIN
                SET @script_versioning_off = N'ALTER TABLE ' + QUOTENAME(@script_db) + N'.'
                    + QUOTENAME(@script_parent_schema) + N'.' + QUOTENAME(@script_parent_table)
                    + N' SET (SYSTEM_VERSIONING = OFF);';
                SET @script_versioning_on = N'ALTER TABLE ' + QUOTENAME(@script_db) + N'.'
                    + QUOTENAME(@script_parent_schema) + N'.' + QUOTENAME(@script_parent_table)
                    + N' SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = '
                    + QUOTENAME(@script_db) + N'.' + QUOTENAME(@script_schema) + N'.' + QUOTENAME(@script_table)
                    + N', DATA_CONSISTENCY_CHECK = OFF));';

                RAISERROR(N'-- Step 1: Disable SYSTEM_VERSIONING on parent table', 10, 1) WITH NOWAIT;
                RAISERROR(N'%s', 10, 1, @script_versioning_off) WITH NOWAIT;
                RAISERROR(N'GO', 10, 1) WITH NOWAIT;
                RAISERROR(N'-- Step 2: Rebuild history table', 10, 1) WITH NOWAIT;
            END

            RAISERROR(N'%s', 10, 1, @script_cmd) WITH NOWAIT;

            IF @script_ci_drop IS NOT NULL
                RAISERROR(N'%s', 10, 1, @script_ci_drop) WITH NOWAIT;

            IF @script_is_temporal = 1 AND @script_parent_schema IS NOT NULL
            BEGIN
                RAISERROR(N'GO', 10, 1) WITH NOWAIT;
                RAISERROR(N'-- Step 3: Re-enable SYSTEM_VERSIONING', 10, 1) WITH NOWAIT;
                RAISERROR(N'%s', 10, 1, @script_versioning_on) WITH NOWAIT;
            END

            IF @script_verify IS NOT NULL
            BEGIN
                SET @script_line = N'-- Verify: ' + @script_verify;
                RAISERROR(N'%s', 10, 1, @script_line) WITH NOWAIT;
            END

            RAISERROR(N'GO', 10, 1) WITH NOWAIT;

            FETCH NEXT FROM script_cursor INTO @script_sort, @script_target_id, @script_db, @script_schema, @script_table,
                  @script_action, @script_cmd, @script_ci_drop, @script_verify, @script_est, @script_size,
                  @script_is_temporal, @script_parent_schema, @script_parent_table;
        END
        CLOSE script_cursor;
        DEALLOCATE script_cursor;

        RAISERROR(N'-- ================================================================', 10, 1) WITH NOWAIT;
        RAISERROR(N'-- End of generated script.', 10, 1) WITH NOWAIT;
    END

/*#endregion 19-OUTPUT */

/*#region 20-SCAN-SUMMARY /* HEAP_SCAN_SUMMARY CommandLog entry */ */
    /*-------------------------------------------------------------------------- */
    /* Plan-only scan logging: persist discovery results to CommandLog */
    /*-------------------------------------------------------------------------- */
    IF @PlanOnly = 1 AND @LogToTable = 'Y' AND @commandlog_exists = 1 AND @resume_loaded = 0
    BEGIN
        /* Detect unconsumed (superseded) plan-only scans for overlapping databases */
        BEGIN
            DECLARE @superseded_cnt integer = 0;
            DECLARE @superseded_info nvarchar(max) = N'';

            SELECT @superseded_cnt = COUNT_BIG(*),
                   @superseded_info = STRING_AGG(
                       N'  RunID ' + CONVERT(nvarchar(36), sub.RunID)
                       + N' (' + CONVERT(nvarchar(10), sub.ScanTime, 120)
                       + N', ' + CONVERT(nvarchar(10), sub.TargetCount) + N' targets)',
                       NCHAR(13) + NCHAR(10))
            FROM (
                SELECT
                    cl.ExtendedInfo.value(N'(/ScanSummary/RunID)[1]', N'uniqueidentifier') AS RunID,
                    cl.StartTime AS ScanTime,
                    cl.ExtendedInfo.value(N'(/ScanSummary/TargetCount)[1]', N'int') AS TargetCount
                FROM dbo.CommandLog cl
                WHERE cl.CommandType = N'HEAP_SCAN_SUMMARY'
                  AND cl.StartTime >= DATEADD(DAY, -30, SYSDATETIME())
                  AND cl.ExtendedInfo.value(N'(/ScanSummary/TargetCount)[1]', N'int') > 0
            ) sub
            /* Not consumed by a resume execution */
            WHERE NOT EXISTS (
                SELECT 1 FROM dbo.CommandLog cl2
                WHERE cl2.CommandType = N'HEAP_REBUILD_START'
                  AND cl2.ExtendedInfo.value(N'(/Parameters/ResumedFromRunID)[1]', N'uniqueidentifier') = sub.RunID
            );

            IF @superseded_cnt > 0
            BEGIN
                SET @Msg = N'INFO: Found ' + CONVERT(nvarchar(10), @superseded_cnt)
                         + N' previous plan-only scan(s) from the last 30 days that were never executed:';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                /* Print details (truncate if too long for RAISERROR) */
                IF LEN(@superseded_info) > 3900
                    SET @superseded_info = LEFT(@superseded_info, 3900) + N'...';
                RAISERROR(@superseded_info, 10, 1) WITH NOWAIT;
                RAISERROR(N'  These are now superseded by the current scan.', 10, 1) WITH NOWAIT;
            END
        END

        INSERT INTO dbo.CommandLog
            (DatabaseName, SchemaName, ObjectName, ObjectType, Command, CommandType,
             StartTime, EndTime, ErrorNumber, ErrorMessage, ExtendedInfo)
        VALUES
        (
            ISNULL(@Databases, DB_NAME()),
            N'dbo',
            N'sp_HeapDoctor',
            N'P',
            @invocation_command,
            N'HEAP_SCAN_SUMMARY',
            @start_time,
            SYSDATETIME(),
            0,
            NULL,
            (
                SELECT
                    @Version AS Version,
                    @RankingAlgoVersion AS RankingAlgoVersion,
                    @RunID AS RunID,
                    @TargetCount AS TargetCount,
                    @DatabaseCount AS DatabasesScanned,
                    (SELECT SUM(page_count) FROM #Targets) AS TotalPageCount,
                    CONVERT(decimal(18,2), (SELECT SUM(page_count) FROM #Targets)) / 128.0 AS TotalSizeMB,
                    @CpuSourceUpper AS CpuSource,
                    DATEDIFF(SECOND, @start_time, SYSDATETIME()) AS ElapsedSeconds,
                    CONVERT(nvarchar(30), @SqlServerStartTime, 126) AS SqlServerStartTime,
                    CONVERT(decimal(10,1), @UptimeHours) AS UptimeHours,
                    (SELECT COUNT_BIG(DISTINCT database_name) FROM #Targets) AS DatabasesWithTargets,
                    (SELECT SUM(ISNULL(total_cpu_ms, 0)) FROM #Targets) AS TotalCpuMs,
                    (SELECT SUM(ISNULL(forwarded_record_count, 0)) FROM #Targets) AS TotalForwardedRecordCount,
                    (SELECT SUM(ISNULL(forwarded_fetch_count, 0)) FROM #Targets) AS TotalForwardedFetchCount,
                    CASE WHEN @obfuscate = 1 THEN @effective_seed ELSE NULL END AS ObfuscateSeed,
                    CASE WHEN @obfuscate = 1 THEN CONVERT(nvarchar(max), @obfu_mapping_encrypted, 2) ELSE NULL END AS ObfuscatedMappingHex,
                    (
                        SELECT
                            DatabaseName AS [Name],
                            HeapsQualified,
                            ScanSeconds
                        FROM @DbScanStats
                        ORDER BY DatabaseName
                        FOR XML RAW(N'Database'), TYPE
                    ) AS Databases,
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
                            CONVERT(integer, has_lob_columns) AS HasLobColumns,
                            usage_hint AS UsageHint,
                            nci_count AS NciCount,
                            heap_compression AS HeapCompression,
                            replication_hint AS ReplicationHint,
                            lock_escalation AS LockEscalation,
                            partition_count AS PartitionCount,
                            CONVERT(integer, has_schema_bound_views) AS HasSchemaBoundViews,
                            CONVERT(integer, has_indexed_views) AS HasIndexedViews,
                            data_space_name AS DataSpaceName,
                            CONVERT(integer, has_fk_references) AS HasFkReferences,
                            fk_ref_count AS FkRefCount,
                            page_io_latch_wait_count AS PageIoLatchWaitCount,
                            page_io_latch_wait_ms AS PageIoLatchWaitMs,
                            CONVERT(integer, is_temporal_history) AS IsTemporalHistory,
                            temporal_parent_schema AS TemporalParentSchema,
                            temporal_parent_table AS TemporalParentTable,
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
                            qs_query_hashes AS QsQueryHashes,
                            CASE
                                WHEN action_chosen = 'CI_SWAP_ONLINE' THEN 'CI_SWAP'
                                WHEN action_chosen LIKE 'HEAP_REBUILD%' THEN 'REBUILD'
                                ELSE 'MONITOR'
                            END AS RecommendedAction
                        FROM #Targets
                        ORDER BY sort_order
                        FOR XML RAW(N'Target'), TYPE
                    ) AS Targets
                FOR XML RAW(N'ScanSummary'), ELEMENTS, TYPE
            )
        );

        /* #159: Emit copy-pasteable resume EXEC so the operator can execute without re-scanning */
        IF @TargetCount > 0
        BEGIN
            RAISERROR(N'', 10, 1) WITH NOWAIT;
            SET @Msg = N'To execute these targets without re-scanning, run:';
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            SET @Msg = N'  EXEC dbo.sp_HeapDoctor @ResumeRunID = '''
                     + CONVERT(nvarchar(36), @RunID) + N''', @PlanOnly = 0;';
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        END
    END

/*#endregion 20-SCAN-SUMMARY */

/*#region 21-EXECUTION /* WHILE loop with rebuilds */ */
    /*-------------------------------------------------------------------------- */
    /* Execute if requested */
    /*-------------------------------------------------------------------------- */
    IF @PlanOnly = 0
    BEGIN
        RAISERROR(N'===============================================================================', 10, 1) WITH NOWAIT;
        RAISERROR(N' Executing Rebuilds', 10, 1) WITH NOWAIT;
        RAISERROR(N'===============================================================================', 10, 1) WITH NOWAIT;
        RAISERROR(N'', 10, 1) WITH NOWAIT;

        DECLARE
            @i              integer = 0,
            @cur_sort       integer,
            @tid            integer,
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
            @succeeded_cnt  integer = 0,
            @failed_cnt     integer = 0,
            @skipped_cnt    integer = 0,
            @elapsed_ms     integer,
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
            @err_number          integer,
            @err_message         nvarchar(4000),
            @verify_sql          nvarchar(max),
            @post_fwd_count      bigint,
            @post_row_count      bigint, /* #73: row count validation */
            @ci_drop_failed      bit,
            @cur_index_name      sysname,
            /* QS performance snapshot (per-target, from #Targets) */
            @cur_qs_snapshot_utc    datetime2(3),
            @cur_qs_logical_reads   bigint,
            @cur_qs_physical_reads  bigint,
            @cur_qs_duration_ms     bigint,
            @cur_qs_executions      bigint,
            @cur_qs_plan_count      integer,
            @cur_qs_query_count     integer,
            @cur_qs_query_hashes    nvarchar(max),
            @cur_usage_hint         varchar(30),
            @cur_ranking_score      decimal(8,4),
            @cur_replication_hint   varchar(20),
            @cur_lock_escalation    tinyint,
            @cur_record_count       bigint,
            @cur_nci_count          integer,
            @cur_est_seconds        integer,
            @cur_days_since_rebuild integer,
            @cur_is_temporal_history bit,
            @cur_temporal_parent_schema sysname,
            @cur_temporal_parent_table  sysname,
            @cur_key_source_index sysname, /* #129: NCI disabled TOCTOU check */
            @cur_nci_disabled     bit,     /* #129: NCI disabled TOCTOU check */
            @cur_has_fk_references bit,    /* #130: FK child stats after CI swap */
            @cur_fk_ref_count     integer,         /* #130: FK ref count for stats update */
            @cur_filtered_nci_count integer,        /* #99: filtered NCI count */
            @versioning_sql         nvarchar(max),
            @versioning_log_id      integer,       /* #141: CommandLog breadcrumb for temporal versioning */
            @has_paused_op          bit,
            @preflight_sessions     integer,
            @preflight_bu_sessions  integer,
            @trace_msg              nvarchar(128),
            /* Live calibration for throughput (always tracked; used for estimates when @EstimateTime=1) */
            @live_pages_rebuilt   bigint = 0,
            @live_elapsed_ms     bigint = 0,
            @live_pps            float  = NULL,
            /* Per-action-type live calibration */
            @live_online_pages   bigint = 0,
            @live_online_ms      bigint = 0,
            @live_offline_pages  bigint = 0,
            @live_offline_ms     bigint = 0,
            @live_ciswap_pages   bigint = 0,
            @live_ciswap_ms      bigint = 0,
            @remaining_pages     bigint,
            @remaining_est_sec   integer,
            @rebuild_elapsed_ms  bigint,
            /* Obfuscation: pseudo values for CommandLog/ExecLog (real values stay for RAISERROR/execution) */
            @pseudo_db              sysname,
            @pseudo_schema          sysname,
            @pseudo_tbl             sysname,
            @pseudo_cmd             nvarchar(max),
            @pseudo_ci_drop         nvarchar(max),
            @pseudo_cur_index_name  sysname,
            /* #33: LOB re-check at execution time */
            @cur_heap_compression   tinyint,
            @cur_has_lob            bit,
            /* #79: Log space pre-flight check */
            @cur_log_free_mb        decimal(18,2),
            @cur_est_log_mb         decimal(18,2);

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

            SET @Msg = N'Lock timeout: ' + CONVERT(nvarchar(20), @LockTimeoutMs) + N' ms per rebuild.';
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        END

        /*
        Log run START to CommandLog
        */
        IF @commandlog_exists = 1
        BEGIN
            -- CommandLog START ExtendedInfo: includes invocation params (@Database, @MinPages, @MinForwardedPct,
            -- @PlanOnly, @Execute, @CpuSource, @LogToTable, @TopN, @Tables, @MaxPages, @LookbackDays,
            -- @AllowCiSwap, @PreferCiSwap, @EstimateTime, @Maxdop, @LockTimeoutMs, @MaxRunSeconds).
            -- @BaselineRebuildMBPerMin, @UpdateStatsAfterRebuild, @Force intentionally omitted from START
            -- entry (available in per-rebuild entries and invocation_command). RunID included for correlation.
            INSERT INTO dbo.CommandLog
                (DatabaseName, SchemaName, ObjectName, ObjectType, Command, CommandType, StartTime, ExtendedInfo)
            VALUES
            (
                ISNULL(@Databases, DB_NAME()),
                N'dbo',
                N'sp_HeapDoctor',
                N'P',
                @invocation_command,
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
                        CONVERT(nvarchar(30), @SqlServerStartTime, 126) AS SqlServerStartTime,
                        CONVERT(decimal(10,1), @UptimeHours) AS UptimeHours,
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
            /* Get next target */
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
                @cur_heap_compression  = heap_compression,
                @cur_est_log_mb        = est_log_mb,
                @cur_is_temporal_history      = is_temporal_history,
                @cur_temporal_parent_schema   = temporal_parent_schema,
                @cur_temporal_parent_table    = temporal_parent_table,
                @cur_key_source_index         = key_source_index,
                @cur_has_fk_references        = has_fk_references,
                @cur_fk_ref_count             = fk_ref_count,
                @cur_filtered_nci_count       = filtered_nci_count,
                /* Obfuscation: pseudo values (NULL when not obfuscating) */
                @pseudo_db             = pseudo_database_name,
                @pseudo_schema         = pseudo_schema_name,
                @pseudo_tbl            = pseudo_table_name,
                @pseudo_cmd            = pseudo_command_text,
                @pseudo_ci_drop        = pseudo_ci_drop
            FROM #Targets
            WHERE sort_order > @i
            ORDER BY sort_order;

            IF ROWCOUNT_BIG() = 0 BREAK;

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
                INSERT INTO #ExecLog(target_id, database_name, full_name, action, start_time, end_time, succeeded, error_message)
                VALUES (@tid,
                    CASE WHEN @obfuscate = 1 THEN @pseudo_db ELSE @db END,
                    CASE WHEN @obfuscate = 1
                         THEN QUOTENAME(@pseudo_db) + N'.' + QUOTENAME(@pseudo_schema) + N'.' + QUOTENAME(@pseudo_tbl)
                         ELSE @full END,
                    @action, SYSDATETIME(), SYSDATETIME(), NULL, N'SKIPPED: Object no longer exists.');
                CONTINUE;
            END

            /*
            #63: AG failover safety - check database is still writable before each rebuild.
            If a failover occurred mid-run, the database becomes read-only on the new secondary.
            DATABASEPROPERTYEX is fast (no DMV scan) and catches failover + other read-only states.
            */
            IF DATABASEPROPERTYEX(@db, N'Updateability') <> N'READ_WRITE'
            BEGIN
                SET @Msg = N'  SKIPPED: Database [' + @db + N'] is no longer READ_WRITE'
                         + N' (possible AG failover). Skipping remaining targets in this database.';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                /* Skip all remaining targets for this database */
                UPDATE #Targets SET sort_order = -1
                WHERE database_name = @db AND sort_order > @i;
                SET @skipped_cnt += 1;
                INSERT INTO #ExecLog(target_id, database_name, full_name, action, start_time, end_time, succeeded, error_message)
                VALUES (@tid,
                    CASE WHEN @obfuscate = 1 THEN @pseudo_db ELSE @db END,
                    CASE WHEN @obfuscate = 1
                         THEN QUOTENAME(@pseudo_db) + N'.' + QUOTENAME(@pseudo_schema) + N'.' + QUOTENAME(@pseudo_tbl)
                         ELSE @full END,
                    @action, SYSDATETIME(), SYSDATETIME(), NULL, N'SKIPPED: DATABASE_READONLY (AG failover suspected)');
                CONTINUE;
            END

            /*
            #33: LOB column re-check for CI swap targets (TOCTOU defense).
            Schema may have changed since discovery (especially with @ResumeRunID).
            If LOB columns were added after discovery, fall back to heap rebuild.
            */
            SET @cur_has_lob = 0;
            IF @action = 'CI_SWAP_ONLINE'
            BEGIN
                SET @verify_sql = N'SELECT @has_lob = CASE WHEN EXISTS (
                    SELECT 1 FROM ' + QUOTENAME(@db) + N'.sys.columns c
                    WHERE c.object_id = OBJECT_ID(@full_param)
                      AND c.is_computed = 0
                      AND (c.max_length = -1 OR c.system_type_id IN (34, 35, 99, 241))
                ) THEN 1 ELSE 0 END;';
                BEGIN TRY
                    EXEC sys.sp_executesql @verify_sql,
                        N'@full_param nvarchar(512), @has_lob bit OUTPUT',
                        @full_param = @full, @has_lob = @cur_has_lob OUTPUT;
                END TRY
                BEGIN CATCH
                    SET @cur_has_lob = 0; /* don't block on metadata errors */
                END CATCH

                IF @cur_has_lob = 1
                BEGIN
                    SET @Msg = N'  WARNING: LOB column detected on ' + @full + N' at execution time (schema changed since discovery). Falling back to heap rebuild.';
                    RAISERROR(@Msg, 10, 1) WITH NOWAIT;

                    /* Generate fallback ALTER TABLE REBUILD command */
                    SET @action = CASE WHEN @Online = 1 THEN 'HEAP_REBUILD_ONLINE' ELSE 'HEAP_REBUILD_OFFLINE' END;
                    SET @cmd = N'ALTER TABLE ' + @full + N' REBUILD'
                        + CASE WHEN @Online = 1 OR @cur_heap_compression > 0 OR @Maxdop IS NOT NULL
                            THEN N' WITH ('
                                + CASE WHEN @Online = 1 THEN N'ONLINE = ON' ELSE N'' END
                                + CASE WHEN @Online = 1 AND (@cur_heap_compression > 0 OR @Maxdop IS NOT NULL) THEN N', ' ELSE N'' END
                                + CASE WHEN @cur_heap_compression = 1 THEN N'DATA_COMPRESSION = ROW'
                                       WHEN @cur_heap_compression = 2 THEN N'DATA_COMPRESSION = PAGE'
                                       ELSE N'' END
                                + CASE WHEN @cur_heap_compression > 0 AND @Maxdop IS NOT NULL THEN N', ' ELSE N'' END
                                + ISNULL(N'MAXDOP = ' + CONVERT(nvarchar(10), @Maxdop), N'')
                                + N')'
                            ELSE N'' END
                        + N';';
                    SET @ci_drop = NULL;
                    SET @cur_index_name = NULL;
                    SET @pseudo_cur_index_name = NULL;

                    /* Update #Targets so ExecLog/CommandLog reflect the fallback */
                    UPDATE #Targets
                    SET action_chosen = @action,
                        command_text = @cmd,
                        ci_drop_command = NULL,
                        has_lob_columns = 1
                    WHERE target_id = @tid;
                END
            END

            /*
            #129: NCI disabled TOCTOU check for CI swap targets.
            The candidate NCI could be disabled between discovery and execution.
            If the key source NCI is now disabled, fall back to heap rebuild.
            */
            IF @action = 'CI_SWAP_ONLINE' AND @cur_key_source_index IS NOT NULL
            BEGIN
                SET @cur_nci_disabled = 0;
                BEGIN TRY
                    SET @verify_sql = N'SELECT @is_disabled = is_disabled
                        FROM ' + QUOTENAME(@db) + N'.sys.indexes
                        WHERE object_id = OBJECT_ID(@full_param)
                          AND name = @idx_name;';
                    EXEC sys.sp_executesql @verify_sql,
                        N'@full_param nvarchar(512), @idx_name sysname, @is_disabled bit OUTPUT',
                        @full_param = @full, @idx_name = @cur_key_source_index, @is_disabled = @cur_nci_disabled OUTPUT;
                END TRY
                BEGIN CATCH
                    SET @cur_nci_disabled = 0; /* don't block on metadata errors */
                END CATCH

                IF @cur_nci_disabled = 1
                BEGIN
                    SET @Msg = N'  WARNING: CI swap key source index [' + @cur_key_source_index
                             + N'] on ' + @full + N' has been disabled since discovery. Falling back to heap rebuild.';
                    RAISERROR(@Msg, 10, 1) WITH NOWAIT;

                    /* Generate fallback ALTER TABLE REBUILD command (same pattern as LOB fallback) */
                    SET @action = CASE WHEN @Online = 1 THEN 'HEAP_REBUILD_ONLINE' ELSE 'HEAP_REBUILD_OFFLINE' END;
                    SET @cmd = N'ALTER TABLE ' + @full + N' REBUILD'
                        + CASE WHEN @Online = 1 OR @cur_heap_compression > 0 OR @Maxdop IS NOT NULL
                            THEN N' WITH ('
                                + CASE WHEN @Online = 1 THEN N'ONLINE = ON' ELSE N'' END
                                + CASE WHEN @Online = 1 AND (@cur_heap_compression > 0 OR @Maxdop IS NOT NULL) THEN N', ' ELSE N'' END
                                + CASE WHEN @cur_heap_compression = 1 THEN N'DATA_COMPRESSION = ROW'
                                       WHEN @cur_heap_compression = 2 THEN N'DATA_COMPRESSION = PAGE'
                                       ELSE N'' END
                                + CASE WHEN @cur_heap_compression > 0 AND @Maxdop IS NOT NULL THEN N', ' ELSE N'' END
                                + ISNULL(N'MAXDOP = ' + CONVERT(nvarchar(10), @Maxdop), N'')
                                + N')'
                            ELSE N'' END
                        + N';';
                    SET @ci_drop = NULL;
                    SET @cur_index_name = NULL;
                    SET @pseudo_cur_index_name = NULL;

                    UPDATE #Targets
                    SET action_chosen = @action,
                        command_text = @cmd,
                        ci_drop_command = NULL
                    WHERE target_id = @tid;
                END
            END

            /*
            #79: Log space pre-flight check before rebuild.
            Compare est_log_mb against available log free space.
            Skip rebuild if estimated log consumption exceeds available free space.
            */
            IF @cur_est_log_mb IS NOT NULL AND @cur_est_log_mb > 0
            BEGIN
                SET @cur_log_free_mb = NULL;
                SET @verify_sql = N'USE ' + QUOTENAME(@db) + N';
                    SELECT @free = SUM(CONVERT(bigint, size) * 8.0 / 1024.0
                                     - CONVERT(bigint, FILEPROPERTY(name, N''SpaceUsed'')) * 8.0 / 1024.0)
                    FROM sys.database_files WHERE type = 1;';
                BEGIN TRY
                    EXEC sys.sp_executesql @verify_sql,
                        N'@free decimal(18,2) OUTPUT',
                        @free = @cur_log_free_mb OUTPUT;
                END TRY
                BEGIN CATCH
                    SET @cur_log_free_mb = NULL; /* can't determine, proceed */
                END CATCH

                IF @cur_log_free_mb IS NOT NULL AND @cur_est_log_mb > @cur_log_free_mb
                BEGIN
                    SET @Msg = N'  SKIPPED: ' + @full + N' - estimated log consumption ('
                        + CONVERT(nvarchar(20), CONVERT(integer, @cur_est_log_mb)) + N' MB) exceeds current log free space ('
                        + CONVERT(nvarchar(20), CONVERT(integer, @cur_log_free_mb)) + N' MB). '
                        + N'Autogrowth is not considered; disk may have sufficient space. '
                        + N'Pre-grow the log file or verify disk space before rebuilding.';
                    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                    SET @skipped_cnt += 1;
                    INSERT INTO #ExecLog(target_id, database_name, full_name, action, start_time, end_time, succeeded, error_message)
                    VALUES (@tid,
                        CASE WHEN @obfuscate = 1 THEN @pseudo_db ELSE @db END,
                        CASE WHEN @obfuscate = 1
                             THEN QUOTENAME(@pseudo_db) + N'.' + QUOTENAME(@pseudo_schema) + N'.' + QUOTENAME(@pseudo_tbl)
                             ELSE @full END,
                        @action, SYSDATETIME(), SYSDATETIME(), NULL,
                        N'SKIPPED: LOG_SPACE_INSUFFICIENT (est=' + CONVERT(nvarchar(20), CONVERT(integer, @cur_est_log_mb))
                            + N'MB, free=' + CONVERT(nvarchar(20), CONVERT(integer, @cur_log_free_mb)) + N'MB)');

                    IF @commandlog_exists = 1
                    BEGIN
                        INSERT INTO dbo.CommandLog
                            (DatabaseName, SchemaName, ObjectName, ObjectType, IndexName, IndexType,
                             Command, CommandType,
                             StartTime, EndTime, ErrorNumber, ErrorMessage, ExtendedInfo)
                        VALUES
                        (
                            CASE WHEN @obfuscate = 1 THEN @pseudo_db ELSE @db END,
                            CASE WHEN @obfuscate = 1 THEN @pseudo_schema ELSE @schema END,
                            CASE WHEN @obfuscate = 1 THEN @pseudo_tbl ELSE @tbl END,
                            N'U',
                            @cur_index_name,
                            0,
                            CASE WHEN @obfuscate = 1 THEN @pseudo_cmd ELSE @cmd END,
                            @action,
                            SYSDATETIME(),
                            SYSDATETIME(),
                            NULL,
                            N'SKIPPED: LOG_SPACE_INSUFFICIENT',
                            (
                                SELECT
                                    @Version AS Version,
                                    @cur_est_log_mb AS EstLogMB,
                                    @cur_log_free_mb AS LogFreeMB,
                                    @RunID AS RunID
                                FOR XML RAW(N'ExtendedInfo'), ELEMENTS
                            )
                        );
                    END
                    CONTINUE;
                END
            END

            /*
            Time limit check
            */
            IF @MaxRunSeconds IS NOT NULL
               AND DATEDIFF(SECOND, @RunStart, SYSDATETIME()) >= @MaxRunSeconds
            BEGIN
                RAISERROR(N'', 10, 1) WITH NOWAIT;
                SET @Msg = N'Time limit (' + CONVERT(nvarchar(10), @MaxRunSeconds) + N' seconds) reached. Stopping gracefully.';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;

                /* Log all remaining targets as SKIPPED (both in-memory and CommandLog) */
                INSERT INTO #ExecLog(target_id, database_name, full_name, action, start_time, end_time, succeeded, error_message)
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

                SET @skipped_cnt += (SELECT COUNT_BIG(*) FROM #Targets WHERE sort_order >= @cur_sort);

                /* Persist SKIPPED entries to CommandLog */
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
                                CONVERT(decimal(18,2), page_count) / 128.0 AS SizeMB,
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
            SET @Msg = N'[' + CONVERT(nvarchar(10), @succeeded_cnt + @failed_cnt + 1) + N'/' + CONVERT(nvarchar(10), @TargetCount) + N'] '
                     + @action + N' on ' + @full;

            /* Append per-target estimate if available */
            IF @EstimateTime = 1
            BEGIN
                SET @remaining_est_sec = NULL;
                SELECT @remaining_est_sec = est_seconds FROM #Targets WHERE target_id = @tid;

                IF @remaining_est_sec IS NOT NULL
                    SET @Msg = @Msg + N'  (est: ' + CONVERT(nvarchar(10), @remaining_est_sec) + N's)';
            END

            RAISERROR(@Msg, 10, 1) WITH NOWAIT;

            /* XE observability: raise user event with key metrics */
            BEGIN TRY
                SET @trace_msg = LEFT(
                    N'sp_HeapDoctor: [' + CONVERT(nvarchar(10), @succeeded_cnt + @failed_cnt + 1)
                    + N'/' + CONVERT(nvarchar(10), @TargetCount) + N'] '
                    + @action + N' ' + @full
                    + N' ' + CONVERT(nvarchar(10), @cur_page_count) + N'p'
                    + N' ' + CONVERT(nvarchar(10), @cur_fwd_pct) + N'%fwd'
                    + ISNULL(N' fc=' + CONVERT(nvarchar(15), @cur_fwd_fetch_count), N'')
                    + ISNULL(N' cpu=' + CONVERT(nvarchar(15), @cur_cpu_ms), N''), 128);
                EXEC sp_trace_generateevent @event_class = 82, @userinfo = @trace_msg;
            END TRY
            BEGIN CATCH
                /* #113: Surface XE trace errors at debug level */
                IF @Debug = 1
                BEGIN
                    SET @Msg = N'  [DEBUG] sp_trace_generateevent failed: ' + LEFT(ERROR_MESSAGE(), 500);
                    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                END
            END CATCH

            SET @start = SYSDATETIME();
            INSERT INTO #ExecLog(target_id, database_name, full_name, action, start_time)
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
            DECLARE @preflight_sleeping integer = 0;
            BEGIN TRY
                SET @verify_sql = N'SELECT
                        @cnt = COUNT_BIG(DISTINCT l.request_session_id),
                        @sleeping = ISNULL(SUM(CASE WHEN s.status = N''sleeping'' AND s.open_transaction_count > 0 THEN 1 ELSE 0 END), 0)
                    FROM sys.dm_tran_locks l
                    JOIN sys.dm_exec_sessions s ON s.session_id = l.request_session_id
                    WHERE l.resource_database_id = DB_ID(@db_param)
                      AND l.resource_type = N''OBJECT''
                      AND l.resource_associated_entity_id = OBJECT_ID(@full_param)
                      AND l.request_session_id <> @@SPID
                      AND l.request_status = N''GRANT'';';
                EXEC sys.sp_executesql @verify_sql,
                    N'@db_param sysname, @full_param nvarchar(512), @cnt integer OUTPUT, @sleeping integer OUTPUT',
                    @db_param = @db, @full_param = @full, @cnt = @preflight_sessions OUTPUT, @sleeping = @preflight_sleeping OUTPUT;
            END TRY
            BEGIN CATCH
                SET @preflight_sessions = 0; /* don't block on pre-flight errors */
            END CATCH

            IF ISNULL(@preflight_sessions, 0) > 0
            BEGIN
                SET @Msg = N'  NOTE: ' + CONVERT(nvarchar(10), @preflight_sessions)
                         + N' session(s) hold locks on ' + @full
                         + CASE WHEN @preflight_sleeping > 0
                                THEN N' (' + CONVERT(nvarchar(10), @preflight_sleeping) + N' sleeping with open transactions)'
                                ELSE N'' END
                         + N'. Sch-M acquisition may block or be blocked.';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            END

            /* Bulk update (BU) lock detection */
            SET @preflight_bu_sessions = 0;
            BEGIN TRY
                SET @verify_sql = N'SELECT @cnt = COUNT_BIG(DISTINCT request_session_id)
                    FROM sys.dm_tran_locks
                    WHERE resource_database_id = DB_ID(@db_param)
                      AND resource_type = N''OBJECT''
                      AND resource_associated_entity_id = OBJECT_ID(@full_param)
                      AND request_session_id <> @@SPID
                      AND request_mode = N''BU''
                      AND request_status = N''GRANT'';';
                EXEC sys.sp_executesql @verify_sql,
                    N'@db_param sysname, @full_param nvarchar(512), @cnt integer OUTPUT',
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

            /* Lock escalation warning for online rebuilds (#78: compound CI swap risk) */
            IF @cur_lock_escalation = 0 AND @action IN ('HEAP_REBUILD_ONLINE', 'CI_SWAP_ONLINE')
            BEGIN
                IF @action = 'CI_SWAP_ONLINE'
                    SET @Msg = N'  WARNING: lock_escalation=TABLE on ' + @full
                             + N'. CI swap acquires Sch-M which blocks ALL readers (including NOLOCK).'
                             + N' Combined with TABLE escalation, blocking may persist for the full CI build duration.'
                             + N' Consider scheduling in off-peak window or using @LockTimeoutMs.';
                ELSE
                    SET @Msg = N'  NOTE: lock_escalation=TABLE on ' + @full
                             + N'. Online rebuild may escalate to table lock.';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            END

            /* #75: INSTEAD OF trigger awareness for CI swap targets */
            IF @action = 'CI_SWAP_ONLINE'
            BEGIN
                DECLARE @trigger_names nvarchar(1000) = NULL;
                BEGIN TRY
                    SET @verify_sql = N'SELECT @names = STRING_AGG(t.name, N'', '')
                        FROM ' + QUOTENAME(@db) + N'.sys.triggers t
                        WHERE t.parent_id = OBJECT_ID(@full_param)
                          AND t.is_instead_of_trigger = 1;';
                    EXEC sys.sp_executesql @verify_sql,
                        N'@full_param nvarchar(512), @names nvarchar(1000) OUTPUT',
                        @full_param = @full, @names = @trigger_names OUTPUT;
                END TRY
                BEGIN CATCH
                    SET @trigger_names = NULL; /* don't block on lookup errors */
                END CATCH

                IF @trigger_names IS NOT NULL
                BEGIN
                    SET @Msg = N'  NOTE: ' + @full + N' has INSTEAD OF trigger(s): ' + @trigger_names
                             + N'. DDL operations (CREATE INDEX, ALTER TABLE REBUILD) do not fire DML triggers.';
                    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                END
            END

            /* #89: Replication guard - skip published heaps unless opt-in */
            IF @cur_replication_hint IS NOT NULL AND @cur_replication_hint <> N'CDC'
               AND @AllowReplicationRebuild = 0
            BEGIN
                SET @Msg = N'  SKIPPED: ' + @full + N' is ' + @cur_replication_hint
                         + N'. Rebuild generates ~' + CONVERT(nvarchar(20), ISNULL(@cur_record_count, 0) * 2)
                         + N' replication events (DELETE+INSERT per row).'
                         + N' Use @AllowReplicationRebuild=1 to rebuild published heaps.';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                SET @skipped_cnt += 1;
                INSERT INTO #ExecLog(target_id, database_name, full_name, action, start_time, end_time, succeeded, error_message)
                VALUES (@tid,
                    CASE WHEN @obfuscate = 1 THEN @pseudo_db ELSE @db END,
                    CASE WHEN @obfuscate = 1
                         THEN QUOTENAME(@pseudo_db) + N'.' + QUOTENAME(@pseudo_schema) + N'.' + QUOTENAME(@pseudo_tbl)
                         ELSE @full END,
                    @action, SYSDATETIME(), SYSDATETIME(), NULL,
                    N'SKIPPED: REPLICATION_PUBLISHED (use @AllowReplicationRebuild=1)');
                CONTINUE;
            END

            /* Replication warning during execution (opt-in confirmed or CDC-only) */
            IF @cur_replication_hint IS NOT NULL
            BEGIN
                SET @Msg = N'  NOTE: ' + @full + N' is ' + @cur_replication_hint
                         + N'. Rebuild generates replication log traffic'
                         + CASE WHEN @cur_replication_hint <> N'CDC'
                                THEN N' (~' + CONVERT(nvarchar(20), ISNULL(@cur_record_count, 0) * 2) + N' distributor events)'
                                ELSE N'' END
                         + N'.';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;

                /* CDC + CI swap specific warning */
                IF @cur_replication_hint LIKE '%CDC%' AND @action = 'CI_SWAP_ONLINE'
                BEGIN
                    SET @Msg = N'  WARNING: CDC-tracked table with CI swap. DDL may require capture instance recreation.';
                    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                END
            END

            /*
            #85: Resumable index resume detection.
            If @UseResumable=1 and this is a CI_SWAP_ONLINE, check sys.index_resumable_operations
            for a PAUSED operation on this temp index. If found, RESUME instead of re-creating.
            */
            IF @UseResumable = 1 AND @action = 'CI_SWAP_ONLINE' AND @cur_index_name IS NOT NULL
            BEGIN
                SET @has_paused_op = 0;
                BEGIN TRY
                    /* #103: Filter by exact temp index name to avoid resuming unrelated paused operations */
                    SET @verify_sql = N'SELECT @has_paused = CASE WHEN EXISTS (
                        SELECT 1 FROM ' + QUOTENAME(@db) + N'.sys.index_resumable_operations iro
                        WHERE iro.object_id = OBJECT_ID(@full_param)
                          AND iro.state = 1 /* PAUSED */
                          AND iro.name = @idx_name
                    ) THEN 1 ELSE 0 END;';
                    EXEC sys.sp_executesql @verify_sql,
                        N'@full_param nvarchar(512), @idx_name sysname, @has_paused bit OUTPUT',
                        @full_param = @full, @idx_name = @cur_index_name, @has_paused = @has_paused_op OUTPUT;
                END TRY
                BEGIN CATCH
                    SET @has_paused_op = 0; /* don't block on metadata errors (e.g., DMV unavailable) */
                END CATCH

                IF @has_paused_op = 1
                BEGIN
                    SET @Msg = N'  Resuming paused resumable index operation on ' + @full + N'...';
                    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                    /* Replace the CREATE command with ALTER INDEX ... RESUME */
                    SET @cmd = N'ALTER INDEX ' + QUOTENAME(@cur_index_name)
                             + N' ON ' + @full + N' RESUME'
                             + COALESCE(N' WITH (MAXDOP = ' + CONVERT(nvarchar(10), @Maxdop) + N')', N'') + N';';
                END
            END

            /*
            #84: Temporal history table - disable SYSTEM_VERSIONING on parent before rebuild.
            #141: Write CommandLog breadcrumb before disabling (recovery aid if session is KILLed).
            */
            SET @versioning_log_id = NULL;
            IF @cur_is_temporal_history = 1 AND @cur_temporal_parent_schema IS NOT NULL
            BEGIN
                SET @Msg = N'  Disabling SYSTEM_VERSIONING on ' + QUOTENAME(@db) + N'.'
                         + QUOTENAME(@cur_temporal_parent_schema) + N'.' + QUOTENAME(@cur_temporal_parent_table) + N'...';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;

                SET @versioning_sql = N'ALTER TABLE ' + QUOTENAME(@db) + N'.'
                    + QUOTENAME(@cur_temporal_parent_schema) + N'.' + QUOTENAME(@cur_temporal_parent_table)
                    + N' SET (SYSTEM_VERSIONING = OFF);';

                /* #141: Breadcrumb with re-enable DDL in Command column (recovery if KILLed) */
                IF @commandlog_exists = 1
                BEGIN
                    DECLARE @versioning_reenable_ddl nvarchar(max) = N'ALTER TABLE ' + QUOTENAME(@db) + N'.'
                        + QUOTENAME(@cur_temporal_parent_schema) + N'.' + QUOTENAME(@cur_temporal_parent_table)
                        + N' SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = '
                        + QUOTENAME(@db) + N'.' + QUOTENAME(@schema) + N'.' + QUOTENAME(@tbl) + N'));';
                    INSERT INTO dbo.CommandLog
                        (DatabaseName, SchemaName, ObjectName, ObjectType, Command, CommandType, StartTime)
                    VALUES
                    (
                        @db,
                        @cur_temporal_parent_schema,
                        @cur_temporal_parent_table,
                        N'U',
                        @versioning_reenable_ddl,
                        N'HEAP_TEMPORAL_VERSIONING_DISABLED',
                        SYSDATETIME()
                    );
                    SET @versioning_log_id = SCOPE_IDENTITY();
                END

                BEGIN TRY
                    EXEC sys.sp_executesql @versioning_sql;
                END TRY
                BEGIN CATCH
                    SET @Msg = N'  ERROR disabling SYSTEM_VERSIONING: ' + LEFT(ERROR_MESSAGE(), 500)
                             + N'. Skipping temporal history rebuild.';
                    RAISERROR(@Msg, 16, 1) WITH NOWAIT;
                    SET @skipped_cnt += 1;
                    INSERT INTO #ExecLog(target_id, database_name, full_name, action, start_time, end_time, succeeded, error_message)
                    VALUES (@tid,
                        CASE WHEN @obfuscate = 1 THEN @pseudo_db ELSE @db END,
                        CASE WHEN @obfuscate = 1
                             THEN QUOTENAME(@pseudo_db) + N'.' + QUOTENAME(@pseudo_schema) + N'.' + QUOTENAME(@pseudo_tbl)
                             ELSE @full END,
                        @action, SYSDATETIME(), SYSDATETIME(), NULL,
                        N'SKIPPED: SYSTEM_VERSIONING_DISABLE_FAILED');
                    CONTINUE;
                END CATCH
            END

            /*
            Execute the main command (with lock timeout prefix/suffix)
            */
            SET @exec_cmd = @LockPrefix + @cmd + @LockSuffix;

            BEGIN TRY
                EXEC sys.sp_executesql @exec_cmd;

                /*
                #138: @end is captured here, BEFORE post-rebuild stats update.
                This ensures CommandLog EndTime, #ExecLog, elapsed_ms, and live
                calibration all reflect pure rebuild duration, not stats overhead.
                */
                SET @end = SYSDATETIME();
                SET @elapsed_ms = DATEDIFF(MILLISECOND, @start, @end);
                SET @elapsed_fmt = CASE WHEN @elapsed_ms < 1000
                    THEN CONVERT(nvarchar(10), CONVERT(decimal(5,1), @elapsed_ms) / 1000) + N's'
                    ELSE CONVERT(nvarchar(10), @elapsed_ms / 1000) + N's'
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

                        /* #102: Include exact remediation DROP DDL in warning */
                        DECLARE @ci_drop_ddl nvarchar(max) = N'DROP INDEX ' + QUOTENAME(@cur_index_name)
                            + N' ON ' + @full + N';';
                        SET @Msg = N'  WARNING: CI swap CREATE succeeded but DROP FAILED on ' + @full
                                 + N'. Error ' + CONVERT(nvarchar(10), ERROR_NUMBER())
                                 + N': ' + LEFT(ERROR_MESSAGE(), 1000)
                                 + N'. The table is now a clustered table, NOT a heap.'
                                 + N' Forwarded records are eliminated.'
                                 + N' To restore heap: ' + @ci_drop_ddl;
                        RAISERROR(@Msg, 16, 1) WITH NOWAIT;

                        /* #102: Log CI_SWAP_DROP_FAILED to CommandLog with remediation DDL */
                        IF @commandlog_exists = 1
                        BEGIN
                            INSERT INTO dbo.CommandLog
                                (DatabaseName, SchemaName, ObjectName, ObjectType, IndexName, IndexType,
                                 Command, CommandType,
                                 StartTime, EndTime, ErrorNumber, ErrorMessage, ExtendedInfo)
                            VALUES
                            (
                                CASE WHEN @obfuscate = 1 THEN @pseudo_db     ELSE @db     END,
                                CASE WHEN @obfuscate = 1 THEN @pseudo_schema ELSE @schema END,
                                CASE WHEN @obfuscate = 1 THEN @pseudo_tbl    ELSE @tbl    END,
                                N'U',
                                CASE WHEN @obfuscate = 1 THEN @pseudo_cur_index_name ELSE @cur_index_name END,
                                0,
                                CASE WHEN @obfuscate = 1 THEN @pseudo_ci_drop ELSE @ci_drop_ddl END,
                                N'CI_SWAP_DROP_FAILED',
                                @start,
                                SYSDATETIME(),
                                ERROR_NUMBER(),
                                LEFT(ERROR_MESSAGE(), 1000),
                                (
                                    SELECT
                                        @Version AS Version,
                                        @RunID AS RunID,
                                        @ci_drop_ddl AS RemediationDDL
                                    FOR XML RAW(N'ExtendedInfo'), ELEMENTS
                                )
                            );
                        END

                        /* Restore lock timeout (prefix ran but suffix did not due to error) */
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
                    /* CI DROP failed; table is now clustered (index_id=1), not heap. */
                    /* Forwarded records are eliminated by the CREATE, but we can't verify via index_id=0. */
                    SET @Msg = N'  Skipping post-rebuild verification (table is now clustered due to DROP failure).';
                    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                    SET @post_fwd_count = 0; /* forwarded records ARE gone (CREATE eliminated them) */
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
                        SET @post_fwd_count = NULL; /* verification failed, don't block */
                    END CATCH

                    IF @post_fwd_count IS NOT NULL AND @post_fwd_count > 0
                    BEGIN
                        SET @Msg = N'  WARNING: Post-rebuild check found ' + CONVERT(nvarchar(20), @post_fwd_count)
                                 + N' forwarded records still present on ' + @full + N'.';
                        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                    END
                    ELSE IF @post_fwd_count = 0
                    BEGIN
                        SET @Msg = N'  Verified: 0 forwarded records.';
                        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                    END
                END

                /* #73: Row count validation after rebuild (detect data loss) */
                IF @ci_drop_failed = 0 AND @cur_record_count IS NOT NULL
                BEGIN
                    BEGIN TRY
                        SET @verify_sql = N'SELECT @rows_out = SUM(record_count)
                            FROM sys.dm_db_index_physical_stats(DB_ID(@db_param), OBJECT_ID(@full_param), 0, NULL, ''SAMPLED'')
                            WHERE index_id = 0;';
                        SET @post_row_count = NULL;
                        EXEC sys.sp_executesql @verify_sql,
                            N'@db_param sysname, @full_param nvarchar(512), @rows_out bigint OUTPUT',
                            @db_param = @db, @full_param = @full, @rows_out = @post_row_count OUTPUT;
                    END TRY
                    BEGIN CATCH
                        SET @post_row_count = NULL;
                    END CATCH

                    IF @post_row_count IS NOT NULL
                       AND ABS(@post_row_count - @cur_record_count) > (@cur_record_count * 0.01 + 10)
                    BEGIN
                        SET @Msg = N'  WARNING: Row count changed from '
                            + CONVERT(nvarchar(20), @cur_record_count) + N' to '
                            + CONVERT(nvarchar(20), @post_row_count) + N' on ' + @full
                            + N'. Investigate potential data loss or concurrent DML.';
                        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                    END
                END

                /* #19/#91: Post-rebuild statistics handling */
                IF @UpdateStatsAfterRebuild = 1
                BEGIN
                    BEGIN TRY
                        -- #143: UPDATE STATISTICS does not support 3-part names; use USE [db] + 2-part name.
                        DECLARE @stats_sql nvarchar(max) = N'USE ' + QUOTENAME(@db) + N'; UPDATE STATISTICS '
                            + QUOTENAME(@schema) + N'.' + QUOTENAME(@tbl) + N' WITH FULLSCAN;';
                        DECLARE @stats_start datetime2(3) = SYSDATETIME();
                        EXEC sys.sp_executesql @stats_sql;
                        DECLARE @stats_ms integer = DATEDIFF(MILLISECOND, @stats_start, SYSDATETIME());
                        SET @Msg = N'  Statistics updated on ' + @full
                                 + N' (' + CONVERT(nvarchar(10), @cur_nci_count) + N' NCI(s), '
                                 + CONVERT(nvarchar(10), @stats_ms) + N'ms).';
                        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                    END TRY
                    BEGIN CATCH
                        SET @Msg = N'  WARNING: UPDATE STATISTICS failed on ' + @full + N': ' + LEFT(ERROR_MESSAGE(), 500);
                        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                    END CATCH
                END
                ELSE
                BEGIN
                    /* #93: Heap rebuild holds Sch-M lock; no DML occurs, so modification_counter is unchanged. */
                    /* Statistics are no more stale after rebuild than before. Auto-update threshold is */
                    /* modification-based and will NOT trigger from the rebuild itself. */
                    SET @Msg = N'  Note: Statistics on ' + @full + N' (heap + '
                             + CONVERT(nvarchar(10), @cur_nci_count) + N' NCI(s)) are unchanged by rebuild.'
                             + N' Use @UpdateStatsAfterRebuild=1 to update statistics explicitly.';
                    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                END

                /*
                #130: After CI swap with FK references, UPDATE STATISTICS on FK child table NCIs.
                CI swap changes the base table from heap (RID locators) to clustered (key locators),
                then back. FK child table NCIs reference the parent via row locators that change.
                Auto-statistics may not fire due to low modification counts on child tables.
                */
                IF @action = N'CI_SWAP_ONLINE'
                   AND @cur_has_fk_references = 1
                   AND @UpdateStatsAfterRebuild = 1
                BEGIN
                    BEGIN TRY
                        DECLARE @fk_child_stats_sql nvarchar(max);
                        DECLARE @fk_child_count integer = 0;
                        DECLARE @fk_child_start datetime2(3) = SYSDATETIME();

                        /* Build dynamic SQL to update stats on all FK child table NCIs */
                        SET @fk_child_stats_sql = N'USE ' + QUOTENAME(@db) + N';
DECLARE @child_schema sysname, @child_table sysname, @child_full nvarchar(512);
DECLARE fk_child_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DISTINCT s.name, t.name
    FROM sys.foreign_keys fk
    JOIN sys.tables t ON t.object_id = fk.parent_object_id
    JOIN sys.schemas s ON s.schema_id = t.schema_id
    WHERE fk.referenced_object_id = OBJECT_ID(@ref_full)
      AND EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.type = 2);
OPEN fk_child_cursor;
FETCH NEXT FROM fk_child_cursor INTO @child_schema, @child_table;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @child_full = QUOTENAME(@child_schema) + N''.'' + QUOTENAME(@child_table);
    EXEC(N''UPDATE STATISTICS '' + @child_full + N'' WITH FULLSCAN;'');
    SET @cnt = @cnt + 1;
    FETCH NEXT FROM fk_child_cursor INTO @child_schema, @child_table;
END
CLOSE fk_child_cursor;
DEALLOCATE fk_child_cursor;';
                        EXEC sys.sp_executesql @fk_child_stats_sql,
                            N'@ref_full nvarchar(512), @cnt integer OUTPUT',
                            @ref_full = @full, @cnt = @fk_child_count OUTPUT;

                        IF @fk_child_count > 0
                        BEGIN
                            DECLARE @fk_stats_ms integer = DATEDIFF(MILLISECOND, @fk_child_start, SYSDATETIME());
                            SET @Msg = N'  Statistics updated on ' + CONVERT(nvarchar(10), @fk_child_count)
                                     + N' FK child table(s) (' + CONVERT(nvarchar(10), @fk_stats_ms) + N'ms).';
                            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                        END
                    END TRY
                    BEGIN CATCH
                        SET @Msg = N'  WARNING: FK child table statistics update failed: ' + LEFT(ERROR_MESSAGE(), 500);
                        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                    END CATCH
                END

                /*
                #99: Filtered NCI warning after CI swap.
                Filtered NCI statistics are especially prone to staleness because their small
                row counts make auto-statistics updates infrequent. Warn when @UpdateStatsAfterRebuild=0.
                */
                IF @cur_filtered_nci_count > 0
                   AND @UpdateStatsAfterRebuild = 0
                BEGIN
                    SET @Msg = N'  WARNING: ' + @full + N' has '
                             + CONVERT(nvarchar(10), @cur_filtered_nci_count)
                             + N' filtered NCI(s). Filtered index statistics are prone to staleness after rebuild.'
                             + N' Consider @UpdateStatsAfterRebuild=1 for tables with filtered indexes.';
                    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                END

                /* XE observability: rebuild succeeded with key metrics */
                BEGIN TRY
                    SET @trace_msg = LEFT(N'sp_HeapDoctor: OK ' + @full
                        + N' ' + @elapsed_fmt
                        + N' ' + CONVERT(nvarchar(10), @cur_page_count) + N'p'
                        + ISNULL(N' fc=' + CONVERT(nvarchar(15), @cur_fwd_fetch_count), N'')
                        + N' post=' + ISNULL(CONVERT(nvarchar(10), @post_fwd_count), N'?'), 128);
                    EXEC sp_trace_generateevent @event_class = 82, @userinfo = @trace_msg;
                END TRY
                BEGIN CATCH
                    /* #113: Surface XE trace errors at debug level */
                    IF @Debug = 1
                    BEGIN
                        SET @Msg = N'  [DEBUG] sp_trace_generateevent failed: ' + LEFT(ERROR_MESSAGE(), 500);
                        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                    END
                END CATCH

                /*
                Live calibration: accumulate throughput data from this rebuild.
                Always tracked (not gated on @EstimateTime) so Summary always has throughput.
                Only counts rebuilds that took > 100ms for rate calc (sub-100ms too noisy).
                */
                SET @rebuild_elapsed_ms = @elapsed_ms; /* reuse from line above (same @start/@end) */

                /* Always count pages rebuilt (not gated on timing threshold) */
                SET @live_pages_rebuilt += @cur_page_count;

                IF @rebuild_elapsed_ms > 100
                BEGIN
                    /* Accumulate timing for rate calculation (sub-100ms too noisy for meaningful rate) */
                    SET @live_elapsed_ms   += @rebuild_elapsed_ms;

                    /* Per-action-type rates for more accurate estimates */
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

                    /* Combined rate uses only timed pages (not @live_pages_rebuilt which includes sub-500ms) */
                    SET @live_pps = CONVERT(float, (@live_online_pages + @live_offline_pages + @live_ciswap_pages))
                                  / NULLIF(@live_elapsed_ms / 1000.0, 0);

                    /* Update remaining target estimates with per-action-type live rates */
                    IF @EstimateTime = 1
                    BEGIN
                        UPDATE #Targets
                        SET est_pages_per_sec = CASE action_chosen
                                WHEN N'HEAP_REBUILD_ONLINE'  THEN COALESCE(
                                    CASE WHEN @live_online_ms > 0 THEN CONVERT(float, @live_online_pages) / (@live_online_ms / 1000.0) END,
                                    @live_pps)
                                WHEN N'HEAP_REBUILD_OFFLINE' THEN COALESCE(
                                    CASE WHEN @live_offline_ms > 0 THEN CONVERT(float, @live_offline_pages) / (@live_offline_ms / 1000.0) END,
                                    @live_pps)
                                WHEN N'CI_SWAP_ONLINE'       THEN COALESCE(
                                    CASE WHEN @live_ciswap_ms > 0 THEN CONVERT(float, @live_ciswap_pages) / (@live_ciswap_ms / 1000.0) END,
                                    @live_pps)
                                ELSE @live_pps
                            END,
                            est_seconds = CEILING(page_count / NULLIF(
                                CASE action_chosen
                                    WHEN N'HEAP_REBUILD_ONLINE'  THEN COALESCE(
                                        CASE WHEN @live_online_ms > 0 THEN CONVERT(float, @live_online_pages) / (@live_online_ms / 1000.0) END,
                                        @live_pps)
                                    WHEN N'HEAP_REBUILD_OFFLINE' THEN COALESCE(
                                        CASE WHEN @live_offline_ms > 0 THEN CONVERT(float, @live_offline_pages) / (@live_offline_ms / 1000.0) END,
                                        @live_pps)
                                    WHEN N'CI_SWAP_ONLINE'       THEN COALESCE(
                                        CASE WHEN @live_ciswap_ms > 0 THEN CONVERT(float, @live_ciswap_pages) / (@live_ciswap_ms / 1000.0) END,
                                        @live_pps)
                                    ELSE @live_pps
                                END, 0))
                        WHERE sort_order > @i;

                        UPDATE #Targets
                        SET est_duration = CASE WHEN est_seconds / 3600 < 10
                                                THEN '0' + CONVERT(varchar(10), est_seconds / 3600)
                                                ELSE CONVERT(varchar(10), est_seconds / 3600)
                                           END + ':'
                                         + RIGHT('00' + CONVERT(varchar(2), (est_seconds % 3600) / 60), 2) + ':'
                                         + RIGHT('00' + CONVERT(varchar(2), est_seconds % 60), 2)
                        WHERE sort_order > @i AND est_seconds IS NOT NULL;

                        /* Compute and display remaining time estimate using per-target estimates */
                        SELECT @remaining_est_sec = SUM(est_seconds) FROM #Targets WHERE sort_order > @i AND est_seconds IS NOT NULL;

                        IF @remaining_est_sec IS NOT NULL AND @remaining_est_sec > 0
                        BEGIN

                            SET @Msg = N'  Live rate: ' + CONVERT(nvarchar(20), CONVERT(integer, @live_pps)) + N' pages/sec'
                                     + N'  |  Remaining: ~'
                                     + CASE WHEN @remaining_est_sec / 3600 < 10
                                            THEN '0' + CONVERT(varchar(10), @remaining_est_sec / 3600)
                                            ELSE CONVERT(varchar(10), @remaining_est_sec / 3600)
                                       END + ':'
                                     + RIGHT('00' + CONVERT(varchar(2), (@remaining_est_sec % 3600) / 60), 2) + ':'
                                     + RIGHT('00' + CONVERT(varchar(2), @remaining_est_sec % 60), 2);
                            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                        END
                    END
                END

                /* #67: Cumulative progress after each successful rebuild */
                SET @Msg = N'  Progress: '
                         + CONVERT(nvarchar(10), @succeeded_cnt + @failed_cnt + @skipped_cnt) + N'/' + CONVERT(nvarchar(10), @TargetCount)
                         + N' (' + CONVERT(nvarchar(10), CONVERT(decimal(5,1), (@succeeded_cnt + @failed_cnt + @skipped_cnt) * 100.0 / NULLIF(@TargetCount, 0))) + N'%%)'
                         + N'  |  Pages rebuilt: ' + CONVERT(nvarchar(20), @live_pages_rebuilt)
                         + CASE WHEN @live_pps IS NOT NULL
                                THEN N'  |  Avg: ' + CONVERT(nvarchar(20), CONVERT(integer, @live_pps)) + N' pages/sec'
                                ELSE N'' END;
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;

                /*
                Log success to CommandLog
                */
                IF @commandlog_exists = 1
                BEGIN
                    SET @extended_info = (
                        SELECT
                            @Version AS Version,
                            @cur_page_count AS PageCount,
                            CONVERT(decimal(18,2), @cur_page_count) / 128.0 AS SizeMB,
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
                                 THEN CONVERT(integer, CONVERT(float, @cur_page_count) / (@elapsed_ms / 1000.0))
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

                /* #84: Re-enable SYSTEM_VERSIONING after successful temporal history rebuild */
                IF @cur_is_temporal_history = 1 AND @cur_temporal_parent_schema IS NOT NULL
                BEGIN
                    SET @versioning_sql = N'ALTER TABLE ' + QUOTENAME(@db) + N'.'
                        + QUOTENAME(@cur_temporal_parent_schema) + N'.' + QUOTENAME(@cur_temporal_parent_table)
                        + N' SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = '
                        + QUOTENAME(@db) + N'.' + QUOTENAME(@schema) + N'.' + QUOTENAME(@tbl) + N'));';
                    BEGIN TRY
                        EXEC sys.sp_executesql @versioning_sql;
                        SET @Msg = N'  Re-enabled SYSTEM_VERSIONING on '
                                 + QUOTENAME(@db) + N'.' + QUOTENAME(@cur_temporal_parent_schema) + N'.' + QUOTENAME(@cur_temporal_parent_table) + N'.';
                        RAISERROR(@Msg, 10, 1) WITH NOWAIT;

                        /* #141: Clear breadcrumb - versioning successfully restored */
                        IF @versioning_log_id IS NOT NULL AND @commandlog_exists = 1
                            UPDATE dbo.CommandLog SET EndTime = SYSDATETIME(), ErrorNumber = 0
                            WHERE ID = @versioning_log_id;
                    END TRY
                    BEGIN CATCH
                        SET @Msg = N'  CRITICAL: Failed to re-enable SYSTEM_VERSIONING on '
                                 + QUOTENAME(@db) + N'.' + QUOTENAME(@cur_temporal_parent_schema) + N'.' + QUOTENAME(@cur_temporal_parent_table)
                                 + N': ' + LEFT(ERROR_MESSAGE(), 500)
                                 + N'. MANUAL RE-ENABLE REQUIRED. Skipping remaining targets in [' + @db + N'].';
                        RAISERROR(@Msg, 16, 1) WITH NOWAIT;
                        SET @failed_cnt += 1;
                        INSERT INTO #ExecLog(target_id, database_name, full_name, action, start_time, end_time, succeeded, error_message)
                        VALUES (@tid,
                            CASE WHEN @obfuscate = 1 THEN @pseudo_db ELSE @db END,
                            CASE WHEN @obfuscate = 1
                                 THEN QUOTENAME(@pseudo_db) + N'.' + QUOTENAME(@pseudo_schema) + N'.' + QUOTENAME(@pseudo_tbl)
                                 ELSE @full END,
                            @action, @start, SYSDATETIME(), 0, N'FAILED: SYSTEM_VERSIONING_REENABLE_FAILED');
                        /* Skip remaining targets in this database - temporal table is in unsafe state */
                        UPDATE #Targets SET sort_order = -1
                        WHERE database_name = @db AND sort_order > @i;
                        CONTINUE;
                    END CATCH
                END
            END TRY
            BEGIN CATCH
                SET @end = SYSDATETIME();
                SET @elapsed_ms = DATEDIFF(MILLISECOND, @start, @end);
                SET @elapsed_fmt = CASE WHEN @elapsed_ms < 1000
                    THEN CONVERT(nvarchar(10), CONVERT(decimal(5,1), @elapsed_ms) / 1000) + N's'
                    ELSE CONVERT(nvarchar(10), @elapsed_ms / 1000) + N's'
                END;

                SET @err_number = ERROR_NUMBER();
                SET @err_message = ERROR_MESSAGE();

                /* Restore lock timeout (prefix ran but suffix did not due to error) */
                IF @LockTimeoutMs IS NOT NULL
                    EXEC sys.sp_executesql @LockSuffix;

                UPDATE #ExecLog
                  SET end_time = @end,
                      succeeded = 0,
                      error_number = @err_number,
                      error_message = @err_message
                WHERE target_id = @tid;

                SET @Msg = N'  FAILED (' + @elapsed_fmt + N'): '
                         + N'Error ' + CONVERT(nvarchar(10), @err_number) + N' - '
                         + LEFT(@err_message, 300);
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;

                /* XE observability: rebuild failed */
                BEGIN TRY
                    SET @trace_msg = LEFT(N'sp_HeapDoctor: FAILED ' + @full + N' E' + CONVERT(nvarchar(10), @err_number), 128);
                    EXEC sp_trace_generateevent @event_class = 82, @userinfo = @trace_msg;
                END TRY
                BEGIN CATCH
                    /* #113: Surface XE trace errors at debug level */
                    IF @Debug = 1
                    BEGIN
                        SET @Msg = N'  [DEBUG] sp_trace_generateevent failed: ' + LEFT(ERROR_MESSAGE(), 500);
                        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                    END
                END CATCH

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
                            CONVERT(decimal(18,2), @cur_page_count) / 128.0 AS SizeMB,
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

                /* #84: Re-enable SYSTEM_VERSIONING after failed temporal history rebuild */
                IF @cur_is_temporal_history = 1 AND @cur_temporal_parent_schema IS NOT NULL
                BEGIN
                    SET @versioning_sql = N'ALTER TABLE ' + QUOTENAME(@db) + N'.'
                        + QUOTENAME(@cur_temporal_parent_schema) + N'.' + QUOTENAME(@cur_temporal_parent_table)
                        + N' SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = '
                        + QUOTENAME(@db) + N'.' + QUOTENAME(@schema) + N'.' + QUOTENAME(@tbl) + N'));';
                    BEGIN TRY
                        EXEC sys.sp_executesql @versioning_sql;
                        SET @Msg = N'  Re-enabled SYSTEM_VERSIONING on '
                                 + QUOTENAME(@db) + N'.' + QUOTENAME(@cur_temporal_parent_schema) + N'.' + QUOTENAME(@cur_temporal_parent_table)
                                 + N' (rebuild failed, but versioning restored).';
                        RAISERROR(@Msg, 10, 1) WITH NOWAIT;

                        /* #141: Clear breadcrumb - versioning successfully restored */
                        IF @versioning_log_id IS NOT NULL AND @commandlog_exists = 1
                            UPDATE dbo.CommandLog SET EndTime = SYSDATETIME(), ErrorNumber = 0
                            WHERE ID = @versioning_log_id;
                    END TRY
                    BEGIN CATCH
                        SET @Msg = N'  CRITICAL: Failed to re-enable SYSTEM_VERSIONING on '
                                 + QUOTENAME(@db) + N'.' + QUOTENAME(@cur_temporal_parent_schema) + N'.' + QUOTENAME(@cur_temporal_parent_table)
                                 + N': ' + LEFT(ERROR_MESSAGE(), 500)
                                 + N'. MANUAL RE-ENABLE REQUIRED. Skipping remaining targets in [' + @db + N'].';
                        RAISERROR(@Msg, 16, 1) WITH NOWAIT;
                        /* Do NOT increment @failed_cnt here - outer CATCH already counted this rebuild as failed */
                        /* Skip remaining targets in this database - temporal table is in unsafe state */
                        UPDATE #Targets SET sort_order = -1
                        WHERE database_name = @db AND sort_order > @i;
                    END CATCH
                END
            END CATCH;
        END

        /*
        Summary
        */
        RAISERROR(N'', 10, 1) WITH NOWAIT;
        RAISERROR(N'===============================================================================', 10, 1) WITH NOWAIT;
        SET @Msg = N' Done. Succeeded: ' + CONVERT(nvarchar(10), @succeeded_cnt)
                 + N'  Failed: ' + CONVERT(nvarchar(10), @failed_cnt)
                 + N'  Skipped: ' + CONVERT(nvarchar(10), @skipped_cnt)
                 + CASE WHEN @discovery_errors > 0
                        THEN N'  ScanErrors: ' + CONVERT(nvarchar(10), @discovery_errors)
                        ELSE N'' END
                 + N'  Elapsed: ' + CONVERT(nvarchar(10), DATEDIFF(SECOND, @RunStart, SYSDATETIME())) + N's'
                 + CASE WHEN @live_pps IS NOT NULL
                        THEN N'  AvgRate: ' + CONVERT(nvarchar(20), CONVERT(integer, @live_pps)) + N' pages/sec'
                        ELSE N'' END;
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        RAISERROR(N'===============================================================================', 10, 1) WITH NOWAIT;

        /* XE observability: run complete */
        BEGIN TRY
            SET @trace_msg = LEFT(N'sp_HeapDoctor: Done S=' + CONVERT(nvarchar(10), @succeeded_cnt)
                + N' F=' + CONVERT(nvarchar(10), @failed_cnt)
                + N' K=' + CONVERT(nvarchar(10), @skipped_cnt)
                + N' ' + CONVERT(nvarchar(10), DATEDIFF(SECOND, @RunStart, SYSDATETIME())) + N's', 128);
            EXEC sp_trace_generateevent @event_class = 82, @userinfo = @trace_msg;
        END TRY
        BEGIN CATCH
            /* #113: Surface XE trace errors at debug level */
            IF @Debug = 1
            BEGIN
                SET @Msg = N'  [DEBUG] sp_trace_generateevent failed: ' + LEFT(ERROR_MESSAGE(), 500);
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            END
        END CATCH

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
                @invocation_command,
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
                        CONVERT(integer, @live_pps) AS AvgPagesPerSec,
                        @RunID AS RunID
                    FOR XML RAW(N'Summary'), ELEMENTS
                )
            );
        END

        SELECT * FROM #ExecLog ORDER BY start_time, target_id;
    END

/*#endregion 21-EXECUTION */

/*#region 22-CLEANUP /* Output parameters, sp_releaseapplock, RETURN */ */
    /* Populate output parameters for automation */
    SET @TargetsFound = @TargetCount;
    IF @PlanOnly = 0
    BEGIN
        SET @Succeeded = @succeeded_cnt;
        SET @Failed = @failed_cnt;
        SET @Skipped = @skipped_cnt;
    END

    /* Release re-entrancy guard */
    EXEC sp_releaseapplock @Resource = N'sp_HeapDoctor', @LockOwner = N'Session';

    /* Return non-zero so SQL Agent jobs see failure */
    IF @failed_cnt > 0
        RETURN 1;
END
GO

EXEC sp_MS_marksystemobject 'sp_HeapDoctor';
GO
/*#endregion 22-CLEANUP */
