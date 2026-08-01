/*
sp_HeapDoctor Test Harness - structural severity tiers (#185)

Tests:
  36A - No structural signal, modest footprint            -> NONE
  36B - Structural signal, modest footprint               -> CAUTIONARY  [the core criterion]
  36C - CI swap path isolated (LOCK_ESCALATION = AUTO)    -> CAUTIONARY
  36D - Plan breadth isolated (@PlanCountWarnThreshold=1) -> CAUTIONARY
  36E - warning_severity populated for EVERY target
  36F - Footprint never de-escalates a structural signal
  36G - Tier thresholds and all four tiers exist in the decision
  36H - Advisories stay at RAISERROR severity 10 (never 16)

  -- Version --
  36V - Version matches dbo.ExpectedVersion

FIXTURE NOTE: every other heap defaults to LOCK_ESCALATION = TABLE, which is
itself a structural signal, so they all qualify and cannot isolate anything.
HeapPlainAuto and HeapCiSwapAuto use AUTO to remove that signal.

NOT COVERED LIVE: the >1024 MB footprint thresholds that separate INFORMATIONAL
from CAUTIONARY/SEVERE. Building a 1 GB heap is impractical here, so 36G asserts
the decision structurally while 36F proves the property that actually matters --
footprint can escalate but never de-escalate.

Prerequisites: Run 01_setup_test_data.sql first.
Run with: sqlcmd -S YourServer -U sa -P YourPassword -d HeapDoctorTest -i 36_test_v0731d.sql
*/

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE [HeapDoctorTest];
GO

RAISERROR(N'=== Batch 36: (#185 structural severity tiers) ===', 10, 1) WITH NOWAIT;

/*#region 36A*/
RAISERROR(N'Test 36A: no structural signal -> NONE (#185)...', 10, 1) WITH NOWAIT;

SELECT * INTO #R36a FROM dbo.ResultsTemplate WHERE 1 = 0;
INSERT INTO #R36a
EXEC dbo.sp_HeapDoctor @Databases = N'HeapDoctorTest', @CpuSource = N'NONE', @PlanOnly = 1;

