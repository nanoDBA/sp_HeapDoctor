/*
sp_HeapDoctor Test Harness - v2026.07.31.3: QUICKIESTORE DDL builder (#194)

Tests:
  -- Issue #194: #Quickie DDL builder used a proc name as a TVF --
  33A - Proc no longer selects FROM sys.sp_describe_first_result_set
  33B - Proc uses sys.dm_exec_describe_first_result_set (the SELECT-able form)
  33C - QUICKIESTORE with a valid @QuickieExecSql reaches and builds #Quickie
  33D - An unresolvable @QuickieExecSql reports the underlying reason, naming it

  -- Version --
  33V - Version is 2026.07.31.3

WHY 33C EXISTS: the only prior QUICKIESTORE coverage (4C) asserts that OMITTING
@QuickieExecSql raises a validation error, so it never reached the DDL builder.
That is how a hard Msg 208 shipped in a documented CPU source. 33C supplies a
stub @QuickieExecSql shaped like sp_QuickieStore output, which reaches the
builder without requiring sp_QuickieStore to be installed.

Prerequisites: Run 01_setup_test_data.sql first.
Run with: sqlcmd -S YourServer -U sa -P YourPassword -d HeapDoctorTest -i 33_test_v0731.sql
*/

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE [HeapDoctorTest];
GO

RAISERROR(N'=== Batch 33: v2026.07.31.3 (#194 QUICKIESTORE DDL builder) ===', 10, 1) WITH NOWAIT;

/*#region 33A*/
------------------------------------------------------------------------
-- 33A: #194 - the invalid object name is gone
------------------------------------------------------------------------
RAISERROR(N'Test 33A: sys.sp_describe_first_result_set no longer selected FROM (#194)...', 10, 1) WITH NOWAIT;

DECLARE @has33a bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%FROM sys.sp_describe_first_result_set%''
    ) SET @out = 1;',
    N'@out bit OUTPUT', @out = @has33a OUTPUT;

IF @has33a = 0
    RAISERROR(N'  PASS 33A: no FROM sys.sp_describe_first_result_set in the proc.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 33A: proc still selects FROM a stored procedure name.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 33B*/
------------------------------------------------------------------------
-- 33B: #194 - the SELECT-able form is used instead
------------------------------------------------------------------------
RAISERROR(N'Test 33B: dm_exec_describe_first_result_set is used (#194)...', 10, 1) WITH NOWAIT;

DECLARE @has33b bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%dm_exec_describe_first_result_set%''
    ) SET @out = 1;',
    N'@out bit OUTPUT', @out = @has33b OUTPUT;

IF @has33b = 1
    RAISERROR(N'  PASS 33B: dm_exec_describe_first_result_set present.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 33B: the SELECT-able describe function is not used.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 33C*/
------------------------------------------------------------------------
-- 33C: #194 - the QUICKIESTORE path actually builds #Quickie.
-- A stub @QuickieExecSql shaped like sp_QuickieStore output reaches the
-- builder without sp_QuickieStore being installed. Before the fix this
-- raised Msg 208, Invalid object name 'sys.sp_describe_first_result_set'.
------------------------------------------------------------------------
RAISERROR(N'Test 33C: QUICKIESTORE builds #Quickie (#194)...', 10, 1) WITH NOWAIT;

DECLARE @err33c integer = 0, @msg33c nvarchar(400) = N'';
BEGIN TRY
    EXEC dbo.sp_HeapDoctor
        @Databases      = N'HeapDoctorTest',
        @CpuSource      = N'QUICKIESTORE',
        @QuickieExecSql = N'SELECT CONVERT(bigint,1) AS plan_id, CONVERT(bigint,1000) AS avg_cpu_time;',
        @PlanOnly       = 1;
END TRY
BEGIN CATCH
    SET @err33c = ERROR_NUMBER();
    SET @msg33c = LEFT(ERROR_MESSAGE(), 300);
END CATCH

IF @err33c = 208
    RAISERROR(N'  FAIL 33C: Msg 208 - the invalid object name is still there.', 10, 1) WITH NOWAIT;
ELSE IF @err33c = 0
    RAISERROR(N'  PASS 33C: QUICKIESTORE path completed without error.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @m33c nvarchar(500) = N'  FAIL 33C: unexpected error ' + CONVERT(nvarchar(10), @err33c) + N': ' + @msg33c;
    RAISERROR(@m33c, 10, 1) WITH NOWAIT;
END
GO
/*#endregion*/

/*#region 33D*/
------------------------------------------------------------------------
-- 33D: #194 - an unresolvable @QuickieExecSql explains itself.
-- Previously this surfaced only as "returned no columns", which does not
-- say WHY. The underlying describe error should reach the operator.
------------------------------------------------------------------------
RAISERROR(N'Test 33D: unresolvable @QuickieExecSql reports the reason (#194)...', 10, 1) WITH NOWAIT;

DECLARE @err33d integer = 0, @msg33d nvarchar(600) = N'';
BEGIN TRY
    EXEC dbo.sp_HeapDoctor
        @Databases      = N'HeapDoctorTest',
        @CpuSource      = N'QUICKIESTORE',
        @QuickieExecSql = N'EXEC dbo.sp_QuickieStore_DoesNotExist;',
        @PlanOnly       = 1;
END TRY
BEGIN CATCH
    SET @err33d = ERROR_NUMBER();
    SET @msg33d = LEFT(ERROR_MESSAGE(), 500);
END CATCH

IF @err33d <> 0 AND (@msg33d LIKE N'%sp_QuickieStore_DoesNotExist%' OR @msg33d LIKE N'%Could not find%')
    RAISERROR(N'  PASS 33D: failure names the unresolvable object.', 10, 1) WITH NOWAIT;
ELSE IF @err33d <> 0
BEGIN
    DECLARE @m33d nvarchar(700) = N'  FAIL 33D: errored but did not name the cause: ' + @msg33d;
    RAISERROR(@m33d, 10, 1) WITH NOWAIT;
END
ELSE
    RAISERROR(N'  FAIL 33D: a nonexistent proc in @QuickieExecSql did not raise an error.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 33V*/
------------------------------------------------------------------------
-- 33V: Version check
------------------------------------------------------------------------
RAISERROR(N'Test 33V: Version check...', 10, 1) WITH NOWAIT;

DECLARE @ver33 nvarchar(20);
EXEC master.sys.sp_executesql
    N'SELECT @v = CONVERT(nvarchar(20),
        SUBSTRING(definition,
                  CHARINDEX(N''@Version nvarchar(20) = N'''''', definition) + 25, 14))
      FROM sys.sql_modules WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'');',
    N'@v nvarchar(20) OUTPUT', @v = @ver33 OUTPUT;

IF @ver33 LIKE N'%2026.07.31.3%'
    RAISERROR(N'  PASS 33V: Version is 2026.07.31.3.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 33V: Version is %s (expected 2026.07.31.3).', 10, 1, @ver33) WITH NOWAIT;
GO
/*#endregion*/

/*#region 33-SUMMARY*/
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'=== Batch 33 tests complete. Review results above. ===', 10, 1) WITH NOWAIT;
GO
/*#endregion*/
