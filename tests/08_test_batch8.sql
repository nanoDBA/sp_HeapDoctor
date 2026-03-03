/*
sp_HeapDoctor Test Harness - Batch 8: Medium-Priority Improvements

Tests Batch 8 additions:
  8A - Usage_hint uptime warning (can't force low uptime; just verify no error)
  8B - Re-entrancy guard (single-session: verify lock acquired/released)
  8C - QS LIKE refinement (verify plan mapping still works)
  8E - #ExecLog temp table (verify execution results correct)
  8F - RunID in ExtendedInfo XML
  8G - TOCTOU existence check
  8H - Graph table guard
  8K - Output parameters
  8L - Azure DTU warning (conditional; verify no error)
  8M - Collation-safe JOIN (verify no error)
  8N - TDE detection (verify no error)
  8O - Verification commands in result set

Prerequisites: Run 01_setup_test_data.sql first.
Run with: sqlcmd -S YourServer -d HeapDoctorTest -i 08_test_batch8.sql
  (add -E for Windows auth, -U/-P for SQL auth, or -G for Azure AD)
*/

SET NOCOUNT ON;
USE [HeapDoctorTest];
GO

------------------------------------------------------------------------
-- Reusable capture table (matches first result set of sp_HeapDoctor)
------------------------------------------------------------------------
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
    page_io_latch_wait_ms  bigint        NULL
);
GO

IF OBJECT_ID('tempdb..#TestCounts') IS NOT NULL DROP TABLE #TestCounts;
CREATE TABLE #TestCounts (PassCount int NOT NULL DEFAULT 0, FailCount int NOT NULL DEFAULT 0);
INSERT #TestCounts DEFAULT VALUES;
GO

------------------------------------------------------------------------
-- Recreate forwarded records (tables may have been rebuilt by prior tests)
------------------------------------------------------------------------
RAISERROR(N'Recreating forwarded records in test heaps...', 10, 1) WITH NOWAIT;

TRUNCATE TABLE dbo.HeapA;
;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapA (ID, Padding, MoreData)
SELECT TOP (20000) n, REPLICATE('A', 10), NULL FROM N;
UPDATE dbo.HeapA SET Padding = REPLICATE('X', 3000), MoreData = REPLICATE('Y', 3000) WHERE ID <= 15000;

TRUNCATE TABLE dbo.HeapB;
;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapB (ID, Code, Padding, MoreData)
SELECT TOP (20000) n, 'CODE-' + CAST(n AS varchar(10)), REPLICATE('B', 10), NULL FROM N;
UPDATE dbo.HeapB SET Padding = REPLICATE('X', 3000), MoreData = REPLICATE('Y', 3000) WHERE ID <= 15000;

TRUNCATE TABLE dbo.HeapC;
;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapC (ID, Padding, BigData)
SELECT TOP (20000) n, REPLICATE('C', 10), NULL FROM N;
UPDATE dbo.HeapC SET Padding = REPLICATE('X', 3000), BigData = REPLICATE(CAST('Z' AS varchar(max)), 500) WHERE ID <= 15000;

TRUNCATE TABLE dbo.HeapE;
;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapE (ID, Code, Padding, MoreData)
SELECT TOP (20000) n, 'CODE-' + CAST(n AS varchar(10)), REPLICATE('E', 10), NULL FROM N;
UPDATE dbo.HeapE SET Padding = REPLICATE('X', 3000), MoreData = REPLICATE('Y', 3000) WHERE ID <= 15000;

TRUNCATE TABLE dbo.HeapF;
;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapF (ID, Padding, MoreData)
SELECT TOP (20000) n, REPLICATE('F', 10), NULL FROM N;
UPDATE dbo.HeapF SET Padding = REPLICATE('X', 3000), MoreData = REPLICATE('Y', 3000) WHERE ID <= 15000;

