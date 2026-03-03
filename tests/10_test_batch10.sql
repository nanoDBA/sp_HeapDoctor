/*
sp_HeapDoctor Test Harness - Batch 10: Obfuscation/Reveal

Tests Batch 10 additions:
  10A - @RevealKey without @RevealRunID (error)
  10B - @RevealKey + @ObfuscateKey together (error)
  10C - @ObfuscateSeed without @ObfuscateKey (warning, no error)
  10D - Plan-only with @ObfuscateKey: pseudonyms in result set
  10E - Deterministic pseudonyms (same key+seed = same result)
  10F - Different seed = different pseudonyms
  10G - Real names absent from command_text when obfuscated
  10H - Execute with @ObfuscateKey: CommandLog uses pseudonyms
  10I - Reveal mode returns correct mapping
  10J - Reveal with wrong key (decryption failure)
  10K - Reveal with nonexistent RunID (error)
  10L - Plan-only obfuscation stores mapping in HEAP_SCAN_SUMMARY
  10M - Reveal from plan-only HEAP_SCAN_SUMMARY
  10N - Plan-only with @LogToTable='N' does not store mapping

Prerequisites: Run 01_setup_test_data.sql first.
Run with: sqlcmd -S YourServer -d HeapDoctorTest -i 10_test_batch10.sql
  (add -E for Windows auth, -U/-P for SQL auth, or -G for Azure AD)
*/

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE [HeapDoctorTest];
GO

------------------------------------------------------------------------
-- Reusable capture table
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

IF OBJECT_ID('tempdb..#TestCounts') IS NOT NULL DROP TABLE #TestCounts;
CREATE TABLE #TestCounts (PassCount int NOT NULL DEFAULT 0, FailCount int NOT NULL DEFAULT 0);
INSERT #TestCounts DEFAULT VALUES;
GO

------------------------------------------------------------------------
-- Ensure forwarded records exist (rebuild if prior tests cleared them)
------------------------------------------------------------------------
RAISERROR(N'Checking forwarded records in test heaps...', 10, 1) WITH NOWAIT;

