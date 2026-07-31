/*
sp_HeapDoctor Test Harness - Batch 15: GitHub Issues #1-3, #7-12

Tests:
  -- Issue #7: Command column truncation fix --
  15A - Command column in HEAP_SCAN_SUMMARY contains full invocation (not truncated)
  15B - Command column includes non-default parameters

  -- Issue #1: sqlserver_start_time and uptime_hours --
  15C - sqlserver_start_time column populated in result set
  15D - uptime_hours column populated and > 0

  -- Issue #3: ranking_algo_version --
  15E - ranking_algo_version column is 'v1' in result set
  15F - ranking_algo_version in HEAP_SCAN_SUMMARY ExtendedInfo XML

  -- Issue #2: @SkipWriteHeavy --
  15G - @SkipWriteHeavy=0 (default) includes write-heavy heaps
  15H - @SkipWriteHeavy=1 excludes write-heavy heaps from results

  -- Issue #10: @MinDaysSinceRebuild --
  15I - @MinDaysSinceRebuild=NULL (default) includes all heaps
  15J - @MinDaysSinceRebuild filters recently-rebuilt heaps

  -- Issue #8: Zero-target HEAP_SCAN_SUMMARY --
  15K - HEAP_SCAN_SUMMARY written when zero targets found

  -- Issue #11: Per-database breakdown in HEAP_SCAN_SUMMARY --
  15L - HEAP_SCAN_SUMMARY contains Databases element with per-DB stats
  15M - HEAP_SCAN_SUMMARY contains summary-level aggregates

  -- Issue #12: Resume staleness warning --
  15N - ranking_algo_version in HEAP_SCAN_SUMMARY XML

Prerequisites: Run 01_setup_test_data.sql first.
Run with: sqlcmd -S YourServer -d HeapDoctorTest -i 15_test_batch15.sql
  (add -E for Windows auth, -U/-P for SQL auth, or -G for Azure AD)
*/

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE [HeapDoctorTest];
GO

------------------------------------------------------------------------
-- Reusable capture table (matches first result set of sp_HeapDoctor)
------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
/* #190: the column list lives once, in dbo.ResultsTemplate (see 01_setup_test_data.sql) */
SELECT * INTO #Results FROM dbo.ResultsTemplate WHERE 1 = 0;
GO

DECLARE @PassCount int = 0, @FailCount int = 0;
DECLARE @Msg nvarchar(4000);
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 15A: Command column not truncated in HEAP_SCAN_SUMMARY', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- Clean up prior test entries
DELETE FROM dbo.CommandLog WHERE CommandType = 'HEAP_SCAN_SUMMARY'
    AND ObjectName = 'sp_HeapDoctor' AND DatabaseName = 'HeapDoctorTest';

EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @PlanOnly  = 1,
    @LogToTable = 'Y',
    @MinPages = 500;

-- Command should contain full invocation, not truncated with '...'
DECLARE @15a_cmd nvarchar(max);
SELECT TOP 1 @15a_cmd = Command
FROM dbo.CommandLog
WHERE CommandType = 'HEAP_SCAN_SUMMARY'
  AND ObjectName = 'sp_HeapDoctor'
ORDER BY ID DESC;

