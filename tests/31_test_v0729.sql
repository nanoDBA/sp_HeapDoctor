/*
sp_HeapDoctor Test Harness - v2026.07.31.1: Remove causal filtered-statistics warning (#186)

Tests:
  -- Issue #186: filtered-NCI staleness warning removed --
  31A - dbo.HeapFiltered (heap with 2 filtered NCIs) is discovered as a target
  31B - Removed: "prone to staleness after rebuild" text absent from proc definition
  31C - Removed: filtered-NCI "@UpdateStatsAfterRebuild=1" recommendation absent
  31D - Kept: correct non-causal note ("unchanged by rebuild") still present
  31E - Kept: filtered_nci_count discovery (FilteredNciCounts CTE + has_filter) still present
  31F - Rebuild with @UpdateStatsAfterRebuild=0 on a filtered-NCI heap succeeds, forwarded = 0
  31G - Rebuild with @UpdateStatsAfterRebuild=1 on a filtered-NCI heap still succeeds
  31H - Reintroduction guard: removed operator-facing message text stays absent

  -- Version --
  31V - Version is 2026.07.31.1

NOTE: The removed WARNING fired via RAISERROR at severity 10 inside the execution
loop. Severity 10 output goes only to the client message stream and cannot be
captured by INSERT...EXEC or a result set, so its ABSENCE cannot be asserted from
T-SQL directly. Tests 31B/31C/31H therefore assert against sys.sql_modules (the
text can no longer be emitted because it no longer exists in the module), and
31F/31G assert the observable behavior: the rebuild still succeeds and still
eliminates forwarded records on a heap carrying filtered NCIs. Both use the
@TargetsFound/@Succeeded OUTPUT parameters so they cannot pass vacuously when
no rebuild actually ran. When running
cross-version, also grep sqlcmd stdout for "prone to staleness" -- it must not appear.

Prerequisites: Run 01_setup_test_data.sql first (creates HeapDoctorTest incl. dbo.HeapFiltered).
Run with: sqlcmd -S YourServer -U sa -P YourPassword -d HeapDoctorTest -i 31_test_v0729.sql
*/

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE [HeapDoctorTest];
GO

/*#region 31-SETUP*/
------------------------------------------------------------------------
-- Capture table (matches sp_HeapDoctor first result set)
------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
CREATE TABLE #Results
(
    version                 nvarchar(20)   NULL,
    target_id               integer        NOT NULL,
    sort_order              integer        NOT NULL,
    database_name           sysname        NOT NULL,
    schema_name             sysname        NOT NULL,
    table_name              sysname        NOT NULL,
    page_count              bigint         NOT NULL,
    record_count            bigint         NULL,
    forwarded_record_count  bigint         NOT NULL,
    forwarded_pct           decimal(6,2)   NOT NULL,
    forwarded_fetch_count   bigint         NULL,
    avg_page_space_pct      decimal(5,2)   NULL,
    avg_frag_pct            decimal(5,2)   NULL,
    ghost_record_count      bigint         NULL,
    total_cpu_ms            bigint         NULL,
    ranking_basis           varchar(20)    NOT NULL,
    nci_count               integer        NOT NULL,
    key_source_index        sysname        NULL,
    action_chosen           varchar(32)    NOT NULL,
    est_pages_per_sec       float          NULL,
    est_seconds             integer        NULL,
    est_duration            nvarchar(20)   NULL,
    qs_snapshot_time_utc    datetime2(3)   NULL,
    qs_total_logical_reads  bigint         NULL,
    qs_total_physical_reads bigint         NULL,
    qs_total_duration_ms    bigint         NULL,
    qs_total_executions     bigint         NULL,
    qs_plan_count           integer        NULL,
    qs_query_count          integer        NULL,
    usage_hint              varchar(30)    NULL,
    ranking_score           decimal(8,4)   NULL,
    ranking_algo_version    nvarchar(10)   NULL,
    heap_compression        varchar(4)     NULL,
    replication_hint        varchar(20)    NULL,
    lock_escalation         varchar(10)    NULL,
    partition_count         integer        NULL,
    has_schema_bound_views  integer        NULL,
    has_indexed_views       integer        NULL,
    has_fk_references       integer        NULL,
    fk_ref_count            integer        NULL,
    filegroup_name          sysname        NULL,
    command_text            nvarchar(max)  NULL,
    ci_drop_command         nvarchar(max)  NULL,
    verify_command          nvarchar(max)  NULL,
    prev_forwarded_pct      decimal(6,2)   NULL,
    rebuilds_in_90d         integer        NULL,
    size_mb                 decimal(18,2)  NULL,
    est_space_savings_mb    decimal(18,2)  NULL,
    est_ci_swap_overhead_mb decimal(18,2)  NULL,
    est_log_mb              decimal(18,2)  NULL,
    days_since_last_rebuild integer        NULL,
    sqlserver_start_time    datetime       NULL,
    uptime_hours            decimal(10,1)  NULL,
    page_io_latch_wait_count bigint        NULL,
    page_io_latch_wait_ms   bigint         NULL,
    is_temporal_history     bit            NULL,
    recommended_action      nvarchar(50)   NULL
);
GO
/*#endregion*/

