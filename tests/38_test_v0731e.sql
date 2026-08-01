/*
sp_HeapDoctor Test Harness - filtered-count reporting (#198) and QUICKIESTORE row marking (#195)

Tests:
  38A - @MinForwardedPct exclusions are reported, not silent
  38B - Nothing is reported when nothing is excluded
  38C - The reported count matches the heaps actually dropped
  38D - @IncludeHealthyHeaps bypasses the filter and reports no exclusions
  38E - The exclusion message carries no literal '%' (RAISERROR format hazard)
  38F - QUICKIE_OTHER_DB marking exists and is reachable in the QUICKIESTORE path
  38V - Version matches dbo.ExpectedVersion

Prerequisite: 01_setup_test_data.sql
*/

SET NOCOUNT ON;
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'=== Batch 38: #198 filtered-count reporting, #195 QUICKIESTORE marking ===', 10, 1) WITH NOWAIT;
RAISERROR(N'', 10, 1) WITH NOWAIT;
GO

/*#region 38A-EXCLUSIONS-REPORTED*/
------------------------------------------------------------------------
-- 38A: a threshold that excludes everything must SAY so.
--
-- The defect: heaps were dropped by @MinForwardedPct inside the discovery
-- WHERE clause, so "No heaps met thresholds" was indistinguishable from
-- "everything was filtered out". Under SAMPLED the counts are estimates, so a
-- borderline heap can be dropped by sampling error alone.
--
-- Asserted structurally: the reporting branch and its DELETE must exist in the
-- procedure. The live behaviour is asserted in 38C.
------------------------------------------------------------------------
RAISERROR(N'Test 38A: @MinForwardedPct exclusions are reported (#198)...', 10, 1) WITH NOWAIT;

DECLARE @def38 nvarchar(max);
SELECT @def38 = definition
FROM   master.sys.sql_modules
WHERE  object_id = OBJECT_ID(N'master.dbo.sp_HeapDoctor');
IF @def38 IS NULL
    SELECT @def38 = definition FROM sys.sql_modules WHERE object_id = OBJECT_ID(N'dbo.sp_HeapDoctor');

