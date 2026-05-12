/*
sp_HeapDoctor Test Harness - @ExcludeDatabases / @ExcludeTables

Validates the dedicated exclusion parameters:
  - @ExcludeDatabases: comma-separated DB patterns, merged with @Databases
  - @ExcludeTables: comma-separated schema.table patterns, merged with @Tables
  - Both logged to CommandLog via @invocation_command
  - NULL @Databases + @ExcludeDatabases implies USER_DATABASES
  - NULL @Tables + @ExcludeTables implies all tables

Prerequisites: Run 01_setup_test_data.sql first (creates HeapDoctorTest with HeapA/B/C).
Run with: sqlcmd -S YourServer -d HeapDoctorTest -i 27_test_exclude_params.sql
*/

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE [HeapDoctorTest];
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
RAISERROR(N' TEST 27A: @ExcludeTables removes specific tables', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

/* Baseline: HeapA/B/C all present */
TRUNCATE TABLE #Results;
INSERT #Results EXEC dbo.sp_HeapDoctor @CpuSource = 'NONE', @PlanOnly = 1;
DECLARE @baseline_count int = (SELECT COUNT_BIG(*) FROM #Results WHERE table_name IN (N'HeapA', N'HeapB', N'HeapC'));
IF @baseline_count = 3
    RAISERROR(N'  PASS 27A-0: Baseline shows HeapA/B/C (3 heaps).', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 27A-0: Baseline missing one or more heaps.', 10, 1) WITH NOWAIT;

/* Exclude HeapA */
TRUNCATE TABLE #Results;
INSERT #Results EXEC dbo.sp_HeapDoctor @CpuSource = 'NONE', @PlanOnly = 1, @ExcludeTables = N'dbo.HeapA';
IF NOT EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapA')
   AND EXISTS (SELECT 1 FROM #Results WHERE table_name IN (N'HeapB', N'HeapC'))
    RAISERROR(N'  PASS 27A-1: @ExcludeTables = ''dbo.HeapA'' removes HeapA, keeps others.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 27A-1: HeapA not excluded properly.', 10, 1) WITH NOWAIT;

/* Multiple excludes */
TRUNCATE TABLE #Results;
INSERT #Results EXEC dbo.sp_HeapDoctor @CpuSource = 'NONE', @PlanOnly = 1, @ExcludeTables = N'dbo.HeapA, dbo.HeapB';
IF NOT EXISTS (SELECT 1 FROM #Results WHERE table_name IN (N'HeapA', N'HeapB'))
   AND EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapC')
    RAISERROR(N'  PASS 27A-2: Multiple comma-separated excludes work.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 27A-2: Multi-exclude failed.', 10, 1) WITH NOWAIT;

/* Wildcard exclude */
TRUNCATE TABLE #Results;
INSERT #Results EXEC dbo.sp_HeapDoctor @CpuSource = 'NONE', @PlanOnly = 1, @ExcludeTables = N'dbo.Heap%';
IF (SELECT COUNT_BIG(*) FROM #Results) = 0
    RAISERROR(N'  PASS 27A-3: Wildcard exclude (dbo.Heap%%) removes all matching heaps.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 27A-3: Wildcard exclude did not remove all heaps.', 10, 1) WITH NOWAIT;

/* Schema-optional exclude */
TRUNCATE TABLE #Results;
INSERT #Results EXEC dbo.sp_HeapDoctor @CpuSource = 'NONE', @PlanOnly = 1, @ExcludeTables = N'HeapC';
IF NOT EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapC')
    RAISERROR(N'  PASS 27A-4: Schema-optional exclude (just table name) works.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 27A-4: Schema-optional exclude failed.', 10, 1) WITH NOWAIT;

/* Composing @Tables include with @ExcludeTables */
TRUNCATE TABLE #Results;
INSERT #Results EXEC dbo.sp_HeapDoctor
    @CpuSource     = 'NONE',
    @PlanOnly      = 1,
    @Tables        = N'dbo.Heap%',
    @ExcludeTables = N'dbo.HeapB';
DECLARE @compose_count int = (SELECT COUNT_BIG(*) FROM #Results);
IF NOT EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapB') AND @compose_count >= 2
    RAISERROR(N'  PASS 27A-5: @Tables + @ExcludeTables compose correctly.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @cMsg nvarchar(200) = N'  *** FAIL 27A-5: Composition failed (HeapB present or count too low: ' + CONVERT(nvarchar(10), @compose_count) + N')';
    RAISERROR(@cMsg, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 27B: @ExcludeDatabases removes specific databases', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

/* USER_DATABASES minus HeapDoctorTest -> zero targets (the only user DB with qualifying heaps) */
TRUNCATE TABLE #Results;
INSERT #Results EXEC dbo.sp_HeapDoctor
    @CpuSource        = 'NONE',
    @PlanOnly         = 1,
    @Databases        = N'USER_DATABASES',
    @ExcludeDatabases = N'HeapDoctorTest';
IF NOT EXISTS (SELECT 1 FROM #Results WHERE database_name = N'HeapDoctorTest')
    RAISERROR(N'  PASS 27B-1: @ExcludeDatabases removes HeapDoctorTest from USER_DATABASES scan.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 27B-1: @ExcludeDatabases did not exclude HeapDoctorTest.', 10, 1) WITH NOWAIT;

/* @ExcludeDatabases with NULL @Databases should default to USER_DATABASES, find HeapDoctorTest targets */
TRUNCATE TABLE #Results;
INSERT #Results EXEC dbo.sp_HeapDoctor
    @CpuSource        = 'NONE',
    @PlanOnly         = 1,
    @ExcludeDatabases = N'master, model, tempdb, msdb';
IF EXISTS (SELECT 1 FROM #Results WHERE database_name = N'HeapDoctorTest')
    RAISERROR(N'  PASS 27B-2: NULL @Databases + @ExcludeDatabases implies USER_DATABASES.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 27B-2: Implicit USER_DATABASES did not kick in.', 10, 1) WITH NOWAIT;

/* Wildcard exclude */
TRUNCATE TABLE #Results;
INSERT #Results EXEC dbo.sp_HeapDoctor
    @CpuSource        = 'NONE',
    @PlanOnly         = 1,
    @Databases        = N'USER_DATABASES',
    @ExcludeDatabases = N'HeapDoctor%';
IF NOT EXISTS (SELECT 1 FROM #Results WHERE database_name = N'HeapDoctorTest')
    RAISERROR(N'  PASS 27B-3: Wildcard DB exclude (HeapDoctor%%) works.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 27B-3: Wildcard DB exclude failed.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 27C: CommandLog logs both new params via @invocation_command', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

EXEC dbo.sp_HeapDoctor
    @CpuSource        = 'NONE',
    @PlanOnly         = 1,
    @ExcludeDatabases = N'tempdb',
    @ExcludeTables    = N'dbo.HeapA',
    @LogToTable       = N'Y';

DECLARE @latest_cmd nvarchar(max) = (
    SELECT TOP (1) Command
    FROM dbo.CommandLog
    WHERE CommandType = N'HEAP_SCAN_SUMMARY'
    ORDER BY ID DESC
);

IF @latest_cmd LIKE N'%@ExcludeDatabases = N''tempdb''%'
   AND @latest_cmd LIKE N'%@ExcludeTables = N''dbo.HeapA''%'
    RAISERROR(N'  PASS 27C-1: CommandLog @invocation_command includes both exclude params.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @cmdMsg nvarchar(2000) = N'  *** FAIL 27C-1: Exclude params missing from Command. Got: '
        + ISNULL(LEFT(@latest_cmd, 1500), N'NULL');
    RAISERROR(@cmdMsg, 10, 1) WITH NOWAIT;
END
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'=== Test 27 complete ===', 10, 1) WITH NOWAIT;
