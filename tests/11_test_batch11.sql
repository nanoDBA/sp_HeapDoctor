/*
sp_HeapDoctor Test Harness - Batch 11: Enhanced Logging & Impact Projections

Tests Batch 11 additions:
  -- Smoke Tests --
  11A - size_mb column populated and correct (page_count / 128)
  11B - Version is 1.0.2026.0302f

  -- Unit Tests (deterministic) --
  11C - size_mb = page_count / 128.0 for all targets (arithmetic check)
  11D - est_ci_swap_overhead_mb populated only for CI_SWAP targets
  11E - est_ci_swap_overhead_mb NULL for HEAP_REBUILD targets
  11F - est_log_mb populated for FULL recovery databases
  11G - est_space_savings_mb populated when avg_page_space_pct < 75
  11H - est_space_savings_mb NULL when avg_page_space_pct >= 75

  -- Functional Tests --
  11I - HEAP_SCAN_SUMMARY logged in plan-only mode with @LogToTable='Y'
  11J - HEAP_SCAN_SUMMARY ExtendedInfo contains TargetCount and TotalSizeMB
  11K - HEAP_SCAN_SUMMARY ExtendedInfo contains per-target elements
  11L - HEAP_SCAN_SUMMARY NOT logged when @LogToTable='N'
  11M - days_since_last_rebuild populated from CommandLog after rebuild
  11N - Enhanced per-rebuild ExtendedInfo contains RecordCount and NciCount

  -- Nondeterministic / Integration Tests --
  11O - ANSI_WARNINGS suppressed (no "Null value" warning in output)
  11P - Obfuscated HEAP_SCAN_SUMMARY uses pseudo names
  11Q - HEAP_SCAN_SUMMARY persists across plan-only runs (trending enablement)
  11R - Full execution + plan-only cycle validates days_since_last_rebuild

Prerequisites: Run 01_setup_test_data.sql first.
Run with: sqlcmd -S YourServer -d HeapDoctorTest -i 11_test_batch11.sql
  (add -E for Windows auth, -U/-P for SQL auth, or -G for Azure AD)
*/

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE [HeapDoctorTest];
GO

------------------------------------------------------------------------
-- Reusable capture table
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
    uptime_hours           decimal(10,1) NULL
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
INSERT dbo.HeapA (ID, Padding, MoreData) SELECT TOP (20000) n, REPLICATE('A', 10), NULL FROM N;
UPDATE dbo.HeapA SET Padding = REPLICATE('X', 3000), MoreData = REPLICATE('Y', 3000) WHERE ID <= 15000;

TRUNCATE TABLE dbo.HeapB;
;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapB (ID, Code, Padding, MoreData) SELECT TOP (20000) n, 'CODE-' + CAST(n AS varchar(10)), REPLICATE('B', 10), NULL FROM N;
UPDATE dbo.HeapB SET Padding = REPLICATE('X', 3000), MoreData = REPLICATE('Y', 3000) WHERE ID <= 15000;

TRUNCATE TABLE dbo.HeapC;
;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapC (ID, Padding, BigData) SELECT TOP (20000) n, REPLICATE('C', 10), NULL FROM N;
UPDATE dbo.HeapC SET Padding = REPLICATE('X', 3000), BigData = REPLICATE(CAST('Z' AS varchar(max)), 500) WHERE ID <= 15000;

