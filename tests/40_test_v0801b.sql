/*
sp_HeapDoctor Test Harness - @LockTimeoutMs covers discovery (#199)

Tests:
  40A - Discovery emits SET LOCK_TIMEOUT when @LockTimeoutMs is set
  40B - A blocked scan (1222) is named, not reported as a generic error
  40C - Partial discovery is announced in those words
  40D - A pre-scan advisory fires even when @LockTimeoutMs is unset
  40E - The advisory is scoped to the heaps being scanned, not the whole database
  40F - OUTPUT parameters are set on the zero-target exit (sp_StatUpdate contract)
  40V - Version matches dbo.ExpectedVersion

Why these are structural
------------------------
The behaviour needs a second session holding a lock, which a single-session
sqlcmd file cannot arrange. tests/test_lock_timeout.sh does that and is the real
proof: it asserts discovery gives up in ~3s against a 40s exclusive blocker
(199B) and reports the run as partial (199C), and both go red in a control run
with a long timeout.

These assertions are the cheap regression net for the same code, so a refactor
that drops the timeout, the 1222 branch, or the advisory fails here even when
nobody runs the two-session script.

Prerequisite: 01_setup_test_data.sql
*/

SET NOCOUNT ON;
GO

RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'=== Batch 40: @LockTimeoutMs covers discovery (#199) ===', 10, 1) WITH NOWAIT;
RAISERROR(N'', 10, 1) WITH NOWAIT;
GO

/*#region 40-DEFINITION*/
IF OBJECT_ID('tempdb..#Def40') IS NOT NULL DROP TABLE #Def40;
CREATE TABLE #Def40 (definition nvarchar(max) NULL);

INSERT INTO #Def40 (definition)
SELECT definition FROM master.sys.sql_modules WHERE object_id = OBJECT_ID(N'master.dbo.sp_HeapDoctor');