-- Only recreate if HeapA was rebuilt (no forwarded records)
IF NOT EXISTS (
    SELECT 1 FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID('dbo.HeapA'), 0, NULL, 'LIMITED')
    WHERE forwarded_record_count > 0
)
BEGIN
    RAISERROR(N'Recreating forwarded records (tables were rebuilt by prior tests)...', 10, 1) WITH NOWAIT;

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
END
ELSE
BEGIN
    RAISERROR(N'Forwarded records already present, skipping recreation.', 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 10A: @RevealKey without @RevealRunID (error)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
DECLARE @caught_10A bit = 0;
BEGIN TRY
    EXEC dbo.sp_HeapDoctor @RevealKey = N'TestKey123';
END TRY
BEGIN CATCH
    SET @caught_10A = 1;
END CATCH

IF @caught_10A = 1
BEGIN
    RAISERROR(N'  PASS: 10A - @RevealKey without @RevealRunID raised error.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL: 10A - @RevealKey without @RevealRunID did not raise error.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 10B: @RevealKey + @ObfuscateKey together (error)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
DECLARE @caught_10B bit = 0;
DECLARE @temp_runid_10B uniqueidentifier = NEWID();
BEGIN TRY
    EXEC dbo.sp_HeapDoctor @RevealKey = N'Key1', @ObfuscateKey = N'Key1', @RevealRunID = @temp_runid_10B;
END TRY
BEGIN CATCH
    SET @caught_10B = 1;
END CATCH

IF @caught_10B = 1
BEGIN
    RAISERROR(N'  PASS: 10B - @RevealKey + @ObfuscateKey together raised error.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL: 10B - @RevealKey + @ObfuscateKey together did not raise error.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 10C: @ObfuscateSeed without @ObfuscateKey (no error)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
DECLARE @caught_10C bit = 0;
BEGIN TRY
    TRUNCATE TABLE #Results;
    INSERT #Results
    EXEC dbo.sp_HeapDoctor
        @Databases = N'HeapDoctorTest',
        @CpuSource = 'NONE',
        @ObfuscateSeed = N'MySeed',
        @PlanOnly = 1;
END TRY
BEGIN CATCH
    SET @caught_10C = 1;
END CATCH

IF @caught_10C = 0
BEGIN
    RAISERROR(N'  PASS: 10C - @ObfuscateSeed without @ObfuscateKey succeeded (warning only).', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL: 10C - @ObfuscateSeed without @ObfuscateKey raised error.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 10D: Plan-only with @ObfuscateKey: pseudonyms', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = 'NONE',
    @ObfuscateKey = N'TestKey123',
    @PlanOnly = 1;

-- All database_name should start with DB_, schema_name with S_, table_name with T_
IF (SELECT COUNT(*) FROM #Results) > 0
   AND NOT EXISTS (SELECT 1 FROM #Results WHERE database_name NOT LIKE 'DB[_]%')
   AND NOT EXISTS (SELECT 1 FROM #Results WHERE schema_name NOT LIKE 'S[_]%')
   AND NOT EXISTS (SELECT 1 FROM #Results WHERE table_name NOT LIKE 'T[_]%')
BEGIN
    RAISERROR(N'  PASS: 10D - All names pseudonymized with correct prefixes (DB_/S_/T_).', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL: 10D - Names not properly pseudonymized.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 10E: Deterministic pseudonyms (same key+seed)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = 'NONE',
    @ObfuscateKey = N'Key1',
    @ObfuscateSeed = N'Seed1',
    @PlanOnly = 1;

DECLARE @pseudo1 sysname = (SELECT TOP 1 table_name FROM #Results ORDER BY target_id);

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = 'NONE',
    @ObfuscateKey = N'Key1',
    @ObfuscateSeed = N'Seed1',
    @PlanOnly = 1;

DECLARE @pseudo2 sysname = (SELECT TOP 1 table_name FROM #Results ORDER BY target_id);

IF @pseudo1 = @pseudo2 AND @pseudo1 IS NOT NULL
BEGIN
    RAISERROR(N'  PASS: 10E - Same key+seed produces same pseudonyms.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL: 10E - Pseudonyms not deterministic.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 10F: Different seed = different pseudonyms', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = 'NONE',
    @ObfuscateKey = N'Key1',
    @ObfuscateSeed = N'SeedA',
    @PlanOnly = 1;

DECLARE @pseudoA sysname = (SELECT TOP 1 table_name FROM #Results ORDER BY target_id);

TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = 'NONE',
    @ObfuscateKey = N'Key1',
    @ObfuscateSeed = N'SeedB',
    @PlanOnly = 1;

DECLARE @pseudoB sysname = (SELECT TOP 1 table_name FROM #Results ORDER BY target_id);

IF @pseudoA <> @pseudoB AND @pseudoA IS NOT NULL AND @pseudoB IS NOT NULL
BEGIN
    RAISERROR(N'  PASS: 10F - Different seeds produce different pseudonyms.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL: 10F - Different seeds produced same pseudonyms.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 10G: Real names absent from command_text', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
TRUNCATE TABLE #Results;
INSERT #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = 'NONE',
    @ObfuscateKey = N'TestKey123',
    @ObfuscateSeed = N'Seed1',
    @PlanOnly = 1;

-- Real database name, table names should NOT appear in command_text
IF NOT EXISTS (SELECT 1 FROM #Results WHERE command_text LIKE '%HeapDoctorTest%')
   AND NOT EXISTS (SELECT 1 FROM #Results WHERE command_text LIKE '%HeapA%')
   AND NOT EXISTS (SELECT 1 FROM #Results WHERE command_text LIKE '%HeapB%')
   AND NOT EXISTS (SELECT 1 FROM #Results WHERE command_text LIKE '%HeapC%')
   AND NOT EXISTS (SELECT 1 FROM #Results WHERE database_name LIKE '%HeapDoctorTest%')
   AND (SELECT COUNT(*) FROM #Results) > 0
BEGIN
    RAISERROR(N'  PASS: 10G - Real names absent from obfuscated result set.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL: 10G - Real names found in obfuscated result set.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 10H: Execute with obfuscation: CommandLog pseudonyms', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
DECLARE @max_cmd_10H int;
SELECT @max_cmd_10H = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;

EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = 'NONE',
    @ObfuscateKey = N'TestKey123',
    @TopN = 1,
    @PlanOnly = 0;

-- Per-rebuild CommandLog entries should NOT contain real names
IF NOT EXISTS (
    SELECT 1 FROM dbo.CommandLog
    WHERE ID > @max_cmd_10H
      AND CommandType NOT IN ('HEAP_REBUILD_START', 'HEAP_REBUILD_END')
      AND (DatabaseName LIKE '%HeapDoctorTest%'
           OR ObjectName LIKE '%HeapA%'
           OR ObjectName LIKE '%HeapB%'
           OR ObjectName LIKE '%HeapC%')
)
AND EXISTS (
    SELECT 1 FROM dbo.CommandLog
    WHERE ID > @max_cmd_10H
      AND CommandType NOT IN ('HEAP_REBUILD_START', 'HEAP_REBUILD_END')
)
BEGIN
    RAISERROR(N'  PASS: 10H - CommandLog per-rebuild entries use pseudonyms.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL: 10H - CommandLog contains real names or no entries found.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END

-- Also verify ObfuscatedMappingHex exists in START entry
IF EXISTS (
    SELECT 1 FROM dbo.CommandLog
    WHERE ID > @max_cmd_10H
      AND CommandType = 'HEAP_REBUILD_START'
      AND CAST(ExtendedInfo AS nvarchar(max)) LIKE '%ObfuscatedMappingHex%'
)
BEGIN
    RAISERROR(N'  PASS: 10H2 - ObfuscatedMappingHex found in START ExtendedInfo.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL: 10H2 - ObfuscatedMappingHex not found in START ExtendedInfo.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 10I: Reveal mode returns correct mapping', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
/*
Find the RunID from the most recent obfuscated START entry (from test 10H),
then call reveal mode and verify it returns the real names.
*/
DECLARE @run_id_10I uniqueidentifier;
SELECT TOP (1) @run_id_10I = CAST(
    ExtendedInfo.value(N'(/Parameters/RunID)[1]', N'nvarchar(36)')
    AS uniqueidentifier)
FROM dbo.CommandLog
WHERE CommandType = N'HEAP_REBUILD_START'
  AND CAST(ExtendedInfo AS nvarchar(max)) LIKE N'%ObfuscatedMappingHex%'
ORDER BY ID DESC;

IF @run_id_10I IS NOT NULL
BEGIN
    -- Capture reveal output
    IF OBJECT_ID('tempdb..#RevealMap') IS NOT NULL DROP TABLE #RevealMap;
    CREATE TABLE #RevealMap (pseudonym nvarchar(20), object_type varchar(10), real_name sysname);

    INSERT #RevealMap
    EXEC dbo.sp_HeapDoctor @RevealKey = N'TestKey123', @RevealRunID = @run_id_10I;

    -- Verify: HeapDoctorTest should appear as a DB entry
    IF EXISTS (SELECT 1 FROM #RevealMap WHERE object_type = 'DB' AND real_name = N'HeapDoctorTest')
       AND EXISTS (SELECT 1 FROM #RevealMap WHERE object_type = 'Schema')
       AND EXISTS (SELECT 1 FROM #RevealMap WHERE object_type = 'Table')
    BEGIN
        RAISERROR(N'  PASS: 10I - Reveal mode returned correct mapping with real names.', 10, 1) WITH NOWAIT;
        UPDATE #TestCounts SET PassCount += 1;
    END
    ELSE
    BEGIN
        RAISERROR(N'  FAIL: 10I - Reveal mode mapping incomplete or incorrect.', 10, 1) WITH NOWAIT;
        UPDATE #TestCounts SET FailCount += 1;
    END

    DROP TABLE #RevealMap;
END
ELSE
BEGIN
    RAISERROR(N'  SKIP: 10I - No obfuscated RunID found (10H may have failed).', 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 10J: Reveal with wrong key (decryption failure)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
DECLARE @run_id_10J uniqueidentifier;
SELECT TOP (1) @run_id_10J = CAST(
    ExtendedInfo.value(N'(/Parameters/RunID)[1]', N'nvarchar(36)')
    AS uniqueidentifier)
FROM dbo.CommandLog
WHERE CommandType = N'HEAP_REBUILD_START'
  AND CAST(ExtendedInfo AS nvarchar(max)) LIKE N'%ObfuscatedMappingHex%'
ORDER BY ID DESC;

DECLARE @caught_10J bit = 0;
IF @run_id_10J IS NOT NULL
BEGIN
    BEGIN TRY
        EXEC dbo.sp_HeapDoctor @RevealKey = N'WrongKey999', @RevealRunID = @run_id_10J;
    END TRY
    BEGIN CATCH
        SET @caught_10J = 1;
    END CATCH

    IF @caught_10J = 1
    BEGIN
        RAISERROR(N'  PASS: 10J - Reveal with wrong key raised error.', 10, 1) WITH NOWAIT;
        UPDATE #TestCounts SET PassCount += 1;
    END
    ELSE
    BEGIN
        RAISERROR(N'  FAIL: 10J - Reveal with wrong key did not raise error.', 10, 1) WITH NOWAIT;
        UPDATE #TestCounts SET FailCount += 1;
    END
END
ELSE
BEGIN
    RAISERROR(N'  SKIP: 10J - No obfuscated RunID found.', 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 10K: Reveal with nonexistent RunID (error)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
DECLARE @caught_10K bit = 0;
BEGIN TRY
    EXEC dbo.sp_HeapDoctor @RevealKey = N'TestKey123', @RevealRunID = 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE';
END TRY
BEGIN CATCH
    SET @caught_10K = 1;
END CATCH

IF @caught_10K = 1
BEGIN
    RAISERROR(N'  PASS: 10K - Reveal with nonexistent RunID raised error.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL: 10K - Reveal with nonexistent RunID did not raise error.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 10L: Plan-only obfuscation stores mapping in HEAP_SCAN_SUMMARY', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
/*
Run plan-only with @ObfuscateKey and @LogToTable='Y'.
Verify HEAP_SCAN_SUMMARY ExtendedInfo contains ObfuscatedMappingHex.
*/
DECLARE @max_cmd_10L int;
SELECT @max_cmd_10L = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;

EXEC dbo.sp_HeapDoctor
    @Databases = 'HeapDoctorTest',
    @CpuSource = 'NONE',
    @ObfuscateKey = N'TestKey10L',
    @ObfuscateSeed = N'PlanOnlySeed',
    @PlanOnly = 1,
    @LogToTable = 'Y';

-- Check HEAP_SCAN_SUMMARY has ObfuscatedMappingHex
IF EXISTS (
    SELECT 1 FROM dbo.CommandLog
    WHERE ID > @max_cmd_10L
      AND CommandType = N'HEAP_SCAN_SUMMARY'
      AND CAST(ExtendedInfo AS nvarchar(max)) LIKE '%ObfuscatedMappingHex%'
)
BEGIN
    RAISERROR(N'  PASS: 10L - HEAP_SCAN_SUMMARY contains ObfuscatedMappingHex.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL: 10L - HEAP_SCAN_SUMMARY missing ObfuscatedMappingHex.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END

-- Also check ObfuscateSeed is present
IF EXISTS (
    SELECT 1 FROM dbo.CommandLog
    WHERE ID > @max_cmd_10L
      AND CommandType = N'HEAP_SCAN_SUMMARY'
      AND CAST(ExtendedInfo AS nvarchar(max)) LIKE '%<ObfuscateSeed>PlanOnlySeed</ObfuscateSeed>%'
)
BEGIN
    RAISERROR(N'  PASS: 10L2 - HEAP_SCAN_SUMMARY contains ObfuscateSeed.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL: 10L2 - HEAP_SCAN_SUMMARY missing ObfuscateSeed.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 10M: Reveal from plan-only HEAP_SCAN_SUMMARY', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
/*
Extract RunID from the HEAP_SCAN_SUMMARY created by 10L, then reveal using it.
Verify the reveal result set contains correct real names.
*/
DECLARE @scan_xml_10M xml;
SELECT TOP (1) @scan_xml_10M = ExtendedInfo
FROM dbo.CommandLog
WHERE CommandType = N'HEAP_SCAN_SUMMARY'
  AND CAST(ExtendedInfo AS nvarchar(max)) LIKE '%ObfuscatedMappingHex%'
ORDER BY ID DESC;

IF @scan_xml_10M IS NOT NULL
BEGIN
    DECLARE @runid_10M uniqueidentifier;
    SET @runid_10M = @scan_xml_10M.value(N'(/ScanSummary/RunID)[1]', N'uniqueidentifier');

    IF @runid_10M IS NOT NULL
    BEGIN
        -- Capture reveal output
        IF OBJECT_ID('tempdb..#Reveal10M') IS NOT NULL DROP TABLE #Reveal10M;
        CREATE TABLE #Reveal10M (pseudonym nvarchar(20), object_type varchar(10), real_name sysname);

        INSERT #Reveal10M
        EXEC dbo.sp_HeapDoctor @RevealKey = N'TestKey10L', @RevealRunID = @runid_10M;

        -- Verify HeapDoctorTest appears as a DB mapping
        IF EXISTS (SELECT 1 FROM #Reveal10M WHERE object_type = 'DB' AND real_name = N'HeapDoctorTest')
        BEGIN
            RAISERROR(N'  PASS: 10M - Reveal from HEAP_SCAN_SUMMARY returned correct DB mapping.', 10, 1) WITH NOWAIT;
            UPDATE #TestCounts SET PassCount += 1;
        END
        ELSE
        BEGIN
            RAISERROR(N'  FAIL: 10M - Reveal from HEAP_SCAN_SUMMARY did not return HeapDoctorTest mapping.', 10, 1) WITH NOWAIT;
            UPDATE #TestCounts SET FailCount += 1;
        END

        -- Verify at least one table mapping exists
        IF EXISTS (SELECT 1 FROM #Reveal10M WHERE object_type = 'Table')
        BEGIN
            RAISERROR(N'  PASS: 10M2 - Reveal contains Table mappings.', 10, 1) WITH NOWAIT;
            UPDATE #TestCounts SET PassCount += 1;
        END
        ELSE
        BEGIN
            RAISERROR(N'  FAIL: 10M2 - Reveal missing Table mappings.', 10, 1) WITH NOWAIT;
            UPDATE #TestCounts SET FailCount += 1;
        END

        DROP TABLE #Reveal10M;
    END
    ELSE
    BEGIN
        RAISERROR(N'  SKIP: 10M - Could not extract RunID from HEAP_SCAN_SUMMARY.', 10, 1) WITH NOWAIT;
    END
END
ELSE
BEGIN
    RAISERROR(N'  SKIP: 10M - No HEAP_SCAN_SUMMARY with mapping found (10L may have failed).', 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 10N: Plan-only with @LogToTable=N does not store mapping', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
DECLARE @max_cmd_10N int;
SELECT @max_cmd_10N = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;

EXEC dbo.sp_HeapDoctor
    @Databases = 'HeapDoctorTest',
    @CpuSource = 'NONE',
    @ObfuscateKey = N'TestKey10N',
    @PlanOnly = 1,
    @LogToTable = 'N';

-- No new CommandLog entries should exist
IF NOT EXISTS (SELECT 1 FROM dbo.CommandLog WHERE ID > @max_cmd_10N)
BEGIN
    RAISERROR(N'  PASS: 10N - No CommandLog entries when @LogToTable=N.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL: 10N - Unexpected CommandLog entries with @LogToTable=N.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
-- Summary
------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

DECLARE @PassCount int, @FailCount int;
SELECT @PassCount = PassCount, @FailCount = FailCount FROM #TestCounts;

DECLARE @summary nvarchar(200);
SET @summary = N' Batch 10 Tests Complete -- PASSED: ' + CAST(@PassCount AS nvarchar(10))
             + N'  FAILED: ' + CAST(@FailCount AS nvarchar(10));
RAISERROR(@summary, 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

IF @FailCount > 0
    RAISERROR(N'THERE WERE FAILURES. Review output above.', 16, 1);
GO
