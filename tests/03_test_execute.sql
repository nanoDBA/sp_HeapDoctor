/*
sp_HeapDoctor Test Harness - Step 3: Execution Tests

Tests @PlanOnly = 0 - actually executes rebuilds.
Verifies forwarded records are eliminated, CommandLog is populated, time limits work.

Prerequisites: Run 01_setup_test_data.sql first (this script re-creates forwarded records as needed).
Run with: sqlcmd -S YourServer -d HeapDoctorTest -i 03_test_execute.sql
  (add -E for Windows auth, -U/-P for SQL auth, or -G for Azure AD)

WARNING: This script modifies tables. It re-creates forwarded records between tests.

NOTE: INSERT...EXEC nesting limitation
  Tests that capture sp_HeapDoctor output via INSERT...EXEC cannot use
  @CpuSource = 'QUICKIESTORE', because sp_HeapDoctor internally uses
  INSERT...EXEC for the QuickieStore path, and SQL Server does not allow
  nested INSERT...EXEC.  See 02_test_planonly.sql header for details.
*/

SET NOCOUNT ON;
USE [HeapDoctorTest];
GO

------------------------------------------------------------------------
-- Helper: Re-create forwarded records (run between tests)
------------------------------------------------------------------------
RAISERROR(N'Re-creating forwarded records in test heaps...', 10, 1) WITH NOWAIT;

-- HeapA: truncate and re-populate
TRUNCATE TABLE dbo.HeapA;

;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapA (ID, Padding, MoreData)
SELECT TOP (20000) n, REPLICATE('A', 10), NULL FROM N;

UPDATE dbo.HeapA
SET Padding = REPLICATE('X', 3000), MoreData = REPLICATE('Y', 3000)
WHERE ID <= 15000;

-- HeapB: truncate and re-populate
TRUNCATE TABLE dbo.HeapB;

;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapB (ID, Code, Padding, MoreData)
SELECT TOP (20000) n, 'CODE-' + CAST(n AS varchar(10)), REPLICATE('B', 10), NULL FROM N;

UPDATE dbo.HeapB
SET Padding = REPLICATE('X', 3000), MoreData = REPLICATE('Y', 3000)
WHERE ID <= 15000;

-- HeapC: truncate and re-populate
TRUNCATE TABLE dbo.HeapC;

;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapC (ID, Padding, BigData)
SELECT TOP (20000) n, REPLICATE('C', 10), NULL FROM N;

UPDATE dbo.HeapC
SET Padding = REPLICATE('X', 3000), BigData = REPLICATE(CAST('Z' AS varchar(max)), 500)
WHERE ID <= 15000;

-- Run queries to refresh QS
DECLARE @sink int;
DECLARE @iter int = 1;
WHILE @iter <= 10
BEGIN
    SELECT @sink = COUNT(*) FROM dbo.HeapA WHERE Padding LIKE '%X%';
    SELECT @sink = COUNT(*) FROM dbo.HeapB WHERE Padding LIKE '%X%';
    SELECT @sink = COUNT(*) FROM dbo.HeapC WHERE Padding LIKE '%X%';
    SET @iter += 1;
END
EXEC sys.sp_query_store_flush_db;
GO

-- Clear previous CommandLog entries
TRUNCATE TABLE dbo.CommandLog;
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 3A: Execute heap rebuild (online)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

EXEC dbo.sp_HeapDoctor
    @CpuSource        = 'NONE',
    @OnlinePreference = 'AUTO',
    @PlanOnly         = 0,
    @LogToTable       = N'Y';
GO

-- 3A-1: Forwarded records should be 0 after rebuild
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'Checking forwarded records after rebuild...', 10, 1) WITH NOWAIT;

DECLARE @3a_fwd_total bigint;
SELECT @3a_fwd_total = SUM(ips.forwarded_record_count)
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'SAMPLED') ips
JOIN sys.objects t ON ips.object_id = t.object_id
WHERE ips.index_id = 0
  AND t.type = 'U'
  AND t.name IN ('HeapA', 'HeapB', 'HeapC');

