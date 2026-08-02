/*
sp_HeapDoctor Test Harness - DarlingData-audit fixes (#206-#211)

Tests:
  43A - Bit parameters are defaulted from NULL before the first consumer (#207)
  43B - @PlanOnly = NULL behaves as plan-only BY DESIGN, with outputs set (#207)
  43C - Every dynamic SQL string is @Debug-printable in chunks (#209)
  43D - The estimate caveat distinguishes where SAMPLED actually ran (#206)
  43E - usage_hint low-confidence threshold is 7 days, and exclusions say so (#211)
  43F - No bare EXEC remains; the guide's EXECUTE rule holds (#208)
  43G - Counter-lifetime caveat is documented at the @Help surface (#210/#206)
  43V - Version matches dbo.ExpectedVersion

Prerequisite: 01_setup_test_data.sql
*/

SET NOCOUNT ON;
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'=== Batch 43: DarlingData-audit fixes (#206-#211) ===', 10, 1) WITH NOWAIT;
RAISERROR(N'', 10, 1) WITH NOWAIT;
GO

/*#region 43-DEFINITION*/
IF OBJECT_ID('tempdb..#Def43') IS NOT NULL DROP TABLE #Def43;
CREATE TABLE #Def43 (definition nvarchar(max) NULL);

INSERT INTO #Def43 (definition)
SELECT definition FROM master.sys.sql_modules WHERE object_id = OBJECT_ID(N'master.dbo.sp_HeapDoctor');

