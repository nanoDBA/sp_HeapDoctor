/*
sp_HeapDoctor Test Harness - @ExcludeDatabases / @ExcludeTables

Validates the dedicated exclusion parameters:
  - @ExcludeDatabases: comma-separated DB patterns, merged with @Databases
  - @ExcludeTables: comma-separated schema.table patterns, merged with @Tables
  - Both logged to CommandLog via @invocation_command
  - NULL @Databases + @ExcludeDatabases implies USER_DATABASES
  - NULL @Tables + @ExcludeTables implies all tables

Prerequisites: Run 01_setup_test_data.sql first (creates HeapDoctorTest with HeapA/B/C).
Run with: sqlcmd -S YourServer -d HeapDoctorTest -i 27_test_exclude_params.sql
*/

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE [HeapDoctorTest];
GO

------------------------------------------------------------------------
-- Capture table (matches sp_HeapDoctor first result set)
------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
/* #190: the column list lives once, in dbo.ResultsTemplate (see 01_setup_test_data.sql) */
SELECT * INTO #Results FROM dbo.ResultsTemplate WHERE 1 = 0;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 27A: @ExcludeTables removes specific tables', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

/* Baseline: HeapA/B/C all present */
TRUNCATE TABLE #Results;
INSERT #Results EXEC dbo.sp_HeapDoctor @CpuSource = 'NONE', @PlanOnly = 1;
DECLARE @baseline_count int = (SELECT COUNT_BIG(*) FROM #Results WHERE table_name IN (N'HeapA', N'HeapB', N'HeapC'));
IF @baseline_count = 3
    RAISERROR(N'  PASS 27A-0: Baseline shows HeapA/B/C (3 heaps).', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 27A-0: Baseline missing one or more heaps.', 10, 1) WITH NOWAIT;

/* Exclude HeapA */
TRUNCATE TABLE #Results;
INSERT #Results EXEC dbo.sp_HeapDoctor @CpuSource = 'NONE', @PlanOnly = 1, @ExcludeTables = N'dbo.HeapA';
IF NOT EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapA')
   AND EXISTS (SELECT 1 FROM #Results WHERE table_name IN (N'HeapB', N'HeapC'))
    RAISERROR(N'  PASS 27A-1: @ExcludeTables = ''dbo.HeapA'' removes HeapA, keeps others.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 27A-1: HeapA not excluded properly.', 10, 1) WITH NOWAIT;

/* Multiple excludes */
TRUNCATE TABLE #Results;
INSERT #Results EXEC dbo.sp_HeapDoctor @CpuSource = 'NONE', @PlanOnly = 1, @ExcludeTables = N'dbo.HeapA, dbo.HeapB';
IF NOT EXISTS (SELECT 1 FROM #Results WHERE table_name IN (N'HeapA', N'HeapB'))
   AND EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapC')
    RAISERROR(N'  PASS 27A-2: Multiple comma-separated excludes work.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 27A-2: Multi-exclude failed.', 10, 1) WITH NOWAIT;

/* Wildcard exclude */
TRUNCATE TABLE #Results;
INSERT #Results EXEC dbo.sp_HeapDoctor @CpuSource = 'NONE', @PlanOnly = 1, @ExcludeTables = N'dbo.Heap%';
IF (SELECT COUNT_BIG(*) FROM #Results) = 0
    RAISERROR(N'  PASS 27A-3: Wildcard exclude (dbo.Heap%%) removes all matching heaps.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 27A-3: Wildcard exclude did not remove all heaps.', 10, 1) WITH NOWAIT;

/* Schema-optional exclude */
TRUNCATE TABLE #Results;
INSERT #Results EXEC dbo.sp_HeapDoctor @CpuSource = 'NONE', @PlanOnly = 1, @ExcludeTables = N'HeapC';
IF NOT EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapC')
    RAISERROR(N'  PASS 27A-4: Schema-optional exclude (just table name) works.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 27A-4: Schema-optional exclude failed.', 10, 1) WITH NOWAIT;

/* Composing @Tables include with @ExcludeTables */
TRUNCATE TABLE #Results;
INSERT #Results EXEC dbo.sp_HeapDoctor
    @CpuSource     = 'NONE',
    @PlanOnly      = 1,
    @Tables        = N'dbo.Heap%',
    @ExcludeTables = N'dbo.HeapB';
DECLARE @compose_count int = (SELECT COUNT_BIG(*) FROM #Results);
IF NOT EXISTS (SELECT 1 FROM #Results WHERE table_name = N'HeapB') AND @compose_count >= 2
    RAISERROR(N'  PASS 27A-5: @Tables + @ExcludeTables compose correctly.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @cMsg nvarchar(200) = N'  FAIL 27A-5: Composition failed (HeapB present or count too low: ' + CONVERT(nvarchar(10), @compose_count) + N')';
    RAISERROR(@cMsg, 10, 1) WITH NOWAIT;
END
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 27B: @ExcludeDatabases removes specific databases', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

/* USER_DATABASES minus HeapDoctorTest -> zero targets (the only user DB with qualifying heaps) */
TRUNCATE TABLE #Results;
INSERT #Results EXEC dbo.sp_HeapDoctor
    @CpuSource        = 'NONE',
    @PlanOnly         = 1,
    @Databases        = N'USER_DATABASES',
    @ExcludeDatabases = N'HeapDoctorTest';
IF NOT EXISTS (SELECT 1 FROM #Results WHERE database_name = N'HeapDoctorTest')
    RAISERROR(N'  PASS 27B-1: @ExcludeDatabases removes HeapDoctorTest from USER_DATABASES scan.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 27B-1: @ExcludeDatabases did not exclude HeapDoctorTest.', 10, 1) WITH NOWAIT;

/* @ExcludeDatabases with NULL @Databases should default to USER_DATABASES, find HeapDoctorTest targets */
TRUNCATE TABLE #Results;
INSERT #Results EXEC dbo.sp_HeapDoctor
    @CpuSource        = 'NONE',
    @PlanOnly         = 1,
    @ExcludeDatabases = N'master, model, tempdb, msdb';
IF EXISTS (SELECT 1 FROM #Results WHERE database_name = N'HeapDoctorTest')
    RAISERROR(N'  PASS 27B-2: NULL @Databases + @ExcludeDatabases implies USER_DATABASES.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 27B-2: Implicit USER_DATABASES did not kick in.', 10, 1) WITH NOWAIT;

/* Wildcard exclude */
TRUNCATE TABLE #Results;
INSERT #Results EXEC dbo.sp_HeapDoctor
    @CpuSource        = 'NONE',
    @PlanOnly         = 1,
    @Databases        = N'USER_DATABASES',
    @ExcludeDatabases = N'HeapDoctor%';
IF NOT EXISTS (SELECT 1 FROM #Results WHERE database_name = N'HeapDoctorTest')
    RAISERROR(N'  PASS 27B-3: Wildcard DB exclude (HeapDoctor%%) works.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 27B-3: Wildcard DB exclude failed.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;
RAISERROR(N' TEST 27C: CommandLog logs both new params via @invocation_command', 10, 1) WITH NOWAIT;
RAISERROR(N'================================================================', 10, 1) WITH NOWAIT;

EXEC dbo.sp_HeapDoctor
    @CpuSource        = 'NONE',
    @PlanOnly         = 1,
    @ExcludeDatabases = N'tempdb',
    @ExcludeTables    = N'dbo.HeapA',
    @LogToTable       = N'Y';

DECLARE @latest_cmd nvarchar(max) = (
    SELECT TOP (1) Command
    FROM dbo.CommandLog
    WHERE CommandType = N'HEAP_SCAN_SUMMARY'
    ORDER BY ID DESC
);

IF @latest_cmd LIKE N'%@ExcludeDatabases = N''tempdb''%'
   AND @latest_cmd LIKE N'%@ExcludeTables = N''dbo.HeapA''%'
    RAISERROR(N'  PASS 27C-1: CommandLog @invocation_command includes both exclude params.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @cmdMsg nvarchar(2000) = N'  FAIL 27C-1: Exclude params missing from Command. Got: '
        + ISNULL(LEFT(@latest_cmd, 1500), N'NULL');
    RAISERROR(@cmdMsg, 10, 1) WITH NOWAIT;
END
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'=== Test 27 complete ===', 10, 1) WITH NOWAIT;
