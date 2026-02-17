/*
sp_HeapDoctor Test Harness - Step 2: Plan-Only Tests

Tests @PlanOnly = 1 across all CPU source modes and action preferences.
Uses INSERT...EXEC to capture the target list result set and runs automated
PASS/FAIL assertions against it.

Prerequisites: Run 01_setup_test_data.sql first.
Run with: sqlcmd -S YourServer -d HeapDoctorTest -i 02_test_planonly.sql
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
    total_cpu_ms           bigint        NULL,
    ranking_basis          varchar(20)   NOT NULL,
    nci_count              int           NOT NULL,
    key_source_index       sysname       NULL,
    action_chosen          varchar(32)   NOT NULL
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
-- Cleanup
------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'Plan-only tests complete. Review PASS/FAIL results above.', 10, 1) WITH NOWAIT;
GO
