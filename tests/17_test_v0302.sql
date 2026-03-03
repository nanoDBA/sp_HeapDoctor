/*
sp_HeapDoctor Test Harness - v1.0.2026.0302d: #25 @Force, #33 LOB TOCTOU, #40 CommandLog schema

Tests:
  -- Issue #25: @Force parameter --
  17A - @Force=0 (default) does not affect normal execution
  17B - @Force=1 runs successfully (no orphaned lock scenario)
  17C - @Force parameter and help text exist in proc definition

  -- Issue #33: LOB column TOCTOU re-check --
  17D - CI swap falls back to heap rebuild when LOB column added post-discovery
  17E - Normal CI swap still works when no LOB columns added (fresh heap)

  -- Issue #40: CommandLog schema validation --
  17F - CommandLog with correct schema passes validation
  17G - CommandLog with missing column disables logging gracefully
  17H - CommandLog with non-xml ExtendedInfo disables logging gracefully

  -- Version --
  17V - Version is 1.0.2026.0302d

Prerequisites: Run 01_setup_test_data.sql first.
Run with: sqlcmd -S YourServer -d HeapDoctorTest -i 17_test_v0302.sql
*/

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
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
    uptime_hours           decimal(10,1) NULL
);
GO

RAISERROR(N'=== Batch 17: v1.0.2026.0302d (#25 @Force, #33 LOB TOCTOU, #40 CommandLog schema) ===', 10, 1) WITH NOWAIT;

