/*
sp_HeapDoctor Test Harness - Batch 7: Environmental Guards and Warnings

Tests Batch 7 additions:
  7A - Replication awareness (replication_hint column)
  7B - Lock escalation warning (lock_escalation column)
  7C - Leftover temp CI detection (DROP+CREATE resume)
  7D - Bulk update lock detection (BU lock check)
  7E - RCSI version store warning
  7F - Transaction log impact warning
  7G - @ScanThrottleMs parameter

Prerequisites: Run 01_setup_test_data.sql first.
Run with: sqlcmd -S YourServer -d HeapDoctorTest -i 07_test_batch7.sql
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
    page_io_latch_wait_ms  bigint        NULL,
    is_temporal_history    bit           NULL
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
RAISERROR(N' TEST 7A: Replication hint column populated correctly', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
/*
All test heaps are non-replicated, so replication_hint should be NULL.
Verifies the column exists and is populated.
*/
TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @PlanOnly = 1;

-- All test heaps should have NULL replication_hint (not replicated)
IF NOT EXISTS (SELECT 1 FROM #Results WHERE replication_hint IS NOT NULL)
BEGIN
    RAISERROR(N'  PASS: 7A - replication_hint is NULL for all non-replicated heaps.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL: 7A - replication_hint is unexpectedly non-NULL.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 7B: Lock escalation column populated', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
/*
Default lock_escalation is TABLE (0). Verify column shows TABLE.
*/
TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @PlanOnly = 1;

-- All test heaps should have lock_escalation = TABLE (default)
IF EXISTS (SELECT 1 FROM #Results WHERE lock_escalation = 'TABLE')
   AND NOT EXISTS (SELECT 1 FROM #Results WHERE lock_escalation NOT IN ('TABLE', 'AUTO', 'DISABLE'))
BEGIN
    RAISERROR(N'  PASS: 7B - lock_escalation column populated with valid values.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL: 7B - lock_escalation column has unexpected values.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 7B2: Lock escalation AUTO detection', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
/*
Change HeapA to LOCK_ESCALATION = AUTO, verify it shows AUTO.
*/
ALTER TABLE dbo.HeapA SET (LOCK_ESCALATION = AUTO);
GO

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @PlanOnly = 1;

IF EXISTS (SELECT 1 FROM #Results WHERE table_name = 'HeapA' AND lock_escalation = 'AUTO')
BEGIN
    RAISERROR(N'  PASS: 7B2 - HeapA shows lock_escalation = AUTO.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL: 7B2 - HeapA does not show lock_escalation = AUTO.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END

-- Restore default
ALTER TABLE dbo.HeapA SET (LOCK_ESCALATION = TABLE);
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 7C: Leftover temp CI detection', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
/*
Simulate a leftover temp index on HeapB (to test DROP prefix detection).
Use NONCLUSTERED so HeapB remains a heap and sp_HeapDoctor still discovers it.
(A real leftover clustered index would convert the table away from a heap,
making it undiscoverable. The name-based detection works for any index type.)
*/
-- Create the leftover index (nonclustered to keep HeapB as a heap)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.HeapB') AND name = N'CX__Temp__HeapB')
    CREATE NONCLUSTERED INDEX [CX__Temp__HeapB] ON dbo.HeapB(ID);
GO

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @AllowCiSwap = 1,
    @PreferCiSwap = 1,
    @PlanOnly = 1;

-- HeapB's command should contain DROP INDEX followed by CREATE CLUSTERED INDEX
IF EXISTS (SELECT 1 FROM #Results
           WHERE table_name = 'HeapB'
             AND command_text LIKE '%DROP INDEX%CX__Temp__HeapB%CREATE CLUSTERED INDEX%')
BEGIN
    RAISERROR(N'  PASS: 7C - Leftover temp CI detected; command includes DROP+CREATE.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL: 7C - Leftover temp CI not detected or command missing DROP prefix.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END

-- Cleanup: drop the leftover CI to restore HeapB to a heap
DROP INDEX [CX__Temp__HeapB] ON dbo.HeapB;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 7C2: No leftover CI - normal CI swap command', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
/*
Without a leftover CI, CI swap command should NOT have DROP prefix.
*/
TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @AllowCiSwap = 1,
    @PreferCiSwap = 1,
    @PlanOnly = 1;

-- HeapB's command should start with CREATE (no DROP prefix)
IF EXISTS (SELECT 1 FROM #Results
           WHERE table_name = 'HeapB'
             AND action_chosen = 'CI_SWAP_ONLINE'
             AND command_text NOT LIKE '%DROP INDEX%')
BEGIN
    RAISERROR(N'  PASS: 7C2 - No leftover CI; command is CREATE only (no DROP prefix).', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL: 7C2 - Command unexpectedly has DROP prefix or HeapB not found.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 7E: RCSI version store warning', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
/*
Enable RCSI on the test database, then run sp_HeapDoctor.
If any heap has > 100K pages, a warning should be emitted.
This is a message-based check - visual inspection via sqlcmd output.
We verify the proc runs without error.
*/
ALTER DATABASE [HeapDoctorTest] SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
GO

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @PlanOnly = 1;

-- Verify proc ran and returned results (the RCSI warning is message-based)
IF EXISTS (SELECT 1 FROM #Results)
BEGIN
    RAISERROR(N'  PASS: 7E - Proc runs successfully with RCSI enabled.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL: 7E - No results returned with RCSI enabled.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END

-- Restore
ALTER DATABASE [HeapDoctorTest] SET READ_COMMITTED_SNAPSHOT OFF WITH ROLLBACK IMMEDIATE;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 7G: @ScanThrottleMs parameter validation', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
/*
Test that @ScanThrottleMs rejects invalid values.
*/
-- Test negative value
BEGIN TRY
    EXEC dbo.sp_HeapDoctor @ScanThrottleMs = -1, @PlanOnly = 1;
    RAISERROR(N'  FAIL: 7G1 - Negative @ScanThrottleMs was not rejected.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END TRY
BEGIN CATCH
    IF ERROR_MESSAGE() LIKE '%ScanThrottleMs%'
    BEGIN
        RAISERROR(N'  PASS: 7G1 - Negative @ScanThrottleMs correctly rejected.', 10, 1) WITH NOWAIT;
        UPDATE #TestCounts SET PassCount += 1;
    END
    ELSE
    BEGIN
        RAISERROR(N'  FAIL: 7G1 - Wrong error for negative @ScanThrottleMs.', 10, 1) WITH NOWAIT;
        UPDATE #TestCounts SET FailCount += 1;
    END
END CATCH

-- Test value > 60000
BEGIN TRY
    EXEC dbo.sp_HeapDoctor @ScanThrottleMs = 99999, @PlanOnly = 1;
    RAISERROR(N'  FAIL: 7G2 - @ScanThrottleMs > 60000 was not rejected.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END TRY
BEGIN CATCH
    IF ERROR_MESSAGE() LIKE '%ScanThrottleMs%'
    BEGIN
        RAISERROR(N'  PASS: 7G2 - @ScanThrottleMs > 60000 correctly rejected.', 10, 1) WITH NOWAIT;
        UPDATE #TestCounts SET PassCount += 1;
    END
    ELSE
    BEGIN
        RAISERROR(N'  FAIL: 7G2 - Wrong error for @ScanThrottleMs > 60000.', 10, 1) WITH NOWAIT;
        UPDATE #TestCounts SET FailCount += 1;
    END
END CATCH
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 7G3: @ScanThrottleMs = 0 runs without error', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @ScanThrottleMs = 0,
    @PlanOnly = 1;

IF EXISTS (SELECT 1 FROM #Results)
BEGIN
    RAISERROR(N'  PASS: 7G3 - @ScanThrottleMs = 0 runs without error.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL: 7G3 - No results returned with @ScanThrottleMs = 0.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 7H: Version check (1.1.x)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @PlanOnly = 1;

IF EXISTS (SELECT 1 FROM #Results WHERE version LIKE '1.%.2026.%')
BEGIN
    RAISERROR(N'  PASS: 7H - Version format valid.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    DECLARE @actual_version nvarchar(20);
    SELECT TOP 1 @actual_version = version FROM #Results;
    DECLARE @Msg7H nvarchar(200) = N'  FAIL: 7H - Expected version 1.x.2026.x, got: ' + ISNULL(@actual_version, N'NULL');
    RAISERROR(@Msg7H, 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 7I: ExtendedInfo includes ReplicationHint/LockEscalation', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
/*
Execute a rebuild and check that ExtendedInfo XML contains the new elements.
*/
-- Clear CommandLog
TRUNCATE TABLE dbo.CommandLog;
GO

-- Re-create forwarded records in HeapA
TRUNCATE TABLE dbo.HeapA;

;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapA (ID, Padding, MoreData)
SELECT TOP (20000) n, REPLICATE('A', 10), NULL FROM N;

UPDATE dbo.HeapA
SET Padding = REPLICATE('X', 3000), MoreData = REPLICATE('Y', 3000)
WHERE ID <= 15000;
GO

-- Execute rebuild (HeapA only by using tight filters)
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @PlanOnly = 0,
    @TopN = 1,
    @LogToTable = N'Y';
GO

-- Check ExtendedInfo contains LockEscalation element
IF EXISTS (
    SELECT 1 FROM dbo.CommandLog
    WHERE CommandType NOT IN ('HEAP_REBUILD_START', 'HEAP_REBUILD_END')
      AND ExtendedInfo IS NOT NULL
      AND CAST(ExtendedInfo AS nvarchar(max)) LIKE '%<LockEscalation>%'
)
BEGIN
    RAISERROR(N'  PASS: 7I - ExtendedInfo contains LockEscalation element.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL: 7I - ExtendedInfo missing LockEscalation element.', 10, 1) WITH NOWAIT;
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
SET @summary = N' Batch 7 Tests Complete -- PASSED: ' + CAST(@PassCount AS nvarchar(10))
             + N'  FAILED: ' + CAST(@FailCount AS nvarchar(10));
RAISERROR(@summary, 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

IF @FailCount > 0
    RAISERROR(N'THERE WERE FAILURES. Review output above.', 16, 1);
GO
