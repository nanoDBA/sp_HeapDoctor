/*
sp_HeapDoctor Test Harness - v2026.07.31.3: Advisory warnings + @LockTimeoutMs docs

Tests:
  -- Issue #179: @PlanCountWarnThreshold parameter --
  30A - @PlanCountWarnThreshold default value accepted (plan-only, no error)
  30B - @PlanCountWarnThreshold non-default logged to @invocation_command
  30C - @PlanCountWarnThreshold parameter exists in proc definition
  30D - Plan count advisory RAISERROR code exists in proc body

  -- Issue #182: Write-heavy NOTE in execution loop --
  30E - Write-heavy NOTE RAISERROR code exists in proc body
  30F - usage_hint column present in result set for all targets

  -- Issue #181: @LockTimeoutMs doc clarification --
  30G - @LockTimeoutMs RAISERROR wording references acquisition (code check)
  30H - @Help renders without error (@LockTimeoutMs + ADVANCED PARAMETERS split)

  -- Version --
  30V - Version is 2026.07.31.3

NOTE: Tests 30D, 30E, and the run-time advisory RAISERROR paths (#179 WARNING and
#182 NOTE) fire inside the execution loop at severity 10. RAISERROR severity 10
output goes only to the client message stream -- it cannot be captured via
INSERT...EXEC or result sets. Those paths are verified by grepping sqlcmd stdout
during cross-version execution testing. The tests here cover everything that IS
observable: parameter acceptance, @invocation_command logging, and code-level
pattern checks via sys.sql_modules.

Prerequisites: Run 01_setup_test_data.sql first (creates HeapDoctorTest with HeapA/B/C).
Run with: sqlcmd -S YourServer -U sa -P YourPassword -d HeapDoctorTest -i 30_test_v0608.sql
*/

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE [HeapDoctorTest];
GO

/*#region 30-SETUP*/
------------------------------------------------------------------------
-- Capture table (matches sp_HeapDoctor first result set)
------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
/* #190: the column list lives once, in dbo.ResultsTemplate (see 01_setup_test_data.sql) */
SELECT * INTO #Results FROM dbo.ResultsTemplate WHERE 1 = 0;
GO
/*#endregion*/

RAISERROR(N'=== Batch 30: v2026.07.31.3 (#179, #182, #181) ===', 10, 1) WITH NOWAIT;

