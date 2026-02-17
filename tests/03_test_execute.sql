/*
sp_HeapDoctor Test Harness - Step 3: Execution Tests

Tests @PlanOnly = 0 - actually executes rebuilds.
Verifies forwarded records are eliminated, CommandLog is populated, time limits work.

Prerequisites: Run 01_setup_test_data.sql first (this script re-creates forwarded records as needed).
Run with: sqlcmd -S YourServer -d HeapDoctorTest -i 03_test_execute.sql
  (add -E for Windows auth, -U/-P for SQL auth, or -G for Azure AD)

WARNING: This script modifies tables. It re-creates forwarded records between tests.
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
RAISERROR(N'Execution tests complete. Review PASS/FAIL results above.', 10, 1) WITH NOWAIT;
GO
