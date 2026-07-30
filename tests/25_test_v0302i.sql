/*
sp_HeapDoctor Test Harness - v2026.07.29.1: Batch I resumable + temporal

Tests:
  -- Issue #85: Resumable index for CI swap --
  25A - @UseResumable parameter accepted (default=1)
  25B - @UseResumable=0 accepted (opt out)
  25C - RESUMABLE = ON in CI swap DDL (code check)
  25D - Resume detection code exists (sys.index_resumable_operations)
  25E - @UseResumable in invocation_command when 0

  -- Issue #84: Temporal history table support --
  25F - @IncludeTemporalHistory=0 excludes history heaps (default)
  25G - @IncludeTemporalHistory=1 includes history heaps
  25H - Temporal history tables block CI swap (code check)
  25I - SYSTEM_VERSIONING disable/enable code exists
  25J - @IncludeTemporalHistory in invocation_command

  -- Version --
  25V - Version is 2026.07.29.1

Prerequisites: Run 01_setup_test_data.sql first.
Run with: sqlcmd -S YourServer -d HeapDoctorTest -i 25_test_v0302i.sql
*/

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE [HeapDoctorTest];
GO

IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
CREATE TABLE #Results
(
    version                nvarchar(20)  NULL,
    target_id              int           NOT NULL,
    sort_order             int           NOT NULL,
    database_name          sysname       NOT NULL,
    schema_name            sysname       NOT NULL,
    table_name             sysname       NOT NULL,
    page_count             bigint        NOT NULL,
    record_count           bigint        NULL,
    forwarded_record_count bigint        NOT NULL,
    forwarded_pct          decimal(6,2)  NOT NULL,
    forwarded_fetch_count  bigint        NULL,
    avg_page_space_pct     decimal(5,2)  NULL,
    avg_frag_pct           decimal(5,2)  NULL,
    ghost_record_count     bigint        NULL,
    total_cpu_ms           bigint        NULL,
    ranking_basis          varchar(20)   NOT NULL,
    nci_count              int           NOT NULL,
    key_source_index       sysname       NULL,
    action_chosen          varchar(32)   NOT NULL,
    est_pages_per_sec      float         NULL,
    est_seconds            int           NULL,
    est_duration           nvarchar(20)  NULL,
    qs_snapshot_time_utc   datetime2(3)  NULL,
    qs_total_logical_reads bigint        NULL,
    qs_total_physical_reads bigint       NULL,
    qs_total_duration_ms   bigint        NULL,
    qs_total_executions    bigint        NULL,
    qs_plan_count          int           NULL,
    qs_query_count         int           NULL,
    usage_hint             varchar(30)   NULL,
    ranking_score          decimal(8,4)  NULL,
    ranking_algo_version   nvarchar(10)  NULL,
    heap_compression       varchar(4)    NULL,
    replication_hint       varchar(20)   NULL,
    lock_escalation        varchar(10)   NULL,
    partition_count        int           NULL,
    has_schema_bound_views int           NULL,
    has_indexed_views      int           NULL,
    has_fk_references      int           NULL,
    fk_ref_count           int           NULL,
    filegroup_name         sysname       NULL,
    command_text           nvarchar(max) NULL,
    ci_drop_command        nvarchar(max) NULL,
    verify_command         nvarchar(max) NULL,
    prev_forwarded_pct     decimal(6,2)  NULL,
    rebuilds_in_90d        int           NULL,
    size_mb                decimal(18,2) NULL,
    est_space_savings_mb   decimal(18,2) NULL,
    est_ci_swap_overhead_mb decimal(18,2) NULL,
    est_log_mb             decimal(18,2) NULL,
    days_since_last_rebuild int           NULL,
    sqlserver_start_time   datetime      NULL,
    uptime_hours           decimal(10,1) NULL,
    page_io_latch_wait_count bigint      NULL,
    page_io_latch_wait_ms  bigint        NULL,
    is_temporal_history    bit           NULL,
    recommended_action     nvarchar(50)  NULL
);
GO

RAISERROR(N'=== Batch 25: v2026.07.29.1 (#85, #84) ===', 10, 1) WITH NOWAIT;

