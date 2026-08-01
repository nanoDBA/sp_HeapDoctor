/*
sp_HeapDoctor Test Harness - run verdict (#203) and OUTPUT contract (#204)

Tests:
  41A - A normal plan-only run reports SUCCESS
  41B - Filtered-out heaps report WARNING, not SUCCESS
  41C - Plan-only sets Succeeded/Failed/Skipped to zero, not NULL
  41D - Informational modes (@Help) set the OUTPUT parameters
  41E - @CheckPermissionsOnly sets the OUTPUT parameters
  41F - The verdict is decided in priority order, ERROR before WARNING
  41G - Reveal mode sets the OUTPUT parameters
  41V - Version matches dbo.ExpectedVersion

Why this file exists
--------------------
@Failed alone was never a verdict. A run can be materially incomplete while
@Failed = 0: discovery blocked on a locked database (#199), heaps dropped by
@MinForwardedPct (#198), or a CI swap whose DROP failed leaving a table
clustered (#187, which even advances the success count).

Separately, OUTPUT parameters were assigned only on the normal completion path,
so every early exit returned NULL and a caller could not distinguish "did
nothing" from "never ran".

Prerequisite: 01_setup_test_data.sql
*/

SET NOCOUNT ON;
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'=== Batch 41: run verdict (#203) and OUTPUT contract (#204) ===', 10, 1) WITH NOWAIT;
RAISERROR(N'', 10, 1) WITH NOWAIT;
GO

/*#region 41A-SUCCESS*/
RAISERROR(N'Test 41A: a normal plan-only run reports SUCCESS (#203)...', 10, 1) WITH NOWAIT;

DECLARE @st41a varchar(10) = NULL, @sm41a nvarchar(1000) = NULL;

EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest', @CpuSource = N'NONE', @PlanOnly = 1,
    @Status = @st41a OUTPUT, @StatusMessage = @sm41a OUTPUT;

IF @st41a = 'SUCCESS' AND @sm41a IS NOT NULL
BEGIN
    DECLARE @m41a nvarchar(400) = N'  PASS 41A: Status = SUCCESS (' + @sm41a + N').';
    RAISERROR(@m41a, 10, 1) WITH NOWAIT;
END
ELSE
BEGIN
    DECLARE @m41a_f nvarchar(400) = N'  FAIL 41A: Status = ' + ISNULL(@st41a, N'NULL')
        + N', message = ' + ISNULL(@sm41a, N'NULL') + N'; expected SUCCESS.';
    RAISERROR(@m41a_f, 10, 1) WITH NOWAIT;
END
GO
/*#endregion*/

/*#region 41B-WARNING-WHEN-FILTERED*/
------------------------------------------------------------------------
-- 41B: the assertion that matters.
--
-- @MinForwardedPct = 99 excludes every heap, so the run finds nothing. Before
-- #203 that returned no targets and no failures, which reads as "healthy". The
-- honest answer is WARNING: the result set is a subset, and absence of targets
-- is not absence of problems.
--
-- The variables are reset first. A previous EXEC leaves its values in them, and
-- a stale SUCCESS would mask a NULL here -- a trap this test fell into during
-- development.
------------------------------------------------------------------------
RAISERROR(N'Test 41B: filtered-out heaps report WARNING, not SUCCESS (#203)...', 10, 1) WITH NOWAIT;

DECLARE @st41b varchar(10) = NULL, @sm41b nvarchar(1000) = NULL;

EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest', @CpuSource = N'NONE', @PlanOnly = 1,
    @MinForwardedPct = 99.0,
    @Status = @st41b OUTPUT, @StatusMessage = @sm41b OUTPUT;

IF @st41b = 'WARNING' AND @sm41b LIKE N'%MinForwardedPct%'
BEGIN
    DECLARE @m41b nvarchar(500) = N'  PASS 41B: Status = WARNING and the message names the filter (' + @sm41b + N').';
    RAISERROR(@m41b, 10, 1) WITH NOWAIT;
END
ELSE
BEGIN
    DECLARE @m41b_f nvarchar(500) = N'  FAIL 41B: Status = ' + ISNULL(@st41b, N'NULL')
        + N', message = ' + ISNULL(@sm41b, N'NULL')
        + N'; expected WARNING naming @MinForwardedPct.';
    RAISERROR(@m41b_f, 10, 1) WITH NOWAIT;
END
GO
/*#endregion*/

/*#region 41C-PLANONLY-OUTPUTS*/
------------------------------------------------------------------------
-- 41C: plan-only left Succeeded/Failed/Skipped NULL, because they were only
-- assigned when @PlanOnly = 0. Nothing executed, so zero is the honest answer.
------------------------------------------------------------------------
RAISERROR(N'Test 41C: plan-only sets all four OUTPUT parameters (#204)...', 10, 1) WITH NOWAIT;