IF ISNULL(@3a_fwd_total, 0) = 0
    RAISERROR(N'  PASS 3A-1: All forwarded records eliminated after rebuild.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @3a_msg nvarchar(200) = N'  *** FAIL 3A-1: ' + CAST(@3a_fwd_total AS nvarchar(20)) + N' forwarded records remain.';
    RAISERROR(@3a_msg, 10, 1) WITH NOWAIT;
END

-- 3A-2: CommandLog should have HEAP_REBUILD_START entry
IF EXISTS (SELECT 1 FROM dbo.CommandLog WHERE CommandType = 'HEAP_REBUILD_START')
    RAISERROR(N'  PASS 3A-2: HEAP_REBUILD_START entry found in CommandLog.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 3A-2: Missing HEAP_REBUILD_START entry in CommandLog.', 10, 1) WITH NOWAIT;

-- 3A-3: CommandLog should have HEAP_REBUILD_END entry
IF EXISTS (SELECT 1 FROM dbo.CommandLog WHERE CommandType = 'HEAP_REBUILD_END')
    RAISERROR(N'  PASS 3A-3: HEAP_REBUILD_END entry found in CommandLog.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 3A-3: Missing HEAP_REBUILD_END entry in CommandLog.', 10, 1) WITH NOWAIT;

-- 3A-4: Per-rebuild entries should exist (one per target)
DECLARE @3a_rebuild_count int = (
    SELECT COUNT(*)
    FROM dbo.CommandLog
    WHERE CommandType NOT IN ('HEAP_REBUILD_START', 'HEAP_REBUILD_END')
);
IF @3a_rebuild_count >= 3
BEGIN
    DECLARE @3a_msg2 nvarchar(200) = N'  PASS 3A-4: ' + CAST(@3a_rebuild_count AS nvarchar(10)) + N' per-rebuild CommandLog entries found.';
    RAISERROR(@3a_msg2, 10, 1) WITH NOWAIT;
END
ELSE
BEGIN
    DECLARE @3a_msg3 nvarchar(200) = N'  *** FAIL 3A-4: Expected >= 3 per-rebuild entries, found ' + CAST(@3a_rebuild_count AS nvarchar(10));
    RAISERROR(@3a_msg3, 10, 1) WITH NOWAIT;
END

-- 3A-5: All CommandLog entries should have ErrorNumber = 0
DECLARE @3a_err_count int = (SELECT COUNT(*) FROM dbo.CommandLog WHERE ISNULL(ErrorNumber, 0) <> 0);
IF @3a_err_count = 0
    RAISERROR(N'  PASS 3A-5: All CommandLog entries have ErrorNumber = 0.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @3a_msg4 nvarchar(200) = N'  *** FAIL 3A-5: ' + CAST(@3a_err_count AS nvarchar(10)) + N' CommandLog entries have non-zero ErrorNumber.';
    RAISERROR(@3a_msg4, 10, 1) WITH NOWAIT;
END

-- 3A-6: Per-rebuild ExtendedInfo should have PostRebuildForwardedRecords element
DECLARE @3a_post_count int = (
    SELECT COUNT(*)
    FROM dbo.CommandLog
    WHERE CommandType NOT IN ('HEAP_REBUILD_START', 'HEAP_REBUILD_END')
      AND ExtendedInfo IS NOT NULL
      AND CAST(ExtendedInfo AS nvarchar(max)) LIKE '%PostRebuildForwardedRecords%'
);
IF @3a_post_count >= 3
    RAISERROR(N'  PASS 3A-6: PostRebuildForwardedRecords found in ExtendedInfo XML.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @3a_msg5 nvarchar(200) = N'  *** FAIL 3A-6: Expected >= 3 entries with PostRebuildForwardedRecords, found ' + CAST(@3a_post_count AS nvarchar(10));
    RAISERROR(@3a_msg5, 10, 1) WITH NOWAIT;
END

-- 3A-7: SizeMB in ExtendedInfo should be > 0 (not truncated to 0 by integer division)
DECLARE @3a_size_zero int = (
    SELECT COUNT(*)
    FROM dbo.CommandLog
    WHERE CommandType NOT IN ('HEAP_REBUILD_START', 'HEAP_REBUILD_END')
      AND ExtendedInfo IS NOT NULL
      AND ExtendedInfo.value('(/ExtendedInfo/SizeMB)[1]', 'decimal(18,2)') = 0
);
IF @3a_size_zero = 0
    RAISERROR(N'  PASS 3A-7: All ExtendedInfo SizeMB values are > 0 (no integer truncation).', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @3a_msg6 nvarchar(200) = N'  *** FAIL 3A-7: ' + CAST(@3a_size_zero AS nvarchar(10)) + N' entries have SizeMB = 0 (integer division bug).';
    RAISERROR(@3a_msg6, 10, 1) WITH NOWAIT;
END

-- 3A-8: HEAP_REBUILD_END ExtendedInfo should have Summary with StopReason
DECLARE @3a_stop_reason nvarchar(100);
SELECT @3a_stop_reason = ExtendedInfo.value('(/Summary/StopReason)[1]', 'nvarchar(100)')
FROM dbo.CommandLog
WHERE CommandType = 'HEAP_REBUILD_END';

IF @3a_stop_reason = 'SUCCESS'
    RAISERROR(N'  PASS 3A-8: HEAP_REBUILD_END StopReason = SUCCESS.', 10, 1) WITH NOWAIT;
ELSE IF @3a_stop_reason IS NOT NULL
BEGIN
    DECLARE @3a_msg7 nvarchar(200) = N'  INFO 3A-8: HEAP_REBUILD_END StopReason = ' + @3a_stop_reason + N' (may be expected).';
    RAISERROR(@3a_msg7, 10, 1) WITH NOWAIT;
END
ELSE
    RAISERROR(N'  *** FAIL 3A-8: HEAP_REBUILD_END missing or no StopReason in ExtendedInfo.', 10, 1) WITH NOWAIT;

-- 3A-9: Per-rebuild entries should have DatabaseName, SchemaName, ObjectName populated
DECLARE @3a_missing_names int = (
    SELECT COUNT(*)
    FROM dbo.CommandLog
    WHERE CommandType NOT IN ('HEAP_REBUILD_START', 'HEAP_REBUILD_END')
      AND (DatabaseName IS NULL OR SchemaName IS NULL OR ObjectName IS NULL)
);
IF @3a_missing_names = 0
    RAISERROR(N'  PASS 3A-9: All rebuild entries have DatabaseName, SchemaName, ObjectName populated.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @3a_msg8 nvarchar(200) = N'  *** FAIL 3A-9: ' + CAST(@3a_missing_names AS nvarchar(10)) + N' entries missing name columns.';
    RAISERROR(@3a_msg8, 10, 1) WITH NOWAIT;
END

-- 3A-10: CommandLog entries should be in chronological order
DECLARE @3a_order_bad int = (
    SELECT COUNT(*)
    FROM dbo.CommandLog cl1
    INNER JOIN dbo.CommandLog cl2
        ON cl1.ID < cl2.ID
       AND cl1.StartTime > cl2.StartTime
    WHERE cl1.CommandType NOT IN ('HEAP_REBUILD_START', 'HEAP_REBUILD_END')
      AND cl2.CommandType NOT IN ('HEAP_REBUILD_START', 'HEAP_REBUILD_END')
);
IF @3a_order_bad = 0
    RAISERROR(N'  PASS 3A-10: CommandLog entries in chronological order.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @3a_msg9 nvarchar(200) = N'  *** FAIL 3A-10: ' + CAST(@3a_order_bad AS nvarchar(10)) + N' entry pairs out of chronological order.';
    RAISERROR(@3a_msg9, 10, 1) WITH NOWAIT;
END

-- 3A-11: Per-rebuild Command should contain actual SQL (ALTER TABLE or CREATE CLUSTERED INDEX)
DECLARE @3a_bad_cmds int = (
    SELECT COUNT(*)
    FROM dbo.CommandLog
    WHERE CommandType NOT IN ('HEAP_REBUILD_START', 'HEAP_REBUILD_END')
      AND Command NOT LIKE 'ALTER TABLE%'
      AND Command NOT LIKE 'CREATE CLUSTERED INDEX%'
);
IF @3a_bad_cmds = 0
    RAISERROR(N'  PASS 3A-11: All rebuild commands are ALTER TABLE or CREATE CLUSTERED INDEX.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @3a_msg10 nvarchar(200) = N'  *** FAIL 3A-11: ' + CAST(@3a_bad_cmds AS nvarchar(10)) + N' commands have unexpected syntax.';
    RAISERROR(@3a_msg10, 10, 1) WITH NOWAIT;
END

-- Display CommandLog for manual review
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'CommandLog entries (manual review):', 10, 1) WITH NOWAIT;

SELECT
    ID, CommandType, DatabaseName, ObjectName, StartTime, EndTime,
    ErrorNumber, ErrorMessage, ExtendedInfo
FROM dbo.CommandLog
ORDER BY ID;
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 3B: Execute CI swap', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- Re-create forwarded records in HeapB only (it has the unique NC index)
TRUNCATE TABLE dbo.HeapB;

;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapB (ID, Code, Padding, MoreData)
SELECT TOP (20000) n, 'CODE-' + CAST(n AS varchar(10)), REPLICATE('B', 10), NULL FROM N;

UPDATE dbo.HeapB
SET Padding = REPLICATE('X', 3000), MoreData = REPLICATE('Y', 3000)
WHERE ID <= 15000;

-- Clear CommandLog
TRUNCATE TABLE dbo.CommandLog;
GO

EXEC dbo.sp_HeapDoctor
    @CpuSource        = 'NONE',
    @AllowCiSwap      = 1,
    @PreferCiSwap     = 1,
    @OnlinePreference = 'AUTO',
    @MinPages         = 1000,
    @PlanOnly         = 0,
    @LogToTable       = N'Y';
GO

-- 3B-1: HeapB should still be a heap (no clustered index left behind)
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'Checking HeapB is still a heap after CI swap...', 10, 1) WITH NOWAIT;

DECLARE @3b_idx_type int;
SELECT @3b_idx_type = i.type
FROM sys.indexes i
JOIN sys.objects t ON i.object_id = t.object_id
WHERE t.name = 'HeapB'
  AND i.index_id IN (0, 1);

IF @3b_idx_type = 0
    RAISERROR(N'  PASS 3B-1: HeapB is still a heap after CI swap.', 10, 1) WITH NOWAIT;
ELSE IF @3b_idx_type = 1
    RAISERROR(N'  *** FAIL 3B-1: Clustered index left behind on HeapB.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  INFO 3B-1: HeapB index type is unexpected. Check sys.indexes.', 10, 1) WITH NOWAIT;

-- 3B-2: Forwarded records eliminated
DECLARE @3b_fwd bigint;
SELECT @3b_fwd = ips.forwarded_record_count
FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID('dbo.HeapB'), NULL, NULL, 'SAMPLED') ips
WHERE ips.index_id = 0;

IF ISNULL(@3b_fwd, 0) = 0
    RAISERROR(N'  PASS 3B-2: HeapB forwarded records = 0.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @3b_msg nvarchar(200) = N'  *** FAIL 3B-2: HeapB still has ' + CAST(@3b_fwd AS nvarchar(20)) + N' forwarded records.';
    RAISERROR(@3b_msg, 10, 1) WITH NOWAIT;
END

-- 3B-3: UX_HeapB_ID nonclustered index should still exist
IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.HeapB') AND name = 'UX_HeapB_ID' AND type = 2)
    RAISERROR(N'  PASS 3B-3: UX_HeapB_ID nonclustered index still exists after CI swap.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 3B-3: UX_HeapB_ID is missing or changed type after CI swap.', 10, 1) WITH NOWAIT;

-- 3B-4: CommandLog should have CI_SWAP entries (on Enterprise/Developer)
DECLARE @3b_ci_count int = (SELECT COUNT(*) FROM dbo.CommandLog WHERE CommandType = 'CI_SWAP_ONLINE');
IF @3b_ci_count > 0
BEGIN
    DECLARE @3b_msg2 nvarchar(200) = N'  PASS 3B-4: CI_SWAP_ONLINE found in CommandLog (' + CAST(@3b_ci_count AS nvarchar(10)) + N' entries).';
    RAISERROR(@3b_msg2, 10, 1) WITH NOWAIT;
END
ELSE
BEGIN
    -- On Standard Edition, CI swap falls back to HEAP_REBUILD_OFFLINE
    DECLARE @3b_offline int = (SELECT COUNT(*) FROM dbo.CommandLog WHERE CommandType LIKE 'HEAP_REBUILD%' AND CommandType NOT IN ('HEAP_REBUILD_START','HEAP_REBUILD_END'));
    IF @3b_offline > 0
        RAISERROR(N'  PASS 3B-4: No CI_SWAP_ONLINE (Standard Edition?), but HEAP_REBUILD entries present.', 10, 1) WITH NOWAIT;
    ELSE
        RAISERROR(N'  *** FAIL 3B-4: No CI_SWAP or HEAP_REBUILD entries in CommandLog.', 10, 1) WITH NOWAIT;
END

-- CommandLog for manual review
SELECT ID, CommandType, ObjectName, Command, ErrorNumber
FROM dbo.CommandLog
ORDER BY ID;
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 3C: @MaxRunSeconds time limit', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- Re-create forwarded records in all heaps
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

TRUNCATE TABLE dbo.CommandLog;
GO

-- Use @MaxRunSeconds = 1 to force a time limit (some targets should be SKIPPED)
EXEC dbo.sp_HeapDoctor
    @CpuSource     = 'NONE',
    @PlanOnly      = 0,
    @MaxRunSeconds = 1,
    @LogToTable    = N'Y';
GO

-- 3C-1: HEAP_REBUILD_END should have StopReason (SUCCESS or COMPLETED_WITH_SKIPS)
DECLARE @3c_stop nvarchar(100);
SELECT @3c_stop = ExtendedInfo.value('(/Summary/StopReason)[1]', 'nvarchar(100)')
FROM dbo.CommandLog
WHERE CommandType = 'HEAP_REBUILD_END';

IF @3c_stop IS NOT NULL
BEGIN
    DECLARE @3c_msg nvarchar(200) = N'  PASS 3C-1: HEAP_REBUILD_END StopReason = ' + @3c_stop + N'. Code path ran without error.';
    RAISERROR(@3c_msg, 10, 1) WITH NOWAIT;
END
ELSE
    RAISERROR(N'  *** FAIL 3C-1: HEAP_REBUILD_END missing or no StopReason.', 10, 1) WITH NOWAIT;

-- Note: On fast hardware, all 3 rebuilds may complete in < 1 second. That's OK.
-- The test validates the code path runs without error.
RAISERROR(N'  INFO 3C: On fast hardware, no targets may be skipped. That is expected.', 10, 1) WITH NOWAIT;
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 3D: SKIPPED targets logged to CommandLog (@MaxRunSeconds=0)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

-- Re-create forwarded records so we have targets
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

TRUNCATE TABLE dbo.CommandLog;
GO

-- @MaxRunSeconds=0 forces immediate timeout; all targets should be SKIPPED
EXEC dbo.sp_HeapDoctor
    @CpuSource     = 'NONE',
    @PlanOnly      = 0,
    @MaxRunSeconds = 0,
    @LogToTable    = N'Y';
GO

-- 3D-1: CommandLog should have SKIPPED entries
DECLARE @3d_skipped int = (
    SELECT COUNT(*)
    FROM dbo.CommandLog
    WHERE ErrorMessage LIKE '%SKIPPED%'
);

IF @3d_skipped >= 1
BEGIN
    DECLARE @3d_msg1 nvarchar(200) = N'  PASS 3D-1: ' + CAST(@3d_skipped AS nvarchar(10)) + N' SKIPPED entries found in CommandLog.';
    RAISERROR(@3d_msg1, 10, 1) WITH NOWAIT;
END
ELSE
    RAISERROR(N'  *** FAIL 3D-1: No SKIPPED entries in CommandLog when @MaxRunSeconds=0.', 10, 1) WITH NOWAIT;

-- 3D-2: SKIPPED entries should have ExtendedInfo with PageCount
DECLARE @3d_with_info int = (
    SELECT COUNT(*)
    FROM dbo.CommandLog
    WHERE ErrorMessage LIKE '%SKIPPED%'
      AND ExtendedInfo IS NOT NULL
      AND CAST(ExtendedInfo AS nvarchar(max)) LIKE '%PageCount%'
);

IF @3d_with_info >= 1
    RAISERROR(N'  PASS 3D-2: SKIPPED entries have ExtendedInfo with PageCount.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 3D-2: SKIPPED entries missing or incomplete ExtendedInfo.', 10, 1) WITH NOWAIT;

-- 3D-3: No actual rebuilds should have happened (all skipped)
DECLARE @3d_rebuilt int = (
    SELECT COUNT(*)
    FROM dbo.CommandLog
    WHERE CommandType NOT IN ('HEAP_REBUILD_START', 'HEAP_REBUILD_END')
      AND ErrorMessage NOT LIKE '%SKIPPED%'
);

IF @3d_rebuilt = 0
    RAISERROR(N'  PASS 3D-3: No actual rebuilds executed (all targets skipped as expected).', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @3d_msg3 nvarchar(200) = N'  *** FAIL 3D-3: ' + CAST(@3d_rebuilt AS nvarchar(10)) + N' targets were rebuilt despite @MaxRunSeconds=0.';
    RAISERROR(@3d_msg3, 10, 1) WITH NOWAIT;
END

-- 3D-4: HEAP_REBUILD_END should have StopReason = TIME_LIMIT or similar
DECLARE @3d_stop nvarchar(100);
SELECT @3d_stop = ExtendedInfo.value('(/Summary/StopReason)[1]', 'nvarchar(100)')
FROM dbo.CommandLog
WHERE CommandType = 'HEAP_REBUILD_END';

IF @3d_stop IS NOT NULL
BEGIN
    DECLARE @3d_msg4 nvarchar(200) = N'  PASS 3D-4: StopReason = ' + @3d_stop;
    RAISERROR(@3d_msg4, 10, 1) WITH NOWAIT;
END
ELSE
    RAISERROR(N'  *** FAIL 3D-4: HEAP_REBUILD_END missing or no StopReason.', 10, 1) WITH NOWAIT;
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 3E: @EstimateTime with CommandLog history', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

/*
  This test needs CommandLog history with successful rebuilds.
  Test 3D truncated CommandLog and only created SKIPPED entries (0ms duration,
  filtered out by the >500ms threshold). So we must run a real rebuild first
  to seed CommandLog with valid throughput data, then re-create forwarded
  records and run PlanOnly with @EstimateTime=1 to verify estimates.
*/

-- Step 1: Create forwarded records and run a real rebuild to seed CommandLog history
TRUNCATE TABLE dbo.CommandLog;

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
GO

RAISERROR(N'  3E-setup: Running real rebuild to seed CommandLog history...', 10, 1) WITH NOWAIT;

EXEC dbo.sp_HeapDoctor
    @CpuSource     = 'NONE',
    @MinPages      = 1000,
    @PlanOnly      = 0,
    @LogToTable    = N'Y';
GO

-- Step 2: Re-create forwarded records so there are targets for the estimate test
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
GO

-- Capture result set with @EstimateTime=1
IF OBJECT_ID('tempdb..#Est') IS NOT NULL DROP TABLE #Est;
CREATE TABLE #Est
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
    action_chosen          varchar(32)   NOT NULL,
    est_pages_per_sec      float         NULL,
    est_seconds            int           NULL,
    est_duration           nvarchar(20)  NULL
);

INSERT #Est
EXEC dbo.sp_HeapDoctor
    @CpuSource     = 'NONE',
    @EstimateTime  = 1,
    @PlanOnly      = 1;
GO

-- 3E-1: est_pages_per_sec should be populated (history exists from earlier tests)
DECLARE @3e_with_est int = (SELECT COUNT(*) FROM #Est WHERE est_pages_per_sec IS NOT NULL);
IF @3e_with_est >= 1
BEGIN
    DECLARE @3e_msg1 nvarchar(200) = N'  PASS 3E-1: ' + CAST(@3e_with_est AS nvarchar(10)) + N' target(s) have est_pages_per_sec from CommandLog history.';
    RAISERROR(@3e_msg1, 10, 1) WITH NOWAIT;
END
ELSE
    RAISERROR(N'  *** FAIL 3E-1: est_pages_per_sec is NULL despite CommandLog history.', 10, 1) WITH NOWAIT;

-- 3E-2: est_seconds should be populated where est_pages_per_sec is
DECLARE @3e_with_sec int = (SELECT COUNT(*) FROM #Est WHERE est_seconds IS NOT NULL);
IF @3e_with_sec >= 1
    RAISERROR(N'  PASS 3E-2: est_seconds populated from history.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 3E-2: est_seconds is NULL despite having est_pages_per_sec.', 10, 1) WITH NOWAIT;

-- 3E-3: est_duration should be in HH:MM:SS format
DECLARE @3e_dur nvarchar(20) = (SELECT TOP 1 est_duration FROM #Est WHERE est_duration IS NOT NULL);
IF @3e_dur IS NOT NULL AND @3e_dur LIKE '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]'
    RAISERROR(N'  PASS 3E-3: est_duration is in HH:MM:SS format.', 10, 1) WITH NOWAIT;
ELSE IF @3e_dur IS NULL
    RAISERROR(N'  *** FAIL 3E-3: est_duration is NULL despite having history.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @3e_msg3 nvarchar(200) = N'  *** FAIL 3E-3: est_duration has unexpected format: ' + @3e_dur;
    RAISERROR(@3e_msg3, 10, 1) WITH NOWAIT;
END

-- 3E-4: est_pages_per_sec should be > 0
DECLARE @3e_bad_rate int = (SELECT COUNT(*) FROM #Est WHERE est_pages_per_sec IS NOT NULL AND est_pages_per_sec <= 0);
IF @3e_bad_rate = 0
    RAISERROR(N'  PASS 3E-4: All est_pages_per_sec values are > 0.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  *** FAIL 3E-4: Some est_pages_per_sec values are <= 0.', 10, 1) WITH NOWAIT;

-- Display estimates for manual review
SELECT table_name, page_count, action_chosen, est_pages_per_sec, est_seconds, est_duration
FROM #Est
ORDER BY sort_order;

IF OBJECT_ID('tempdb..#Est') IS NOT NULL DROP TABLE #Est;
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'Execution tests complete. Review PASS/FAIL results above.', 10, 1) WITH NOWAIT;
GO