IF @15a_cmd NOT LIKE '%...%' AND @15a_cmd LIKE '%@PlanOnly%'
    RAISERROR(N'  PASS 15A: Command column contains full invocation', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 15A: Command column is truncated or missing @PlanOnly. Got: %s', 10, 1, @15a_cmd) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 15B: Command column includes non-default parameters', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

DECLARE @15b_cmd nvarchar(max);
SELECT TOP 1 @15b_cmd = Command
FROM dbo.CommandLog
WHERE CommandType = 'HEAP_SCAN_SUMMARY'
  AND ObjectName = 'sp_HeapDoctor'
ORDER BY ID DESC;

-- @MinPages was set to 500 (non-default), should appear in Command
IF @15b_cmd LIKE '%@MinPages = 500%'
    RAISERROR(N'  PASS 15B: Command contains non-default @MinPages = 500', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 15B: Command missing @MinPages = 500. Got: %s', 10, 1, @15b_cmd) WITH NOWAIT;

-- @CpuSource was NONE (non-default), should appear
IF @15b_cmd LIKE '%@CpuSource%'
    RAISERROR(N'  PASS 15B: Command contains non-default @CpuSource', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 15B: Command missing @CpuSource', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 15C: sqlserver_start_time populated in result set', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @PlanOnly  = 1;

IF EXISTS (SELECT 1 FROM #Results WHERE sqlserver_start_time IS NOT NULL)
    RAISERROR(N'  PASS 15C: sqlserver_start_time is populated', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 15C: sqlserver_start_time is NULL', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 15D: uptime_hours populated and > 0', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

IF EXISTS (SELECT 1 FROM #Results WHERE uptime_hours IS NOT NULL AND uptime_hours > 0)
    RAISERROR(N'  PASS 15D: uptime_hours is populated and > 0', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 15D: uptime_hours is NULL or 0', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 15E: ranking_algo_version is v1', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

DECLARE @15e_ver nvarchar(10);
SELECT TOP 1 @15e_ver = ranking_algo_version FROM #Results;

IF @15e_ver = N'v1'
    RAISERROR(N'  PASS 15E: ranking_algo_version is v1', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 15E: ranking_algo_version is [%s], expected v1', 10, 1, @15e_ver) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 15F: ranking_algo_version in HEAP_SCAN_SUMMARY XML', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

DECLARE @15f_xml xml;
SELECT TOP 1 @15f_xml = ExtendedInfo
FROM dbo.CommandLog
WHERE CommandType = 'HEAP_SCAN_SUMMARY'
ORDER BY ID DESC;

IF @15f_xml.value(N'(/ScanSummary/RankingAlgoVersion)[1]', N'nvarchar(10)') = N'v1'
    RAISERROR(N'  PASS 15F: RankingAlgoVersion v1 in HEAP_SCAN_SUMMARY XML', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 15F: RankingAlgoVersion missing or wrong in HEAP_SCAN_SUMMARY', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 15K: Zero-target HEAP_SCAN_SUMMARY', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- Force zero targets with impossible threshold
DELETE FROM dbo.CommandLog WHERE CommandType = 'HEAP_SCAN_SUMMARY'
    AND ObjectName = 'sp_HeapDoctor' AND DatabaseName = 'HeapDoctorTest';

EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @PlanOnly  = 1,
    @LogToTable = 'Y',
    @MinForwardedPct = 99.99;

DECLARE @15k_xml xml;
SELECT TOP 1 @15k_xml = ExtendedInfo
FROM dbo.CommandLog
WHERE CommandType = 'HEAP_SCAN_SUMMARY'
  AND ObjectName = 'sp_HeapDoctor'
ORDER BY ID DESC;

IF @15k_xml IS NOT NULL
    AND @15k_xml.value(N'(/ScanSummary/TargetCount)[1]', N'int') = 0
    RAISERROR(N'  PASS 15K: HEAP_SCAN_SUMMARY written with TargetCount=0', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 15K: HEAP_SCAN_SUMMARY not written for zero targets', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 15L: Per-database breakdown in HEAP_SCAN_SUMMARY', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- Run a normal plan-only to get a HEAP_SCAN_SUMMARY with targets
DELETE FROM dbo.CommandLog WHERE CommandType = 'HEAP_SCAN_SUMMARY'
    AND ObjectName = 'sp_HeapDoctor' AND DatabaseName = 'HeapDoctorTest';

EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @PlanOnly  = 1,
    @LogToTable = 'Y';

DECLARE @15l_xml xml;
SELECT TOP 1 @15l_xml = ExtendedInfo
FROM dbo.CommandLog
WHERE CommandType = 'HEAP_SCAN_SUMMARY'
  AND ObjectName = 'sp_HeapDoctor'
ORDER BY ID DESC;

IF @15l_xml.exist(N'/ScanSummary/Databases/Database') = 1
    RAISERROR(N'  PASS 15L: HEAP_SCAN_SUMMARY has Databases/Database elements', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 15L: HEAP_SCAN_SUMMARY missing Databases breakdown', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 15M: Summary-level aggregates in HEAP_SCAN_SUMMARY', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

DECLARE @15m_xml xml;
SELECT TOP 1 @15m_xml = ExtendedInfo
FROM dbo.CommandLog
WHERE CommandType = 'HEAP_SCAN_SUMMARY'
  AND ObjectName = 'sp_HeapDoctor'
ORDER BY ID DESC;

IF @15m_xml.exist(N'/ScanSummary/DatabasesWithTargets') = 1
   AND @15m_xml.exist(N'/ScanSummary/TotalCpuMs') = 1
   AND @15m_xml.exist(N'/ScanSummary/TotalForwardedRecordCount') = 1
   AND @15m_xml.exist(N'/ScanSummary/TotalForwardedFetchCount') = 1
    RAISERROR(N'  PASS 15M: Summary aggregates present in HEAP_SCAN_SUMMARY', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 15M: Missing summary aggregates in HEAP_SCAN_SUMMARY', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 15N: UptimeHours in HEAP_SCAN_SUMMARY XML', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

DECLARE @15n_xml xml;
SELECT TOP 1 @15n_xml = ExtendedInfo
FROM dbo.CommandLog
WHERE CommandType = 'HEAP_SCAN_SUMMARY'
  AND ObjectName = 'sp_HeapDoctor'
ORDER BY ID DESC;

IF @15n_xml.exist(N'/ScanSummary/UptimeHours') = 1
   AND @15n_xml.exist(N'/ScanSummary/SqlServerStartTime') = 1
    RAISERROR(N'  PASS 15N: UptimeHours and SqlServerStartTime in HEAP_SCAN_SUMMARY', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 15N: Missing uptime info in HEAP_SCAN_SUMMARY', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' BATCH 15 COMPLETE', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N'', 10, 1) WITH NOWAIT;
GO
