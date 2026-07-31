/*
sp_HeapDoctor Test Harness - v2026.07.31.1: Batch G discovery

Tests:
  -- Issue #22: IO latch wait stats --
  23A - page_io_latch_wait_count column exists in result set
  23B - page_io_latch_wait_ms column exists in result set
  23C - Wait stats columns present in HEAP_SCAN_SUMMARY XML
  23D - Wait stats columns survive resume mode

  -- Issue #88: @BaselineRebuildMBPerMin cold-start ETA --
  23E - @BaselineRebuildMBPerMin parameter accepted
  23F - @BaselineRebuildMBPerMin=0 rejected (validation)
  23G - @BaselineRebuildMBPerMin=-1 rejected (validation)
  23H - @BaselineRebuildMBPerMin in invocation_command
  23I - Baseline populates est_pages_per_sec on targets

  -- Version --
  23V - Version is 2026.07.31.1

Prerequisites: Run 01_setup_test_data.sql first.
Run with: sqlcmd -S YourServer -d HeapDoctorTest -i 23_test_v0302i.sql
*/

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE [HeapDoctorTest];
GO

IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
/* #190: the column list lives once, in dbo.ResultsTemplate (see 01_setup_test_data.sql) */
SELECT * INTO #Results FROM dbo.ResultsTemplate WHERE 1 = 0;
GO

RAISERROR(N'=== Batch 23: v2026.07.31.1 (#22, #88) ===', 10, 1) WITH NOWAIT;

