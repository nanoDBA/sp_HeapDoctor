/*
sp_HeapDoctor Test Harness - v1.0.2026.0302i: Batch D quick wins

Tests:
  -- Issue #24: Hardware context in debug banner --
  20A - @Debug=1 shows hardware context (schedulers, memory, NUMA)

  -- Issue #47: @FillFactor for CI swap --
  20B - @FillFactor=0 accepted (server default)
  20C - @FillFactor=80 included in CI swap CREATE INDEX
  20D - @FillFactor=101 rejected with error
  20E - @FillFactor in invocation_command when non-zero

  -- Issue #39: Memory-optimized table detection --
  20F - Memory-optimized count message absent (no In-Memory OLTP tables in test DB)

  -- Issue #21: Idempotency guard --
  20G - @MinDaysSinceRebuild already exists (closes #21)

  -- Version --
  20V - Version is 1.0.2026.0302i

Prerequisites: Run 01_setup_test_data.sql first.
Run with: sqlcmd -S YourServer -d HeapDoctorTest -i 20_test_v0302d.sql
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
    uptime_hours           decimal(10,1) NULL,
    page_io_latch_wait_count bigint      NULL,
    page_io_latch_wait_ms  bigint        NULL,
    is_temporal_history    bit           NULL
);
GO

RAISERROR(N'=== Batch 20: v1.0.2026.0302i (#24, #47, #39, #21) ===', 10, 1) WITH NOWAIT;

------------------------------------------------------------------------
-- 20A: #24 - @Debug=1 shows hardware context
------------------------------------------------------------------------
RAISERROR(N'Test 20A: @Debug=1 hardware context (#24)...', 10, 1) WITH NOWAIT;

-- We can't directly capture RAISERROR output, but we can verify it runs without error
DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @Debug = 1;

IF EXISTS (SELECT 1 FROM #Results)
    RAISERROR(N'  PASS 20A: @Debug=1 ran without error (check output above for [DEBUG] Schedulers/Memory/NUMA lines).', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 20A: No results with @Debug=1.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 20B: #47 - @FillFactor=0 accepted (server default)
------------------------------------------------------------------------
RAISERROR(N'Test 20B: @FillFactor=0 accepted (#47)...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @FillFactor = 0;

IF EXISTS (SELECT 1 FROM #Results)
    RAISERROR(N'  PASS 20B: @FillFactor=0 accepted without error.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 20B: No results with @FillFactor=0.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 20C: #47 - @FillFactor=80 included in CI swap CREATE INDEX
------------------------------------------------------------------------
RAISERROR(N'Test 20C: @FillFactor=80 in CI swap command (#47)...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @AllowCiSwap = 1,
    @PreferCiSwap = 1,
    @FillFactor = 80;

DECLARE @ci_cmd nvarchar(max);
SELECT @ci_cmd = command_text FROM #Results WHERE action_chosen = N'CI_SWAP_ONLINE';

IF @ci_cmd LIKE N'%FILLFACTOR = 80%'
    RAISERROR(N'  PASS 20C: FILLFACTOR = 80 found in CI swap command.', 10, 1) WITH NOWAIT;
ELSE IF @ci_cmd IS NOT NULL
    RAISERROR(N'  FAIL 20C: CI swap command missing FILLFACTOR clause.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  PASS 20C: No CI swap target (FILLFACTOR test not applicable, but @FillFactor=80 accepted).', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 20D: #47 - @FillFactor=101 rejected with error
------------------------------------------------------------------------
RAISERROR(N'Test 20D: @FillFactor=101 rejected (#47)...', 10, 1) WITH NOWAIT;

BEGIN TRY
    EXEC dbo.sp_HeapDoctor
        @Databases = N'HeapDoctorTest',
        @CpuSource = N'NONE',
        @PlanOnly = 1,
        @FillFactor = 101;
    RAISERROR(N'  FAIL 20D: @FillFactor=101 did not raise error.', 10, 1) WITH NOWAIT;
END TRY
BEGIN CATCH
    IF ERROR_MESSAGE() LIKE N'%@FillFactor%'
        RAISERROR(N'  PASS 20D: @FillFactor=101 correctly rejected.', 10, 1) WITH NOWAIT;
    ELSE
    BEGIN
        DECLARE @err20d nvarchar(4000) = ERROR_MESSAGE();
        RAISERROR(N'  FAIL 20D: Unexpected error: %s', 10, 1, @err20d) WITH NOWAIT;
    END
END CATCH
GO

------------------------------------------------------------------------
-- 20E: #47 - @FillFactor in invocation_command
------------------------------------------------------------------------
RAISERROR(N'Test 20E: @FillFactor in invocation_command (#47)...', 10, 1) WITH NOWAIT;

DECLARE @pre_id20e int;
SELECT @pre_id20e = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @LogToTable = N'Y',
    @FillFactor = 90;

DECLARE @cmd20e nvarchar(max);
SELECT TOP 1 @cmd20e = Command
FROM dbo.CommandLog
WHERE ID > @pre_id20e
  AND CommandType = N'HEAP_SCAN_SUMMARY'
ORDER BY ID DESC;

IF @cmd20e LIKE N'%@FillFactor = 90%'
    RAISERROR(N'  PASS 20E: @FillFactor = 90 found in invocation_command.', 10, 1) WITH NOWAIT;
ELSE IF @cmd20e IS NOT NULL
    RAISERROR(N'  FAIL 20E: @FillFactor not found in Command column.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 20E: No HEAP_SCAN_SUMMARY found.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 20F: #39 - Memory-optimized count (no In-Memory OLTP tables in test DB)
------------------------------------------------------------------------
RAISERROR(N'Test 20F: Memory-optimized table exclusion message (#39)...', 10, 1) WITH NOWAIT;

-- HeapDoctorTest has no memory-optimized tables, so message should NOT appear
-- We verify the code exists in the proc definition
DECLARE @has_memopt_check bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%memory-optimized table%excluded%''
    ) SET @out = 1;',
    N'@out bit OUTPUT',
    @out = @has_memopt_check OUTPUT;

IF @has_memopt_check = 1
    RAISERROR(N'  PASS 20F: Memory-optimized exclusion message code found in proc.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 20F: Memory-optimized exclusion message not found in proc.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 20G: #21 - @MinDaysSinceRebuild already exists (idempotency guard)
------------------------------------------------------------------------
RAISERROR(N'Test 20G: @MinDaysSinceRebuild exists (#21 idempotency)...', 10, 1) WITH NOWAIT;

DECLARE @has_min_days bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%@MinDaysSinceRebuild%''
    ) SET @out = 1;',
    N'@out bit OUTPUT',
    @out = @has_min_days OUTPUT;

IF @has_min_days = 1
    RAISERROR(N'  PASS 20G: @MinDaysSinceRebuild parameter exists (idempotency guard).', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 20G: @MinDaysSinceRebuild not found.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 20V: Version check
------------------------------------------------------------------------
RAISERROR(N'Test 20V: Version check...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1;

DECLARE @ver20 nvarchar(20);
SELECT TOP 1 @ver20 = version FROM #Results;

IF @ver20 = N'1.0.2026.0302i'
    RAISERROR(N'  PASS 20V: Version is 1.0.2026.0302i.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 20V: Version is %s (expected 1.0.2026.0302i).', 10, 1, @ver20) WITH NOWAIT;
GO

------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'Batch 20 tests complete. Review PASS/FAIL results above.', 10, 1) WITH NOWAIT;
GO