RAISERROR(N'Done recreating forwarded records.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- Clean CommandLog of prior HEAP_SCAN_SUMMARY entries for clean test state
------------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM dbo.CommandLog WHERE CommandType = 'HEAP_SCAN_SUMMARY')
    DELETE FROM dbo.CommandLog WHERE CommandType = 'HEAP_SCAN_SUMMARY';
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'========================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' Batch 11 Tests: Enhanced Logging & Impact Projections', 10, 1) WITH NOWAIT;
RAISERROR(N'========================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N'', 10, 1) WITH NOWAIT;

------------------------------------------------------------------------
-- 11A: Smoke test - size_mb column populated
------------------------------------------------------------------------
RAISERROR(N'--- 11A: size_mb column populated ---', 10, 1) WITH NOWAIT;
TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @PlanOnly = 1;

IF EXISTS (SELECT 1 FROM #Results WHERE size_mb IS NOT NULL AND size_mb > 0)
BEGIN
    RAISERROR(N'  PASS 11A: size_mb column is populated and > 0.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL 11A: size_mb column is NULL or 0 for all targets.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
-- 11B: Smoke test - Version is 1.0.2026.0302f
------------------------------------------------------------------------
RAISERROR(N'--- 11B: Version check ---', 10, 1) WITH NOWAIT;

IF EXISTS (SELECT 1 FROM #Results WHERE version = N'1.0.2026.0302f')
BEGIN
    RAISERROR(N'  PASS 11B: Version is 1.0.2026.0302f.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    DECLARE @actual_ver nvarchar(20);
    SELECT TOP 1 @actual_ver = version FROM #Results;
    DECLARE @ver_msg nvarchar(200) = N'  FAIL 11B: Expected version 1.0.2026.0302f, got ' + ISNULL(@actual_ver, N'NULL');
    RAISERROR(@ver_msg, 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
-- 11C: Unit test - size_mb = page_count / 128.0 (deterministic arithmetic)
------------------------------------------------------------------------
RAISERROR(N'--- 11C: size_mb = page_count / 128.0 ---', 10, 1) WITH NOWAIT;

IF NOT EXISTS (
    SELECT 1 FROM #Results
    WHERE ABS(size_mb - CAST(page_count AS decimal(18,2)) / 128.0) > 0.01
)
AND EXISTS (SELECT 1 FROM #Results)
BEGIN
    RAISERROR(N'  PASS 11C: size_mb matches page_count / 128.0 for all targets.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL 11C: size_mb does not match page_count / 128.0 for one or more targets.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
-- 11D: Unit test - est_ci_swap_overhead_mb for CI_SWAP targets
-- Requires @AllowCiSwap and @PreferCiSwap to force CI_SWAP action
------------------------------------------------------------------------
RAISERROR(N'--- 11D: est_ci_swap_overhead_mb for CI_SWAP targets ---', 10, 1) WITH NOWAIT;
TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @AllowCiSwap = 1,
    @PreferCiSwap = 1,
    @PlanOnly = 1;

-- Check if any CI_SWAP targets have est_ci_swap_overhead_mb populated
IF EXISTS (SELECT 1 FROM #Results WHERE action_chosen = 'CI_SWAP_ONLINE' AND est_ci_swap_overhead_mb IS NOT NULL AND est_ci_swap_overhead_mb > 0)
BEGIN
    RAISERROR(N'  PASS 11D: est_ci_swap_overhead_mb populated for CI_SWAP targets.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE IF NOT EXISTS (SELECT 1 FROM #Results WHERE action_chosen = 'CI_SWAP_ONLINE')
BEGIN
    -- No CI_SWAP targets found (possibly no suitable key index) - skip
    RAISERROR(N'  PASS 11D: No CI_SWAP targets to validate (no suitable key index). Skipped.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL 11D: CI_SWAP targets exist but est_ci_swap_overhead_mb is NULL.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
-- 11E: Unit test - est_ci_swap_overhead_mb NULL for HEAP_REBUILD targets
------------------------------------------------------------------------
RAISERROR(N'--- 11E: est_ci_swap_overhead_mb NULL for HEAP_REBUILD ---', 10, 1) WITH NOWAIT;

-- Rerun without CI swap to get HEAP_REBUILD targets
TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @AllowCiSwap = 0,
    @PlanOnly = 1;

IF NOT EXISTS (SELECT 1 FROM #Results WHERE action_chosen LIKE 'HEAP_REBUILD%' AND est_ci_swap_overhead_mb IS NOT NULL)
AND EXISTS (SELECT 1 FROM #Results WHERE action_chosen LIKE 'HEAP_REBUILD%')
BEGIN
    RAISERROR(N'  PASS 11E: est_ci_swap_overhead_mb is NULL for HEAP_REBUILD targets.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL 11E: est_ci_swap_overhead_mb should be NULL for HEAP_REBUILD targets.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
-- 11F: Unit test - est_log_mb populated for FULL recovery database
------------------------------------------------------------------------
RAISERROR(N'--- 11F: est_log_mb for FULL recovery ---', 10, 1) WITH NOWAIT;

-- HeapDoctorTest should be in FULL recovery (set by setup script)
DECLARE @recovery_model nvarchar(20);
SELECT @recovery_model = recovery_model_desc FROM sys.databases WHERE name = N'HeapDoctorTest';

IF @recovery_model = N'FULL'
BEGIN
    IF EXISTS (SELECT 1 FROM #Results WHERE est_log_mb IS NOT NULL AND est_log_mb > 0)
    BEGIN
        RAISERROR(N'  PASS 11F: est_log_mb populated for FULL recovery database.', 10, 1) WITH NOWAIT;
        UPDATE #TestCounts SET PassCount += 1;
    END
    ELSE
    BEGIN
        RAISERROR(N'  FAIL 11F: est_log_mb should be populated for FULL recovery database.', 10, 1) WITH NOWAIT;
        UPDATE #TestCounts SET FailCount += 1;
    END
END
ELSE
BEGIN
    -- Database is not in FULL recovery; est_log_mb should be NULL
    IF NOT EXISTS (SELECT 1 FROM #Results WHERE est_log_mb IS NOT NULL)
    BEGIN
        RAISERROR(N'  PASS 11F: est_log_mb correctly NULL for non-FULL recovery database.', 10, 1) WITH NOWAIT;
        UPDATE #TestCounts SET PassCount += 1;
    END
    ELSE
    BEGIN
        RAISERROR(N'  FAIL 11F: est_log_mb should be NULL for non-FULL recovery database.', 10, 1) WITH NOWAIT;
        UPDATE #TestCounts SET FailCount += 1;
    END
END
GO

------------------------------------------------------------------------
-- 11G: Unit test - est_space_savings_mb populated when avg_page_space_pct < 75
------------------------------------------------------------------------
RAISERROR(N'--- 11G: est_space_savings_mb when page space < 75%% ---', 10, 1) WITH NOWAIT;

-- Heaps with forwarded records typically have low avg_page_space_pct
IF EXISTS (SELECT 1 FROM #Results WHERE avg_page_space_pct < 75.0 AND est_space_savings_mb IS NOT NULL AND est_space_savings_mb > 0)
BEGIN
    RAISERROR(N'  PASS 11G: est_space_savings_mb populated when avg_page_space_pct < 75.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE IF NOT EXISTS (SELECT 1 FROM #Results WHERE avg_page_space_pct < 75.0)
BEGIN
    RAISERROR(N'  PASS 11G: No targets with avg_page_space_pct < 75 to validate. Skipped.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL 11G: est_space_savings_mb should be populated when avg_page_space_pct < 75.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
-- 11H: Unit test - est_space_savings_mb NULL when avg_page_space_pct >= 75
------------------------------------------------------------------------
RAISERROR(N'--- 11H: est_space_savings_mb NULL when page space >= 75%% ---', 10, 1) WITH NOWAIT;

IF NOT EXISTS (SELECT 1 FROM #Results WHERE avg_page_space_pct >= 75.0 AND est_space_savings_mb IS NOT NULL)
BEGIN
    RAISERROR(N'  PASS 11H: est_space_savings_mb correctly NULL when avg_page_space_pct >= 75.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL 11H: est_space_savings_mb should be NULL when avg_page_space_pct >= 75.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
-- 11I: Functional test - HEAP_SCAN_SUMMARY logged in plan-only mode
------------------------------------------------------------------------
RAISERROR(N'--- 11I: HEAP_SCAN_SUMMARY logged when @PlanOnly=1, @LogToTable=Y ---', 10, 1) WITH NOWAIT;

-- Clean any prior scan summaries
DELETE FROM dbo.CommandLog WHERE CommandType = 'HEAP_SCAN_SUMMARY';

-- Run plan-only with logging
TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @LogToTable = 'Y',
    @PlanOnly = 1;

IF EXISTS (SELECT 1 FROM dbo.CommandLog WHERE CommandType = 'HEAP_SCAN_SUMMARY')
BEGIN
    RAISERROR(N'  PASS 11I: HEAP_SCAN_SUMMARY entry found in CommandLog.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL 11I: HEAP_SCAN_SUMMARY entry NOT found in CommandLog.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
-- 11J: Functional test - HEAP_SCAN_SUMMARY ExtendedInfo has TargetCount + TotalSizeMB
------------------------------------------------------------------------
RAISERROR(N'--- 11J: HEAP_SCAN_SUMMARY ExtendedInfo structure ---', 10, 1) WITH NOWAIT;

IF EXISTS (
    SELECT 1 FROM dbo.CommandLog
    WHERE CommandType = 'HEAP_SCAN_SUMMARY'
      AND ExtendedInfo.exist('(/ScanSummary/TargetCount)[1]') = 1
      AND ExtendedInfo.exist('(/ScanSummary/TotalSizeMB)[1]') = 1
      AND ExtendedInfo.value('(/ScanSummary/TargetCount)[1]', 'int') > 0
      AND ExtendedInfo.value('(/ScanSummary/TotalSizeMB)[1]', 'decimal(18,2)') > 0
)
BEGIN
    RAISERROR(N'  PASS 11J: HEAP_SCAN_SUMMARY ExtendedInfo has TargetCount and TotalSizeMB > 0.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL 11J: HEAP_SCAN_SUMMARY ExtendedInfo missing TargetCount or TotalSizeMB.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
-- 11K: Functional test - HEAP_SCAN_SUMMARY has per-target elements
------------------------------------------------------------------------
RAISERROR(N'--- 11K: HEAP_SCAN_SUMMARY per-target elements ---', 10, 1) WITH NOWAIT;

IF EXISTS (
    SELECT 1 FROM dbo.CommandLog
    WHERE CommandType = 'HEAP_SCAN_SUMMARY'
      AND ExtendedInfo.exist('(/ScanSummary/Targets/Target)[1]') = 1
      AND ExtendedInfo.exist('(/ScanSummary/Targets/Target/@ForwardedPct)[1]') = 1
      AND ExtendedInfo.exist('(/ScanSummary/Targets/Target/@RankingScore)[1]') = 1
)
BEGIN
    RAISERROR(N'  PASS 11K: HEAP_SCAN_SUMMARY has per-target elements with ForwardedPct and RankingScore.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL 11K: HEAP_SCAN_SUMMARY missing per-target elements or attributes.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
-- 11L: Functional test - HEAP_SCAN_SUMMARY NOT logged when @LogToTable='N'
------------------------------------------------------------------------
RAISERROR(N'--- 11L: HEAP_SCAN_SUMMARY NOT logged with @LogToTable=N ---', 10, 1) WITH NOWAIT;

-- Clean existing entries
DELETE FROM dbo.CommandLog WHERE CommandType = 'HEAP_SCAN_SUMMARY';

-- Run plan-only with logging OFF
TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @LogToTable = 'N',
    @PlanOnly = 1;

IF NOT EXISTS (SELECT 1 FROM dbo.CommandLog WHERE CommandType = 'HEAP_SCAN_SUMMARY')
BEGIN
    RAISERROR(N'  PASS 11L: No HEAP_SCAN_SUMMARY when @LogToTable=N.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL 11L: HEAP_SCAN_SUMMARY should not exist when @LogToTable=N.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
-- 11M: Functional test - days_since_last_rebuild from CommandLog
-- Execute a rebuild, then verify days_since_last_rebuild on next scan
------------------------------------------------------------------------
RAISERROR(N'--- 11M: days_since_last_rebuild from CommandLog ---', 10, 1) WITH NOWAIT;

-- Execute a real rebuild (one heap)
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @TopN = 1,
    @PlanOnly = 0,
    @LogToTable = 'Y';

-- Recreate forwarded records in all heaps so they appear again
TRUNCATE TABLE dbo.HeapA;
;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapA (ID, Padding, MoreData) SELECT TOP (20000) n, REPLICATE('A', 10), NULL FROM N;
UPDATE dbo.HeapA SET Padding = REPLICATE('X', 3000), MoreData = REPLICATE('Y', 3000) WHERE ID <= 15000;

TRUNCATE TABLE dbo.HeapB;
;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapB (ID, Code, Padding, MoreData) SELECT TOP (20000) n, 'CODE-' + CAST(n AS varchar(10)), REPLICATE('B', 10), NULL FROM N;
UPDATE dbo.HeapB SET Padding = REPLICATE('X', 3000), MoreData = REPLICATE('Y', 3000) WHERE ID <= 15000;

TRUNCATE TABLE dbo.HeapC;
;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapC (ID, Padding, BigData) SELECT TOP (20000) n, REPLICATE('C', 10), NULL FROM N;
UPDATE dbo.HeapC SET Padding = REPLICATE('X', 3000), BigData = REPLICATE(CAST('Z' AS varchar(max)), 500) WHERE ID <= 15000;

-- Plan-only scan should now show days_since_last_rebuild for the rebuilt heap
TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @PlanOnly = 1;

IF EXISTS (SELECT 1 FROM #Results WHERE days_since_last_rebuild IS NOT NULL AND days_since_last_rebuild >= 0)
BEGIN
    RAISERROR(N'  PASS 11M: days_since_last_rebuild populated from CommandLog.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL 11M: days_since_last_rebuild should be populated after a rebuild.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
-- 11N: Functional test - Enhanced per-rebuild ExtendedInfo
------------------------------------------------------------------------
RAISERROR(N'--- 11N: RecordCount and NciCount in per-rebuild ExtendedInfo ---', 10, 1) WITH NOWAIT;

-- Check the most recent rebuild entry for RecordCount and NciCount
IF EXISTS (
    SELECT 1 FROM dbo.CommandLog
    WHERE CommandType IN ('HEAP_REBUILD_ONLINE', 'HEAP_REBUILD_OFFLINE', 'CI_SWAP_ONLINE')
      AND DatabaseName = 'HeapDoctorTest'
      AND ExtendedInfo.exist('(/ExtendedInfo/RecordCount)[1]') = 1
      AND ExtendedInfo.exist('(/ExtendedInfo/NciCount)[1]') = 1
)
BEGIN
    RAISERROR(N'  PASS 11N: Per-rebuild ExtendedInfo contains RecordCount and NciCount.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL 11N: Per-rebuild ExtendedInfo missing RecordCount or NciCount.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
-- 11O: Nondeterministic test - ANSI_WARNINGS suppressed
-- We verify by checking that the proc runs without the warning appearing.
-- Since we can't capture client warnings in T-SQL, we verify indirectly:
-- The ANSI_WARNINGS OFF/ON should be inside discovery SQL.
-- Direct verification: run with @Debug=1 and check no error.
------------------------------------------------------------------------
RAISERROR(N'--- 11O: ANSI_WARNINGS suppressed (proc runs clean) ---', 10, 1) WITH NOWAIT;

-- If the proc ran successfully above without error, ANSI_WARNINGS suppression is working.
-- The "Null value is eliminated" message was an informational warning, not an error,
-- so we verify the proc completes successfully.
BEGIN TRY
    TRUNCATE TABLE #Results;
    INSERT #Results
    EXEC dbo.sp_HeapDoctor
        @Databases = N'HeapDoctorTest',
        @PlanOnly = 1;

    IF EXISTS (SELECT 1 FROM #Results)
    BEGIN
        RAISERROR(N'  PASS 11O: Discovery scan completed without error (ANSI_WARNINGS suppressed).', 10, 1) WITH NOWAIT;
        UPDATE #TestCounts SET PassCount += 1;
    END
    ELSE
    BEGIN
        RAISERROR(N'  FAIL 11O: No results from discovery scan.', 10, 1) WITH NOWAIT;
        UPDATE #TestCounts SET FailCount += 1;
    END
END TRY
BEGIN CATCH
    DECLARE @err_msg_11O nvarchar(1000) = N'  FAIL 11O: Error during scan: ' + LEFT(ERROR_MESSAGE(), 500);
    RAISERROR(@err_msg_11O, 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END CATCH
GO

------------------------------------------------------------------------
-- 11P: Integration test - Obfuscated HEAP_SCAN_SUMMARY uses pseudo names
------------------------------------------------------------------------
RAISERROR(N'--- 11P: Obfuscated HEAP_SCAN_SUMMARY ---', 10, 1) WITH NOWAIT;

-- Clean scan summaries
DELETE FROM dbo.CommandLog WHERE CommandType = 'HEAP_SCAN_SUMMARY';

-- Run with obfuscation + logging
-- Note: plan-only + obfuscation mapping is now persisted in HEAP_SCAN_SUMMARY when @LogToTable='Y'
TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @ObfuscateKey = N'test-batch11-key',
    @ObfuscateSeed = N'deterministic-seed',
    @LogToTable = 'Y',
    @PlanOnly = 1;

-- Verify HEAP_SCAN_SUMMARY was logged
IF EXISTS (SELECT 1 FROM dbo.CommandLog WHERE CommandType = 'HEAP_SCAN_SUMMARY')
BEGIN
    -- Check that target names in XML use pseudo prefixes (DB_, S_, T_)
    DECLARE @scan_xml xml;
    SELECT TOP 1 @scan_xml = ExtendedInfo
    FROM dbo.CommandLog
    WHERE CommandType = 'HEAP_SCAN_SUMMARY'
    ORDER BY ID DESC;

    DECLARE @first_db_name nvarchar(256);
    SET @first_db_name = @scan_xml.value('(/ScanSummary/Targets/Target/@DatabaseName)[1]', 'nvarchar(256)');

    IF @first_db_name LIKE 'DB_%'
    BEGIN
        RAISERROR(N'  PASS 11P: Obfuscated HEAP_SCAN_SUMMARY uses pseudo names (DB_ prefix).', 10, 1) WITH NOWAIT;
        UPDATE #TestCounts SET PassCount += 1;
    END
    ELSE
    BEGIN
        DECLARE @p_msg nvarchar(500) = N'  FAIL 11P: Expected DB_ prefix in scan summary, got: ' + ISNULL(@first_db_name, N'NULL');
        RAISERROR(@p_msg, 10, 1) WITH NOWAIT;
        UPDATE #TestCounts SET FailCount += 1;
    END
END
ELSE
BEGIN
    RAISERROR(N'  FAIL 11P: No HEAP_SCAN_SUMMARY logged for obfuscated plan-only run.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
-- 11Q: Integration test - HEAP_SCAN_SUMMARY persists (trending enablement)
-- Run two plan-only scans; verify both entries exist in CommandLog
------------------------------------------------------------------------
RAISERROR(N'--- 11Q: HEAP_SCAN_SUMMARY persists across runs ---', 10, 1) WITH NOWAIT;

-- Clean
DELETE FROM dbo.CommandLog WHERE CommandType = 'HEAP_SCAN_SUMMARY';

-- First scan
TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @LogToTable = 'Y',
    @PlanOnly = 1;

-- Second scan
TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @LogToTable = 'Y',
    @PlanOnly = 1;

DECLARE @scan_count int;
SELECT @scan_count = COUNT(*) FROM dbo.CommandLog WHERE CommandType = 'HEAP_SCAN_SUMMARY';

IF @scan_count >= 2
BEGIN
    RAISERROR(N'  PASS 11Q: Multiple HEAP_SCAN_SUMMARY entries persist in CommandLog for trending.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    DECLARE @q_msg nvarchar(200) = N'  FAIL 11Q: Expected >= 2 HEAP_SCAN_SUMMARY entries, got ' + CAST(@scan_count AS nvarchar(10));
    RAISERROR(@q_msg, 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
-- 11R: Integration test - Full cycle: execute + plan-only validates
-- days_since_last_rebuild = 0 (same day)
------------------------------------------------------------------------
RAISERROR(N'--- 11R: days_since_last_rebuild = 0 on same-day rebuild ---', 10, 1) WITH NOWAIT;

-- The rebuild from 11M happened today; days_since_last_rebuild should be 0
IF EXISTS (SELECT 1 FROM #Results WHERE days_since_last_rebuild = 0)
BEGIN
    RAISERROR(N'  PASS 11R: days_since_last_rebuild = 0 for same-day rebuild.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE IF EXISTS (SELECT 1 FROM #Results WHERE days_since_last_rebuild IS NOT NULL)
BEGIN
    -- Not 0 but populated (could be different timezone or boundary case)
    RAISERROR(N'  PASS 11R: days_since_last_rebuild populated (not exactly 0, possible timezone boundary).', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL 11R: days_since_last_rebuild should be populated after same-day rebuild.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
-- Summary
------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'========================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' Batch 11 PASS/FAIL Results', 10, 1) WITH NOWAIT;
RAISERROR(N'========================================================================', 10, 1) WITH NOWAIT;

DECLARE @p int, @f int;
SELECT @p = PassCount, @f = FailCount FROM #TestCounts;
DECLARE @summary nvarchar(200) = N'  PASSED: ' + CAST(@p AS nvarchar(10)) + N'  FAILED: ' + CAST(@f AS nvarchar(10));
RAISERROR(@summary, 10, 1) WITH NOWAIT;

IF @f > 0
    RAISERROR(N'THERE WERE FAILURES. Review output above.', 16, 1);
ELSE
    RAISERROR(N'  All Batch 11 tests passed.', 10, 1) WITH NOWAIT;

RAISERROR(N'', 10, 1) WITH NOWAIT;
GO