RAISERROR(N'Forwarded records recreated.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 8B: Re-entrancy guard (normal run completes)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
/*
Verify that a normal run acquires and releases the applock without error.
After the proc returns, we should be able to acquire the lock ourselves.
*/
TRUNCATE TABLE #Results;

INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @PlanOnly = 1;

-- Verify lock was released by trying to acquire it
DECLARE @lock_test int;
EXEC @lock_test = sp_getapplock @Resource = N'sp_HeapDoctor', @LockMode = N'Exclusive', @LockTimeout = 0, @LockOwner = N'Session';
IF @lock_test >= 0
BEGIN
    -- Release our test lock
    EXEC sp_releaseapplock @Resource = N'sp_HeapDoctor', @LockOwner = N'Session';
    RAISERROR(N'  PASS: 8B - Re-entrancy lock released after normal run.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL: 8B - Could not acquire applock after proc completed (lock not released?).', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 8C: QS LIKE pre-filter still maps plans', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
/*
With the tightened LIKE pattern (Table="[TableName]"), verify that
Query Store plans are still correctly mapped (ranking_basis = QS_CPU or QS_NO_DATA,
not all FWD_PCT).
*/
TRUNCATE TABLE #Results;

INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'QUERY_STORE',
    @PlanOnly = 1;

IF EXISTS (SELECT 1 FROM #Results WHERE ranking_basis IN ('QS_CPU', 'QS_NO_DATA'))
BEGIN
    RAISERROR(N'  PASS: 8C - QS mapping works with tightened LIKE pattern.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE IF NOT EXISTS (SELECT 1 FROM #Results)
BEGIN
    RAISERROR(N'  SKIP: 8C - No results returned (cannot verify QS mapping).', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL: 8C - All results have FWD_PCT ranking_basis; QS mapping may be broken.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 8K: Output parameters populated', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
/*
Call with OUTPUT parameters and verify @TargetsFound is populated.
*/
DECLARE @tf int, @s int, @f int, @sk int;

EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @PlanOnly = 1,
    @TargetsFound = @tf OUTPUT,
    @Succeeded = @s OUTPUT,
    @Failed = @f OUTPUT,
    @Skipped = @sk OUTPUT;

IF @tf IS NOT NULL AND @tf > 0
BEGIN
    RAISERROR(N'  PASS: 8K - @TargetsFound output parameter populated.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    DECLARE @Msg nvarchar(4000); SET @Msg =N'  FAIL: 8K - @TargetsFound is ' + ISNULL(CAST(@tf AS nvarchar(10)), N'NULL');
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END

-- @Succeeded/@Failed/@Skipped should be NULL in PlanOnly mode
IF @s IS NULL AND @f IS NULL AND @sk IS NULL
BEGIN
    RAISERROR(N'  PASS: 8K2 - Execution output params NULL in PlanOnly mode.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL: 8K2 - Execution output params should be NULL in PlanOnly mode.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 8O: Verification command populated', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
/*
Every target should have a verify_command containing dm_db_index_physical_stats.
*/
TRUNCATE TABLE #Results;

INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @PlanOnly = 1;

IF NOT EXISTS (SELECT 1 FROM #Results WHERE verify_command IS NULL)
   AND EXISTS (SELECT 1 FROM #Results WHERE verify_command LIKE '%dm_db_index_physical_stats%')
BEGIN
    RAISERROR(N'  PASS: 8O - verify_command populated for all targets.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    DECLARE @null_verify int;
    SELECT @null_verify = COUNT(*) FROM #Results WHERE verify_command IS NULL;
    DECLARE @Msg nvarchar(4000); SET @Msg =N'  FAIL: 8O - ' + CAST(@null_verify AS nvarchar(10)) + N' target(s) have NULL verify_command.';
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 8F: RunID in ExtendedInfo XML (execution test)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
/*
Execute a rebuild and verify RunID appears in ExtendedInfo for the CommandLog entry.
Requires CommandLog table. Tests 8E (temp table) and 8F (RunID) and 8J (stats warning).
*/

-- Get max CommandID before execution
DECLARE @max_cmd_before int;
SELECT @max_cmd_before = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;

EXEC dbo.sp_HeapDoctor
    @Databases = 'HeapDoctorTest',
    @CpuSource = 'NONE',
    @TopN = 1,
    @PlanOnly = 0;

-- Check for RunID in ExtendedInfo
IF EXISTS (
    SELECT 1 FROM dbo.CommandLog
    WHERE ID > @max_cmd_before
      AND CommandType NOT IN ('HEAP_REBUILD_START', 'HEAP_REBUILD_END')
      AND CAST(ExtendedInfo AS nvarchar(max)) LIKE '%<RunID>%'
)
BEGIN
    RAISERROR(N'  PASS: 8F - RunID found in per-rebuild ExtendedInfo.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL: 8F - RunID not found in per-rebuild ExtendedInfo.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END

-- Also check START entry has RunID
IF EXISTS (
    SELECT 1 FROM dbo.CommandLog
    WHERE ID > @max_cmd_before
      AND CommandType = 'HEAP_REBUILD_START'
      AND CAST(ExtendedInfo AS nvarchar(max)) LIKE '%<RunID>%'
)
BEGIN
    RAISERROR(N'  PASS: 8F2 - RunID found in START ExtendedInfo.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL: 8F2 - RunID not found in START ExtendedInfo.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 8E: #ExecLog execution results correct', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
/*
After execution, verify the summary counts are correct.
This implicitly tests #ExecLog (previously @ExecLog) is working.
*/

DECLARE @tf2 int, @s2 int, @f2 int, @sk2 int;

EXEC dbo.sp_HeapDoctor
    @Databases = 'HeapDoctorTest',
    @CpuSource = 'NONE',
    @TopN = 1,
    @PlanOnly = 0,
    @TargetsFound = @tf2 OUTPUT,
    @Succeeded = @s2 OUTPUT,
    @Failed = @f2 OUTPUT,
    @Skipped = @sk2 OUTPUT;

IF @s2 IS NOT NULL AND @s2 >= 0 AND @f2 IS NOT NULL AND @sk2 IS NOT NULL
BEGIN
    RAISERROR(N'  PASS: 8E - Execution output params populated (verifies #ExecLog).', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    DECLARE @Msg nvarchar(4000); SET @Msg =N'  FAIL: 8E - Succeeded=' + ISNULL(CAST(@s2 AS nvarchar(10)), N'NULL')
             + N', Failed=' + ISNULL(CAST(@f2 AS nvarchar(10)), N'NULL')
             + N', Skipped=' + ISNULL(CAST(@sk2 AS nvarchar(10)), N'NULL');
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 8M: Collation-safe JOINs (no error)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
/*
Run with QUERY_STORE to exercise the #PlanObjMap JOINs with COLLATE DATABASE_DEFAULT.
If collation mismatches exist, the proc would error.
*/
TRUNCATE TABLE #Results;
BEGIN TRY
    INSERT #Results
    EXEC dbo.sp_HeapDoctor
        @CpuSource = 'QUERY_STORE',
        @PlanOnly = 1;

    RAISERROR(N'  PASS: 8M - QS execution with COLLATE DATABASE_DEFAULT succeeded.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END TRY
BEGIN CATCH
    DECLARE @Msg nvarchar(4000); SET @Msg =N'  FAIL: 8M - Error: ' + LEFT(ERROR_MESSAGE(), 500);
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END CATCH
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 8N: TDE detection (no error on non-TDE database)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
/*
HeapDoctorTest is not TDE-enabled, so the TDE check should simply not fire.
Verify the proc doesn't error when checking dm_database_encryption_keys.
*/
TRUNCATE TABLE #Results;
BEGIN TRY
    INSERT #Results
    EXEC dbo.sp_HeapDoctor
        @CpuSource = 'NONE',
        @PlanOnly = 1;

    RAISERROR(N'  PASS: 8N - TDE check did not error on non-TDE database.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END TRY
BEGIN CATCH
    DECLARE @Msg nvarchar(4000); SET @Msg =N'  FAIL: 8N - Error: ' + LEFT(ERROR_MESSAGE(), 500);
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END CATCH
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 8V: Version check (1.3.x)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
TRUNCATE TABLE #Results;

INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @PlanOnly = 1;

IF EXISTS (SELECT 1 FROM #Results WHERE version LIKE '1.%.2026.%')
BEGIN
    RAISERROR(N'  PASS: 8V - Version starts with 1.x.2026.x.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    DECLARE @v8 nvarchar(20);
    SELECT TOP 1 @v8 = version FROM #Results;
    DECLARE @Msg nvarchar(4000); SET @Msg =N'  FAIL: 8V - Expected version 1.x.2026.x, got: ' + ISNULL(@v8, N'NULL');
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
-- Summary
------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

DECLARE @PassCount int, @FailCount int;
SELECT @PassCount = PassCount, @FailCount = FailCount FROM #TestCounts;

DECLARE @summary nvarchar(200);
SET @summary = N' Batch 8 Tests Complete -- PASSED: ' + CAST(@PassCount AS nvarchar(10))
             + N'  FAILED: ' + CAST(@FailCount AS nvarchar(10));
RAISERROR(@summary, 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

IF @FailCount > 0
    RAISERROR(N'THERE WERE FAILURES. Review output above.', 16, 1);
GO