IF NOT EXISTS (SELECT 1 FROM #Def40)
    INSERT INTO #Def40 (definition)
    SELECT definition FROM sys.sql_modules WHERE object_id = OBJECT_ID(N'dbo.sp_HeapDoctor');
GO
/*#endregion*/

/*#region 40A-DISCOVERY-TIMEOUT*/
------------------------------------------------------------------------
-- 40A: the discovery SQL must set LOCK_TIMEOUT.
--
-- Before #199 the timeout wrapped only the rebuild, so a 2s cap could produce a
-- 41s run: the scan blocked long before the rebuild was reached.
------------------------------------------------------------------------
RAISERROR(N'Test 40A: discovery emits SET LOCK_TIMEOUT (#199)...', 10, 1) WITH NOWAIT;

IF EXISTS (SELECT 1 FROM #Def40
           WHERE definition LIKE N'%bound the DISCOVERY wait%'
             AND definition LIKE N'%SET LOCK_TIMEOUT %+ CONVERT(nvarchar(20), @LockTimeoutMs)%')
    RAISERROR(N'  PASS 40A: discovery sets LOCK_TIMEOUT from @LockTimeoutMs.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 40A: discovery does not bound its lock wait; an exclusive lock will stall the scan.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 40B-1222-NAMED*/
------------------------------------------------------------------------
-- 40B: error 1222 out of discovery means "could not get a shared lock", not
-- "this database is broken". The generic wording sent operators looking for
-- corruption.
------------------------------------------------------------------------
RAISERROR(N'Test 40B: a blocked scan is named rather than reported generically (#199)...', 10, 1) WITH NOWAIT;

IF EXISTS (SELECT 1 FROM #Def40
           WHERE definition LIKE N'%ERROR_NUMBER() = 1222%'
             AND definition LIKE N'%BLOCKED scanning%')
    RAISERROR(N'  PASS 40B: 1222 is handled as a blocked scan with its own message.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 40B: a lock timeout during discovery is still reported as a generic scan error.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 40C-PARTIAL-ANNOUNCED*/
------------------------------------------------------------------------
-- 40C: a blocked scan makes the target list incomplete. That is a different
-- claim from "some database errored", and must be said plainly so a short
-- result set is never read as a clean bill of health.
------------------------------------------------------------------------
RAISERROR(N'Test 40C: partial discovery is announced (#199)...', 10, 1) WITH NOWAIT;

IF EXISTS (SELECT 1 FROM #Def40
           WHERE definition LIKE N'%DISCOVERY WAS PARTIAL%'
             AND definition LIKE N'%@discovery_blocked%')
    RAISERROR(N'  PASS 40C: partial discovery is announced separately from generic scan errors.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 40C: a partial scan is not distinguished from a complete one.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 40D-ADVISORY-WHEN-UNSET*/
------------------------------------------------------------------------
-- 40D: @LockTimeoutMs defaults to NULL, so by default the scan still waits
-- indefinitely. The pre-scan advisory is what stops a blocked run being
-- indistinguishable from a slow one in that case.
------------------------------------------------------------------------
RAISERROR(N'Test 40D: pre-scan advisory fires even with @LockTimeoutMs unset (#199)...', 10, 1) WITH NOWAIT;

IF EXISTS (SELECT 1 FROM #Def40
           WHERE definition LIKE N'%exclusively locked by another session%'
             AND definition LIKE N'%@LockTimeoutMs_param IS NULL%'
             AND definition LIKE N'%wait indefinitely%')
    RAISERROR(N'  PASS 40D: advisory names the unbounded-wait case explicitly.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 40D: with @LockTimeoutMs unset, a blocked scan is still silent.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 40E-ADVISORY-SCOPED*/
------------------------------------------------------------------------
-- 40E: the advisory joins #HeapObjects, so it reports only locks on heaps this
-- run will actually scan. An unscoped check would fire on unrelated activity
-- elsewhere in the database and become noise people learn to ignore.
------------------------------------------------------------------------
RAISERROR(N'Test 40E: advisory is scoped to the heaps being scanned (#199)...', 10, 1) WITH NOWAIT;

IF EXISTS (SELECT 1 FROM #Def40
           WHERE definition LIKE N'%dm_tran_locks%JOIN #HeapObjects%'
             AND definition LIKE N'%request_session_id <> @@SPID%')
    RAISERROR(N'  PASS 40E: advisory is restricted to scanned heaps and ignores this session.', 10, 1) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 40E: advisory is not scoped to the heaps being scanned; it will produce noise.', 10, 1) WITH NOWAIT;
GO
/*#endregion*/

/*#region 40F-OUTPUT-CONTRACT*/
------------------------------------------------------------------------
-- 40F: OUTPUT parameters are set on the zero-target exit.
--
-- They used to be assigned only on the normal completion path, so this early
-- return left all four NULL. A caller doing "IF @TargetsFound = 0" got NULL,
-- the comparison was never true, and "nothing needed rebuilding" was
-- indistinguishable from "the procedure never ran" -- the exact case a nightly
-- job against a healthy server hits every time.
--
-- Convention adopted from sp_StatUpdate (CONSISTENCY_GUIDELINES.md, "Output
-- Parameter Contract").
--
-- @MinForwardedPct = 99 guarantees the zero-target path is the one taken.
------------------------------------------------------------------------
RAISERROR(N'Test 40F: OUTPUT parameters set on the zero-target exit...', 10, 1) WITH NOWAIT;

DECLARE @t40 integer = NULL, @s40 integer = NULL, @f40 integer = NULL, @k40 integer = NULL;

EXEC dbo.sp_HeapDoctor
    @Databases       = N'HeapDoctorTest',
    @CpuSource       = N'NONE',
    @PlanOnly        = 1,
    @MinForwardedPct = 99.0,
    @TargetsFound    = @t40 OUTPUT,
    @Succeeded       = @s40 OUTPUT,
    @Failed          = @f40 OUTPUT,
    @Skipped         = @k40 OUTPUT;

IF @t40 IS NOT NULL AND @s40 IS NOT NULL AND @f40 IS NOT NULL AND @k40 IS NOT NULL
   AND @t40 = 0
BEGIN
    DECLARE @m40f nvarchar(200) = N'  PASS 40F: zero-target exit set all four OUTPUT parameters (TargetsFound = '
        + CONVERT(nvarchar(10), @t40) + N').';
    RAISERROR(@m40f, 10, 1) WITH NOWAIT;
END
ELSE
BEGIN
    DECLARE @m40f_f nvarchar(300) = N'  FAIL 40F: OUTPUT parameters after zero-target exit: TargetsFound='
        + ISNULL(CONVERT(nvarchar(10), @t40), N'NULL')
        + N' Succeeded=' + ISNULL(CONVERT(nvarchar(10), @s40), N'NULL')
        + N' Failed='    + ISNULL(CONVERT(nvarchar(10), @f40), N'NULL')
        + N' Skipped='   + ISNULL(CONVERT(nvarchar(10), @k40), N'NULL')
        + N'; expected all non-NULL with TargetsFound = 0.';
    RAISERROR(@m40f_f, 10, 1) WITH NOWAIT;
END
GO
/*#endregion*/

/*#region 40V-VERSION*/
RAISERROR(N'Test 40V: Version check...', 10, 1) WITH NOWAIT;

IF OBJECT_ID('tempdb..#R40v') IS NOT NULL DROP TABLE #R40v;
SELECT * INTO #R40v FROM dbo.ResultsTemplate WHERE 1 = 0;

INSERT INTO #R40v
EXEC dbo.sp_HeapDoctor @Databases = N'HeapDoctorTest', @CpuSource = N'NONE', @PlanOnly = 1;

DECLARE @ver40 nvarchar(20);
SELECT TOP (1) @ver40 = version FROM #R40v;

IF @ver40 = (SELECT version FROM dbo.ExpectedVersion)
    RAISERROR(N'  PASS 40V: Version matches dbo.ExpectedVersion (%s).', 10, 1, @ver40) WITH NOWAIT;
ELSE
    RAISERROR(N'  FAIL 40V: Version is %s and does not match dbo.ExpectedVersion.', 10, 1, @ver40) WITH NOWAIT;

IF OBJECT_ID('tempdb..#R40v') IS NOT NULL DROP TABLE #R40v;
IF OBJECT_ID('tempdb..#Def40') IS NOT NULL DROP TABLE #Def40;
GO
/*#endregion*/

/*#region 40-SUMMARY*/
RAISERROR(N'', 10, 1) WITH NOWAIT;
RAISERROR(N'=== Batch 40 tests complete. Review results above. ===', 10, 1) WITH NOWAIT;
GO
/*#endregion*/
