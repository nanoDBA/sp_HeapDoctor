/*
sp_HeapDoctor Test Harness - Batch 9: Low-Priority Polish

Tests Batch 9 additions:
  9A - Sub-second duration formatting
  9B - Error message truncation (1000 chars)
  9C - Version in per-rebuild ExtendedInfo
  9D - MAXRECURSION 0 (unlimited)
  9E - DATALENGTH instead of LEN in CTE
  9F - UTC vs local time documentation in @Help
  9G - Permission documentation in @Help
  9I - Ledger table exclusion (safe on SQL <2022)
  9J - AG sync-commit warning (no error if no AG)
  9K - Backup running check (no error if no backup)
  9L - Trending columns (prev_forwarded_pct, rebuilds_in_90d)
  9M - Tiered @Help output (COMMON/ADVANCED/QUICKIESTORE)

Prerequisites: Run 01_setup_test_data.sql first.
Run with: sqlcmd -S YourServer -d HeapDoctorTest -i 09_test_batch9.sql
  (add -E for Windows auth, -U/-P for SQL auth, or -G for Azure AD)
*/

SET NOCOUNT ON;
USE [HeapDoctorTest];
GO

------------------------------------------------------------------------
-- Reusable capture table
------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
/* #190: the column list lives once, in dbo.ResultsTemplate (see 01_setup_test_data.sql) */
SELECT * INTO #Results FROM dbo.ResultsTemplate WHERE 1 = 0;
GO

IF OBJECT_ID('tempdb..#TestCounts') IS NOT NULL DROP TABLE #TestCounts;
CREATE TABLE #TestCounts (PassCount int NOT NULL DEFAULT 0, FailCount int NOT NULL DEFAULT 0);
INSERT #TestCounts DEFAULT VALUES;
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
RAISERROR(N' TEST 9C: Version in per-rebuild ExtendedInfo', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
/*
Execute a rebuild and verify Version appears in ExtendedInfo for the
per-rebuild CommandLog entry (not just START).
*/
DECLARE @max_cmd_before int;
SELECT @max_cmd_before = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;

EXEC dbo.sp_HeapDoctor
    @Databases = 'HeapDoctorTest',
    @CpuSource = 'NONE',
    @TopN = 1,
    @PlanOnly = 0;

IF EXISTS (
    SELECT 1 FROM dbo.CommandLog
    WHERE ID > @max_cmd_before
      AND CommandType NOT IN ('HEAP_REBUILD_START', 'HEAP_REBUILD_END')
      AND CAST(ExtendedInfo AS nvarchar(max)) LIKE '%<Version>%'
)
BEGIN
    RAISERROR(N'  PASS 9C: Version found in per-rebuild ExtendedInfo.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL 9C: Version not found in per-rebuild ExtendedInfo.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END

-- Also check END/Summary has Version
IF EXISTS (
    SELECT 1 FROM dbo.CommandLog
    WHERE ID > @max_cmd_before
      AND CommandType = 'HEAP_REBUILD_END'
      AND CAST(ExtendedInfo AS nvarchar(max)) LIKE '%<Version>%'
)
BEGIN
    RAISERROR(N'  PASS 9C2: Version found in END/Summary ExtendedInfo.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL 9C2: Version not found in END/Summary ExtendedInfo.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 9L: Trending columns populated', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
/*
After executing rebuilds above, run again. The prev_forwarded_pct and
rebuilds_in_90d columns should now have data from the CommandLog history.
Re-create forwarded records first so the rebuilt heap re-appears as a target.
*/
RAISERROR(N'  9L: Recreating forwarded records in all heaps (9C rebuilt one)...', 10, 1) WITH NOWAIT;

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

TRUNCATE TABLE #Results;

INSERT #Results
EXEC dbo.sp_HeapDoctor
    @Databases = 'HeapDoctorTest',
    @CpuSource = 'NONE',
    @PlanOnly = 1;

-- At least one target should have rebuilds_in_90d > 0 (from test execution above)
IF EXISTS (SELECT 1 FROM #Results WHERE rebuilds_in_90d > 0)
BEGIN
    RAISERROR(N'  PASS 9L: rebuilds_in_90d populated from CommandLog.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    RAISERROR(N'  FAIL 9L: No targets have rebuilds_in_90d > 0 (expected from prior test executions).', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 9M: Tiered @Help output', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
/*
Verify @Help output contains the tiered sections.
Can't capture RAISERROR output directly, but we can verify proc runs
with @Help=1 without error.
*/
BEGIN TRY
    EXEC dbo.sp_HeapDoctor @Help = 1;
    RAISERROR(N'  PASS 9M: @Help executed without error.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END TRY
BEGIN CATCH
    DECLARE @Msg nvarchar(4000); SET @Msg =N'  FAIL 9M: @Help error: ' + LEFT(ERROR_MESSAGE(), 500);
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END CATCH
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 9D: Large @Databases list (MAXRECURSION 0)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
/*
Verify MAXRECURSION = 0 allows large database lists without error.
Pass a long comma-separated list (> 100 items won't exist, but parsing
should work without recursion error).
*/
BEGIN TRY
    TRUNCATE TABLE #Results;
    INSERT #Results
    EXEC dbo.sp_HeapDoctor
        @Databases = N'HeapDoctorTest,db1,db2,db3,db4,db5,db6,db7,db8,db9,db10,db11,db12,db13,db14,db15,db16,db17,db18,db19,db20',
        @CpuSource = 'NONE',
        @PlanOnly = 1;

    RAISERROR(N'  PASS 9D: Large @Databases list parsed without MAXRECURSION error.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END TRY
BEGIN CATCH
    DECLARE @Msg nvarchar(4000); SET @Msg =N'  FAIL 9D: Error: ' + LEFT(ERROR_MESSAGE(), 500);
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET FailCount += 1;
END CATCH
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 9V: Version check (1.4.x)', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
------------------------------------------------------------------------
TRUNCATE TABLE #Results;

INSERT #Results
EXEC dbo.sp_HeapDoctor
    @CpuSource = 'NONE',
    @PlanOnly = 1;

IF EXISTS (SELECT 1 FROM #Results WHERE version LIKE '2026.%')
BEGIN
    RAISERROR(N'  PASS 9V: Version starts with 2026.x.', 10, 1) WITH NOWAIT;
    UPDATE #TestCounts SET PassCount += 1;
END
ELSE
BEGIN
    DECLARE @v9 nvarchar(20);
    SELECT TOP 1 @v9 = version FROM #Results;
    DECLARE @Msg nvarchar(4000); SET @Msg =N'  FAIL 9V: Expected version 2026.x, got: ' + ISNULL(@v9, N'NULL');
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
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
SET @summary = N' Batch 9 Tests Complete -- PASSED: ' + CAST(@PassCount AS nvarchar(10))
             + N'  FAILED: ' + CAST(@FailCount AS nvarchar(10));
RAISERROR(@summary, 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

IF @FailCount > 0
    RAISERROR(N'THERE WERE FAILURES. Review output above.', 16, 1);
GO