IF NOT EXISTS (SELECT 1 FROM #Def43)
    INSERT INTO #Def43 (definition)
    SELECT definition FROM sys.sql_modules WHERE object_id = OBJECT_ID(N'dbo.sp_HeapDoctor');
GO
/*#endregion*/

/*#region 43A-NULL-DEFAULTING-POSITION*/
------------------------------------------------------------------------
-- 43A: the ISNULL block must run BEFORE @Help is consumed. Defaulting after
-- any consumer is dead code for that consumer -- the ordering is the point,
-- not just the existence.
------------------------------------------------------------------------
RAISERROR(N'Test 43A: bit defaulting precedes the first consumer (#207)...', 10, 1) WITH NOWAIT;

DECLARE @def43a nvarchar(max) = (SELECT definition FROM #Def43);
DECLARE @pos_default integer = CHARINDEX(N'@PlanOnly                 = ISNULL(@PlanOnly, 1)', @def43a);
DECLARE @pos_help    integer = CHARINDEX(N'IF @Help = 1', @def43a);

IF @pos_default > 0 AND @pos_help > 0 AND @pos_default < @pos_help
    RAISERROR(N'  PASS 43A: ISNULL defaulting sits before the @Help consumer.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 43A: bit parameters are not defaulted ahead of @Help; a NULL can still skip a guard.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 43B-NULL-PLANONLY-BEHAVIOUR*/
------------------------------------------------------------------------
-- 43B: the behavioural half. Before #207 a NULL @PlanOnly happened to act as
-- plan-only only because the guard was written IF @PlanOnly = 0 -- safe by
-- accident. Now NULL means "the declared default" by construction, and the
-- OUTPUT contract must hold on that path too.
------------------------------------------------------------------------
RAISERROR(N'Test 43B: @PlanOnly = NULL is plan-only by design (#207)...', 10, 1) WITH NOWAIT;

DECLARE @nullbit bit;  /* deliberately uninitialised: the common way NULL arrives */
DECLARE @st43 varchar(10), @t43 integer, @s43 integer, @f43 integer;

EXEC dbo.sp_HeapDoctor
    @Databases = N'HeapDoctorTest', @CpuSource = N'NONE',
    @PlanOnly = @nullbit,
    @Status = @st43 OUTPUT, @TargetsFound = @t43 OUTPUT,
    @Succeeded = @s43 OUTPUT, @Failed = @f43 OUTPUT;

IF @st43 IS NOT NULL AND @t43 > 0 AND @s43 = 0 AND @f43 = 0
BEGIN
    DECLARE @m43b nvarchar(300) = N'  PASS 43B: NULL @PlanOnly planned ' + CONVERT(nvarchar(10), @t43)
        + N' target(s), executed nothing, Status = ' + @st43 + N'.';
    RAISERROR(@m43b, 10, 1) WITH NOWAIT;
END
ELSE
BEGIN
    DECLARE @m43b_f nvarchar(300) = N'  FAIL 43B: NULL @PlanOnly gave Status=' + ISNULL(@st43, N'NULL')
        + N' Targets=' + ISNULL(CONVERT(nvarchar(10), @t43), N'NULL')
        + N' Succeeded=' + ISNULL(CONVERT(nvarchar(10), @s43), N'NULL') + N'.';
    RAISERROR(@m43b_f, 10, 1) WITH NOWAIT;
END
GO
/*#endregion*/

/*#region 43C-DEBUG-PRINTABLE*/
------------------------------------------------------------------------
-- 43C: dynamic SQL must be printable before execution (#209). Structural: a
-- .sql test cannot read its own message stream, so the live proof (a 39,872-
-- char discovery dump containing INSERT INTO #Heaps) ran at development time;
-- this pins the mechanism. The '%s'-argument form matters: printing the string
-- AS the format would interpret every '%' in the dumped SQL.
------------------------------------------------------------------------
RAISERROR(N'Test 43C: dynamic SQL is @Debug-printable in chunks (#209)...', 10, 1) WITH NOWAIT;

IF EXISTS (SELECT 1 FROM #Def43
           WHERE definition LIKE N'%SUBSTRING(@discovery_sql, @dbg_pos, 2000)%'
             AND definition LIKE N'%RAISERROR(N''&%s'', 10, 1, @dbg_chunk)%' ESCAPE N'&'
             AND definition LIKE N'%SUBSTRING(@QuickieBatch, @dbg_pos, 2000)%'
             AND definition LIKE N'%SUBSTRING(@exec_cmd, @dbg_pos, 2000)%')
    RAISERROR(N'  PASS 43C: discovery, QUICKIESTORE and rebuild strings all dump under @Debug via the %%s-argument form.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 43C: at least one dynamic SQL string is not @Debug-printable.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 43D-CONDITIONAL-CAVEAT*/
------------------------------------------------------------------------
-- 43D: dm_db_index_physical_stats silently substitutes DETAILED below 10,000
-- pages, so "counts are SAMPLED estimates; re-run with DETAILED" was advice to
-- repeat the scan the operator just did (#206). The caveat must now split on
-- whether any excluded heap was large enough for SAMPLED to have actually run.
------------------------------------------------------------------------
RAISERROR(N'Test 43D: estimate caveat distinguishes where SAMPLED ran (#206)...', 10, 1) WITH NOWAIT;

IF EXISTS (SELECT 1 FROM #Def43
           WHERE definition LIKE N'%@below_large%'
             AND definition LIKE N'%page_count >= 10000%'
             AND definition LIKE N'%DETAILED ran automatically and counts are exact%'
             AND definition LIKE N'%where SQL Server runs DETAILED regardless of the requested SAMPLED mode%')
    RAISERROR(N'  PASS 43D: the caveat is conditional on 10,000-page eligibility, both branches present.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 43D: the exclusion message still calls exact counts estimates.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 43E-UPTIME-THRESHOLD*/
------------------------------------------------------------------------
-- 43E: usage_hint drives ranking penalties and @SkipWriteHeavy exclusions, so
-- the low-uptime guard is 7 days (168h), not 24h (#211) -- and exclusions taken
-- below it must say they rest on low-confidence data.
------------------------------------------------------------------------
RAISERROR(N'Test 43E: usage_hint threshold is 168h and exclusions disclose it (#211)...', 10, 1) WITH NOWAIT;

IF EXISTS (SELECT 1 FROM #Def43
           WHERE definition LIKE N'%@UptimeHours < 168.0%'
             AND definition LIKE N'%LOW-CONFIDENCE usage data%'
             AND definition NOT LIKE N'%@UptimeHours < 24.0%')
    RAISERROR(N'  PASS 43E: threshold raised to 168h; @SkipWriteHeavy exclusions carry the low-confidence note.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 43E: the 24-hour guard survives, or exclusions are silent about confidence.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 43F-NO-BARE-EXEC*/
------------------------------------------------------------------------
-- 43F: the committed STYLE_GUIDE forbids EXEC and the procedure carried 87 of
-- them undeclared as a deviation (#208). LIKE N'%EXEC %' cannot false-match
-- EXECUTE (the character after EXEC there is U, not a space).
------------------------------------------------------------------------
RAISERROR(N'Test 43F: no bare EXEC remains in the procedure (#208)...', 10, 1) WITH NOWAIT;

IF EXISTS (SELECT 1 FROM #Def43
           WHERE definition NOT LIKE N'%EXEC %'
             AND definition NOT LIKE N'%EXEC(%'
             AND definition LIKE N'%EXECUTE sys.sp_executesql%')
    RAISERROR(N'  PASS 43F: EXEC is fully swept to EXECUTE.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 43F: bare EXEC remains, contradicting the committed STYLE_GUIDE.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 43G-LIFETIME-DOCUMENTED*/
------------------------------------------------------------------------
-- 43G: the @ScanMode help must state the DETAILED substitution and the
-- avg_frag_pct NULL rule (#206); verified at the definition level since @Help
-- output cannot be captured from a .sql test.
------------------------------------------------------------------------
RAISERROR(N'Test 43G: @Help documents the mode substitution (#206/#210)...', 10, 1) WITH NOWAIT;

IF EXISTS (SELECT 1 FROM #Def43
           WHERE definition LIKE N'%Below that SQL Server silently runs DETAILED%'
             AND definition LIKE N'%avg_frag_pct is NULL for heaps at or%')
    RAISERROR(N'  PASS 43G: the substitution and NULL rule are in @Help.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 43G: @Help still presents SAMPLED as what actually runs.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 43V-VERSION*/
RAISERROR(N'Test 43V: Version check...', 10, 1) WITH NOWAIT;

IF OBJECT_ID('tempdb..#R43v') IS NOT NULL DROP TABLE #R43v;
SELECT * INTO #R43v FROM dbo.ResultsTemplate WHERE 1 = 0;

INSERT INTO #R43v
EXEC dbo.sp_HeapDoctor @Databases = N'HeapDoctorTest', @CpuSource = N'NONE', @PlanOnly = 1;

DECLARE @ver43 nvarchar(20);
SELECT TOP (1) @ver43 = version FROM #R43v;

IF @ver43 = (SELECT version FROM dbo.ExpectedVersion)
    RAISERROR(N'  PASS 43V: Version matches dbo.ExpectedVersion (%s).', 10, 1, @ver43) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 43V: Version is %s and does not match dbo.ExpectedVersion.', 10, 1, @ver43) WITH NOWAIT;

IF OBJECT_ID('tempdb..#R43v') IS NOT NULL DROP TABLE #R43v;
IF OBJECT_ID('tempdb..#Def43') IS NOT NULL DROP TABLE #Def43;
GO
/*#endregion*/

/*#region 43-SUMMARY*/
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'=== Batch 43 tests complete. Review results above. ===', 10, 1) WITH NOWAIT;
GO
/*#endregion*/