DECLARE @sev36a varchar(16) = (SELECT TOP (1) warning_severity FROM #R36a WHERE table_name = N'HeapPlainAuto');
IF @sev36a = 'NONE'
    RAISERROR(N'  PASS 36A: HeapPlainAuto (AUTO escalation, plain heap) is NONE.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 36A: expected NONE, got %s.', 10, 1, @sev36a) WITH NOWAIT;
GO
/*#endregion*/

/*#region 36B*/
------------------------------------------------------------------------
-- 36B: THE criterion this issue exists for. HeapA is ~21 MB -- far below
-- any footprint threshold -- but has LOCK_ESCALATION = TABLE. Under the old
-- footprint-centric boundary it stayed silent purely because it was small.
------------------------------------------------------------------------
RAISERROR(N'Test 36B: structural signal on a modest heap -> CAUTIONARY (#185)...', 10, 1) WITH NOWAIT;

DECLARE @sev36b varchar(16) = (SELECT TOP (1) warning_severity FROM #R36a WHERE table_name = N'HeapA');
DECLARE @size36b decimal(18,2) = (SELECT TOP (1) size_mb FROM #R36a WHERE table_name = N'HeapA');

IF @sev36b = 'CAUTIONARY' AND @size36b < 1024
    RAISERROR(N'  PASS 36B: a modest heap with a structural signal warns at CAUTIONARY.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @m36b nvarchar(300) = N'  FAIL 36B: severity=' + ISNULL(@sev36b, N'NULL')
        + N' size_mb=' + ISNULL(CONVERT(nvarchar(20), @size36b), N'NULL')
        + N' (expected CAUTIONARY on a sub-1024 MB heap).';
    RAISERROR(@m36b, 10, 1) WITH NOWAIT;
END
GO
/*#endregion*/

/*#region 36E*/
RAISERROR(N'Test 36E: warning_severity populated for every target (#185)...', 10, 1) WITH NOWAIT;

DECLARE @null36 integer = (SELECT COUNT_BIG(*) FROM #R36a WHERE warning_severity IS NULL);
IF @null36 = 0
    RAISERROR(N'  PASS 36E: every target has a severity tier.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 36E: %d target(s) have NULL warning_severity.', 10, 1, @null36) WITH NOWAIT;
GO
/*#endregion*/

/*#region 36F*/
------------------------------------------------------------------------
-- 36F: footprint may escalate but must never de-escalate. Any target with a
-- structural signal must be at least CAUTIONARY, whatever its size.
------------------------------------------------------------------------
RAISERROR(N'Test 36F: footprint never de-escalates a structural signal (#185)...', 10, 1) WITH NOWAIT;

DECLARE @bad36f integer =
(
    SELECT COUNT_BIG(*)
    FROM #R36a
    WHERE (lock_escalation = 'TABLE' OR action_chosen = 'CI_SWAP_ONLINE')
      AND warning_severity IN ('NONE', 'INFORMATIONAL')
);

IF @bad36f = 0
    RAISERROR(N'  PASS 36F: no structurally-flagged target sits below CAUTIONARY.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 36F: %d structurally-flagged target(s) below CAUTIONARY.', 10, 1, @bad36f) WITH NOWAIT;

IF OBJECT_ID('tempdb..#R36a') IS NOT NULL DROP TABLE #R36a;
GO
/*#endregion*/

/*#region 36C*/
------------------------------------------------------------------------
-- 36C: the CI swap signal alone. HeapCiSwapAuto has AUTO escalation, so the
-- only qualifying signal is the chosen action.
------------------------------------------------------------------------
RAISERROR(N'Test 36C: CI swap path alone -> CAUTIONARY (#185)...', 10, 1) WITH NOWAIT;

SELECT * INTO #R36c FROM dbo.ResultsTemplate WHERE 1 = 0;
INSERT INTO #R36c
EXEC dbo.sp_HeapDoctor
    @Databases    = N'HeapDoctorTest',
    @Tables       = N'dbo.HeapCiSwapAuto',
    @CpuSource    = N'NONE',
    @PlanOnly     = 1,
    @AllowCiSwap  = 1,
    @PreferCiSwap = 1;

DECLARE @act36c varchar(32) = (SELECT TOP (1) action_chosen FROM #R36c);
DECLARE @sev36c varchar(16) = (SELECT TOP (1) warning_severity FROM #R36c);
DECLARE @esc36c varchar(10) = (SELECT TOP (1) lock_escalation FROM #R36c);

IF @act36c = 'CI_SWAP_ONLINE' AND @esc36c = 'AUTO' AND @sev36c = 'CAUTIONARY'
    RAISERROR(N'  PASS 36C: CI swap alone raises the tier to CAUTIONARY.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @m36c nvarchar(300) = N'  FAIL 36C: action=' + ISNULL(@act36c, N'NULL')
        + N' escalation=' + ISNULL(@esc36c, N'NULL')
        + N' severity=' + ISNULL(@sev36c, N'NULL')
        + N' (expected CI_SWAP_ONLINE / AUTO / CAUTIONARY).';
    RAISERROR(@m36c, 10, 1) WITH NOWAIT;
END

IF OBJECT_ID('tempdb..#R36c') IS NOT NULL DROP TABLE #R36c;
GO
/*#endregion*/

/*#region 36D*/
------------------------------------------------------------------------
-- 36D: the plan-breadth signal alone. @PlanCountWarnThreshold = 1 makes any
-- target with a Query Store plan qualify, on a heap with AUTO escalation.
------------------------------------------------------------------------
RAISERROR(N'Test 36D: plan breadth alone -> CAUTIONARY (#185)...', 10, 1) WITH NOWAIT;

DECLARE @sink36 integer;
SELECT @sink36 = COUNT_BIG(*) FROM dbo.HeapPlainAuto WHERE Padding LIKE '%X%';
EXEC sys.sp_query_store_flush_db;

SELECT * INTO #R36d FROM dbo.ResultsTemplate WHERE 1 = 0;
INSERT INTO #R36d
EXEC dbo.sp_HeapDoctor
    @Databases              = N'HeapDoctorTest',
    @Tables                 = N'dbo.HeapPlainAuto',
    @CpuSource              = N'QUERY_STORE',
    @PlanOnly               = 1,
    @PlanCountWarnThreshold = 1;

DECLARE @plans36 integer = (SELECT TOP (1) qs_plan_count FROM #R36d);
DECLARE @sev36d varchar(16) = (SELECT TOP (1) warning_severity FROM #R36d);

IF @plans36 >= 1 AND @sev36d = 'CAUTIONARY'
    RAISERROR(N'  PASS 36D: plan breadth alone raises the tier to CAUTIONARY.', 10, 1) WITH NOWAIT;
ELSE IF @plans36 IS NULL OR @plans36 = 0
    RAISERROR(N'  FAIL 36D: no Query Store plans attributed to the heap, so the signal was not exercised.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 36D: qs_plan_count=%d but severity is not CAUTIONARY.', 10, 1, @plans36) WITH NOWAIT;

IF OBJECT_ID('tempdb..#R36d') IS NOT NULL DROP TABLE #R36d;
GO
/*#endregion*/

/*#region 36G*/
RAISERROR(N'Test 36G: all four tiers and the 1024 MB thresholds exist (#185)...', 10, 1) WITH NOWAIT;

DECLARE @ok36g bit = 0;
EXEC master.sys.sp_executesql
    N'IF EXISTS (
        SELECT 1 FROM sys.sql_modules
        WHERE object_id = OBJECT_ID(N''dbo.sp_HeapDoctor'')
          AND definition LIKE N''%SEVERE%''
          AND definition LIKE N''%CAUTIONARY%''
          AND definition LIKE N''%INFORMATIONAL%''
          AND definition LIKE N''%1024%''
    ) SET @out = 1;',
    N'@out bit OUTPUT', @out = @ok36g OUTPUT;

IF @ok36g = 1
    RAISERROR(N'  PASS 36G: tier decision contains all tiers and the footprint thresholds.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 36G: tier decision is incomplete.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 36H*/
------------------------------------------------------------------------
-- 36H: severity 16 turns an advisory into a batch-aborting error that
-- TRY/CATCH can swallow and that fails SQL Agent steps. The tier is carried
-- in the message text, not the RAISERROR severity.
------------------------------------------------------------------------
RAISERROR(N'Test 36H: the structural advisory stays at severity 10 (#185)...', 10, 1) WITH NOWAIT;

/*
Asserted behaviourally rather than by pattern-matching the module text. A LIKE
spanning "operationally delicate" to "16, 1" matches any later RAISERROR in the
procedure and is a false positive by construction.

Severity 16 aborts the batch and is catchable, so executing a rebuild on a
CAUTIONARY target and observing no error is direct evidence the advisory is
informational. HeapA carries LOCK_ESCALATION = TABLE, so the advisory fires.
*/
TRUNCATE TABLE dbo.HeapA;
;WITH N AS (SELECT n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects)
INSERT dbo.HeapA (ID, Padding, MoreData)
SELECT TOP (20000) n, REPLICATE('S', 10), NULL FROM N;
UPDATE dbo.HeapA SET Padding = REPLICATE('X', 3000), MoreData = REPLICATE('Y', 3000) WHERE ID <= 15000;

DECLARE @err36h integer = 0, @found36h integer, @succ36h integer;
BEGIN TRY
    EXEC dbo.sp_HeapDoctor
        @Databases    = N'HeapDoctorTest',
        @Tables       = N'dbo.HeapA',
        @CpuSource    = N'NONE',
        @PlanOnly     = 0,
        @TargetsFound = @found36h OUTPUT,
        @Succeeded    = @succ36h  OUTPUT;
END TRY
BEGIN CATCH
    SET @err36h = ERROR_NUMBER();
END CATCH

IF @err36h = 0 AND @found36h >= 1 AND @succ36h >= 1
    RAISERROR(N'  PASS 36H: the advisory fired on a CAUTIONARY target without aborting the run.', 10, 1) WITH NOWAIT;
ELSE
BEGIN
    DECLARE @m36h nvarchar(300) = N'  FAIL 36H: err=' + CONVERT(nvarchar(10), @err36h)
        + N' targets=' + ISNULL(CONVERT(nvarchar(10), @found36h), N'NULL')
        + N' succeeded=' + ISNULL(CONVERT(nvarchar(10), @succ36h), N'NULL')
        + N' (a severity-16 advisory would abort here).';
    RAISERROR(@m36h, 10, 1) WITH NOWAIT;
END
GO
/*#endregion*/

/*#region 36V*/
RAISERROR(N'Test 36V: Version check...', 10, 1) WITH NOWAIT;

SELECT * INTO #R36v FROM dbo.ResultsTemplate WHERE 1 = 0;
INSERT INTO #R36v
EXEC dbo.sp_HeapDoctor @Databases = N'HeapDoctorTest', @CpuSource = N'NONE', @PlanOnly = 1;

DECLARE @ver36 nvarchar(20) = (SELECT TOP (1) version FROM #R36v);
IF @ver36 = (SELECT version FROM dbo.ExpectedVersion)
    RAISERROR(N'  PASS 36V: Version matches dbo.ExpectedVersion.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 36V: Version is %s and does not match dbo.ExpectedVersion.', 10, 1, @ver36) WITH NOWAIT;

IF OBJECT_ID('tempdb..#R36v') IS NOT NULL DROP TABLE #R36v;
GO
/*#endregion*/

/*#region 36-SUMMARY*/
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'=== Batch 36 tests complete. Review results above. ===', 10, 1) WITH NOWAIT;
GO
/*#endregion*/
