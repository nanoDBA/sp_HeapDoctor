/*
sp_HeapDoctor Test Harness - Batch H output features

Tests:
  -- Issue #16: @OutputTable --
  24A - @OutputTable creates table and inserts results
  24B - @OutputTable second run appends (table already exists)
  24C - @OutputTable with spaces rejected
  24D - @OutputTable in invocation_command

  -- Issue #23: @GenerateScript --
  24E - @GenerateScript=1 accepted (plan-only implied)
  24F - @GenerateScript code exists in proc definition
  24G - @GenerateScript in invocation_command

  -- Version --
  24V - Version matches dbo.ExpectedVersion

Prerequisites: Run 01_setup_test_data.sql first.
Run with: sqlcmd -S YourServer -d HeapDoctorTest -i 24_test_v0302i.sql
*/

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE [HeapDoctorTest];
GO

IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
/* #190: the column list lives once, in dbo.ResultsTemplate (see 01_setup_test_data.sql) */
SELECT * INTO #Results FROM dbo.ResultsTemplate WHERE 1 = 0;
GO

RAISERROR(N'=== Batch 24: (#16, #23) ===', 10, 1) WITH NOWAIT;

------------------------------------------------------------------------
-- Setup: clean up any prior test output table
------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.HeapDoctorTestOutput') IS NOT NULL DROP TABLE dbo.HeapDoctorTestOutput;
GO