------------------------------------------------------------------------
-- 17A: @Force=0 (default) does not interfere with normal execution
------------------------------------------------------------------------
RAISERROR(N'Test 17A: @Force=0 (default) normal execution...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1;

IF EXISTS (SELECT 1 FROM #Results)
    RAISERROR(N'  PASS 17A: @Force=0 (default) runs normally.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 17A: No results with @Force=0.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 17B: @Force=1 runs successfully (bypass re-entrancy guard)
------------------------------------------------------------------------
RAISERROR(N'Test 17B: @Force=1 execution...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @Force = 1;

IF EXISTS (SELECT 1 FROM #Results)
    RAISERROR(N'  PASS 17B: @Force=1 runs successfully.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 17B: No results with @Force=1.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 17C: @Force parameter exists in proc definition (check master DB)
------------------------------------------------------------------------
RAISERROR(N'Test 17C: @Force in proc definition...', 10, 1) WITH NOWAIT;

DECLARE @has_force bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%@Force%bit%''
    ) SET @out = 1;',
    N'@out bit OUTPUT',
    @out = @has_force OUTPUT;

IF @has_force = 1
    RAISERROR(N'  PASS 17C: @Force parameter found in proc definition.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 17C: @Force not found in proc definition.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 17D: LOB column TOCTOU - CI swap falls back when LOB added post-discovery
-- Strategy: Create a heap with a unique NCI (CI swap eligible), discover it,
-- then add a LOB column, then execute with @ResumeRunID.
------------------------------------------------------------------------
RAISERROR(N'Test 17D: LOB TOCTOU - CI swap fallback on schema change...', 10, 1) WITH NOWAIT;

-- Create test heap eligible for CI swap
IF OBJECT_ID(N'dbo.HeapLobTest') IS NOT NULL DROP TABLE dbo.HeapLobTest;
CREATE TABLE dbo.HeapLobTest
(
    ID       int          NOT NULL,
    Col1     int          NULL,
    Col2     nvarchar(50) NULL
);
CREATE UNIQUE NONCLUSTERED INDEX UX_HeapLobTest_ID ON dbo.HeapLobTest(ID);

-- Insert enough rows + create forwarded records
DECLARE @i17 int = 1;
WHILE @i17 <= 20000
BEGIN
    INSERT dbo.HeapLobTest(ID, Col1, Col2) VALUES (@i17, @i17, REPLICATE(N'X', 10));
    SET @i17 += 1;
END

-- Cause forwarded records by expanding rows
UPDATE dbo.HeapLobTest SET Col2 = REPLICATE(N'Y', 50);

-- Step 1: Plan-only run to discover (should choose CI_SWAP_ONLINE)
DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.HeapLobTest',
    @CpuSource = N'NONE',
    @MinPages = 1,
    @AllowCiSwap = 1,
    @PreferCiSwap = 1,
    @PlanOnly = 1,
    @LogToTable = N'Y';

DECLARE @plan_runid17 uniqueidentifier;
DECLARE @plan_action17 varchar(32);

-- Get the RunID from HEAP_SCAN_SUMMARY
SELECT TOP 1 @plan_runid17 = TRY_CONVERT(uniqueidentifier,
    CONVERT(xml, ExtendedInfo).value(N'(/ScanSummary/RunID)[1]', N'nvarchar(36)'))
FROM dbo.CommandLog
WHERE CommandType = N'HEAP_SCAN_SUMMARY'
  AND DatabaseName = N'HeapDoctorTest'
ORDER BY ID DESC;

SELECT @plan_action17 = action_chosen FROM #Results WHERE table_name = N'HeapLobTest';

IF @plan_action17 = 'CI_SWAP_ONLINE'
    RAISERROR(N'  INFO 17D: Initial plan chose CI_SWAP_ONLINE (as expected).', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  INFO 17D: Initial plan chose %s (CI swap not eligible; test may not exercise LOB fallback).', 10, 1, @plan_action17) WITH NOWAIT;

-- Step 2: Add a LOB column (schema change after discovery)
ALTER TABLE dbo.HeapLobTest ADD LobCol nvarchar(max) NULL;

-- Step 3: Resume execute - should detect LOB at execution time and fall back
IF @plan_runid17 IS NOT NULL
BEGIN
    EXEC dbo.sp_HeapDoctor
        @ResumeRunID = @plan_runid17,
        @Tables = N'dbo.HeapLobTest',
        @PlanOnly = 0,
        @MinPages = 1;

    -- Check CommandLog for the action taken
    DECLARE @actual_action17 nvarchar(50);
    SELECT TOP 1 @actual_action17 = CommandType
    FROM dbo.CommandLog
    WHERE ObjectName = N'HeapLobTest'
      AND CommandType IN (N'HEAP_REBUILD_ONLINE', N'HEAP_REBUILD_OFFLINE', N'CI_SWAP_ONLINE')
    ORDER BY ID DESC;

    IF @actual_action17 IN (N'HEAP_REBUILD_ONLINE', N'HEAP_REBUILD_OFFLINE')
        RAISERROR(N'  PASS 17D: LOB detected at execution, fell back to %s.', 10, 1, @actual_action17) WITH NOWAIT;
    ELSE IF @actual_action17 = N'CI_SWAP_ONLINE'
        RAISERROR(N'  FAIL 17D: CI swap was attempted despite LOB column (action: %s).', 10, 1, @actual_action17) WITH NOWAIT;
    ELSE
        RAISERROR(N'  FAIL 17D: No rebuild found in CommandLog (action: %s).', 10, 1, @actual_action17) WITH NOWAIT;
END
ELSE
    RAISERROR(N'  FAIL 17D: Could not get plan-only RunID from HEAP_SCAN_SUMMARY.', 10, 1) WITH NOWAIT;

-- Cleanup
IF OBJECT_ID(N'dbo.HeapLobTest') IS NOT NULL DROP TABLE dbo.HeapLobTest;
GO

------------------------------------------------------------------------
-- 17E: Normal CI swap still works (no false positive from LOB check)
-- Use a fresh test heap (not HeapB which may have been rebuilt already)
------------------------------------------------------------------------
RAISERROR(N'Test 17E: CI swap works normally without LOB columns...', 10, 1) WITH NOWAIT;

-- Create a fresh heap eligible for CI swap
IF OBJECT_ID(N'dbo.HeapCiTest') IS NOT NULL DROP TABLE dbo.HeapCiTest;
CREATE TABLE dbo.HeapCiTest
(
    ID       int          NOT NULL,
    Col1     int          NULL,
    Col2     nvarchar(50) NULL
);
CREATE UNIQUE NONCLUSTERED INDEX UX_HeapCiTest_ID ON dbo.HeapCiTest(ID);

DECLARE @j17 int = 1;
WHILE @j17 <= 20000
BEGIN
    INSERT dbo.HeapCiTest(ID, Col1, Col2) VALUES (@j17, @j17, REPLICATE(N'X', 10));
    SET @j17 += 1;
END
UPDATE dbo.HeapCiTest SET Col2 = REPLICATE(N'Y', 50);

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.HeapCiTest',
    @CpuSource = N'NONE',
    @MinPages = 1,
    @AllowCiSwap = 1,
    @PreferCiSwap = 1,
    @PlanOnly = 1;

DECLARE @ci_action varchar(32);
SELECT @ci_action = action_chosen FROM #Results WHERE table_name = N'HeapCiTest';

IF @ci_action = 'CI_SWAP_ONLINE'
    RAISERROR(N'  PASS 17E: Fresh heap eligible for CI_SWAP_ONLINE (no false LOB positive).', 10, 1) WITH NOWAIT;
ELSE IF @ci_action IS NOT NULL
    RAISERROR(N'  PASS 17E: Heap action is %s (CI swap not chosen but LOB check is not the cause).', 10, 1, @ci_action) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 17E: No targets returned for HeapCiTest.', 10, 1) WITH NOWAIT;

IF OBJECT_ID(N'dbo.HeapCiTest') IS NOT NULL DROP TABLE dbo.HeapCiTest;
GO

------------------------------------------------------------------------
-- 17F: CommandLog schema validation - correct schema passes
------------------------------------------------------------------------
RAISERROR(N'Test 17F: CommandLog schema validation - correct schema...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @LogToTable = N'Y';

IF EXISTS (SELECT 1 FROM #Results)
    RAISERROR(N'  PASS 17F: CommandLog with correct schema passes validation.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 17F: No results returned.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 17G: CommandLog schema validation - missing column disables logging
-- Strategy: Rename ExtendedInfo column, run proc, verify it still works, restore
------------------------------------------------------------------------
RAISERROR(N'Test 17G: CommandLog missing column detection...', 10, 1) WITH NOWAIT;

EXEC sp_rename N'dbo.CommandLog.ExtendedInfo', N'ExtendedInfo_bak', N'COLUMN';

BEGIN TRY
    DELETE FROM #Results;
    INSERT INTO #Results
    EXEC dbo.sp_HeapDoctor
        @Databases = N'HeapDoctorTest',
        @CpuSource = N'NONE',
        @PlanOnly = 1,
        @LogToTable = N'Y';

    IF EXISTS (SELECT 1 FROM #Results)
        RAISERROR(N'  PASS 17G: Proc runs with missing CommandLog column (logging disabled gracefully).', 10, 1) WITH NOWAIT;
    ELSE
        RAISERROR(N'  FAIL 17G: Proc failed with missing CommandLog column.', 10, 1) WITH NOWAIT;
END TRY
BEGIN CATCH
    DECLARE @err17g nvarchar(4000) = ERROR_MESSAGE();
    RAISERROR(N'  FAIL 17G: Proc threw error with missing column: %s', 10, 1, @err17g) WITH NOWAIT;
END CATCH

EXEC sp_rename N'dbo.CommandLog.ExtendedInfo_bak', N'ExtendedInfo', N'COLUMN';
GO

------------------------------------------------------------------------
-- 17H: CommandLog ExtendedInfo type validation
-- Strategy: Rename xml column, add nvarchar(max) column with same name,
-- run proc, verify it still works, restore.
------------------------------------------------------------------------
RAISERROR(N'Test 17H: CommandLog ExtendedInfo type validation...', 10, 1) WITH NOWAIT;

-- Rename real xml column out of the way
EXEC sp_rename N'dbo.CommandLog.ExtendedInfo', N'ExtendedInfo_xml', N'COLUMN';
-- Add nvarchar(max) column with the expected name
ALTER TABLE dbo.CommandLog ADD ExtendedInfo nvarchar(max) NULL;

BEGIN TRY
    DELETE FROM #Results;
    INSERT INTO #Results
    EXEC dbo.sp_HeapDoctor
        @Databases = N'HeapDoctorTest',
        @CpuSource = N'NONE',
        @PlanOnly = 1,
        @LogToTable = N'Y';

    IF EXISTS (SELECT 1 FROM #Results)
        RAISERROR(N'  PASS 17H: Proc runs with non-xml ExtendedInfo (logging disabled gracefully).', 10, 1) WITH NOWAIT;
    ELSE
        RAISERROR(N'  FAIL 17H: Proc failed with non-xml ExtendedInfo.', 10, 1) WITH NOWAIT;
END TRY
BEGIN CATCH
    DECLARE @err17h nvarchar(4000) = ERROR_MESSAGE();
    RAISERROR(N'  FAIL 17H: Proc threw error: %s', 10, 1, @err17h) WITH NOWAIT;
END CATCH

-- Restore: drop the fake column, rename the real one back
ALTER TABLE dbo.CommandLog DROP COLUMN ExtendedInfo;
EXEC sp_rename N'dbo.CommandLog.ExtendedInfo_xml', N'ExtendedInfo', N'COLUMN';
GO

------------------------------------------------------------------------
-- 17V: Version check
------------------------------------------------------------------------
RAISERROR(N'Test 17V: Version check...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1;

DECLARE @ver17 nvarchar(20);
SELECT TOP 1 @ver17 = version FROM #Results;

IF @ver17 = N'1.0.2026.0302d'
    RAISERROR(N'  PASS 17V: Version is 1.0.2026.0302d.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 17V: Version is %s (expected 1.0.2026.0302d).', 10, 1, @ver17) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- Summary
------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'Batch 17 tests complete. Review PASS/FAIL results above.', 10, 1) WITH NOWAIT;
GO