------------------------------------------------------------------------
-- 25A: #85 - @UseResumable=1 accepted (default)
------------------------------------------------------------------------
RAISERROR(N'Test 25A: @UseResumable=1 accepted (#85)...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @MinPages = 1,
    @UseResumable = 1;

IF EXISTS (SELECT 1 FROM #Results)
    RAISERROR(N'  PASS 25A: @UseResumable=1 accepted.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 25A: No results returned.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 25B: #85 - @UseResumable=0 accepted (opt out)
------------------------------------------------------------------------
RAISERROR(N'Test 25B: @UseResumable=0 accepted (#85)...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @MinPages = 1,
    @UseResumable = 0;

IF EXISTS (SELECT 1 FROM #Results)
    RAISERROR(N'  PASS 25B: @UseResumable=0 accepted.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 25B: No results returned.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 25C: #85 - RESUMABLE = ON in CI swap DDL (code check)
------------------------------------------------------------------------
RAISERROR(N'Test 25C: RESUMABLE = ON in CI swap DDL (#85)...', 10, 1) WITH NOWAIT;

DECLARE @has_resumable bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%RESUMABLE = ON%''
    ) SET @out = 1;',
    N'@out bit OUTPUT',
    @out = @has_resumable OUTPUT;

IF @has_resumable = 1
    RAISERROR(N'  PASS 25C: RESUMABLE = ON found in CI swap DDL.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 25C: RESUMABLE = ON not found in proc.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 25D: #85 - Resume detection code exists (sys.index_resumable_operations)
------------------------------------------------------------------------
RAISERROR(N'Test 25D: Resume detection code exists (#85)...', 10, 1) WITH NOWAIT;

DECLARE @has_resume_detect bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%index_resumable_operations%''
          AND definition LIKE N''%RESUME%''
    ) SET @out = 1;',
    N'@out bit OUTPUT',
    @out = @has_resume_detect OUTPUT;

IF @has_resume_detect = 1
    RAISERROR(N'  PASS 25D: Resume detection (sys.index_resumable_operations + RESUME) found.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 25D: Resume detection not found in proc.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 25E: #85 - @UseResumable=0 in invocation_command
------------------------------------------------------------------------
RAISERROR(N'Test 25E: @UseResumable=0 in invocation_command (#85)...', 10, 1) WITH NOWAIT;

DECLARE @pre_id25e int;
SELECT @pre_id25e = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @LogToTable = N'Y',
    @UseResumable = 0;

DECLARE @cmd25e nvarchar(max);
SELECT TOP 1 @cmd25e = Command
FROM dbo.CommandLog
WHERE ID > @pre_id25e
  AND CommandType = N'HEAP_SCAN_SUMMARY'
ORDER BY ID DESC;

IF @cmd25e LIKE N'%@UseResumable%0%'
    RAISERROR(N'  PASS 25E: @UseResumable=0 found in invocation_command.', 10, 1) WITH NOWAIT;
ELSE IF @cmd25e IS NOT NULL
    RAISERROR(N'  FAIL 25E: @UseResumable not found in Command column.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 25E: No HEAP_SCAN_SUMMARY found.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- Setup: Create temporal history table heap for #84 tests
------------------------------------------------------------------------
RAISERROR(N'  Setup: Creating temporal table with history heap...', 10, 1) WITH NOWAIT;

-- Drop if exists (must disable versioning first)
IF OBJECT_ID(N'dbo.TemporalTest') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.tables WHERE object_id = OBJECT_ID(N'dbo.TemporalTest') AND temporal_type = 2)
        EXEC(N'ALTER TABLE dbo.TemporalTest SET (SYSTEM_VERSIONING = OFF);');
    DROP TABLE IF EXISTS dbo.TemporalTest;
END
DROP TABLE IF EXISTS dbo.TemporalTestHistory;
GO

CREATE TABLE dbo.TemporalTestHistory
(
    ID    int          NOT NULL,
    Col1  nvarchar(50) NULL,
    SysStartTime datetime2 NOT NULL,
    SysEndTime   datetime2 NOT NULL
);
GO

CREATE TABLE dbo.TemporalTest
(
    ID    int          NOT NULL PRIMARY KEY CLUSTERED,
    Col1  nvarchar(50) NULL,
    SysStartTime datetime2 GENERATED ALWAYS AS ROW START NOT NULL,
    SysEndTime   datetime2 GENERATED ALWAYS AS ROW END   NOT NULL,
    PERIOD FOR SYSTEM_TIME (SysStartTime, SysEndTime)
) WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.TemporalTestHistory));
GO

-- Populate base table
DECLARE @t25 int = 1;
WHILE @t25 <= 2000
BEGIN
    INSERT dbo.TemporalTest(ID, Col1) VALUES (@t25, REPLICATE(N'X', 10));
    SET @t25 += 1;
END
-- Update to create versions (rows move to history with small Col1)
UPDATE dbo.TemporalTest SET Col1 = REPLICATE(N'Y', 10);
GO

-- Disable versioning to create forwarded records in history table
ALTER TABLE dbo.TemporalTest SET (SYSTEM_VERSIONING = OFF);
GO
-- Update history rows to be larger (creates forwarded records)
UPDATE dbo.TemporalTestHistory SET Col1 = REPLICATE(N'Z', 50);
GO
-- Re-enable versioning
ALTER TABLE dbo.TemporalTest SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.TemporalTestHistory));
GO

------------------------------------------------------------------------
-- 25F: #84 - @IncludeTemporalHistory=0 excludes history heaps
------------------------------------------------------------------------
RAISERROR(N'Test 25F: @IncludeTemporalHistory=0 excludes history heaps (#84)...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @MinPages = 1;

IF NOT EXISTS (SELECT 1 FROM #Results WHERE table_name = N'TemporalTestHistory')
    RAISERROR(N'  PASS 25F: TemporalTestHistory excluded (default @IncludeTemporalHistory=0).', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 25F: TemporalTestHistory found in results (should be excluded).', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 25G: #84 - @IncludeTemporalHistory=1 includes history heaps
------------------------------------------------------------------------
RAISERROR(N'Test 25G: @IncludeTemporalHistory=1 includes history heaps (#84)...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @MinPages = 1,
    @IncludeTemporalHistory = 1;

IF EXISTS (SELECT 1 FROM #Results WHERE table_name = N'TemporalTestHistory')
BEGIN
    -- Check is_temporal_history flag
    IF EXISTS (SELECT 1 FROM #Results WHERE table_name = N'TemporalTestHistory' AND is_temporal_history = 1)
        RAISERROR(N'  PASS 25G: TemporalTestHistory included with is_temporal_history=1.', 10, 1) WITH NOWAIT;
    ELSE
        RAISERROR(N'  FAIL 25G: TemporalTestHistory included but is_temporal_history not set.', 10, 1) WITH NOWAIT;
END
ELSE
    RAISERROR(N'  FAIL 25G: TemporalTestHistory not found in results.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 25H: #84 - Temporal history tables block CI swap (code check)
------------------------------------------------------------------------
RAISERROR(N'Test 25H: Temporal history blocks CI swap (#84)...', 10, 1) WITH NOWAIT;

DECLARE @has_temporal_ci_block bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%is_temporal_history = 0%CI_SWAP%''
    ) SET @out = 1;',
    N'@out bit OUTPUT',
    @out = @has_temporal_ci_block OUTPUT;

IF @has_temporal_ci_block = 1
    RAISERROR(N'  PASS 25H: is_temporal_history = 0 guard found in CI swap conditions.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 25H: Temporal CI swap guard not found in proc.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 25I: #84 - SYSTEM_VERSIONING disable/enable code exists
------------------------------------------------------------------------
RAISERROR(N'Test 25I: SYSTEM_VERSIONING disable/enable code exists (#84)...', 10, 1) WITH NOWAIT;

DECLARE @has_versioning bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%SYSTEM_VERSIONING = OFF%''
          AND definition LIKE N''%SYSTEM_VERSIONING = ON%HISTORY_TABLE%''
    ) SET @out = 1;',
    N'@out bit OUTPUT',
    @out = @has_versioning OUTPUT;

IF @has_versioning = 1
    RAISERROR(N'  PASS 25I: SYSTEM_VERSIONING disable/enable code found.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 25I: SYSTEM_VERSIONING lifecycle code not found.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 25J: #84 - @IncludeTemporalHistory in invocation_command
------------------------------------------------------------------------
RAISERROR(N'Test 25J: @IncludeTemporalHistory in invocation_command (#84)...', 10, 1) WITH NOWAIT;

DECLARE @pre_id25j int;
SELECT @pre_id25j = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @LogToTable = N'Y',
    @IncludeTemporalHistory = 1;

DECLARE @cmd25j nvarchar(max);
SELECT TOP 1 @cmd25j = Command
FROM dbo.CommandLog
WHERE ID > @pre_id25j
  AND CommandType = N'HEAP_SCAN_SUMMARY'
ORDER BY ID DESC;

IF @cmd25j LIKE N'%@IncludeTemporalHistory%'
    RAISERROR(N'  PASS 25J: @IncludeTemporalHistory found in invocation_command.', 10, 1) WITH NOWAIT;
ELSE IF @cmd25j IS NOT NULL
    RAISERROR(N'  FAIL 25J: @IncludeTemporalHistory not found in Command column.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 25J: No HEAP_SCAN_SUMMARY found.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 25V: Version check
------------------------------------------------------------------------
RAISERROR(N'Test 25V: Version check...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1;

DECLARE @ver25 nvarchar(20);
SELECT TOP 1 @ver25 = version FROM #Results;

IF @ver25 = N'2026.07.29.1'
    RAISERROR(N'  PASS 25V: Version is 2026.07.29.1.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 25V: Version is %s (expected 2026.07.29.1).', 10, 1, @ver25) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- Cleanup
------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.TemporalTest') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.tables WHERE object_id = OBJECT_ID(N'dbo.TemporalTest') AND temporal_type = 2)
        EXEC(N'ALTER TABLE dbo.TemporalTest SET (SYSTEM_VERSIONING = OFF);');
    DROP TABLE dbo.TemporalTest;
END
DROP TABLE IF EXISTS dbo.TemporalTestHistory;
IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'Batch 25 tests complete. Review PASS/FAIL results above.', 10, 1) WITH NOWAIT;
GO