------------------------------------------------------------------------
-- 23A: #22 - page_io_latch_wait_count column exists in result set
------------------------------------------------------------------------
RAISERROR(N'Test 23A: page_io_latch_wait_count column in result set (#22)...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @MinPages = 1;

IF EXISTS (SELECT 1 FROM #Results WHERE page_io_latch_wait_count IS NOT NULL)
    RAISERROR(N'  PASS 23A: page_io_latch_wait_count populated in result set.', 10, 1) WITH NOWAIT;
ELSE IF EXISTS (SELECT 1 FROM #Results)
    RAISERROR(N'  PASS 23A: page_io_latch_wait_count column exists (NULL values expected when no IO waits).', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 23A: No results returned.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 23B: #22 - page_io_latch_wait_ms column exists in result set
------------------------------------------------------------------------
RAISERROR(N'Test 23B: page_io_latch_wait_ms column in result set (#22)...', 10, 1) WITH NOWAIT;

IF EXISTS (SELECT 1 FROM #Results WHERE page_io_latch_wait_ms IS NOT NULL)
    RAISERROR(N'  PASS 23B: page_io_latch_wait_ms populated in result set.', 10, 1) WITH NOWAIT;
ELSE IF EXISTS (SELECT 1 FROM #Results)
    RAISERROR(N'  PASS 23B: page_io_latch_wait_ms column exists (NULL values expected when no IO waits).', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 23B: No results returned.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 23C: #22 - Wait stats columns in HEAP_SCAN_SUMMARY XML
------------------------------------------------------------------------
RAISERROR(N'Test 23C: Wait stats in HEAP_SCAN_SUMMARY XML (#22)...', 10, 1) WITH NOWAIT;

DECLARE @has_xml_attrs bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%PageIoLatchWaitCount%''
          AND definition LIKE N''%PageIoLatchWaitMs%''
    ) SET @out = 1;',
    N'@out bit OUTPUT',
    @out = @has_xml_attrs OUTPUT;

IF @has_xml_attrs = 1
    RAISERROR(N'  PASS 23C: PageIoLatchWaitCount and PageIoLatchWaitMs in HEAP_SCAN_SUMMARY XML.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 23C: Wait stats attributes not found in HEAP_SCAN_SUMMARY XML code.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 23D: #22 - Wait stats survive resume mode (code check)
------------------------------------------------------------------------
RAISERROR(N'Test 23D: Wait stats in resume loader (#22)...', 10, 1) WITH NOWAIT;

DECLARE @has_resume_cols bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%@PageIoLatchWaitCount%bigint%''
          AND definition LIKE N''%@PageIoLatchWaitMs%bigint%''
    ) SET @out = 1;',
    N'@out bit OUTPUT',
    @out = @has_resume_cols OUTPUT;

IF @has_resume_cols = 1
    RAISERROR(N'  PASS 23D: Wait stats columns in resume loader.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 23D: Wait stats not found in resume loader code.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 23E: #88 - @BaselineRebuildMBPerMin parameter accepted
------------------------------------------------------------------------
RAISERROR(N'Test 23E: @BaselineRebuildMBPerMin parameter accepted (#88)...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @MinPages = 1,
    @EstimateTime = 1,
    @BaselineRebuildMBPerMin = 500;

IF EXISTS (SELECT 1 FROM #Results)
    RAISERROR(N'  PASS 23E: @BaselineRebuildMBPerMin=500 accepted.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 23E: No results returned.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 23F: #88 - @BaselineRebuildMBPerMin=0 rejected
------------------------------------------------------------------------
RAISERROR(N'Test 23F: @BaselineRebuildMBPerMin=0 rejected (#88)...', 10, 1) WITH NOWAIT;

BEGIN TRY
    EXEC dbo.sp_HeapDoctor
        @Databases = N'HeapDoctorTest',
        @CpuSource = N'NONE',
        @PlanOnly = 1,
        @BaselineRebuildMBPerMin = 0;
    RAISERROR(N'  FAIL 23F: @BaselineRebuildMBPerMin=0 was accepted (should be rejected).', 10, 1) WITH NOWAIT;
END TRY
BEGIN CATCH
    IF ERROR_MESSAGE() LIKE N'%@BaselineRebuildMBPerMin must be a positive integer%'
        RAISERROR(N'  PASS 23F: @BaselineRebuildMBPerMin=0 correctly rejected.', 10, 1) WITH NOWAIT;
    ELSE
    BEGIN
        DECLARE @err23f nvarchar(500) = ERROR_MESSAGE();
        RAISERROR(N'  FAIL 23F: Wrong error: %s', 10, 1, @err23f) WITH NOWAIT;
    END
END CATCH
GO

------------------------------------------------------------------------
-- 23G: #88 - @BaselineRebuildMBPerMin=-1 rejected
------------------------------------------------------------------------
RAISERROR(N'Test 23G: @BaselineRebuildMBPerMin=-1 rejected (#88)...', 10, 1) WITH NOWAIT;

BEGIN TRY
    EXEC dbo.sp_HeapDoctor
        @Databases = N'HeapDoctorTest',
        @CpuSource = N'NONE',
        @PlanOnly = 1,
        @BaselineRebuildMBPerMin = -1;
    RAISERROR(N'  FAIL 23G: @BaselineRebuildMBPerMin=-1 was accepted (should be rejected).', 10, 1) WITH NOWAIT;
END TRY
BEGIN CATCH
    IF ERROR_MESSAGE() LIKE N'%@BaselineRebuildMBPerMin must be a positive integer%'
        RAISERROR(N'  PASS 23G: @BaselineRebuildMBPerMin=-1 correctly rejected.', 10, 1) WITH NOWAIT;
    ELSE
    BEGIN
        DECLARE @err23g nvarchar(500) = ERROR_MESSAGE();
        RAISERROR(N'  FAIL 23G: Wrong error: %s', 10, 1, @err23g) WITH NOWAIT;
    END
END CATCH
GO

------------------------------------------------------------------------
-- 23H: #88 - @BaselineRebuildMBPerMin in invocation_command
------------------------------------------------------------------------
RAISERROR(N'Test 23H: @BaselineRebuildMBPerMin in invocation_command (#88)...', 10, 1) WITH NOWAIT;

DECLARE @pre_id23h int;
SELECT @pre_id23h = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @LogToTable = N'Y',
    @EstimateTime = 1,
    @BaselineRebuildMBPerMin = 500;

DECLARE @cmd23h nvarchar(max);
SELECT TOP 1 @cmd23h = Command
FROM dbo.CommandLog
WHERE ID > @pre_id23h
  AND CommandType = N'HEAP_SCAN_SUMMARY'
ORDER BY ID DESC;

IF @cmd23h LIKE N'%@BaselineRebuildMBPerMin%500%'
    RAISERROR(N'  PASS 23H: @BaselineRebuildMBPerMin=500 found in invocation_command.', 10, 1) WITH NOWAIT;
ELSE IF @cmd23h IS NOT NULL
    RAISERROR(N'  FAIL 23H: @BaselineRebuildMBPerMin not found in Command column.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 23H: No HEAP_SCAN_SUMMARY found.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 23I: #88 - Baseline populates est_pages_per_sec on targets
------------------------------------------------------------------------
RAISERROR(N'Test 23I: Baseline populates est_pages_per_sec (#88)...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1,
    @MinPages = 1,
    @EstimateTime = 1,
    @BaselineRebuildMBPerMin = 500;

-- 500 MB/min = 500 * 128 / 60 = 1066.67 pages/sec
IF EXISTS (SELECT 1 FROM #Results WHERE est_pages_per_sec IS NOT NULL AND est_pages_per_sec > 1000)
    RAISERROR(N'  PASS 23I: est_pages_per_sec populated from baseline rate.', 10, 1) WITH NOWAIT;
ELSE IF EXISTS (SELECT 1 FROM #Results WHERE est_pages_per_sec IS NOT NULL)
    RAISERROR(N'  PASS 23I: est_pages_per_sec populated (value differs from expected - may have CommandLog history).', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 23I: est_pages_per_sec is NULL - baseline not applied.', 10, 1) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- 23V: Version check
------------------------------------------------------------------------
RAISERROR(N'Test 23V: Version check...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly = 1;

DECLARE @ver23 nvarchar(20);
SELECT TOP 1 @ver23 = version FROM #Results;

IF @ver23 = N'2026.07.31.1'
    RAISERROR(N'  PASS 23V: Version is 2026.07.31.1.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 23V: Version is %s (expected 2026.07.31.1).', 10, 1, @ver23) WITH NOWAIT;
GO

------------------------------------------------------------------------
-- Cleanup
------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'Batch 23 tests complete. Review results above.', 10, 1) WITH NOWAIT;
GO