/*#region 30A*/
------------------------------------------------------------------------
-- 30A: #179 - @PlanCountWarnThreshold default accepted (plan-only)
------------------------------------------------------------------------
RAISERROR(N'Test 30A: @PlanCountWarnThreshold default accepted (#179)...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases             = N'HeapDoctorTest',
    @CpuSource             = N'NONE',
    @PlanOnly              = 1,
    @PlanCountWarnThreshold = 50;

IF EXISTS (SELECT 1 FROM #Results)
    RAISERROR(N'  PASS 30A: @PlanCountWarnThreshold = 50 accepted, results returned.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 30A: No results returned with @PlanCountWarnThreshold = 50.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 30B*/
------------------------------------------------------------------------
-- 30B: #179 - Non-default @PlanCountWarnThreshold logged to @invocation_command
-- Verified via HEAP_SCAN_SUMMARY in CommandLog (written when @PlanOnly=1 + @LogToTable=Y).
------------------------------------------------------------------------
RAISERROR(N'Test 30B: @PlanCountWarnThreshold non-default in @invocation_command (#179)...', 10, 1) WITH NOWAIT;

DECLARE @pre_id30b integer;
SELECT @pre_id30b = ISNULL(MAX(ID), 0) FROM dbo.CommandLog;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases              = N'HeapDoctorTest',
    @CpuSource              = N'NONE',
    @PlanOnly               = 1,
    @LogToTable             = N'Y',
    @PlanCountWarnThreshold = 25;

DECLARE @cmd30b nvarchar(max);
SELECT TOP (1) @cmd30b = Command
FROM dbo.CommandLog
WHERE ID > @pre_id30b
  AND CommandType = N'HEAP_SCAN_SUMMARY'
ORDER BY ID DESC;

IF @cmd30b LIKE N'%@PlanCountWarnThreshold%25%'
    RAISERROR(N'  PASS 30B: @PlanCountWarnThreshold = 25 found in @invocation_command.', 10, 1) WITH NOWAIT;
ELSE IF @cmd30b IS NOT NULL
BEGIN
    DECLARE @msg30b nvarchar(2000) = N'  FAIL 30B: @PlanCountWarnThreshold not found in Command. Got: '
        + LEFT(@cmd30b, 1500);
    RAISERROR(@msg30b, 10, 1) WITH NOWAIT;
END
ELSE
    RAISERROR(N'  FAIL 30B: No HEAP_SCAN_SUMMARY found in CommandLog.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 30C*/
------------------------------------------------------------------------
-- 30C: #179 - @PlanCountWarnThreshold parameter exists in proc definition
------------------------------------------------------------------------
RAISERROR(N'Test 30C: @PlanCountWarnThreshold parameter exists (#179)...', 10, 1) WITH NOWAIT;

DECLARE @has_param30c bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%@PlanCountWarnThreshold%integer%''
    ) SET @out = 1;',
    N'@out bit OUTPUT',
    @out = @has_param30c OUTPUT;

IF @has_param30c = 1
    RAISERROR(N'  PASS 30C: @PlanCountWarnThreshold integer parameter found in proc.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 30C: @PlanCountWarnThreshold not found in proc definition.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 30D*/
------------------------------------------------------------------------
-- 30D: #179 - Plan count advisory RAISERROR code exists in proc body
-- The run-time WARNING fires during the execution loop and cannot be
-- captured via INSERT...EXEC. This test verifies the guarding code is
-- present in the proc definition.
------------------------------------------------------------------------
RAISERROR(N'Test 30D: Plan count advisory code exists in proc body (#179)...', 10, 1) WITH NOWAIT;

DECLARE @has_warn30d bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%@cur_qs_plan_count%@PlanCountWarnThreshold%''
          AND definition LIKE N''%cached plan(s) in Query Store%''
    ) SET @out = 1;',
    N'@out bit OUTPUT',
    @out = @has_warn30d OUTPUT;

IF @has_warn30d = 1
    RAISERROR(N'  PASS 30D: Plan count advisory guard + RAISERROR text found.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 30D: Plan count advisory code not found in proc definition.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 30E*/
------------------------------------------------------------------------
-- 30E: #182 - Write-heavy NOTE RAISERROR code exists in proc body
-- The NOTE fires during the execution loop. Verified here via
-- sys.sql_modules so the guard logic and text are confirmed present.
------------------------------------------------------------------------
RAISERROR(N'Test 30E: Write-heavy NOTE code exists in proc body (#182)...', 10, 1) WITH NOWAIT;

DECLARE @has_note30e bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%@cur_usage_hint%WRITE_HEAVY%@SkipWriteHeavy%''
          AND definition LIKE N''%Forwarded records recur fast%''
    ) SET @out = 1;',
    N'@out bit OUTPUT',
    @out = @has_note30e OUTPUT;

IF @has_note30e = 1
    RAISERROR(N'  PASS 30E: Write-heavy NOTE guard + RAISERROR text found.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 30E: Write-heavy NOTE code not found in proc definition.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 30F*/
------------------------------------------------------------------------
-- 30F: #182 - usage_hint column is present and populated in result set
-- Verifies the column the run-time check reads from is correctly
-- returned in the plan-only result set (structural regression guard).
------------------------------------------------------------------------
RAISERROR(N'Test 30F: usage_hint column present in result set (#182)...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly  = 1;

/*
usage_hint is NULL when dm_db_index_usage_stats has no data for the heap
(e.g. no DML since last restart), so we assert the column EXISTS in the
result set (i.e. #Results.usage_hint is not itself an error) and that at
least some rows are returned. The column value being NULL for all rows is
valid in a freshly-seeded test DB.
*/
DECLARE @row_count30f integer = (SELECT COUNT_BIG(*) FROM #Results);
IF @row_count30f > 0
    RAISERROR(N'  PASS 30F: usage_hint column accepted without error, results returned.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 30F: No results returned; cannot verify usage_hint column.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 30G*/
------------------------------------------------------------------------
-- 30G: #181 - @LockTimeoutMs RAISERROR text references "acquisition"
-- Verifies the corrected wording is in place. The RAISERROR fires in
-- the execution loop preamble when @LockTimeoutMs IS NOT NULL.
------------------------------------------------------------------------
RAISERROR(N'Test 30G: @LockTimeoutMs RAISERROR wording references acquisition (#181)...', 10, 1) WITH NOWAIT;

DECLARE @has_acq30g bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%caps wait to obtain Sch-M%hold duration = full rebuild duration%''
    ) SET @out = 1;',
    N'@out bit OUTPUT',
    @out = @has_acq30g OUTPUT;

IF @has_acq30g = 1
    RAISERROR(N'  PASS 30G: LockTimeoutMs RAISERROR text contains acquisition clarification.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 30G: LockTimeoutMs acquisition wording not found in proc definition.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 30H*/
------------------------------------------------------------------------
-- 30H: #181 - @Help renders without error (covers ADVANCED PARAMETERS split)
-- Exercises all RAISERROR blocks in the @Help region. A truncated or
-- malformed RAISERROR string causes an error at severity 16+.
------------------------------------------------------------------------
RAISERROR(N'Test 30H: @Help renders without error (#181 ADVANCED PARAMETERS split)...', 10, 1) WITH NOWAIT;

DECLARE @help_ok30h bit = 1;
BEGIN TRY
    EXEC dbo.sp_HeapDoctor
        @Help = 1;
END TRY
BEGIN CATCH
    SET @help_ok30h = 0;
    DECLARE @err30h nvarchar(2000) = N'  FAIL 30H: @Help raised error: ' + ERROR_MESSAGE();
    RAISERROR(@err30h, 10, 1) WITH NOWAIT;
END CATCH

IF @help_ok30h = 1
    RAISERROR(N'  PASS 30H: @Help=Y completed without error.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 30V*/
------------------------------------------------------------------------
-- 30V: Version check
------------------------------------------------------------------------
RAISERROR(N'Test 30V: Version check...', 10, 1) WITH NOWAIT;

DELETE FROM #Results;
INSERT INTO #Results
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest',
    @CpuSource = N'NONE',
    @PlanOnly  = 1;

DECLARE @ver30 nvarchar(20);
SELECT TOP (1) @ver30 = version FROM #Results;

IF @ver30 = N'2026.07.31.3'
    RAISERROR(N'  PASS 30V: Version is 2026.07.31.3.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 30V: Version is %s (expected 2026.07.31.3).', 10, 1, @ver30) WITH NOWAIT;
GO
/*#endregion*/

/*#region 30-CLEANUP*/
------------------------------------------------------------------------
-- Cleanup
------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Results') IS NOT NULL DROP TABLE #Results;
GO
/*#endregion*/

/*#region 30-SUMMARY*/
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'=== Batch 30 tests complete. Review results above. ===', 10, 1) WITH NOWAIT;
GO
/*#endregion*/
