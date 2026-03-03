/*
sp_HeapDoctor Test Harness - Step 13: @Tables Parameter Tests

Tests @Tables include/exclude filtering with Ola Hallengren-style patterns.
Uses INSERT...EXEC to capture the target list result set and runs automated
PASS/FAIL assertions against it.

Prerequisites: Run 01_setup_test_data.sql first.
Run with: sqlcmd -S YourServer -d HeapDoctorTest -i 13_test_tables_param.sql
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
    page_io_latch_wait_ms  bigint        NULL
);
GO

DECLARE @PassCount int = 0, @FailCount int = 0;
DECLARE @Msg nvarchar(4000);
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 13A: @Tables = single specific table', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @Tables    = N'dbo.HeapA',
    @PlanOnly  = 1;

-- 13A-1: Only HeapA should appear
DECLARE @13a_count int = (SELECT COUNT(*) FROM #Results);
IF @13a_count = 1 AND EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapA')
    RAISERROR(N'  PASS 13A-1: Only HeapA returned.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @13a_msg nvarchar(200) = N'  *** FAIL 13A-1: Expected only HeapA, found ' + CAST(@13a_count AS nvarchar(10)) + N' rows.';
    RAISERROR(@13a_msg, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 13B: @Tables = multiple specific tables', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @Tables    = N'dbo.HeapA, dbo.HeapB',
    @PlanOnly  = 1;

-- 13B-1: HeapA and HeapB should appear, HeapC should not
DECLARE @13b_count int = (SELECT COUNT(*) FROM #Results);
IF @13b_count = 2
   AND EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapA')
   AND EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapB')
   AND NOT EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapC')
    RAISERROR(N'  PASS 13B-1: HeapA and HeapB returned, HeapC excluded.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @13b_msg nvarchar(200) = N'  *** FAIL 13B-1: Expected HeapA+HeapB only, found ' + CAST(@13b_count AS nvarchar(10)) + N' rows.';
    RAISERROR(@13b_msg, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 13C: @Tables = wildcard include', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @Tables    = N'dbo.Heap%',
    @MinPages  = 100,
    @PlanOnly  = 1;

-- 13C-1: All Heap* tables should appear (HeapA, HeapB, HeapC, HeapD, HeapE, HeapF)
-- HeapD is normally filtered by @MinPages=1000 but we lowered it to 100
DECLARE @13c_count int = (SELECT COUNT(*) FROM #Results);
IF @13c_count >= 3
    RAISERROR(N'  PASS 13C-1: Wildcard dbo.Heap%% returned multiple heaps.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @13c_msg nvarchar(200) = N'  *** FAIL 13C-1: Expected >= 3 heaps from dbo.Heap%%, found ' + CAST(@13c_count AS nvarchar(10));
    RAISERROR(@13c_msg, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 13D: @Tables = wildcard with exclusion', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @Tables    = N'dbo.Heap%, -dbo.HeapC',
    @PlanOnly  = 1;

-- 13D-1: HeapA and HeapB should appear, HeapC should NOT
IF EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapA')
   AND EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapB')
   AND NOT EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapC')
    RAISERROR(N'  PASS 13D-1: HeapA+HeapB included, HeapC excluded by -dbo.HeapC.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 13D-1: Exclusion -dbo.HeapC did not work as expected.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 13E: @Tables = table name only (no schema)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @Tables    = N'HeapA',
    @PlanOnly  = 1;

-- 13E-1: HeapA should appear (schema defaults to % = any)
DECLARE @13e_count int = (SELECT COUNT(*) FROM #Results);
IF @13e_count = 1 AND EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapA')
    RAISERROR(N'  PASS 13E-1: Table name without schema matched HeapA.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @13e_msg nvarchar(200) = N'  *** FAIL 13E-1: Expected HeapA only, found ' + CAST(@13e_count AS nvarchar(10)) + N' rows.';
    RAISERROR(@13e_msg, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 13F: @Tables = NULL (all tables, no filter)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @Tables    = NULL,
    @PlanOnly  = 1;

-- 13F-1: All qualifying heaps should appear (HeapA, HeapB, HeapC at minimum)
DECLARE @13f_count int = (SELECT COUNT(*) FROM #Results WHERE table_name IN (N'HeapA', N'HeapB', N'HeapC'));
IF @13f_count = 3
    RAISERROR(N'  PASS 13F-1: @Tables=NULL returns all heaps (HeapA/B/C found).', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @13f_msg nvarchar(200) = N'  *** FAIL 13F-1: Expected 3 heaps with @Tables=NULL, found ' + CAST(@13f_count AS nvarchar(10));
    RAISERROR(@13f_msg, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 13G: @Tables = nonexistent table (no matches)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @Tables    = N'dbo.NoSuchTable',
    @PlanOnly  = 1;

-- 13G-1: No rows should come back
DECLARE @13g_count int = (SELECT COUNT(*) FROM #Results);
IF @13g_count = 0
    RAISERROR(N'  PASS 13G-1: Nonexistent table returned 0 targets.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @13g_msg nvarchar(200) = N'  *** FAIL 13G-1: Expected 0 rows for nonexistent table, found ' + CAST(@13g_count AS nvarchar(10));
    RAISERROR(@13g_msg, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 13H: @Tables = exclude only (all except specific)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- When only exclusions are provided (no inclusions), all tables except excluded should appear.
-- The logic: "no inclusion patterns" means the include filter is a no-op (all pass),
-- then the exclude filter removes the specified tables.
TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @Tables    = N'-dbo.HeapA, -dbo.HeapB',
    @PlanOnly  = 1;

-- 13H-1: HeapA and HeapB should NOT appear, HeapC should
IF NOT EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapA')
   AND NOT EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapB')
   AND EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapC')
    RAISERROR(N'  PASS 13H-1: Exclude-only filter removed HeapA+HeapB, kept HeapC.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 13H-1: Exclude-only pattern did not filter correctly.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 13I: @Tables = wildcard exclusion pattern', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @Tables    = N'-dbo.HeapA%',
    @PlanOnly  = 1;

-- 13I-1: HeapA should NOT appear (matches -dbo.HeapA%), HeapB and HeapC should
IF NOT EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapA')
   AND EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapB')
   AND EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapC')
    RAISERROR(N'  PASS 13I-1: Wildcard exclusion -dbo.HeapA%% removed HeapA, kept B+C.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 13I-1: Wildcard exclusion -dbo.HeapA%% did not filter correctly.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 13J: @Tables underscore in table name is literal', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- Underscore should be treated as literal (not single-char wildcard)
-- HeapA should NOT match 'dbo.Heap_' because _ is escaped to [_]
-- (HeapA has 5 chars, Heap_ would match exactly 5 chars if _ were a wildcard)
TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @Tables    = N'dbo.Heap_',
    @PlanOnly  = 1;

-- 13J-1: No results (no table named exactly "Heap_")
DECLARE @13j_count int = (SELECT COUNT(*) FROM #Results);
IF @13j_count = 0
    RAISERROR(N'  PASS 13J-1: Underscore treated as literal (no match for Heap_).', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @13j_msg nvarchar(200) = N'  *** FAIL 13J-1: Underscore was treated as wildcard. Found ' + CAST(@13j_count AS nvarchar(10)) + N' rows.';
    RAISERROR(@13j_msg, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' @Tables parameter tests complete', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
GO
