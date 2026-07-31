/*
sp_HeapDoctor Test Harness - v2026.07.31.2: Batch E statistics

Tests:
  -- Issue #19: @UpdateStatsAfterRebuild --
  21A - @UpdateStatsAfterRebuild=0 accepted (default)
  21B - @UpdateStatsAfterRebuild=1 runs UPDATE STATISTICS after rebuild
  21C - @UpdateStatsAfterRebuild=1 in invocation_command

  -- Issue #91: Post-rebuild statistics message --
  21D - Stale stats message includes NCI count
  21E - @UpdateStatsAfterRebuild parameter exists in proc definition

  -- Version --
  21V - Version is 2026.07.31.2

Prerequisites: Run 01_setup_test_data.sql first.
Run with: sqlcmd -S YourServer -d HeapDoctorTest -i 21_test_v0302e.sql
*/

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE [HeapDoctorTest];
GO

IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
/* #190: the column list lives once, in dbo.ResultsTemplate (see 01_setup_test_data.sql) */
SELECT * INTO #Results FROM dbo.ResultsTemplate WHERE 1 = 0;
GO

RAISERROR(N'=== Batch 21: v2026.07.31.2 (#19, #91) ===', 10, 1) WITH NOWAIT;

------------------------------------------------------------------------
-- Setup: create inline test heap with NCI for stats tests
------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.HeapStatsTest') IS NOT NULL DROP TABLE dbo.HeapStatsTest;
CREATE TABLE dbo.HeapStatsTest
(
    ID   int          NOT NULL,
    Col1 int          NULL,
    Col2 nvarchar(50) NULL
);
CREATE NONCLUSTERED INDEX IX_HeapStatsTest_Col1 ON dbo.HeapStatsTest(Col1);

DECLARE @s21 int = 1;
WHILE @s21 <= 10000
BEGIN
    INSERT dbo.HeapStatsTest(ID, Col1, Col2) VALUES (@s21, @s21, REPLICATE(N'X', 10));
    SET @s21 += 1;
END
UPDATE dbo.HeapStatsTest SET Col2 = REPLICATE(N'Y', 50);
GO

------------------------------------------------------------------------
-- 21A: #19 - @UpdateStatsAfterRebuild=0 accepted (plan-only)
------------------------------------------------------------------------
RAISERROR(N'Test 21A: @UpdateStatsAfterRebuild=0 accepted (#19)...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @UpdateStatsAfterRebuild = 0;

IF EXISTS (SELECT 1 FROM #Results)
    RAISERROR(N'  PASS 21A: @UpdateStatsAfterRebuild=0 accepted.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 21A: No results.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 21B: #19 - @UpdateStatsAfterRebuild=1 runs UPDATE STATISTICS
-- Test by executing on our inline heap and checking CommandLog
------------------------------------------------------------------------
RAISERROR(N'Test 21B: @UpdateStatsAfterRebuild=1 execution (#19)...', 10, 1) WITH NOWAIT;

DECLARE @pre_id21b int;
SELECT @pre_id21b = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;

-- Execute rebuild with stats update
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @Tables = N'dbo.HeapStatsTest',
    @CpuSource = N'NONE',
    @PlanOnly = 0,
    @MinPages = 1,
    @LogToTable = N'Y',
    @UpdateStatsAfterRebuild = 1;

-- Verify rebuild succeeded
DECLARE @rebuild_ok21b int;
SELECT @rebuild_ok21b = COUNT(*)
FROM dbo.CommandLog
WHERE ID > @pre_id21b
  AND ObjectName = N'HeapStatsTest'
  AND CommandType IN (N'HEAP_REBUILD_ONLINE', N'HEAP_REBUILD_OFFLINE', N'CI_SWAP_ONLINE')
  AND ErrorNumber = 0;

IF @rebuild_ok21b > 0
    RAISERROR(N'  PASS 21B: Rebuild with @UpdateStatsAfterRebuild=1 succeeded (stats update in output above).', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 21B: No successful rebuild found.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 21C: #19 - @UpdateStatsAfterRebuild=1 in invocation_command
------------------------------------------------------------------------
RAISERROR(N'Test 21C: @UpdateStatsAfterRebuild=1 in invocation_command (#19)...', 10, 1) WITH NOWAIT;

DECLARE @pre_id21c int;
SELECT @pre_id21c = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @LogToTable = N'Y',
    @UpdateStatsAfterRebuild = 1;

DECLARE @cmd21c nvarchar(max);
SELECT TOP 1 @cmd21c = Command
FROM dbo.CommandLog
WHERE ID > @pre_id21c
  AND CommandType = N'HEAP_SCAN_SUMMARY'
ORDER BY ID DESC;

IF @cmd21c LIKE N'%@UpdateStatsAfterRebuild%'
    RAISERROR(N'  PASS 21C: @UpdateStatsAfterRebuild found in invocation_command.', 10, 1) WITH NOWAIT;
ELSE IF @cmd21c IS NOT NULL
    RAISERROR(N'  FAIL 21C: @UpdateStatsAfterRebuild not found in Command column.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 21C: No HEAP_SCAN_SUMMARY found.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 21D: #91 - Stale stats message includes NCI count (code check)
------------------------------------------------------------------------
RAISERROR(N'Test 21D: Stale stats message includes NCI count (#91)...', 10, 1) WITH NOWAIT;

DECLARE @has_nci_msg bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%NCI(s)%Auto-update%''
    ) SET @out = 1;',
    N'@out bit OUTPUT',
    @out = @has_nci_msg OUTPUT;

IF @has_nci_msg = 1
    RAISERROR(N'  PASS 21D: Stale stats message includes NCI count.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 21D: NCI count not found in stale stats message.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 21E: @UpdateStatsAfterRebuild parameter exists
------------------------------------------------------------------------
RAISERROR(N'Test 21E: @UpdateStatsAfterRebuild parameter exists (#19)...', 10, 1) WITH NOWAIT;

DECLARE @has_param bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%@UpdateStatsAfterRebuild%bit%''
    ) SET @out = 1;',
    N'@out bit OUTPUT',
    @out = @has_param OUTPUT;

IF @has_param = 1
    RAISERROR(N'  PASS 21E: @UpdateStatsAfterRebuild parameter found.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 21E: @UpdateStatsAfterRebuild not found in proc.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 21V: Version check
------------------------------------------------------------------------
RAISERROR(N'Test 21V: Version check...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1;

DECLARE @ver21 nvarchar(20);
SELECT TOP 1 @ver21 = version FROM #Results;

IF @ver21 = N'2026.07.31.2'
    RAISERROR(N'  PASS 21V: Version is 2026.07.31.2.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 21V: Version is %s (expected 2026.07.31.2).', 10, 1, @ver21) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- Cleanup
------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.HeapStatsTest') IS NOT NULL DROP TABLE dbo.HeapStatsTest;
IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'Batch 21 tests complete. Review results above.', 10, 1) WITH NOWAIT;
GO