------------------------------------------------------------------------
-- 24A: #16 - @OutputTable creates table and inserts results
------------------------------------------------------------------------
RAISERROR(N'Test 24A: @OutputTable creates table and inserts results (#16)...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @MinPages = 1,
    @OutputTable = N'dbo.HeapDoctorTestOutput';

DECLARE @row_cnt24a int;
SELECT @row_cnt24a = COUNT(*) FROM dbo.HeapDoctorTestOutput;

IF @row_cnt24a > 0 AND OBJECT_ID(N'dbo.HeapDoctorTestOutput') IS NOT NULL
    RAISERROR(N'  PASS 24A: @OutputTable created and %d row(s) inserted.', 10, 1, @row_cnt24a) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 24A: Output table not created or empty.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 24B: #16 - @OutputTable second run appends
------------------------------------------------------------------------
RAISERROR(N'Test 24B: @OutputTable second run appends (#16)...', 10, 1) WITH NOWAIT;

DECLARE @pre_cnt24b int;
SELECT @pre_cnt24b = COUNT(*) FROM dbo.HeapDoctorTestOutput;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @MinPages = 1,
    @OutputTable = N'dbo.HeapDoctorTestOutput';

DECLARE @post_cnt24b int;
SELECT @post_cnt24b = COUNT(*) FROM dbo.HeapDoctorTestOutput;

IF @post_cnt24b > @pre_cnt24b
    RAISERROR(N'  PASS 24B: @OutputTable appended rows (%d -> %d).', 10, 1, @pre_cnt24b, @post_cnt24b) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 24B: Row count did not increase (%d -> %d).', 10, 1, @pre_cnt24b, @post_cnt24b) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 24C: #16 - @OutputTable with spaces rejected
------------------------------------------------------------------------
RAISERROR(N'Test 24C: @OutputTable with spaces rejected (#16)...', 10, 1) WITH NOWAIT;

BEGIN TRY
    EXEC dbo.sp_HeapDoctor
        @Databases = N'HeapDoctorTest',
        @CpuSource = N'NONE',
        @PlanOnly = 1,
        @OutputTable = N'bad table name';
    RAISERROR(N'  FAIL 24C: @OutputTable with spaces was accepted.', 10, 1) WITH NOWAIT;
END TRY
BEGIN CATCH
    IF ERROR_MESSAGE() LIKE N'%@OutputTable must not contain spaces%'
        RAISERROR(N'  PASS 24C: @OutputTable with spaces correctly rejected.', 10, 1) WITH NOWAIT;
    ELSE
    BEGIN
        DECLARE @err24c nvarchar(500) = ERROR_MESSAGE();
        RAISERROR(N'  FAIL 24C: Wrong error: %s', 10, 1, @err24c) WITH NOWAIT;
    END
END CATCH
GO

------------------------------------------------------------------------
-- 24D: #16 - @OutputTable in invocation_command
------------------------------------------------------------------------
RAISERROR(N'Test 24D: @OutputTable in invocation_command (#16)...', 10, 1) WITH NOWAIT;

DECLARE @pre_id24d int;
SELECT @pre_id24d = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @LogToTable = N'Y',
    @OutputTable = N'dbo.HeapDoctorTestOutput';

DECLARE @cmd24d nvarchar(max);
SELECT TOP 1 @cmd24d = Command
FROM dbo.CommandLog
WHERE ID > @pre_id24d
  AND CommandType = N'HEAP_SCAN_SUMMARY'
ORDER BY ID DESC;

IF @cmd24d LIKE N'%@OutputTable%HeapDoctorTestOutput%'
    RAISERROR(N'  PASS 24D: @OutputTable found in invocation_command.', 10, 1) WITH NOWAIT;
ELSE IF @cmd24d IS NOT NULL
    RAISERROR(N'  FAIL 24D: @OutputTable not found in Command column.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 24D: No HEAP_SCAN_SUMMARY found.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 24E: #23 - @GenerateScript=1 accepted (plan-only implied)
------------------------------------------------------------------------
RAISERROR(N'Test 24E: @GenerateScript=1 accepted (#23)...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @GenerateScript = 1,
    @MinPages = 1;

IF EXISTS (SELECT 1 FROM #Results)
    RAISERROR(N'  PASS 24E: @GenerateScript=1 accepted, results returned.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 24E: No results returned.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 24F: #23 - @GenerateScript code exists in proc definition
------------------------------------------------------------------------
RAISERROR(N'Test 24F: @GenerateScript code exists (#23)...', 10, 1) WITH NOWAIT;

DECLARE @has_script bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%Generated rebuild script%paste into SSMS%''
    ) SET @out = 1;',
    N'@out bit OUTPUT',
    @out = @has_script OUTPUT;

IF @has_script = 1
    RAISERROR(N'  PASS 24F: @GenerateScript output code found in proc.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 24F: @GenerateScript output not found in proc.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 24G: #23 - @GenerateScript in invocation_command
------------------------------------------------------------------------
RAISERROR(N'Test 24G: @GenerateScript in invocation_command (#23)...', 10, 1) WITH NOWAIT;

DECLARE @pre_id24g int;
SELECT @pre_id24g = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @GenerateScript = 1,
    @LogToTable = N'Y';

DECLARE @cmd24g nvarchar(max);
SELECT TOP 1 @cmd24g = Command
FROM dbo.CommandLog
WHERE ID > @pre_id24g
  AND CommandType = N'HEAP_SCAN_SUMMARY'
ORDER BY ID DESC;

IF @cmd24g LIKE N'%@GenerateScript%'
    RAISERROR(N'  PASS 24G: @GenerateScript found in invocation_command.', 10, 1) WITH NOWAIT;
ELSE IF @cmd24g IS NOT NULL
    RAISERROR(N'  FAIL 24G: @GenerateScript not found in Command column.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 24G: No HEAP_SCAN_SUMMARY found.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 24V: Version check
------------------------------------------------------------------------
RAISERROR(N'Test 24V: Version check...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1;

DECLARE @ver24 nvarchar(20);
SELECT TOP 1 @ver24 = version FROM #Results;

IF @ver24 = (SELECT version FROM dbo.ExpectedVersion)
    RAISERROR(N'  PASS 24V: Version matches dbo.ExpectedVersion.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 24V: Version is %s and does not match dbo.ExpectedVersion.', 10, 1, @ver24) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- Cleanup
------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.HeapDoctorTestOutput') IS NOT NULL DROP TABLE dbo.HeapDoctorTestOutput;
IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'Batch 24 tests complete. Review results above.', 10, 1) WITH NOWAIT;
GO
