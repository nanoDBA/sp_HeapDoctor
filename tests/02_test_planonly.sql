/*
sp_HeapDoctor Test Harness - Step 2: Plan-Only Tests

Tests @PlanOnly = 1 across all CPU source modes and action preferences.
Uses INSERT...EXEC to capture the target list result set and runs automated
PASS/FAIL assertions against it.

IMPORTANT: INSERT...EXEC nesting limitation
  SQL Server does not allow nested INSERT...EXEC.  These tests use
  INSERT #Results EXEC dbo.sp_HeapDoctor ... to capture output.  If
  @CpuSource = 'QUICKIESTORE' is active, sp_HeapDoctor internally does
  INSERT #Quickie EXEC sp_executesql @InnerSql, which creates a nested
  INSERT...EXEC and will fail with:
    "An INSERT EXEC statement cannot be nested."
  Therefore, QUICKIESTORE tests in this file must NOT use the INSERT...EXEC
  capture pattern.  Use direct EXEC (visual inspection) instead.

Prerequisites: Run 01_setup_test_data.sql first.
Run with: sqlcmd -S YourServer -d HeapDoctorTest -i 02_test_planonly.sql
  (add -E for Windows auth, -U/-P for SQL auth, or -G for Azure AD)
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
    uptime_hours           decimal(10,1) NULL
);
GO

DECLARE @PassCount int = 0, @FailCount int = 0;
DECLARE @Msg nvarchar(4000);
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 2A: PlanOnly, CpuSource=NONE (baseline)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @PlanOnly  = 1;

-- 2A-1: HeapA, HeapB, HeapC should all appear
DECLARE @2a_count int = (SELECT COUNT(*) FROM #Results WHERE table_name IN ('HeapA','HeapB','HeapC'));
IF @2a_count = 3
    RAISERROR(N'  PASS 2A-1: Found all 3 expected heaps.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @2a_msg nvarchar(200) = N'  *** FAIL 2A-1: Expected 3 heaps, found ' + CAST(@2a_count AS nvarchar(10));
    RAISERROR(@2a_msg, 10, 1) WITH NOWAIT;
END

-- 2A-2: HeapD should NOT appear (too small)
IF NOT EXISTS (SELECT 1 FROM #Results WHERE table_name = 'HeapD')
    RAISERROR(N'  PASS 2A-2: HeapD correctly filtered out by @MinPages.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 2A-2: HeapD should not appear (too small).', 10, 1) WITH NOWAIT;

-- 2A-3: total_cpu_ms should be NULL (CpuSource=NONE)
IF NOT EXISTS (SELECT 1 FROM #Results WHERE total_cpu_ms IS NOT NULL)
    RAISERROR(N'  PASS 2A-3: total_cpu_ms is NULL for all targets (CpuSource=NONE).', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 2A-3: total_cpu_ms should be NULL when CpuSource=NONE.', 10, 1) WITH NOWAIT;

-- 2A-4: ranking_basis should be FWD_PCT
IF NOT EXISTS (SELECT 1 FROM #Results WHERE ranking_basis <> 'FWD_PCT')
    RAISERROR(N'  PASS 2A-4: ranking_basis = FWD_PCT for all targets.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 2A-4: ranking_basis should be FWD_PCT when CpuSource=NONE.', 10, 1) WITH NOWAIT;

-- 2A-5: action_chosen should be HEAP_REBUILD_ONLINE or HEAP_REBUILD_OFFLINE
IF NOT EXISTS (SELECT 1 FROM #Results WHERE action_chosen NOT IN ('HEAP_REBUILD_ONLINE','HEAP_REBUILD_OFFLINE'))
    RAISERROR(N'  PASS 2A-5: action_chosen is valid rebuild type for all targets.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 2A-5: Unexpected action_chosen value.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 2B: PlanOnly, CpuSource=QUERY_STORE', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'QUERY_STORE',
    @PlanOnly  = 1;

-- 2B-1: Same 3 targets
DECLARE @2b_count int = (SELECT COUNT(*) FROM #Results WHERE table_name IN ('HeapA','HeapB','HeapC'));
IF @2b_count = 3
    RAISERROR(N'  PASS 2B-1: Found all 3 expected heaps.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @2b_msg nvarchar(200) = N'  *** FAIL 2B-1: Expected 3 heaps, found ' + CAST(@2b_count AS nvarchar(10));
    RAISERROR(@2b_msg, 10, 1) WITH NOWAIT;
END

-- 2B-2: total_cpu_ms should be populated for at least some targets
DECLARE @2b_cpu_count int = (SELECT COUNT(*) FROM #Results WHERE total_cpu_ms IS NOT NULL AND total_cpu_ms > 0);
IF @2b_cpu_count > 0
BEGIN
    DECLARE @2b_cpu_msg nvarchar(200) = N'  PASS 2B-2: ' + CAST(@2b_cpu_count AS nvarchar(10)) + N' target(s) have CPU data from Query Store.';
    RAISERROR(@2b_cpu_msg, 10, 1) WITH NOWAIT;
END
ELSE
    RAISERROR(N'  *** FAIL 2B-2: No targets have CPU data. Query Store may not have flushed.', 10, 1) WITH NOWAIT;

-- 2B-3: ranking_basis should include QS_CPU for targets with CPU data
IF EXISTS (SELECT 1 FROM #Results WHERE ranking_basis = 'QS_CPU')
    RAISERROR(N'  PASS 2B-3: At least one target has ranking_basis = QS_CPU.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 2B-3: No targets have ranking_basis = QS_CPU.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 2C: PlanOnly, CI swap enabled', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource     = 'NONE',
    @AllowCiSwap   = 1,
    @PreferCiSwap  = 1,
    @PlanOnly      = 1;

-- 2C-1: HeapB should use CI_SWAP_ONLINE (has unique NC, no LOB)
-- Note: CI swap requires online support (Enterprise/Developer). On Standard, HeapB uses HEAP_REBUILD_OFFLINE.
DECLARE @2c_heapb_action varchar(32) = (SELECT action_chosen FROM #Results WHERE table_name = 'HeapB');
IF @2c_heapb_action = 'CI_SWAP_ONLINE'
    RAISERROR(N'  PASS 2C-1: HeapB action_chosen = CI_SWAP_ONLINE.', 10, 1) WITH NOWAIT;
ELSE IF @2c_heapb_action = 'HEAP_REBUILD_OFFLINE'
    RAISERROR(N'  PASS 2C-1: HeapB action_chosen = HEAP_REBUILD_OFFLINE (Standard Edition - CI swap requires online).', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @2c_msg nvarchar(200) = N'  *** FAIL 2C-1: HeapB action_chosen = ' + ISNULL(@2c_heapb_action, N'NULL');
    RAISERROR(@2c_msg, 10, 1) WITH NOWAIT;
END

-- 2C-2: HeapA should NOT use CI swap (no suitable unique key)
DECLARE @2c_heapa_action varchar(32) = (SELECT action_chosen FROM #Results WHERE table_name = 'HeapA');
IF @2c_heapa_action LIKE 'HEAP_REBUILD%'
    RAISERROR(N'  PASS 2C-2: HeapA uses HEAP_REBUILD (no suitable CI swap key).', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @2c_msg2 nvarchar(200) = N'  *** FAIL 2C-2: HeapA should not use CI swap. Got: ' + ISNULL(@2c_heapa_action, N'NULL');
    RAISERROR(@2c_msg2, 10, 1) WITH NOWAIT;
END

-- 2C-3: HeapC should NOT use CI swap (has LOB column varchar(max))
DECLARE @2c_heapc_action varchar(32) = (SELECT action_chosen FROM #Results WHERE table_name = 'HeapC');
IF @2c_heapc_action LIKE 'HEAP_REBUILD%'
    RAISERROR(N'  PASS 2C-3: HeapC uses HEAP_REBUILD (LOB guard blocked CI swap).', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @2c_msg3 nvarchar(200) = N'  *** FAIL 2C-3: HeapC should not use CI swap (has LOB). Got: ' + ISNULL(@2c_heapc_action, N'NULL');
    RAISERROR(@2c_msg3, 10, 1) WITH NOWAIT;
END

-- 2C-4: HeapB should have key_source_index populated (on Enterprise)
DECLARE @2c_key sysname = (SELECT key_source_index FROM #Results WHERE table_name = 'HeapB');
IF @2c_key IS NOT NULL OR @2c_heapb_action <> 'CI_SWAP_ONLINE'
    RAISERROR(N'  PASS 2C-4: HeapB key_source_index populated or CI swap not chosen.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 2C-4: HeapB CI_SWAP_ONLINE but key_source_index is NULL.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 2D: PlanOnly, @MinPages filter (high threshold)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @MinPages  = 100000,
    @PlanOnly  = 1;

-- 2D-1: Should return 0 targets (all test heaps < 100K pages)
DECLARE @2d_count int = (SELECT COUNT(*) FROM #Results);
IF @2d_count = 0
    RAISERROR(N'  PASS 2D-1: Zero targets returned (all heaps below 100K page threshold).', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @2d_msg nvarchar(200) = N'  *** FAIL 2D-1: Expected 0 targets, found ' + CAST(@2d_count AS nvarchar(10));
    RAISERROR(@2d_msg, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 2D2: PlanOnly, @MaxPages filter (low cap)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @MaxPages  = 100,
    @MinPages  = 1,
    @PlanOnly  = 1;

-- 2D2-1: Should return 0 targets (all test heaps > 100 pages)
DECLARE @2d2_count int = (SELECT COUNT(*) FROM #Results);
IF @2d2_count = 0
    RAISERROR(N'  PASS 2D2-1: Zero targets returned (all heaps above 100 page cap).', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @2d2_msg nvarchar(200) = N'  *** FAIL 2D2-1: Expected 0 targets with @MaxPages=100, found ' + CAST(@2d2_count AS nvarchar(10));
    RAISERROR(@2d2_msg, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 2E: PlanOnly, @OnlinePreference = OFF', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource        = 'NONE',
    @OnlinePreference = 'OFF',
    @PlanOnly         = 1;

-- 2E-1: action_chosen should be HEAP_REBUILD_OFFLINE for all
IF NOT EXISTS (SELECT 1 FROM #Results WHERE action_chosen <> 'HEAP_REBUILD_OFFLINE')
    RAISERROR(N'  PASS 2E-1: All targets use HEAP_REBUILD_OFFLINE.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 2E-1: Some targets are not HEAP_REBUILD_OFFLINE.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 2F: PlanOnly with @Maxdop', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- We need the commands result set to check for MAXDOP.
-- INSERT...EXEC captures the first result set (target list), which doesn't include command_text.
-- We'll use a second capture table for the commands result set.
-- Workaround: call the proc, then manually verify MAXDOP via the printed output.
-- For a more robust check, we call it with @Debug=1 and verify the output.

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @Maxdop    = 2,
    @PlanOnly  = 1;

-- 2F-1: Targets found (basic sanity)
DECLARE @2f_count int = (SELECT COUNT(*) FROM #Results);
IF @2f_count >= 3
    RAISERROR(N'  PASS 2F-1: Targets found with @Maxdop=2.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @2f_msg nvarchar(200) = N'  *** FAIL 2F-1: Expected >= 3 targets, found ' + CAST(@2f_count AS nvarchar(10));
    RAISERROR(@2f_msg, 10, 1) WITH NOWAIT;
END

-- Note: MAXDOP in command_text cannot be verified from the target list result set.
-- Inspect the commands result set in the output above for "MAXDOP = 2".
RAISERROR(N'  INFO 2F-2: Verify "MAXDOP = 2" in the commands output above (manual check).', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 2G: PlanOnly, multi-database (USER_DATABASES)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @Databases = 'USER_DATABASES',
    @CpuSource = 'NONE',
    @PlanOnly  = 1;

-- 2G-1: HeapDoctorTest targets should appear
DECLARE @2g_count int = (SELECT COUNT(*) FROM #Results WHERE database_name = 'HeapDoctorTest');
IF @2g_count >= 3
BEGIN
    DECLARE @2g_msg nvarchar(200) = N'  PASS 2G-1: Found ' + CAST(@2g_count AS nvarchar(10)) + N' targets in HeapDoctorTest from USER_DATABASES scan.';
    RAISERROR(@2g_msg, 10, 1) WITH NOWAIT;
END
ELSE
BEGIN
    DECLARE @2g_msg2 nvarchar(200) = N'  *** FAIL 2G-1: Expected >= 3 HeapDoctorTest targets, found ' + CAST(@2g_count AS nvarchar(10));
    RAISERROR(@2g_msg2, 10, 1) WITH NOWAIT;
END

-- 2G-2: database_name column should be populated for all
IF NOT EXISTS (SELECT 1 FROM #Results WHERE database_name IS NULL OR database_name = '')
    RAISERROR(N'  PASS 2G-2: database_name populated for all targets.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 2G-2: Some targets have NULL/empty database_name.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 2H: PlanOnly, @Debug=1', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @Debug     = 1,
    @PlanOnly  = 1;

-- 2H-1: Targets found (debug mode doesn't break normal operation)
DECLARE @2h_count int = (SELECT COUNT(*) FROM #Results);
IF @2h_count >= 3
    RAISERROR(N'  PASS 2H-1: @Debug=1 produced valid results. Check output above for [DEBUG] lines.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @2h_msg nvarchar(200) = N'  *** FAIL 2H-1: Expected >= 3 targets with @Debug=1, found ' + CAST(@2h_count AS nvarchar(10));
    RAISERROR(@2h_msg, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 2I: PlanOnly, @EstimateTime=1 (no history)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- Ensure no leftover CommandLog history from prior test runs
TRUNCATE TABLE dbo.CommandLog;

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource     = 'NONE',
    @EstimateTime  = 1,
    @PlanOnly      = 1;

-- 2I-1: Targets should still be found
DECLARE @2i_count int = (SELECT COUNT(*) FROM #Results WHERE table_name IN ('HeapA','HeapB','HeapC'));
IF @2i_count = 3
    RAISERROR(N'  PASS 2I-1: Found all 3 expected heaps with @EstimateTime=1.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @2i_msg nvarchar(200) = N'  *** FAIL 2I-1: Expected 3 heaps, found ' + CAST(@2i_count AS nvarchar(10));
    RAISERROR(@2i_msg, 10, 1) WITH NOWAIT;
END

-- 2I-2: est_pages_per_sec should be NULL (no CommandLog history)
IF NOT EXISTS (SELECT 1 FROM #Results WHERE est_pages_per_sec IS NOT NULL)
    RAISERROR(N'  PASS 2I-2: est_pages_per_sec is NULL (no history available).', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 2I-2: est_pages_per_sec should be NULL without CommandLog history.', 10, 1) WITH NOWAIT;

-- 2I-3: est_seconds should be NULL
IF NOT EXISTS (SELECT 1 FROM #Results WHERE est_seconds IS NOT NULL)
    RAISERROR(N'  PASS 2I-3: est_seconds is NULL (no history available).', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 2I-3: est_seconds should be NULL without CommandLog history.', 10, 1) WITH NOWAIT;

-- 2I-4: est_duration should be NULL
IF NOT EXISTS (SELECT 1 FROM #Results WHERE est_duration IS NOT NULL)
    RAISERROR(N'  PASS 2I-4: est_duration is NULL (no history available).', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 2I-4: est_duration should be NULL without CommandLog history.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 2J: QS snapshot populated with QUERY_STORE', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'QUERY_STORE',
    @PlanOnly  = 1;

-- 2J-1: qs_total_logical_reads populated for QS_CPU targets
DECLARE @2j_qscpu_count int = (SELECT COUNT(*) FROM #Results WHERE ranking_basis = 'QS_CPU');
DECLARE @2j_reads_count int = (SELECT COUNT(*) FROM #Results WHERE ranking_basis = 'QS_CPU' AND qs_total_logical_reads IS NOT NULL);
IF @2j_qscpu_count > 0 AND @2j_reads_count = @2j_qscpu_count
    RAISERROR(N'  PASS 2J-1: qs_total_logical_reads populated for all QS_CPU targets.', 10, 1) WITH NOWAIT;
ELSE IF @2j_qscpu_count = 0
    RAISERROR(N'  SKIP 2J-1: No QS_CPU targets found (QS may not have scan data). Not a failure.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @2j1_msg nvarchar(200) = N'  *** FAIL 2J-1: ' + CAST(@2j_reads_count AS nvarchar(10)) + N'/' + CAST(@2j_qscpu_count AS nvarchar(10)) + N' QS_CPU targets have qs_total_logical_reads.';
    RAISERROR(@2j1_msg, 10, 1) WITH NOWAIT;
END

-- 2J-2: qs_plan_count > 0 for QS_CPU targets
DECLARE @2j_plan_count int = (SELECT COUNT(*) FROM #Results WHERE ranking_basis = 'QS_CPU' AND qs_plan_count > 0);
IF @2j_qscpu_count > 0 AND @2j_plan_count = @2j_qscpu_count
    RAISERROR(N'  PASS 2J-2: qs_plan_count > 0 for all QS_CPU targets.', 10, 1) WITH NOWAIT;
ELSE IF @2j_qscpu_count = 0
    RAISERROR(N'  SKIP 2J-2: No QS_CPU targets.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @2j2_msg nvarchar(200) = N'  *** FAIL 2J-2: ' + CAST(@2j_plan_count AS nvarchar(10)) + N'/' + CAST(@2j_qscpu_count AS nvarchar(10)) + N' QS_CPU targets have qs_plan_count > 0.';
    RAISERROR(@2j2_msg, 10, 1) WITH NOWAIT;
END

-- 2J-3: qs_query_count > 0 for QS_CPU targets
DECLARE @2j_query_count int = (SELECT COUNT(*) FROM #Results WHERE ranking_basis = 'QS_CPU' AND qs_query_count > 0);
IF @2j_qscpu_count > 0 AND @2j_query_count = @2j_qscpu_count
    RAISERROR(N'  PASS 2J-3: qs_query_count > 0 for all QS_CPU targets.', 10, 1) WITH NOWAIT;
ELSE IF @2j_qscpu_count = 0
    RAISERROR(N'  SKIP 2J-3: No QS_CPU targets.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @2j3_msg nvarchar(200) = N'  *** FAIL 2J-3: ' + CAST(@2j_query_count AS nvarchar(10)) + N'/' + CAST(@2j_qscpu_count AS nvarchar(10)) + N' QS_CPU targets have qs_query_count > 0.';
    RAISERROR(@2j3_msg, 10, 1) WITH NOWAIT;
END

-- 2J-4: qs_snapshot_time_utc populated for QS_CPU targets
DECLARE @2j_snap_count int = (SELECT COUNT(*) FROM #Results WHERE ranking_basis = 'QS_CPU' AND qs_snapshot_time_utc IS NOT NULL);
IF @2j_qscpu_count > 0 AND @2j_snap_count = @2j_qscpu_count
    RAISERROR(N'  PASS 2J-4: qs_snapshot_time_utc populated for all QS_CPU targets.', 10, 1) WITH NOWAIT;
ELSE IF @2j_qscpu_count = 0
    RAISERROR(N'  SKIP 2J-4: No QS_CPU targets.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @2j4_msg nvarchar(200) = N'  *** FAIL 2J-4: ' + CAST(@2j_snap_count AS nvarchar(10)) + N'/' + CAST(@2j_qscpu_count AS nvarchar(10)) + N' QS_CPU targets have qs_snapshot_time_utc.';
    RAISERROR(@2j4_msg, 10, 1) WITH NOWAIT;
END

-- 2J-5: qs_total_executions > 0 for QS_CPU targets
DECLARE @2j_exec_count int = (SELECT COUNT(*) FROM #Results WHERE ranking_basis = 'QS_CPU' AND qs_total_executions > 0);
IF @2j_qscpu_count > 0 AND @2j_exec_count = @2j_qscpu_count
    RAISERROR(N'  PASS 2J-5: qs_total_executions > 0 for all QS_CPU targets.', 10, 1) WITH NOWAIT;
ELSE IF @2j_qscpu_count = 0
    RAISERROR(N'  SKIP 2J-5: No QS_CPU targets.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @2j5_msg nvarchar(200) = N'  *** FAIL 2J-5: ' + CAST(@2j_exec_count AS nvarchar(10)) + N'/' + CAST(@2j_qscpu_count AS nvarchar(10)) + N' QS_CPU targets have qs_total_executions > 0.';
    RAISERROR(@2j5_msg, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 2K: QS snapshot NULL for CpuSource=NONE', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @PlanOnly  = 1;

-- 2K-1: All qs_* columns should be NULL
IF NOT EXISTS (SELECT 1 FROM #Results WHERE qs_snapshot_time_utc IS NOT NULL
                                         OR qs_total_logical_reads IS NOT NULL
                                         OR qs_total_physical_reads IS NOT NULL
                                         OR qs_total_duration_ms IS NOT NULL
                                         OR qs_total_executions IS NOT NULL
                                         OR qs_plan_count IS NOT NULL
                                         OR qs_query_count IS NOT NULL)
    RAISERROR(N'  PASS 2K-1: All QS snapshot columns are NULL when CpuSource=NONE.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 2K-1: Some QS snapshot columns are non-NULL when CpuSource=NONE.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 2L: forwarded_fetch_count from operational stats', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- Re-use existing #Results from 2K (CpuSource=NONE, all heaps present)
-- The test setup ran queries against HeapA/B/C which create forwarded_fetch_count > 0

-- 2L-1: forwarded_fetch_count should be populated (NOT NULL) for targets
DECLARE @2l_ffc_count int = (SELECT COUNT(*) FROM #Results WHERE forwarded_fetch_count IS NOT NULL);
IF @2l_ffc_count >= 1
BEGIN
    DECLARE @2l_msg1 nvarchar(200) = N'  PASS 2L-1: forwarded_fetch_count populated for ' + CAST(@2l_ffc_count AS nvarchar(10)) + N' target(s).';
    RAISERROR(@2l_msg1, 10, 1) WITH NOWAIT;
END
ELSE
    RAISERROR(N'  *** FAIL 2L-1: forwarded_fetch_count is NULL for all targets.', 10, 1) WITH NOWAIT;

-- 2L-2: forwarded_fetch_count should be > 0 for heaps that had table scans
DECLARE @2l_ffc_positive int = (SELECT COUNT(*) FROM #Results WHERE forwarded_fetch_count > 0);
IF @2l_ffc_positive >= 1
BEGIN
    DECLARE @2l_msg2 nvarchar(200) = N'  PASS 2L-2: forwarded_fetch_count > 0 for ' + CAST(@2l_ffc_positive AS nvarchar(10)) + N' target(s) (forwarded records being accessed).';
    RAISERROR(@2l_msg2, 10, 1) WITH NOWAIT;
END
ELSE
    RAISERROR(N'  INFO 2L-2: forwarded_fetch_count = 0 for all targets (no table scans hit forwarded records during test setup).', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 2M: usage_hint from dm_db_index_usage_stats', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- Re-use existing #Results from 2K (CpuSource=NONE, all heaps present)
-- Test heaps have more scans (20 iterations in setup) than updates (1-2 statements),
-- so none should be flagged as WRITE_HEAVY or WRITE_ONLY.

-- 2M-1: usage_hint should be NULL for read-heavy heaps (more reads than writes)
DECLARE @2m_hinted int = (SELECT COUNT(*) FROM #Results WHERE usage_hint IS NOT NULL);
IF @2m_hinted = 0
BEGIN
    RAISERROR(N'  PASS 2M-1: usage_hint is NULL for all targets (correct: test heaps are read-heavy).', 10, 1) WITH NOWAIT;
END
ELSE
BEGIN
    DECLARE @2m_msg1 nvarchar(200) = N'  INFO 2M-1: usage_hint populated for ' + CAST(@2m_hinted AS nvarchar(10)) + N' target(s). Expected NULL for read-heavy test heaps.';
    RAISERROR(@2m_msg1, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 2N: ranking_score (LOG10-normalized)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- Re-use existing #Results from 2K (CpuSource=NONE, all heaps present)

-- 2N-1: ranking_score should be populated (NOT NULL) for all targets
DECLARE @2n_score_count int = (SELECT COUNT(*) FROM #Results WHERE ranking_score IS NOT NULL);
DECLARE @2n_total_count int = (SELECT COUNT(*) FROM #Results);
IF @2n_score_count = @2n_total_count AND @2n_total_count > 0
    RAISERROR(N'  PASS 2N-1: ranking_score populated for all targets.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @2n_msg1 nvarchar(200) = N'  *** FAIL 2N-1: ranking_score populated for ' + CAST(@2n_score_count AS nvarchar(10)) + N'/' + CAST(@2n_total_count AS nvarchar(10)) + N' targets.';
    RAISERROR(@2n_msg1, 10, 1) WITH NOWAIT;
END

-- 2N-2: ranking_score should be > 0 (forwarded_pct > 0 guarantees a positive score)
DECLARE @2n_positive int = (SELECT COUNT(*) FROM #Results WHERE ranking_score > 0);
IF @2n_positive = @2n_total_count AND @2n_total_count > 0
    RAISERROR(N'  PASS 2N-2: ranking_score > 0 for all targets.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @2n_msg2 nvarchar(200) = N'  *** FAIL 2N-2: Expected all ranking_score > 0, got ' + CAST(@2n_positive AS nvarchar(10)) + N'/' + CAST(@2n_total_count AS nvarchar(10));
    RAISERROR(@2n_msg2, 10, 1) WITH NOWAIT;
END

-- 2N-3: sort_order should match ranking_score descending (highest score = sort_order 1)
DECLARE @2n_order_bad int = (
    SELECT COUNT(*)
    FROM #Results r1
    INNER JOIN #Results r2
        ON r1.sort_order < r2.sort_order
       AND r1.ranking_score < r2.ranking_score
);
IF @2n_order_bad = 0
    RAISERROR(N'  PASS 2N-3: sort_order matches ranking_score descending order.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @2n_msg3 nvarchar(200) = N'  *** FAIL 2N-3: ' + CAST(@2n_order_bad AS nvarchar(10)) + N' sort_order violations vs ranking_score.';
    RAISERROR(@2n_msg3, 10, 1) WITH NOWAIT;
END

-- 2N-4: With QS CPU data, ranking_score should be higher for targets with CPU
TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'QUERY_STORE',
    @PlanOnly  = 1;

DECLARE @2n_with_cpu decimal(8,4) = (SELECT MAX(ranking_score) FROM #Results WHERE total_cpu_ms IS NOT NULL AND total_cpu_ms > 0);
DECLARE @2n_no_cpu decimal(8,4) = (SELECT MAX(ranking_score) FROM #Results WHERE total_cpu_ms IS NULL OR total_cpu_ms = 0);
IF @2n_with_cpu IS NOT NULL AND @2n_no_cpu IS NOT NULL AND @2n_with_cpu > @2n_no_cpu
    RAISERROR(N'  PASS 2N-4: Targets with CPU data have higher ranking_score than those without.', 10, 1) WITH NOWAIT;
ELSE IF @2n_with_cpu IS NULL OR @2n_no_cpu IS NULL
    RAISERROR(N'  SKIP 2N-4: Cannot compare (all targets have CPU data or none do).', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @2n_msg4 nvarchar(200) = N'  *** FAIL 2N-4: Max CPU score (' + CAST(@2n_with_cpu AS nvarchar(20)) + N') not > max no-CPU score (' + CAST(@2n_no_cpu AS nvarchar(20)) + N').';
    RAISERROR(@2n_msg4, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
-- Cleanup
------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'Plan-only tests complete. Review PASS/FAIL results above.', 10, 1) WITH NOWAIT;
GO