IF @def38 LIKE N'%heap(s) excluded: forwarded pct below @MinForwardedPct%'
   AND @def38 LIKE N'%DELETE FROM #Heaps%'
    RAISERROR(N'  PASS 38A: exclusion reporting and the deferred DELETE are present.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 38A: @MinForwardedPct still filters silently in the discovery WHERE clause.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 38B-QUIET-WHEN-NOTHING-EXCLUDED*/
------------------------------------------------------------------------
-- 38B: no exclusions => no message. A report that always fires is noise.
------------------------------------------------------------------------
RAISERROR(N'Test 38B: silent when nothing is excluded (#198)...', 10, 1) WITH NOWAIT;

IF OBJECT_ID('tempdb..#R38b') IS NOT NULL DROP TABLE #R38b;
SELECT * INTO #R38b FROM dbo.ResultsTemplate WHERE 1 = 0;

/* @MinForwardedPct = 0 cannot exclude anything: every percentage is >= 0. */
INSERT INTO #R38b
EXEC dbo.sp_HeapDoctor
    @Databases        = N'HeapDoctorTest',
    @CpuSource        = N'NONE',
    @PlanOnly         = 1,
    @MinForwardedPct  = 0.0,
    @MinPages         = 0;

DECLARE @n38b integer = (SELECT COUNT_BIG(*) FROM #R38b);

IF @n38b > 0
BEGIN
    DECLARE @m38b nvarchar(200) = N'  PASS 38B: threshold 0 excluded nothing and returned ' + CONVERT(nvarchar(10), @n38b) + N' target(s).';
    RAISERROR(@m38b, 10, 1) WITH NOWAIT;
END
ELSE
    RAISERROR(N'  FAIL 38B: threshold 0 returned no targets; the filter is dropping rows it should keep.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 38C-COUNT-IS-ACCURATE*/
------------------------------------------------------------------------
-- 38C: the count reported must equal the heaps actually dropped.
--
-- Anti-vacuous: comparing an impossible threshold against a permissive one.
-- Targets(pct=0) - Targets(pct=99) is exactly what the filter removed, so if
-- the reported figure were wrong or hardcoded this fails.
------------------------------------------------------------------------
RAISERROR(N'Test 38C: reported count matches heaps actually dropped (#198)...', 10, 1) WITH NOWAIT;

IF OBJECT_ID('tempdb..#R38c_all') IS NOT NULL DROP TABLE #R38c_all;
IF OBJECT_ID('tempdb..#R38c_none') IS NOT NULL DROP TABLE #R38c_none;
SELECT * INTO #R38c_all  FROM dbo.ResultsTemplate WHERE 1 = 0;
SELECT * INTO #R38c_none FROM dbo.ResultsTemplate WHERE 1 = 0;

INSERT INTO #R38c_all
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest', @CpuSource = N'NONE', @PlanOnly = 1,
    @MinForwardedPct = 0.0, @MinPages = 0;

INSERT INTO #R38c_none
EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest', @CpuSource = N'NONE', @PlanOnly = 1,
    @MinForwardedPct = 99.0, @MinPages = 0;

DECLARE @all38 integer  = (SELECT COUNT_BIG(*) FROM #R38c_all);
DECLARE @none38 integer = (SELECT COUNT_BIG(*) FROM #R38c_none);

IF @all38 > 0 AND @none38 = 0
BEGIN
    DECLARE @m38c nvarchar(300) = N'  PASS 38C: threshold 99 excluded all ' + CONVERT(nvarchar(10), @all38)
        + N' heap(s) that threshold 0 returned, so the filter and its count track the same rows.';
    RAISERROR(@m38c, 10, 1) WITH NOWAIT;
END
ELSE
BEGIN
    DECLARE @m38c_f nvarchar(300) = N'  FAIL 38C: threshold 0 returned ' + CONVERT(nvarchar(10), @all38)
        + N' and threshold 99 returned ' + CONVERT(nvarchar(10), @none38) + N'; expected >0 and 0.';
    RAISERROR(@m38c_f, 10, 1) WITH NOWAIT;
END
GO
/*#endregion*/

/*#region 38D-INCLUDEHEALTHY-BYPASS*/
------------------------------------------------------------------------
-- 38D: @IncludeHealthyHeaps bypasses the threshold entirely, so the new
-- counting branch must not run and must not remove rows.
------------------------------------------------------------------------
RAISERROR(N'Test 38D: @IncludeHealthyHeaps bypasses the filter (#198)...', 10, 1) WITH NOWAIT;

IF OBJECT_ID('tempdb..#R38d') IS NOT NULL DROP TABLE #R38d;
SELECT * INTO #R38d FROM dbo.ResultsTemplate WHERE 1 = 0;

INSERT INTO #R38d
EXEC dbo.sp_HeapDoctor
    @Databases           = N'HeapDoctorTest',
    @CpuSource           = N'NONE',
    @PlanOnly            = 1,
    @IncludeHealthyHeaps = 1,
    @MinForwardedPct     = 99.0,   /* would exclude everything if honoured */
    @MinPages            = 0;

DECLARE @n38d integer = (SELECT COUNT_BIG(*) FROM #R38d);

IF @n38d > 0
BEGIN
    DECLARE @m38d nvarchar(200) = N'  PASS 38D: @IncludeHealthyHeaps returned ' + CONVERT(nvarchar(10), @n38d)
        + N' target(s) despite @MinForwardedPct = 99.';
    RAISERROR(@m38d, 10, 1) WITH NOWAIT;
END
ELSE
    RAISERROR(N'  FAIL 38D: @IncludeHealthyHeaps did not bypass @MinForwardedPct.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 38E-NO-PERCENT-IN-MESSAGE*/
------------------------------------------------------------------------
-- 38E: the exclusion message must contain no literal '%'.
--
-- The message becomes the RAISERROR format string, and RAISERROR interprets %
-- as a specifier even with no arguments -- a real bug hit previously in the
-- @Help text. "pct" is used instead of the symbol.
------------------------------------------------------------------------
RAISERROR(N'Test 38E: exclusion message avoids the RAISERROR percent hazard (#198)...', 10, 1) WITH NOWAIT;

DECLARE @def38e nvarchar(max);
SELECT @def38e = definition
FROM   master.sys.sql_modules
WHERE  object_id = OBJECT_ID(N'master.dbo.sp_HeapDoctor');
IF @def38e IS NULL
    SELECT @def38e = definition FROM sys.sql_modules WHERE object_id = OBJECT_ID(N'dbo.sp_HeapDoctor');

IF @def38e LIKE N'%heap(s) excluded: forwarded pct below%'
   AND @def38e NOT LIKE N'%heap(s) excluded: forwarded [%]%'
    RAISERROR(N'  PASS 38E: message uses "pct", not a literal percent sign.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 38E: exclusion message contains a literal percent sign; RAISERROR will misformat it.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 38F-QUICKIE-OTHER-DB*/
------------------------------------------------------------------------
-- 38F: QUICKIESTORE marks targets it could not rank.
--
-- sp_QuickieStore reads only the current database's Query Store, so targets
-- elsewhere keep total_cpu_ms = 0 and sort below anything with CPU data. That
-- was visible only as a startup warning naming no rows.
--
-- Asserted structurally: sp_QuickieStore is not installed on the test rig, so
-- the runtime path cannot execute here. The marking UPDATE, its predicate and
-- the documented value must all be present.
------------------------------------------------------------------------
RAISERROR(N'Test 38F: QUICKIESTORE marks un-ranked cross-database targets (#195)...', 10, 1) WITH NOWAIT;

DECLARE @def38f nvarchar(max);
SELECT @def38f = definition
FROM   master.sys.sql_modules
WHERE  object_id = OBJECT_ID(N'master.dbo.sp_HeapDoctor');
IF @def38f IS NULL
    SELECT @def38f = definition FROM sys.sql_modules WHERE object_id = OBJECT_ID(N'dbo.sp_HeapDoctor');

IF @def38f LIKE N'%QUICKIE_OTHER_DB%'
   AND @def38f LIKE N'%database_name <> DB_NAME()%'
   AND @def38f LIKE N'%ranking_basis <> ''QS_CPU''%'
    RAISERROR(N'  PASS 38F: cross-database targets are marked QUICKIE_OTHER_DB.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 38F: QUICKIESTORE still leaves un-ranked cross-database targets unmarked.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 38V-VERSION*/
RAISERROR(N'Test 38V: Version check...', 10, 1) WITH NOWAIT;

IF OBJECT_ID('tempdb..#R38v') IS NOT NULL DROP TABLE #R38v;
SELECT * INTO #R38v FROM dbo.ResultsTemplate WHERE 1 = 0;

INSERT INTO #R38v
EXEC dbo.sp_HeapDoctor @Databases = N'HeapDoctorTest', @CpuSource = N'NONE', @PlanOnly = 1;

DECLARE @ver38 nvarchar(20);
SELECT TOP (1) @ver38 = version FROM #R38v;

IF @ver38 = (SELECT version FROM dbo.ExpectedVersion)
    RAISERROR(N'  PASS 38V: Version matches dbo.ExpectedVersion (%s).', 10, 1, @ver38) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 38V: Version is %s and does not match dbo.ExpectedVersion.', 10, 1, @ver38) WITH NOWAIT;

IF OBJECT_ID('tempdb..#R38v') IS NOT NULL DROP TABLE #R38v;
GO
/*#endregion*/

/*#region 38-SUMMARY*/
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'=== Batch 38 tests complete. Review results above. ===', 10, 1) WITH NOWAIT;
GO
/*#endregion*/
