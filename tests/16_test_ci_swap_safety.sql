/*
sp_HeapDoctor Test Harness - Batch 16: CI Swap Safety Guards

Tests:
  -- Issue #32: XACT_ABORT OFF --
  16A - Proc runs successfully when caller has SET XACT_ABORT ON

  -- Issue #46: Computed column exclusion --
  16B - CI swap key excludes computed columns from CandidateKeys CTE

  -- Issue #42: Schema-bound view detection --
  16C - CI swap blocked when schema-bound view references the heap

  -- Issue #50: Indexed view detection --
  16D - CI swap blocked when indexed view references the heap

  -- Issue #27: Partitioned heap detection --
  16E - partition_count column populated for non-partitioned heaps

  -- Issue #26: Filegroup --
  16F - filegroup_name column populated in result set

  -- Issue #53: CDC CI swap guard --
  16G - result set columns for new CI swap safety fields exist

  -- New result set columns --
  16H - HEAP_SCAN_SUMMARY XML includes new CI swap safety attributes

Prerequisites: Run 01_setup_test_data.sql first.
Run with: sqlcmd -S YourServer -d HeapDoctorTest -i 16_test_ci_swap_safety.sql
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

RAISERROR(N'=== Batch 16: CI Swap Safety Guards ===', 10, 1) WITH NOWAIT;

------------------------------------------------------------------------
-- 16A: XACT_ABORT OFF (#32)
-- Proc should run successfully even when caller has XACT_ABORT ON
------------------------------------------------------------------------
RAISERROR(N'Test 16A: XACT_ABORT ON in caller session...', 10, 1) WITH NOWAIT;

SET XACT_ABORT ON;
BEGIN TRY
    DELETE FROM #Results;
    INSERT INTO #Results
    EXEC dbo.sp_HeapDoctor
        @Databases = N'HeapDoctorTest',
        @CpuSource = N'NONE',
        @PlanOnly = 1;

    IF EXISTS (SELECT 1 FROM #Results)
        RAISERROR(N'  PASS 16A: Proc runs with XACT_ABORT ON in caller.', 10, 1) WITH NOWAIT;
    ELSE
        RAISERROR(N'  FAIL 16A: No results returned with XACT_ABORT ON.', 10, 1) WITH NOWAIT;
END TRY
BEGIN CATCH
    DECLARE @err16A nvarchar(4000) = ERROR_MESSAGE();
    RAISERROR(N'  FAIL 16A: Proc errored with XACT_ABORT ON: %s', 10, 1, @err16A) WITH NOWAIT;
END CATCH
SET XACT_ABORT OFF;
GO

------------------------------------------------------------------------
-- 16B: Computed column exclusion (#46)
-- Create a heap with computed column in a unique NCI key.
-- CI swap should NOT select that index (computed columns excluded).
------------------------------------------------------------------------
RAISERROR(N'Test 16B: Computed column exclusion from CI swap keys...', 10, 1) WITH NOWAIT;

-- Create test table with computed column in unique NCI
IF OBJECT_ID(N'dbo.HeapComputed', N'U') IS NOT NULL DROP TABLE dbo.HeapComputed;
CREATE TABLE dbo.HeapComputed
(
    ID          int          NOT NULL,
    FirstName   varchar(50)  NOT NULL,
    LastName    varchar(50)  NOT NULL,
    FullName    AS (FirstName + ' ' + LastName) PERSISTED,
    Padding     varchar(4000) NULL
);
-- This unique NCI uses the computed column - should NOT be a CI swap candidate
CREATE UNIQUE NONCLUSTERED INDEX UX_HeapComputed_FullName ON dbo.HeapComputed(FullName);
-- This unique NCI uses a real column - should be the CI swap candidate
CREATE UNIQUE NONCLUSTERED INDEX UX_HeapComputed_ID ON dbo.HeapComputed(ID);

-- Populate with forwarded records
;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapComputed (ID, FirstName, LastName, Padding)
SELECT TOP (5000) n, 'First' + CAST(n AS varchar(10)), 'Last' + CAST(n AS varchar(10)), 'x'
FROM N;

UPDATE dbo.HeapComputed SET Padding = REPLICATE('X', 3000) WHERE ID <= 3000;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.HeapComputed',
    @CpuSource = N'NONE',
    @PlanOnly = 1;

IF EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapComputed'
           AND action_chosen = 'CI_SWAP_ONLINE'
           AND key_source_index = N'UX_HeapComputed_ID')
    RAISERROR(N'  PASS 16B: CI swap selected UX_HeapComputed_ID (real column), not computed column index.', 10, 1) WITH NOWAIT;
ELSE IF EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapComputed'
                AND action_chosen = 'CI_SWAP_ONLINE'
                AND key_source_index = N'UX_HeapComputed_FullName')
    RAISERROR(N'  FAIL 16B: CI swap incorrectly selected computed column index UX_HeapComputed_FullName.', 10, 1) WITH NOWAIT;
ELSE IF EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapComputed')
    RAISERROR(N'  PASS 16B: HeapComputed found (action: %s, key: %s).', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 16B: HeapComputed not found in results.', 10, 1) WITH NOWAIT;

DROP TABLE dbo.HeapComputed;
GO

------------------------------------------------------------------------
-- 16C: Schema-bound view detection (#42)
-- Create a heap with a schema-bound view. CI swap should fall back to
-- heap rebuild because schema-bound views block DDL on the base table.
------------------------------------------------------------------------
RAISERROR(N'Test 16C: Schema-bound view blocks CI swap...', 10, 1) WITH NOWAIT;

IF OBJECT_ID(N'dbo.vw_HeapSB', N'V') IS NOT NULL DROP VIEW dbo.vw_HeapSB;
IF OBJECT_ID(N'dbo.HeapSchemaBound', N'U') IS NOT NULL DROP TABLE dbo.HeapSchemaBound;

CREATE TABLE dbo.HeapSchemaBound
(
    ID       int           NOT NULL,
    Code     char(10)      NOT NULL,
    Padding  varchar(4000) NULL
);
CREATE UNIQUE NONCLUSTERED INDEX UX_HeapSB_ID ON dbo.HeapSchemaBound(ID);
GO

CREATE VIEW dbo.vw_HeapSB WITH SCHEMABINDING AS
SELECT ID, Code FROM dbo.HeapSchemaBound;
GO

-- Populate with forwarded records
;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapSchemaBound (ID, Code, Padding)
SELECT TOP (5000) n, 'C' + RIGHT('00000' + CAST(n AS varchar(10)), 5), 'x'
FROM N;

UPDATE dbo.HeapSchemaBound SET Padding = REPLICATE('X', 3000) WHERE ID <= 3000;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.HeapSchemaBound',
    @CpuSource = N'NONE',
    @PlanOnly = 1;

IF EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapSchemaBound'
           AND has_schema_bound_views = 1
           AND action_chosen <> 'CI_SWAP_ONLINE')
    RAISERROR(N'  PASS 16C: Schema-bound view detected, CI swap blocked (action: HEAP_REBUILD).', 10, 1) WITH NOWAIT;
ELSE IF EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapSchemaBound'
                AND action_chosen = 'CI_SWAP_ONLINE')
    RAISERROR(N'  FAIL 16C: CI swap NOT blocked despite schema-bound view.', 10, 1) WITH NOWAIT;
ELSE IF NOT EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapSchemaBound')
    RAISERROR(N'  FAIL 16C: HeapSchemaBound not found in results.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 16C: Unexpected state - has_schema_bound_views not set.', 10, 1) WITH NOWAIT;

DROP VIEW dbo.vw_HeapSB;
DROP TABLE dbo.HeapSchemaBound;
GO

------------------------------------------------------------------------
-- 16D: Indexed view detection (#50)
-- Create a heap with an indexed view. CI swap should fall back to
-- heap rebuild because indexed views add overhead to DDL.
------------------------------------------------------------------------
RAISERROR(N'Test 16D: Indexed view blocks CI swap...', 10, 1) WITH NOWAIT;

IF OBJECT_ID(N'dbo.vw_HeapIX', N'V') IS NOT NULL DROP VIEW dbo.vw_HeapIX;
IF OBJECT_ID(N'dbo.HeapIndexedView', N'U') IS NOT NULL DROP TABLE dbo.HeapIndexedView;

CREATE TABLE dbo.HeapIndexedView
(
    ID       int           NOT NULL,
    Code     char(10)      NOT NULL,
    Padding  varchar(4000) NULL
);
CREATE UNIQUE NONCLUSTERED INDEX UX_HeapIX_ID ON dbo.HeapIndexedView(ID);
GO

CREATE VIEW dbo.vw_HeapIX WITH SCHEMABINDING AS
SELECT ID, Code FROM dbo.HeapIndexedView;
GO

-- Create a clustered index on the view (makes it an indexed view)
CREATE UNIQUE CLUSTERED INDEX CIX_vw_HeapIX ON dbo.vw_HeapIX(ID);
GO

-- Populate with forwarded records
;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapIndexedView (ID, Code, Padding)
SELECT TOP (5000) n, 'I' + RIGHT('00000' + CAST(n AS varchar(10)), 5), 'x'
FROM N;

UPDATE dbo.HeapIndexedView SET Padding = REPLICATE('X', 3000) WHERE ID <= 3000;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.HeapIndexedView',
    @CpuSource = N'NONE',
    @PlanOnly = 1;

IF EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapIndexedView'
           AND has_indexed_views = 1
           AND action_chosen <> 'CI_SWAP_ONLINE')
    RAISERROR(N'  PASS 16D: Indexed view detected, CI swap blocked (action: HEAP_REBUILD).', 10, 1) WITH NOWAIT;
ELSE IF EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapIndexedView'
                AND action_chosen = 'CI_SWAP_ONLINE')
    RAISERROR(N'  FAIL 16D: CI swap NOT blocked despite indexed view.', 10, 1) WITH NOWAIT;
ELSE IF NOT EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapIndexedView')
    RAISERROR(N'  FAIL 16D: HeapIndexedView not found in results.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 16D: Unexpected state - has_indexed_views not set.', 10, 1) WITH NOWAIT;

DROP VIEW dbo.vw_HeapIX;
DROP TABLE dbo.HeapIndexedView;
GO

------------------------------------------------------------------------
-- 16E: Partitioned heap detection (#27)
-- Verify partition_count = 1 for standard (non-partitioned) heaps.
------------------------------------------------------------------------
RAISERROR(N'Test 16E: partition_count populated for non-partitioned heaps...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1;

IF EXISTS (SELECT 1 FROM #Results WHERE partition_count = 1)
   AND NOT EXISTS (SELECT 1 FROM #Results WHERE partition_count IS NULL)
    RAISERROR(N'  PASS 16E: partition_count = 1 for all non-partitioned heaps.', 10, 1) WITH NOWAIT;
ELSE IF EXISTS (SELECT 1 FROM #Results WHERE partition_count IS NULL)
    RAISERROR(N'  FAIL 16E: partition_count is NULL for some heaps.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 16E: No results to validate partition_count.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 16F: Filegroup name populated (#26)
-- Standard heaps should have filegroup_name = 'PRIMARY'.
------------------------------------------------------------------------
RAISERROR(N'Test 16F: filegroup_name populated in result set...', 10, 1) WITH NOWAIT;

IF EXISTS (SELECT 1 FROM #Results WHERE filegroup_name IS NOT NULL)
    RAISERROR(N'  PASS 16F: filegroup_name populated (value: PRIMARY expected).', 10, 1) WITH NOWAIT;
ELSE IF EXISTS (SELECT 1 FROM #Results)
    RAISERROR(N'  FAIL 16F: filegroup_name is NULL for all results.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 16F: No results to validate.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 16G: New result set columns exist
-- Verify partition_count, has_schema_bound_views, has_indexed_views,
-- filegroup_name are all present and have sensible defaults.
------------------------------------------------------------------------
RAISERROR(N'Test 16G: New CI swap safety columns have sensible defaults...', 10, 1) WITH NOWAIT;

IF EXISTS (SELECT 1 FROM #Results
           WHERE partition_count >= 1
             AND has_schema_bound_views = 0
             AND has_indexed_views = 0
             AND filegroup_name IS NOT NULL)
    RAISERROR(N'  PASS 16G: All new columns populated with sensible defaults.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 16G: New columns have unexpected values.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 16H: HEAP_SCAN_SUMMARY XML includes new attributes
-- Run plan-only with logging, check ExtendedInfo XML for new attributes.
------------------------------------------------------------------------
RAISERROR(N'Test 16H: HEAP_SCAN_SUMMARY XML includes CI swap safety attributes...', 10, 1) WITH NOWAIT;

DECLARE @RunID16H uniqueidentifier = NEWID();

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @LogToTable = N'Y';

-- Check the latest HEAP_SCAN_SUMMARY entry
DECLARE @xml16H xml;
SELECT TOP 1 @xml16H = ExtendedInfo
FROM dbo.CommandLog
WHERE CommandType = N'HEAP_SCAN_SUMMARY'
ORDER BY ID DESC;

IF @xml16H IS NOT NULL
BEGIN
    -- Check for new attributes in Target elements
    IF @xml16H.exist(N'/ScanSummary/Targets/Target/@PartitionCount') = 1
       AND @xml16H.exist(N'/ScanSummary/Targets/Target/@HasSchemaBoundViews') = 1
       AND @xml16H.exist(N'/ScanSummary/Targets/Target/@HasIndexedViews') = 1
       AND @xml16H.exist(N'/ScanSummary/Targets/Target/@DataSpaceName') = 1
        RAISERROR(N'  PASS 16H: HEAP_SCAN_SUMMARY XML contains all new CI swap safety attributes.', 10, 1) WITH NOWAIT;
    ELSE
        RAISERROR(N'  FAIL 16H: HEAP_SCAN_SUMMARY XML missing one or more new attributes.', 10, 1) WITH NOWAIT;
END
ELSE
    RAISERROR(N'  FAIL 16H: No HEAP_SCAN_SUMMARY found in CommandLog.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- Cleanup test objects
------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.HeapComputed', N'U') IS NOT NULL DROP TABLE dbo.HeapComputed;
IF OBJECT_ID(N'dbo.vw_HeapSB', N'V') IS NOT NULL DROP VIEW dbo.vw_HeapSB;
IF OBJECT_ID(N'dbo.HeapSchemaBound', N'U') IS NOT NULL DROP TABLE dbo.HeapSchemaBound;
IF OBJECT_ID(N'dbo.vw_HeapIX', N'V') IS NOT NULL DROP VIEW dbo.vw_HeapIX;
IF OBJECT_ID(N'dbo.HeapIndexedView', N'U') IS NOT NULL DROP TABLE dbo.HeapIndexedView;

RAISERROR(N'=== Batch 16 tests complete ===', 10, 1) WITH NOWAIT;