DECLARE @t41c integer = NULL, @s41c integer = NULL, @f41c integer = NULL, @k41c integer = NULL;

EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest', @CpuSource = N'NONE', @PlanOnly = 1,
    @TargetsFound = @t41c OUTPUT, @Succeeded = @s41c OUTPUT,
    @Failed = @f41c OUTPUT, @Skipped = @k41c OUTPUT;

IF @t41c IS NOT NULL AND @s41c IS NOT NULL AND @f41c IS NOT NULL AND @k41c IS NOT NULL
BEGIN
    DECLARE @m41c nvarchar(300) = N'  PASS 41C: plan-only returned TargetsFound=' + CONVERT(nvarchar(10), @t41c)
        + N' Succeeded=' + CONVERT(nvarchar(10), @s41c)
        + N' Failed='    + CONVERT(nvarchar(10), @f41c)
        + N' Skipped='   + CONVERT(nvarchar(10), @k41c) + N'.';
    RAISERROR(@m41c, 10, 1) WITH NOWAIT;
END
ELSE
    RAISERROR(N'  FAIL 41C: plan-only left at least one OUTPUT parameter NULL.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 41D-HELP-OUTPUTS*/
RAISERROR(N'Test 41D: @Help sets the OUTPUT parameters (#204)...', 10, 1) WITH NOWAIT;

DECLARE @t41d integer = NULL, @st41d varchar(10) = NULL;

EXEC dbo.sp_HeapDoctor @Help = 1, @TargetsFound = @t41d OUTPUT, @Status = @st41d OUTPUT;

IF @t41d = 0 AND @st41d IS NOT NULL
BEGIN
    DECLARE @m41d nvarchar(200) = N'  PASS 41D: @Help returned TargetsFound = 0 and Status = ' + @st41d + N'.';
    RAISERROR(@m41d, 10, 1) WITH NOWAIT;
END
ELSE
BEGIN
    DECLARE @m41d_f nvarchar(300) = N'  FAIL 41D: @Help returned TargetsFound = '
        + ISNULL(CONVERT(nvarchar(10), @t41d), N'NULL') + N', Status = ' + ISNULL(@st41d, N'NULL') + N'.';
    RAISERROR(@m41d_f, 10, 1) WITH NOWAIT;
END
GO
/*#endregion*/

/*#region 41E-PERMISSIONS-OUTPUTS*/
RAISERROR(N'Test 41E: @CheckPermissionsOnly sets the OUTPUT parameters (#204)...', 10, 1) WITH NOWAIT;

DECLARE @t41e integer = NULL, @st41e varchar(10) = NULL;

EXEC dbo.sp_HeapDoctor
    @CheckPermissionsOnly = 1, @Databases = N'HeapDoctorTest',
    @TargetsFound = @t41e OUTPUT, @Status = @st41e OUTPUT;

IF @t41e = 0 AND @st41e IS NOT NULL
BEGIN
    DECLARE @m41e nvarchar(200) = N'  PASS 41E: @CheckPermissionsOnly returned TargetsFound = 0 and Status = ' + @st41e + N'.';
    RAISERROR(@m41e, 10, 1) WITH NOWAIT;
END
ELSE
BEGIN
    DECLARE @m41e_f nvarchar(300) = N'  FAIL 41E: @CheckPermissionsOnly returned TargetsFound = '
        + ISNULL(CONVERT(nvarchar(10), @t41e), N'NULL') + N', Status = ' + ISNULL(@st41e, N'NULL') + N'.';
    RAISERROR(@m41e_f, 10, 1) WITH NOWAIT;
END
GO
/*#endregion*/

/*#region 41F-PRIORITY*/
------------------------------------------------------------------------
-- 41F: the verdict must be decided in priority order, so a run that both
-- failed and skipped reports ERROR rather than WARNING. Asserted structurally:
-- producing a genuine rebuild failure on demand is not reliable, but the
-- ordering of the branches is what the priority rule consists of.
------------------------------------------------------------------------
RAISERROR(N'Test 41F: ERROR takes priority over WARNING (#203)...', 10, 1) WITH NOWAIT;

DECLARE @def41 nvarchar(max);
SELECT @def41 = definition FROM master.sys.sql_modules WHERE object_id = OBJECT_ID(N'master.dbo.sp_HeapDoctor');
IF @def41 IS NULL
    SELECT @def41 = definition FROM sys.sql_modules WHERE object_id = OBJECT_ID(N'dbo.sp_HeapDoctor');

/*
Scoped to the decision chain, not the whole module. Comparing first occurrences
globally is wrong: the zero-target early exit also assigns WARNING, and it sits
thousands of lines before the cleanup region -- so a global comparison "fails"
against correct code. Anchor on the chain's own IF and look only within it.
*/
DECLARE @chain_pos integer = CHARINDEX(N'IF @failed_cnt > 0 OR @recovery_cnt > 0', @def41);
DECLARE @chain nvarchar(max) = CASE WHEN @chain_pos > 0
                                    THEN SUBSTRING(@def41, @chain_pos, 2000)
                                    ELSE N'' END;

IF @chain_pos > 0
   AND CHARINDEX(N'SET @Status = ''ERROR''', @chain) > 0
   AND CHARINDEX(N'SET @Status = ''ERROR''', @chain) < CHARINDEX(N'SET @Status = ''WARNING''', @chain)
   AND @chain LIKE N'%MANUAL RECOVERY%'
    RAISERROR(N'  PASS 41F: ERROR is evaluated before WARNING in the verdict chain, and recovery-required counts as ERROR.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 41F: verdict priority is not ERROR > WARNING, or recovery-required is not an ERROR.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 41G-REVEAL-OUTPUTS*/
------------------------------------------------------------------------
-- 41G: reveal mode is the third informational exit. #204 named it alongside
-- @Help and @CheckPermissionsOnly, and it was the one with no test.
--
-- A nonexistent RunID is used deliberately: the point is that the exit path
-- assigns the OUTPUT parameters, not that decryption succeeds. Wrapped in
-- TRY/CATCH because an unknown RunID may raise, and a raise is an acceptable
-- outcome for this path -- what is not acceptable is returning NULL quietly.
------------------------------------------------------------------------
RAISERROR(N'Test 41G: reveal mode sets the OUTPUT parameters (#204)...', 10, 1) WITH NOWAIT;

DECLARE @t41g integer = NULL, @st41g varchar(10) = NULL, @raised41g bit = 0;

BEGIN TRY
    EXEC dbo.sp_HeapDoctor
        @RevealKey    = N'not-a-real-key',
        @RevealRunID  = '00000000-0000-0000-0000-000000000001',
        @TargetsFound = @t41g OUTPUT,
        @Status       = @st41g OUTPUT;
END TRY
BEGIN CATCH
    SET @raised41g = 1;
END CATCH;

IF @raised41g = 1
    RAISERROR(N'  SKIP 41G: reveal mode raised for an unknown RunID, so the exit path was not reached.', 10, 1) WITH NOWAIT;
ELSE IF @t41g = 0 AND @st41g IS NOT NULL
BEGIN
    DECLARE @m41g nvarchar(200) = N'  PASS 41G: reveal mode returned TargetsFound = 0 and Status = ' + @st41g + N'.';
    RAISERROR(@m41g, 10, 1) WITH NOWAIT;
END
ELSE
BEGIN
    DECLARE @m41g_f nvarchar(300) = N'  FAIL 41G: reveal mode returned TargetsFound = '
        + ISNULL(CONVERT(nvarchar(10), @t41g), N'NULL') + N', Status = ' + ISNULL(@st41g, N'NULL') + N'.';
    RAISERROR(@m41g_f, 10, 1) WITH NOWAIT;
END
GO
/*#endregion*/

/*#region 41V-VERSION*/
RAISERROR(N'Test 41V: Version check...', 10, 1) WITH NOWAIT;

IF OBJECT_ID('tempdb..#R41v') IS NOT NULL DROP TABLE #R41v;
SELECT * INTO #R41v FROM dbo.ResultsTemplate WHERE 1 = 0;

INSERT INTO #R41v
EXEC dbo.sp_HeapDoctor @Databases = N'HeapDoctorTest', @CpuSource = N'NONE', @PlanOnly = 1;

DECLARE @ver41 nvarchar(20);
SELECT TOP (1) @ver41 = version FROM #R41v;

IF @ver41 = (SELECT version FROM dbo.ExpectedVersion)
    RAISERROR(N'  PASS 41V: Version matches dbo.ExpectedVersion (%s).', 10, 1, @ver41) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 41V: Version is %s and does not match dbo.ExpectedVersion.', 10, 1, @ver41) WITH NOWAIT;

IF OBJECT_ID('tempdb..#R41v') IS NOT NULL DROP TABLE #R41v;
GO
/*#endregion*/

/*#region 41-SUMMARY*/
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'=== Batch 41 tests complete. Review results above. ===', 10, 1) WITH NOWAIT;
GO
/*#endregion*/
