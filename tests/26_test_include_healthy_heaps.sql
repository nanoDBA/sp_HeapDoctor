/*
sp_HeapDoctor Test Harness - @IncludeHealthyHeaps parameter

Validates the @IncludeHealthyHeaps bypass:
  - Default (=0): heaps with 0 forwarded records are excluded.
  - Set (=1):    those same heaps appear in the result set.
  - @MinPages still applies (proves bypass is targeted, not a global short-circuit).
  - @invocation_command logs the parameter when non-default.

Prerequisites: Run 01_setup_test_data.sql first (creates HeapDoctorTest with HeapA/B/C/D).
Run with: sqlcmd -S YourServer -d HeapDoctorTest -i 26_test_include_healthy_heaps.sql
*/

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE [HeapDoctorTest];
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' SETUP: dbo.HeapHealthy (large heap, zero forwarded records)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

IF OBJECT_ID(N'dbo.HeapHealthy', N'U') IS NOT NULL DROP TABLE dbo.HeapHealthy;
CREATE TABLE dbo.HeapHealthy
(
    ID       int           NOT NULL,
    Padding  varchar(4000) NOT NULL,
    Padding2 varchar(4000) NOT NULL
);

/* Insert rows at full width up-front; no updates -> no forwarded records. */
;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapHealthy (ID, Padding, Padding2)
SELECT TOP (5000) n, REPLICATE('A', 4000), REPLICATE('B', 4000)
FROM N;
GO

DECLARE @fwd bigint, @pages bigint, @msg nvarchar(200);
SELECT @fwd = ISNULL(forwarded_record_count, 0), @pages = page_count
FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID(N'dbo.HeapHealthy'), 0, NULL, N'SAMPLED');
SET @msg = N'HeapHealthy state: pages=' + CONVERT(nvarchar(20), @pages) + N', forwarded_records=' + CONVERT(nvarchar(20), @fwd);
RAISERROR(@msg, 10, 1) WITH NOWAIT;

IF @fwd <> 0
    RAISERROR(N'  *** SETUP FAIL: HeapHealthy unexpectedly has forwarded records.', 16, 1);
IF @pages < 1000
    RAISERROR(N'  *** SETUP FAIL: HeapHealthy must have >= 1000 pages for @MinPages=1000 baseline.', 16, 1);
GO

------------------------------------------------------------------------
-- Capture table (matches sp_HeapDoctor first result set)
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
    is_temporal_history    bit           NULL,
    recommended_action     nvarchar(50)  NULL
);
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 26A: Default (@IncludeHealthyHeaps=0) excludes healthy heap', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @PlanOnly  = 1;

IF NOT EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapHealthy')
    RAISERROR(N'  PASS 26A-1: HeapHealthy correctly excluded by default.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 26A-1: HeapHealthy should not appear when @IncludeHealthyHeaps=0.', 10, 1) WITH NOWAIT;

/* Sanity: HeapA/B/C should still appear (regression check on existing filter). */
DECLARE @forwarded_count int = (SELECT COUNT_BIG(*) FROM #Results WHERE table_name IN (N'HeapA', N'HeapB', N'HeapC'));
IF @forwarded_count = 3
    RAISERROR(N'  PASS 26A-2: HeapA/B/C still discovered (existing filter intact).', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @msg26a2 nvarchar(200) = N'  *** FAIL 26A-2: Expected 3 forwarded heaps, found ' + CONVERT(nvarchar(10), @forwarded_count);
    RAISERROR(@msg26a2, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 26B: @IncludeHealthyHeaps=1 includes healthy heap', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource          = 'NONE',
    @PlanOnly           = 1,
    @IncludeHealthyHeaps = 1;

IF EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapHealthy' AND forwarded_record_count = 0)
    RAISERROR(N'  PASS 26B-1: HeapHealthy appears with @IncludeHealthyHeaps=1 (zero forwarded records).', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 26B-1: HeapHealthy missing when @IncludeHealthyHeaps=1.', 10, 1) WITH NOWAIT;

/* HeapD is tiny (~50 rows, well under 1000 pages) and must still be filtered by @MinPages,
   proving @IncludeHealthyHeaps bypasses ONLY the forwarded-record filters. */
IF NOT EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapD')
    RAISERROR(N'  PASS 26B-2: HeapD still filtered by @MinPages (bypass is targeted, not global).', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 26B-2: HeapD should still be excluded by @MinPages even with @IncludeHealthyHeaps=1.', 10, 1) WITH NOWAIT;

/* Ranking sanity: HeapHealthy has 0 forwarded -> forwarded_pct term is 0, fetch_rate term is 0.
   With CpuSource=NONE, cpu_ms term is 0 too. Score should be ~0 (or NULL-safe small value). */
DECLARE @score decimal(8,4) = (SELECT ranking_score FROM #Results WHERE table_name = N'HeapHealthy');
IF @score IS NOT NULL AND @score < 0.5
    RAISERROR(N'  PASS 26B-3: ranking_score collapses near 0 for healthy heap (as expected).', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @scoreMsg nvarchar(200) = N'  *** FAIL 26B-3: Expected ranking_score < 0.5 for healthy heap, got '
        + ISNULL(CONVERT(nvarchar(20), @score), N'NULL');
    RAISERROR(@scoreMsg, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 26C: @IncludeHealthyHeaps + @Tables scoping', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource          = 'NONE',
    @PlanOnly           = 1,
    @IncludeHealthyHeaps = 1,
    @Tables             = N'dbo.HeapHealthy';

IF (SELECT COUNT_BIG(*) FROM #Results) = 1
   AND EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapHealthy')
    RAISERROR(N'  PASS 26C-1: @Tables scope returns exactly the targeted healthy heap.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @cnt int = (SELECT COUNT_BIG(*) FROM #Results);
    DECLARE @cntMsg nvarchar(200) = N'  *** FAIL 26C-1: Expected 1 row (HeapHealthy), got ' + CONVERT(nvarchar(10), @cnt);
    RAISERROR(@cntMsg, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 26D: @invocation_command logs @IncludeHealthyHeaps when non-default', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

/* Run with @LogToTable=Y so CommandLog records the invocation; we use @PlanOnly=1 so
   HEAP_SCAN_SUMMARY is written rather than HEAP_REBUILD_START. */
EXEC dbo.sp_HeapDoctor
    @CpuSource          = 'NONE',
    @PlanOnly           = 1,
    @IncludeHealthyHeaps = 1,
    @LogToTable         = N'Y';

DECLARE @latest_cmd nvarchar(max) = (
    SELECT TOP (1) Command
    FROM dbo.CommandLog
    WHERE CommandType = N'HEAP_SCAN_SUMMARY'
    ORDER BY ID DESC
);

IF @latest_cmd LIKE N'%@IncludeHealthyHeaps = 1%'
    RAISERROR(N'  PASS 26D-1: @invocation_command includes "@IncludeHealthyHeaps = 1".', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @cmdMsg nvarchar(2000) = N'  *** FAIL 26D-1: Command did not log @IncludeHealthyHeaps. Got: '
        + ISNULL(LEFT(@latest_cmd, 1500), N'NULL');
    RAISERROR(@cmdMsg, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
-- Cleanup
------------------------------------------------------------------------
DROP TABLE dbo.HeapHealthy;
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'=== Test 26 complete ===', 10, 1) WITH NOWAIT;
