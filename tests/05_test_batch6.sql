/*
sp_HeapDoctor Test Harness - Step 5: Batch 6 Tests (Critical Bug Fixes)

Tests:
  6A - Partitioned heap discovery (not tested here; requires Enterprise partition function)
  6B - Compression preservation in CI swap and ALTER TABLE REBUILD
  6C - GETUTCDATE uptime (verified implicitly; no timezone-specific test)
  6D - Temporal table exclusion
  6E - Always Encrypted exclusion (requires AE setup; verified syntactically only)
  6F - RETURN 1 on failure

Prerequisites: Run 01_setup_test_data.sql first (creates HeapE, HeapF, HeapTemporal).
Run with: sqlcmd -S YourServer -d HeapDoctorTest -i 05_test_batch6.sql
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
    uptime_hours           decimal(10,1) NULL,
    page_io_latch_wait_count bigint      NULL,
    page_io_latch_wait_ms  bigint        NULL
);
GO

------------------------------------------------------------------------
-- Recreate forwarded records (tables may have been rebuilt by prior tests)
------------------------------------------------------------------------
RAISERROR(N'Recreating forwarded records in test heaps...', 10, 1) WITH NOWAIT;

TRUNCATE TABLE dbo.HeapA;
;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapA (ID, Padding, MoreData)
SELECT TOP (20000) n, REPLICATE('A', 10), NULL FROM N;
UPDATE dbo.HeapA SET Padding = REPLICATE('X', 3000), MoreData = REPLICATE('Y', 3000) WHERE ID <= 15000;

TRUNCATE TABLE dbo.HeapB;
;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapB (ID, Code, Padding, MoreData)
SELECT TOP (20000) n, 'CODE-' + CAST(n AS varchar(10)), REPLICATE('B', 10), NULL FROM N;
UPDATE dbo.HeapB SET Padding = REPLICATE('X', 3000), MoreData = REPLICATE('Y', 3000) WHERE ID <= 15000;

TRUNCATE TABLE dbo.HeapC;
;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapC (ID, Padding, BigData)
SELECT TOP (20000) n, REPLICATE('C', 10), NULL FROM N;
UPDATE dbo.HeapC SET Padding = REPLICATE('X', 3000), BigData = REPLICATE(CAST('Z' AS varchar(max)), 500) WHERE ID <= 15000;

TRUNCATE TABLE dbo.HeapE;
;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapE (ID, Code, Padding, MoreData)
SELECT TOP (20000) n, 'CODE-' + CAST(n AS varchar(10)), REPLICATE('E', 10), NULL FROM N;
UPDATE dbo.HeapE SET Padding = REPLICATE('X', 3000), MoreData = REPLICATE('Y', 3000) WHERE ID <= 15000;

TRUNCATE TABLE dbo.HeapF;
;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapF (ID, Padding, MoreData)
SELECT TOP (20000) n, REPLICATE('F', 10), NULL FROM N;
UPDATE dbo.HeapF SET Padding = REPLICATE('X', 3000), MoreData = REPLICATE('Y', 3000) WHERE ID <= 15000;

RAISERROR(N'Forwarded records recreated.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 5A: Temporal table excluded from discovery (6D)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @MinPages  = 1,
    @PlanOnly  = 1;

-- 5A-1: HeapTemporal should NOT appear (temporal_type filter)
IF NOT EXISTS (SELECT 1 FROM #Results WHERE table_name = 'HeapTemporal')
    RAISERROR(N'  PASS 5A-1: HeapTemporal correctly excluded (temporal_type = 1).', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 5A-1: HeapTemporal should not appear (temporal table).', 10, 1) WITH NOWAIT;

-- 5A-2: HeapTemporalHistory should NOT appear (temporal_type = 2 for history table)
IF NOT EXISTS (SELECT 1 FROM #Results WHERE table_name = 'HeapTemporalHistory')
    RAISERROR(N'  PASS 5A-2: HeapTemporalHistory correctly excluded (history table).', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 5A-2: HeapTemporalHistory should not appear.', 10, 1) WITH NOWAIT;

-- 5A-3: Non-temporal heaps should still appear
DECLARE @5a_count int = (SELECT COUNT(*) FROM #Results WHERE table_name IN ('HeapA','HeapB','HeapC'));
IF @5a_count = 3
    RAISERROR(N'  PASS 5A-3: Non-temporal heaps (A, B, C) still discovered.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @5a_msg nvarchar(200) = N'  *** FAIL 5A-3: Expected 3 non-temporal heaps, found ' + CAST(@5a_count AS nvarchar(10));
    RAISERROR(@5a_msg, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 5B: Compression column populated (6B)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- Re-use #Results from 5A

-- 5B-1: HeapE should have heap_compression = PAGE
DECLARE @5b_heape_comp varchar(4) = (SELECT heap_compression FROM #Results WHERE table_name = 'HeapE');
IF @5b_heape_comp = 'PAGE'
    RAISERROR(N'  PASS 5B-1: HeapE heap_compression = PAGE.', 10, 1) WITH NOWAIT;
ELSE IF @5b_heape_comp IS NULL
    RAISERROR(N'  *** FAIL 5B-1: HeapE not found in results.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @5b1_msg nvarchar(200) = N'  *** FAIL 5B-1: HeapE heap_compression = ' + ISNULL(@5b_heape_comp, 'NULL') + N', expected PAGE.';
    RAISERROR(@5b1_msg, 10, 1) WITH NOWAIT;
END

-- 5B-2: HeapF should have heap_compression = ROW
DECLARE @5b_heapf_comp varchar(4) = (SELECT heap_compression FROM #Results WHERE table_name = 'HeapF');
IF @5b_heapf_comp = 'ROW'
    RAISERROR(N'  PASS 5B-2: HeapF heap_compression = ROW.', 10, 1) WITH NOWAIT;
ELSE IF @5b_heapf_comp IS NULL
    RAISERROR(N'  *** FAIL 5B-2: HeapF not found in results.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @5b2_msg nvarchar(200) = N'  *** FAIL 5B-2: HeapF heap_compression = ' + ISNULL(@5b_heapf_comp, 'NULL') + N', expected ROW.';
    RAISERROR(@5b2_msg, 10, 1) WITH NOWAIT;
END

-- 5B-3: HeapA should have heap_compression = NONE (uncompressed)
DECLARE @5b_heapa_comp varchar(4) = (SELECT heap_compression FROM #Results WHERE table_name = 'HeapA');
IF @5b_heapa_comp = 'NONE'
    RAISERROR(N'  PASS 5B-3: HeapA heap_compression = NONE.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @5b3_msg nvarchar(200) = N'  *** FAIL 5B-3: HeapA heap_compression = ' + ISNULL(@5b_heapa_comp, 'NULL') + N', expected NONE.';
    RAISERROR(@5b3_msg, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 5C: Compression in CI swap command (6B)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource     = 'NONE',
    @AllowCiSwap   = 1,
    @PreferCiSwap  = 1,
    @MinPages      = 1,
    @PlanOnly      = 1;

-- 5C-1: HeapE CI swap command should include DATA_COMPRESSION = PAGE
DECLARE @5c_heape_cmd nvarchar(max) = (SELECT command_text FROM #Results WHERE table_name = 'HeapE');
DECLARE @5c_heape_action varchar(32) = (SELECT action_chosen FROM #Results WHERE table_name = 'HeapE');

IF @5c_heape_action = 'CI_SWAP_ONLINE' AND @5c_heape_cmd LIKE '%DATA_COMPRESSION = PAGE%'
    RAISERROR(N'  PASS 5C-1: HeapE CI swap command includes DATA_COMPRESSION = PAGE.', 10, 1) WITH NOWAIT;
ELSE IF @5c_heape_action <> 'CI_SWAP_ONLINE'
BEGIN
    DECLARE @5c1_skip nvarchar(200) = N'  SKIP 5C-1: HeapE action = ' + ISNULL(@5c_heape_action, 'NULL') + N' (not CI swap; Standard Edition?).';
    RAISERROR(@5c1_skip, 10, 1) WITH NOWAIT;
END
ELSE
    RAISERROR(N'  *** FAIL 5C-1: HeapE CI_SWAP_ONLINE command missing DATA_COMPRESSION = PAGE.', 10, 1) WITH NOWAIT;

-- 5C-2: HeapA command should NOT include DATA_COMPRESSION (uncompressed)
DECLARE @5c_heapa_cmd nvarchar(max) = (SELECT command_text FROM #Results WHERE table_name = 'HeapA');
IF @5c_heapa_cmd NOT LIKE '%DATA_COMPRESSION%'
    RAISERROR(N'  PASS 5C-2: HeapA command does not include DATA_COMPRESSION (correct, uncompressed).', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 5C-2: HeapA command has DATA_COMPRESSION but heap is uncompressed.', 10, 1) WITH NOWAIT;

-- 5C-3: HeapF rebuild command should include DATA_COMPRESSION = ROW
DECLARE @5c_heapf_cmd nvarchar(max) = (SELECT command_text FROM #Results WHERE table_name = 'HeapF');
IF @5c_heapf_cmd LIKE '%DATA_COMPRESSION = ROW%'
    RAISERROR(N'  PASS 5C-3: HeapF rebuild command includes DATA_COMPRESSION = ROW.', 10, 1) WITH NOWAIT;
ELSE IF @5c_heapf_cmd IS NULL
    RAISERROR(N'  *** FAIL 5C-3: HeapF not found in results.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @5c3_msg nvarchar(200) = N'  *** FAIL 5C-3: HeapF command missing DATA_COMPRESSION = ROW. Command: ' + LEFT(ISNULL(@5c_heapf_cmd, ''), 150);
    RAISERROR(@5c3_msg, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 5D: Compression preserved after CI swap execution (6B)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- Re-create forwarded records in HeapE
TRUNCATE TABLE dbo.HeapE;
;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapE (ID, Code, Padding, MoreData)
SELECT TOP (20000) n, 'CODE-' + CAST(n AS varchar(10)), REPLICATE('E', 10), NULL FROM N;
UPDATE dbo.HeapE SET Padding = REPLICATE('X', 3000), MoreData = REPLICATE('Y', 3000) WHERE ID <= 15000;

TRUNCATE TABLE dbo.CommandLog;
GO

EXEC dbo.sp_HeapDoctor
    @CpuSource        = 'NONE',
    @AllowCiSwap      = 1,
    @PreferCiSwap     = 1,
    @OnlinePreference = 'AUTO',
    @MinPages         = 1000,
    @Databases        = 'HeapDoctorTest',
    @PlanOnly         = 0,
    @LogToTable       = N'Y';
GO

-- 5D-1: HeapE should still have PAGE compression after CI swap
DECLARE @5d_comp tinyint;
SELECT @5d_comp = MAX(data_compression)
FROM sys.partitions
WHERE object_id = OBJECT_ID('dbo.HeapE') AND index_id = 0;

IF @5d_comp = 2
    RAISERROR(N'  PASS 5D-1: HeapE still has PAGE compression after rebuild.', 10, 1) WITH NOWAIT;
ELSE IF @5d_comp = 0
    RAISERROR(N'  *** FAIL 5D-1: HeapE lost compression (now NONE). DATA_COMPRESSION not preserved.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @5d1_msg nvarchar(200) = N'  *** FAIL 5D-1: HeapE compression = ' + CAST(ISNULL(@5d_comp, -1) AS nvarchar(10)) + N', expected 2 (PAGE).';
    RAISERROR(@5d1_msg, 10, 1) WITH NOWAIT;
END

-- 5D-2: HeapE forwarded records should be 0
DECLARE @5d_fwd bigint;
SELECT @5d_fwd = forwarded_record_count
FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID('dbo.HeapE'), 0, NULL, 'SAMPLED')
WHERE index_id = 0;

IF ISNULL(@5d_fwd, 0) = 0
    RAISERROR(N'  PASS 5D-2: HeapE forwarded records = 0 after rebuild.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @5d2_msg nvarchar(200) = N'  *** FAIL 5D-2: HeapE still has ' + CAST(@5d_fwd AS nvarchar(20)) + N' forwarded records.';
    RAISERROR(@5d2_msg, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 5E: ROW compression preserved after rebuild (6B)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- Re-create forwarded records in HeapF
TRUNCATE TABLE dbo.HeapF;
;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapF (ID, Padding, MoreData)
SELECT TOP (20000) n, REPLICATE('F', 10), NULL FROM N;
UPDATE dbo.HeapF SET Padding = REPLICATE('X', 3000), MoreData = REPLICATE('Y', 3000) WHERE ID <= 15000;

TRUNCATE TABLE dbo.CommandLog;
GO

EXEC dbo.sp_HeapDoctor
    @CpuSource        = 'NONE',
    @OnlinePreference = 'AUTO',
    @MinPages         = 1000,
    @Databases        = 'HeapDoctorTest',
    @PlanOnly         = 0,
    @LogToTable       = N'Y';
GO

-- 5E-1: HeapF should still have ROW compression after rebuild
DECLARE @5e_comp tinyint;
SELECT @5e_comp = MAX(data_compression)
FROM sys.partitions
WHERE object_id = OBJECT_ID('dbo.HeapF') AND index_id = 0;

IF @5e_comp = 1
    RAISERROR(N'  PASS 5E-1: HeapF still has ROW compression after rebuild.', 10, 1) WITH NOWAIT;
ELSE IF @5e_comp = 0
    RAISERROR(N'  *** FAIL 5E-1: HeapF lost compression (now NONE). DATA_COMPRESSION not preserved.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @5e1_msg nvarchar(200) = N'  *** FAIL 5E-1: HeapF compression = ' + CAST(ISNULL(@5e_comp, -1) AS nvarchar(10)) + N', expected 1 (ROW).';
    RAISERROR(@5e1_msg, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 5F: RETURN code on failure (6F)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- When @PlanOnly = 1, proc should always return 0 (no execution, no failure)
DECLARE @5f_rc_planonly int;
EXEC @5f_rc_planonly = dbo.sp_HeapDoctor @CpuSource = 'NONE', @PlanOnly = 1;

IF @5f_rc_planonly = 0
    RAISERROR(N'  PASS 5F-1: RETURN = 0 for @PlanOnly = 1 (no execution).', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @5f1_msg nvarchar(200) = N'  *** FAIL 5F-1: RETURN = ' + CAST(@5f_rc_planonly AS nvarchar(10)) + N' for @PlanOnly = 1, expected 0.';
    RAISERROR(@5f1_msg, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
-- Recreate forwarded records for version check (prior tests may have rebuilt all heaps)
------------------------------------------------------------------------
TRUNCATE TABLE dbo.HeapA;
;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapA (ID, Padding, MoreData)
SELECT TOP (20000) n, REPLICATE('A', 10), NULL FROM N;
UPDATE dbo.HeapA SET Padding = REPLICATE('X', 3000), MoreData = REPLICATE('Y', 3000) WHERE ID <= 15000;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 5G: Version updated (Batch 6)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

IF OBJECT_ID('tempdb..#VerCheck') IS NOT NULL DROP TABLE #VerCheck;
CREATE TABLE #VerCheck
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

INSERT #VerCheck
EXEC dbo.sp_HeapDoctor @CpuSource = 'NONE', @MinPages = 1, @PlanOnly = 1;

DECLARE @5g_ver nvarchar(20) = (SELECT TOP 1 version FROM #VerCheck);
IF @5g_ver LIKE N'1.%.2026.%'
    RAISERROR(N'  PASS 5G-1: Version matches 1.x.2026.x.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @5g_msg nvarchar(200) = N'  *** FAIL 5G-1: Version = ' + ISNULL(@5g_ver, 'NULL') + N', expected 1.x.2026.x.';
    RAISERROR(@5g_msg, 10, 1) WITH NOWAIT;
END

IF OBJECT_ID('tempdb..#VerCheck') IS NOT NULL DROP TABLE #VerCheck;
GO

------------------------------------------------------------------------
-- Cleanup
------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'Batch 6 tests complete. Review PASS/FAIL results above.', 10, 1) WITH NOWAIT;
GO
