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

-- Verify: All targets should succeed.
-- Verify: Forwarded records should be 0 after rebuild.

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'Checking forwarded records after rebuild...', 10, 1) WITH NOWAIT;

SELECT
    t.name AS table_name,
    ips.forwarded_record_count,
    CASE WHEN ips.forwarded_record_count = 0 THEN 'PASS' ELSE '*** FAIL ***' END AS result
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'SAMPLED') ips
JOIN sys.objects t ON ips.object_id = t.object_id
WHERE ips.index_id = 0
  AND t.type = 'U'
  AND t.name IN ('HeapA', 'HeapB', 'HeapC')
ORDER BY t.name;

-- Verify CommandLog
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'CommandLog entries:', 10, 1) WITH NOWAIT;

SELECT
    ID, CommandType, DatabaseName, ObjectName, StartTime, EndTime,
    ErrorNumber, ErrorMessage, ExtendedInfo
FROM dbo.CommandLog
ORDER BY ID;
GO

-- Verify: Should have HEAP_REBUILD_START, per-rebuild entries, HEAP_REBUILD_END.
-- Verify: Per-rebuild ExtendedInfo should have PageCount, SizeMB, ForwardedRecords, ForwardedPct.
-- Verify: ErrorNumber = 0 for all entries.

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

-- Verify: HeapB should use CI_SWAP_ONLINE.
-- Verify: HeapB should still be a heap after (no clustered index left behind).

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'Checking HeapB is still a heap after CI swap...', 10, 1) WITH NOWAIT;

SELECT
    t.name AS table_name,
    i.type_desc AS index_type,
    CASE WHEN i.type = 0 THEN 'PASS (still a heap)' ELSE '*** FAIL (clustered index left behind) ***' END AS result
FROM sys.indexes i
JOIN sys.objects t ON i.object_id = t.object_id
WHERE t.name = 'HeapB'
  AND i.index_id IN (0, 1);

-- Verify: Forwarded records eliminated
SELECT
    t.name AS table_name,
    ips.forwarded_record_count,
    CASE WHEN ips.forwarded_record_count = 0 THEN 'PASS' ELSE '*** FAIL ***' END AS result
FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID('dbo.HeapB'), NULL, NULL, 'SAMPLED') ips
JOIN sys.objects t ON ips.object_id = t.object_id
WHERE ips.index_id = 0;

-- CommandLog
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

-- Verify: ExecLog should show some targets as SKIPPED.
-- Verify: Summary should show Skipped > 0 (unless all rebuilds completed in < 1 second).
-- Note: On fast hardware, all 3 rebuilds may complete in < 1 second. That's OK -
-- the test validates the code path runs without error.

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'Execution tests complete. Review output above.', 10, 1) WITH NOWAIT;
GO