RAISERROR(N'=== Batch 31: v2026.07.31.1 (#186 filtered-statistics warning removal) ===', 10, 1) WITH NOWAIT;

/*#region 31A*/
------------------------------------------------------------------------
-- 31A: #186 - dbo.HeapFiltered is discovered as a target
-- Confirms the new fixture actually produces forwarded records. Without
-- this, 31F/31G would pass vacuously on an empty target list.
------------------------------------------------------------------------
RAISERROR(N'Test 31A: dbo.HeapFiltered discovered as target (#186)...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables    = N'dbo.HeapFiltered',
    @CpuSource = N'NONE',
    @PlanOnly  = 1;

IF EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapFiltered')
    RAISERROR(N'  PASS 31A: dbo.HeapFiltered discovered as a target.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 31A: dbo.HeapFiltered not discovered. Re-run 01_setup_test_data.sql.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 31B*/
------------------------------------------------------------------------
-- 31B: #186 - "prone to staleness after rebuild" removed from proc
------------------------------------------------------------------------
RAISERROR(N'Test 31B: staleness claim removed from proc definition (#186)...', 10, 1) WITH NOWAIT;

DECLARE @has31b bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%prone to staleness%''
    ) SET @out = 1;',
    N'@out bit OUTPUT',
    @out = @has31b OUTPUT;

IF @has31b = 0
    RAISERROR(N'  PASS 31B: "prone to staleness" no longer present in proc.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 31B: "prone to staleness" still present -- the causal claim survives.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 31C*/
------------------------------------------------------------------------
-- 31C: #186 - filtered-NCI "@UpdateStatsAfterRebuild=1" recommendation removed
------------------------------------------------------------------------
RAISERROR(N'Test 31C: filtered-NCI stats recommendation removed (#186)...', 10, 1) WITH NOWAIT;

DECLARE @has31c bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%Consider @UpdateStatsAfterRebuild=1%''
    ) SET @out = 1;',
    N'@out bit OUTPUT',
    @out = @has31c OUTPUT;

IF @has31c = 0
    RAISERROR(N'  PASS 31C: filtered-NCI stats recommendation removed.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 31C: proc still recommends @UpdateStatsAfterRebuild=1 for filtered indexes.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 31D*/
------------------------------------------------------------------------
-- 31D: #93/#186 - the correct non-causal note is still emitted
-- #186 removes the false warning; it must NOT remove the accurate one.
------------------------------------------------------------------------
RAISERROR(N'Test 31D: correct non-causal statistics note retained (#93/#186)...', 10, 1) WITH NOWAIT;

DECLARE @has31d bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%are unchanged by rebuild%''
    ) SET @out = 1;',
    N'@out bit OUTPUT',
    @out = @has31d OUTPUT;

IF @has31d = 1
    RAISERROR(N'  PASS 31D: non-causal "unchanged by rebuild" note retained.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 31D: the correct #93 note was removed along with the false one.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 31E*/
------------------------------------------------------------------------
-- 31E: #186 - filtered_nci_count discovery is retained
-- The column stays (result-set/discovery contract); only the runtime
-- recommendation it drove was removed.
------------------------------------------------------------------------
RAISERROR(N'Test 31E: filtered_nci_count discovery retained (#186)...', 10, 1) WITH NOWAIT;

DECLARE @has31e bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%FilteredNciCounts%''
          AND definition LIKE N''%has_filter = 1%''
    ) SET @out = 1;',
    N'@out bit OUTPUT',
    @out = @has31e OUTPUT;

IF @has31e = 1
    RAISERROR(N'  PASS 31E: FilteredNciCounts CTE and has_filter predicate retained.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 31E: filtered_nci_count discovery was removed (over-broad fix).', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 31F*/
------------------------------------------------------------------------
-- 31F: #186 - rebuild with @UpdateStatsAfterRebuild=0 on a filtered-NCI heap
-- This is the exact combination that used to emit the false warning.
-- It must succeed and eliminate forwarded records.
--
-- Uses the @TargetsFound / @Succeeded OUTPUT parameters as an anti-vacuous
-- guard: asserting "forwarded = 0" alone would pass trivially if the heap
-- had no forwarded records to begin with and no rebuild ever ran.
--
-- Plain EXEC, not INSERT...EXEC: in execute mode the proc returns an extra
-- result set, so INSERT...EXEC raises Msg 213 even when the rebuild works.
-- Same convention as 03_test_execute.sql.
------------------------------------------------------------------------
RAISERROR(N'Test 31F: rebuild with @UpdateStatsAfterRebuild=0 on filtered-NCI heap (#186)...', 10, 1) WITH NOWAIT;

DECLARE @found31f integer, @succ31f integer, @fwd31f bigint;

EXEC dbo.sp_HeapDoctor
    @Databases               = N'HeapDoctorTest',
    @Tables                  = N'dbo.HeapFiltered',
    @CpuSource               = N'NONE',
    @PlanOnly                = 0,
    @UpdateStatsAfterRebuild = 0,
    @TargetsFound            = @found31f OUTPUT,
    @Succeeded               = @succ31f  OUTPUT;

SELECT @fwd31f = ISNULL(SUM(ips.forwarded_record_count), -1)
FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(N'dbo.HeapFiltered'), 0, NULL, 'SAMPLED') ips;

IF @found31f >= 1 AND @succ31f >= 1 AND @fwd31f = 0
    RAISERROR(N'  PASS 31F: rebuild ran and eliminated forwarded records (stats untouched).', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @m31f nvarchar(500) = N'  FAIL 31F: targets=' + ISNULL(CONVERT(nvarchar(10), @found31f), N'NULL')
        + N' succeeded=' + ISNULL(CONVERT(nvarchar(10), @succ31f), N'NULL')
        + N' forwarded=' + ISNULL(CONVERT(nvarchar(20), @fwd31f), N'NULL')
        + N' (expected targets>=1, succeeded>=1, forwarded=0).';
    RAISERROR(@m31f, 10, 1) WITH NOWAIT;
END
GO
/*#endregion*/

/*#region 31G*/
------------------------------------------------------------------------
-- 31G: #19/#186 - @UpdateStatsAfterRebuild=1 still works on a filtered-NCI heap
-- Regression guard: removing the warning must not disturb the stats path.
--
-- 31F just rebuilt the heap, so forwarded records must be recreated first.
-- A shrink-then-grow UPDATE is NOT enough: after a rebuild the heap holds
-- roughly one large row per page, so shrinking frees space and growing fits
-- back on the same page without forwarding. Reproduce the original setup
-- condition instead -- densely pack short rows, then grow them.
------------------------------------------------------------------------
RAISERROR(N'Test 31G: @UpdateStatsAfterRebuild=1 on filtered-NCI heap (#19/#186)...', 10, 1) WITH NOWAIT;

TRUNCATE TABLE dbo.HeapFiltered;

;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapFiltered (ID, Status, Padding, MoreData)
SELECT TOP (20000)
       n,
       CASE n % 3 WHEN 0 THEN 'PENDING' WHEN 1 THEN 'FAILED' ELSE 'DONE' END,
       REPLICATE('G', 10),
       NULL
FROM N;

UPDATE dbo.HeapFiltered
SET Padding = REPLICATE('X', 3000), MoreData = REPLICATE('Y', 3000)
WHERE ID <= 15000;

DECLARE @found31g integer, @succ31g integer, @fwd31g bigint;

EXEC dbo.sp_HeapDoctor
    @Databases               = N'HeapDoctorTest',
    @Tables                  = N'dbo.HeapFiltered',
    @CpuSource               = N'NONE',
    @PlanOnly                = 0,
    @UpdateStatsAfterRebuild = 1,
    @TargetsFound            = @found31g OUTPUT,
    @Succeeded               = @succ31g  OUTPUT;

SELECT @fwd31g = ISNULL(SUM(ips.forwarded_record_count), -1)
FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(N'dbo.HeapFiltered'), 0, NULL, 'SAMPLED') ips;

IF @found31g >= 1 AND @succ31g >= 1 AND @fwd31g = 0
    RAISERROR(N'  PASS 31G: rebuild + UPDATE STATISTICS ran on filtered-NCI heap.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @m31g nvarchar(500) = N'  FAIL 31G: targets=' + ISNULL(CONVERT(nvarchar(10), @found31g), N'NULL')
        + N' succeeded=' + ISNULL(CONVERT(nvarchar(10), @succ31g), N'NULL')
        + N' forwarded=' + ISNULL(CONVERT(nvarchar(20), @fwd31g), N'NULL')
        + N' (expected targets>=1, succeeded>=1, forwarded=0).';
    RAISERROR(@m31g, 10, 1) WITH NOWAIT;
END
GO
/*#endregion*/

/*#region 31H*/
------------------------------------------------------------------------
-- 31H: #186 - reintroduction guard
-- Asserts the removed MESSAGE text is gone. Deliberately keys on the
-- operator-facing fragment "filtered NCI(s)" rather than on prose like
-- "filtered index statistics", because the #186 comment block legitimately
-- discusses filtered index statistics in order to explain why the warning
-- must not come back. This is the check that would have caught #163.
------------------------------------------------------------------------
RAISERROR(N'Test 31H: reintroduction guard (#186)...', 10, 1) WITH NOWAIT;

DECLARE @has31h bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%filtered NCI(s)%''
    ) SET @out = 1;',
    N'@out bit OUTPUT',
    @out = @has31h OUTPUT;

IF @has31h = 0
    RAISERROR(N'  PASS 31H: removed operator-facing "filtered NCI(s)" message text absent.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 31H: the filtered-NCI statistics message has been reintroduced.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 31V*/
------------------------------------------------------------------------
-- 31V: Version check
------------------------------------------------------------------------
RAISERROR(N'Test 31V: Version check...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly  = 1;

DECLARE @ver31 nvarchar(20);
SELECT TOP (1) @ver31 = version FROM #Results;

IF @ver31 = N'2026.07.31.1'
    RAISERROR(N'  PASS 31V: Version is 2026.07.31.1.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 31V: Version is %s (expected 2026.07.31.1).', 10, 1, @ver31) WITH NOWAIT;
GO
/*#endregion*/

/*#region 31-CLEANUP*/
------------------------------------------------------------------------
-- Cleanup
------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
GO
/*#endregion*/

/*#region 31-SUMMARY*/
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'=== Batch 31 tests complete. Review PASS/FAIL results above. ===', 10, 1) WITH NOWAIT;
GO
/*#endregion*/
